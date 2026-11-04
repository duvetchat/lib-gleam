//// The JavaScript counterpart of `libduvet/http/client`, `core.request` and
//// `session`: the same requests, tokens and renewal, as promises, because
//// `fetch` can't block the way the BEAM's transport does.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import libduvet/api_router
import libduvet/error.{type DuvetError}
import libduvet/http/core
import libduvet/http/send
import libduvet/http/sign_in.{type SignIn}
import libduvet/http/transport
import libduvet/model/decoding
import libduvet/model/rest as models

pub type Cell(a)

@external(javascript, "./rest_ffi.mjs", "new_cell")
fn new_cell(value: a) -> Cell(a)

@external(javascript, "./rest_ffi.mjs", "get_cell")
fn get(cell: Cell(a)) -> a

@external(javascript, "./rest_ffi.mjs", "set_cell")
fn set(cell: Cell(a), value: a) -> Nil

@external(javascript, "./rest_ffi.mjs", "exchange")
fn exchange(
  method: String,
  url: String,
  headers: List(#(String, String)),
  pieces: List(BitArray),
  timeout_ms: Int,
  on_progress: Option(fn(Int, Int) -> Nil),
) -> Promise(Result(transport.Response, send.SendError))

/// How long the space-command lists are kept: as `http/commands` keeps them.
const commands_ttl_ms = 300_000

pub opaque type RestClient {
  RestClient(
    router: api_router.ApiRouter,
    auth: core.AuthMode,
    timeout_ms: Int,
    tokens: Cell(#(String, String)),
    refreshing: Cell(Option(Promise(Result(SignIn, DuvetError)))),
    commands: Cell(Dict(String, #(Timestamp, models.SpaceCommands))),
  )
}

pub fn new(
  router: api_router.ApiRouter,
  token: String,
  session_token: String,
  timeout_ms: Int,
) -> RestClient {
  built(router, token, session_token, timeout_ms, core.Session)
}

pub fn new_bot(
  router: api_router.ApiRouter,
  token: String,
  timeout_ms: Int,
) -> RestClient {
  built(router, token, "", timeout_ms, core.Bot)
}

fn built(
  router: api_router.ApiRouter,
  token: String,
  session_token: String,
  timeout_ms: Int,
  auth: core.AuthMode,
) -> RestClient {
  RestClient(
    router: router,
    auth: auth,
    timeout_ms: timeout_ms,
    tokens: new_cell(#(token, session_token)),
    refreshing: new_cell(None),
    commands: new_cell(dict.new()),
  )
}

pub fn router(client: RestClient) -> api_router.ApiRouter {
  client.router
}

pub fn token(client: RestClient) -> String {
  get(client.tokens).0
}

pub fn session_token(client: RestClient) -> String {
  get(client.tokens).1
}

pub fn is_bot(client: RestClient) -> Bool {
  client.auth == core.Bot
}

/// The headers the gateway's upgrade carries.
pub fn auth_headers(client: RestClient) -> List(#(String, String)) {
  core.auth_headers(token(client), session_token(client), client.auth)
}

pub fn default_meta(client: RestClient) -> core.Meta(a) {
  core.Meta(
    query: [],
    renew: True,
    timeout: client.timeout_ms,
    on_progress: None,
    abort: None,
  )
}

/// Sends a request and fails unless it succeeds. Unless renewal is off, a 401
/// renews the session and sends the request once more, as `core.request` does.
pub fn request(
  client: RestClient,
  method: String,
  path: String,
  action: String,
  body: core.Body,
  meta: core.Meta(a),
) -> Promise(Result(transport.Response, DuvetError)) {
  let #(sent_token, sent_session) = get(client.tokens)
  use first <- promise.await(send_once(
    client,
    sent_token,
    sent_session,
    method,
    path,
    body,
    meta,
  ))
  case first {
    Error(failure) -> promise.resolve(Error(failure))
    Ok(response) ->
      case meta.renew && client.auth == core.Session && response.status == 401 {
        False -> promise.resolve(core.assert_ok(response, action))
        True -> {
          use renewed <- promise.await(renew(client, sent_token))
          case renewed {
            Error(_) -> promise.resolve(core.assert_ok(response, action))
            Ok(_) -> {
              let #(new_token, new_session) = get(client.tokens)
              use second <- promise.map(send_once(
                client,
                new_token,
                new_session,
                method,
                path,
                body,
                meta,
              ))
              case second {
                Error(failure) -> Error(failure)
                Ok(response) -> core.assert_ok(response, action)
              }
            }
          }
        }
      }
  }
}

fn send_once(
  client: RestClient,
  token: String,
  session_token: String,
  method: String,
  path: String,
  body: core.Body,
  meta: core.Meta(a),
) -> Promise(Result(transport.Response, DuvetError)) {
  let built =
    core.build(
      client.router,
      token,
      session_token,
      method,
      path,
      body,
      meta.query,
      client.auth,
    )
  exchange(
    built.method,
    built.url,
    built.headers,
    built.pieces,
    meta.timeout,
    meta.on_progress,
  )
  |> promise.map(from_send)
}

fn from_send(outcome: Result(a, send.SendError)) -> Result(a, DuvetError) {
  case outcome {
    Ok(value) -> Ok(value)
    Error(failure) -> Error(error.from_send_error(failure))
  }
}

// ---------------------------------------------------------------------------
// The session
// ---------------------------------------------------------------------------

fn renew(
  client: RestClient,
  sent_token: String,
) -> Promise(Result(Nil, DuvetError)) {
  let #(token, session_token) = get(client.tokens)
  case sent_token != token, session_token == "" {
    True, _ -> promise.resolve(Ok(Nil))
    False, True ->
      promise.resolve(
        Error(
          error.AuthError(error.AuthFailure(
            action: "refresh session",
            status_code: 401,
            body: None,
          )),
        ),
      )
    False, False ->
      refresh_session(client)
      |> promise.map(fn(outcome) {
        case outcome {
          Ok(_) -> Ok(Nil)
          Error(failure) -> Error(failure)
        }
      })
  }
}

/// Rotates the session's tokens. Callers that ask while one is running share
/// it: a refresh token works only once.
pub fn refresh_session(
  client: RestClient,
) -> Promise(Result(SignIn, DuvetError)) {
  case get(client.refreshing) {
    Some(running) -> running
    None -> {
      let running =
        refresh_with_retries(client, 0)
        |> promise.map(fn(outcome) {
          set(client.refreshing, None)
          case outcome {
            Error(failure) -> Error(failure)
            Ok(response) -> finish_refresh(client, response)
          }
        })
      set(client.refreshing, Some(running))
      running
    }
  }
}

fn refresh_with_retries(
  client: RestClient,
  attempt: Int,
) -> Promise(Result(transport.Response, DuvetError)) {
  let url = api_router.url_from_path(client.router, "/api/auth/refresh", [])
  let headers = case session_token(client) {
    "" -> []
    value -> [#("X-Session-Token", value)]
  }
  use outcome <- promise.await(
    exchange("POST", url, headers, [], client.timeout_ms, None)
    |> promise.map(from_send),
  )
  case outcome {
    Ok(response) if response.status == 429 && attempt < 3 -> {
      use _ <- promise.await(promise.wait(retry_after_ms(response)))
      refresh_with_retries(client, attempt + 1)
    }
    _ -> promise.resolve(outcome)
  }
}

/// A 429 means "try again later": wait as long as the API says, up to 20s, as
/// `session` does.
fn retry_after_ms(response: transport.Response) -> Int {
  let raw = case transport.header(response, "retry-after") {
    Ok(value) -> value
    Error(Nil) ->
      case transport.header(response, "x-ratelimit-reset-after") {
        Ok(value) -> value
        Error(Nil) -> ""
      }
  }
  let seconds = case float.parse(raw), int.parse(raw) {
    Ok(value), _ -> float.truncate(float.ceiling(value))
    _, Ok(value) -> value
    _, _ -> 1
  }
  int.min(seconds, 20) * 1000
}

fn finish_refresh(
  client: RestClient,
  response: transport.Response,
) -> Result(SignIn, DuvetError) {
  let body = core.body_text(response)
  case response.status {
    401 | 403 -> {
      set(client.tokens, #("", ""))
      Error(error.auth("refresh session", response.status, body))
    }
    status if status >= 200 && status < 300 ->
      case parse_frame(body) {
        Error(Nil) ->
          Error(error.MalformedMessage("the token answer isn't JSON"))
        Ok(object) -> {
          let sign_in = sign_in.from_json(object)
          let session_token = case sign_in.session_token {
            Some(value) if value != "" -> value
            _ -> session_token(client)
          }
          set(client.tokens, #(sign_in.token, session_token))
          Ok(sign_in)
        }
      }
    status -> Error(error.api("refresh session", status, body))
  }
}

pub fn log_in(
  client: RestClient,
  email: String,
  password: String,
) -> Promise(Result(SignIn, DuvetError)) {
  let body =
    core.JsonBody(
      json.object([
        #("email", json.string(email)),
        #("password", json.string(password)),
      ]),
    )
  let meta = core.with_renew(default_meta(client), False)
  use outcome <- promise.map(request(
    client,
    "POST",
    "/api/auth/login",
    "log in",
    body,
    meta,
  ))
  case outcome {
    Error(failure) -> Error(failure)
    Ok(response) ->
      case core.decode_map(response) {
        Error(failure) -> Error(failure)
        Ok(object) -> {
          let sign_in = sign_in.from_json(object)
          let session = case sign_in.session_token {
            Some(value) -> value
            None -> ""
          }
          set(client.tokens, #(sign_in.token, session))
          Ok(sign_in)
        }
      }
  }
}

/// Ends the session. Best effort: the tokens are forgotten either way.
pub fn log_out(client: RestClient) -> Promise(Nil) {
  let meta = core.with_renew(default_meta(client), False)
  use _ <- promise.map(request(
    client,
    "POST",
    "/api/auth/logout",
    "log out",
    core.NoBody,
    meta,
  ))
  set(client.tokens, #("", ""))
}

/// Sends one read ack, ignoring failures; the throttling is the TypeScript
/// layer's.
pub fn send_ack(
  client: RestClient,
  path: String,
  action: String,
  message_id: String,
) -> Promise(Nil) {
  let body =
    core.JsonBody(json.object([#("message_id", json.string(message_id))]))
  use _ <- promise.map(request(
    client,
    "POST",
    path,
    action,
    body,
    default_meta(client),
  ))
  Nil
}

// ---------------------------------------------------------------------------
// The space-command cache
// ---------------------------------------------------------------------------

pub fn cached_commands(
  client: RestClient,
  space_id: String,
  now: Timestamp,
) -> Option(models.SpaceCommands) {
  case dict.get(get(client.commands), space_id) {
    Ok(#(at, commands)) -> {
      let age = duration.to_milliseconds(timestamp.difference(at, now))
      case age < commands_ttl_ms {
        True -> Some(commands)
        False -> None
      }
    }
    Error(Nil) -> None
  }
}

pub fn cache_commands(
  client: RestClient,
  space_id: String,
  now: Timestamp,
  commands: models.SpaceCommands,
) -> Nil {
  set(
    client.commands,
    dict.insert(get(client.commands), space_id, #(now, commands)),
  )
}

pub fn forget_commands(client: RestClient, space_id: String) -> Nil {
  set(client.commands, dict.delete(get(client.commands), space_id))
}

pub fn clear_commands(client: RestClient) -> Nil {
  set(client.commands, dict.new())
}

/// A JSON object, for `model`'s decoders: a gateway frame, say.
pub fn parse_frame(text: String) -> Result(decoding.Object, Nil) {
  case json.parse(text, decode.dict(decode.string, decode.dynamic)) {
    Ok(object) -> Ok(object)
    Error(_) -> Error(Nil)
  }
}
