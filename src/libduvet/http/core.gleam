import gleam/bit_array
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import libduvet/api_router
import libduvet/error.{type DuvetError}
import libduvet/http/multipart.{type FilePart}
import libduvet/http/send
import libduvet/http/session.{type Session}
import libduvet/http/transport
import libduvet/json_value
import libduvet/model/decoding

/// How a request authenticates: a person's session, or a bot's token. A bot
/// sends `Authorization: Bot <token>` and has no session token, so a 401 ends
/// the request instead of renewing a session it doesn't have.
pub type AuthMode {
  Session
  Bot
}

/// What every request needs: where the API is, how to reach it, whose tokens
/// to send, how to authenticate them, and how long it may take.
pub type Core {
  Core(
    router: api_router.ApiRouter,
    transport: transport.Transport,
    session: Session,
    auth: AuthMode,
    timeout_ms: Int,
  )
}

pub fn start(
  transport: transport.Transport,
  router: api_router.ApiRouter,
  token: String,
  session_token: String,
  timeout_ms: Int,
  auth: AuthMode,
) -> Core {
  Core(
    router: router,
    transport: transport,
    session: session.start(transport, router, token, session_token, timeout_ms),
    auth: auth,
    timeout_ms: timeout_ms,
  )
}

/// A request's body.
pub type Body {
  NoBody
  JsonBody(value: json.Json)
  MultipartBody(fields: List(#(String, String)), files: List(FilePart))
}

/// What a request may say beyond its method, path and body.
pub type Meta(a) {
  Meta(
    query: List(#(String, String)),
    /// Whether a 401 renews the session and sends the request once more.
    renew: Bool,
    timeout: Int,
    on_progress: Option(fn(Int, Int) -> Nil),
    abort: Option(Subject(a)),
  )
}

/// The defaults: no query, renewal on, the client's timeout, no progress, no
/// abort.
pub fn default_meta(core: Core) -> Meta(a) {
  Meta(
    query: [],
    renew: True,
    timeout: core.timeout_ms,
    on_progress: None,
    abort: None,
  )
}

pub fn with_query(meta: Meta(a), query: List(#(String, String))) -> Meta(a) {
  Meta(
    query: query,
    renew: meta.renew,
    timeout: meta.timeout,
    on_progress: meta.on_progress,
    abort: meta.abort,
  )
}

pub fn with_renew(meta: Meta(a), renew: Bool) -> Meta(a) {
  Meta(
    query: meta.query,
    renew: renew,
    timeout: meta.timeout,
    on_progress: meta.on_progress,
    abort: meta.abort,
  )
}

pub fn with_timeout(meta: Meta(a), timeout: Int) -> Meta(a) {
  Meta(
    query: meta.query,
    renew: meta.renew,
    timeout: timeout,
    on_progress: meta.on_progress,
    abort: meta.abort,
  )
}

pub fn with_progress(
  meta: Meta(a),
  on_progress: fn(Int, Int) -> Nil,
) -> Meta(a) {
  Meta(
    query: meta.query,
    renew: meta.renew,
    timeout: meta.timeout,
    on_progress: Some(on_progress),
    abort: meta.abort,
  )
}

pub fn with_abort(meta: Meta(a), abort: Subject(b)) -> Meta(b) {
  Meta(
    query: meta.query,
    renew: meta.renew,
    timeout: meta.timeout,
    on_progress: meta.on_progress,
    abort: Some(abort),
  )
}

/// Sends a request to the API with the session's headers, and fails unless it
/// succeeds. Unless renewal is off, a 401 renews the session and sends the
/// request once more, as does a 401 to a request sent before a renewal that
/// has finished since.
pub fn request(
  core: Core,
  method: String,
  path: String,
  action: String,
  body: Body,
  meta: Meta(a),
) -> Result(transport.Response, DuvetError) {
  let #(token, session_token) = session.tokens(core.session)
  let sent =
    build(
      core.router,
      token,
      session_token,
      method,
      path,
      body,
      meta.query,
      core.auth,
    )
  case send_once(core, sent, meta) {
    Error(failure) -> Error(failure)
    Ok(response) ->
      case meta.renew && core.auth == Session && response.status == 401 {
        False -> assert_ok(response, action)
        True -> {
          let #(current_token, _) = session.tokens(core.session)
          let renewed = case current_token != token {
            True -> Ok(Nil)
            False -> session.renew(core.session, token)
          }
          case renewed {
            Error(_) -> assert_ok(response, action)
            Ok(_) -> {
              let #(new_token, new_session_token) = session.tokens(core.session)
              let resent =
                build(
                  core.router,
                  new_token,
                  new_session_token,
                  method,
                  path,
                  body,
                  meta.query,
                  core.auth,
                )
              case send_once(core, resent, meta) {
                Error(failure) -> Error(failure)
                Ok(second) -> assert_ok(second, action)
              }
            }
          }
        }
      }
  }
}

/// A request ready for a transport: what a transport needs, on any target.
pub type Built {
  Built(
    method: String,
    url: String,
    headers: List(#(String, String)),
    pieces: List(BitArray),
  )
}

pub fn build(
  router: api_router.ApiRouter,
  token: String,
  session_token: String,
  method: String,
  path: String,
  body: Body,
  query: List(#(String, String)),
  mode: AuthMode,
) -> Built {
  let url = api_router.url_from_path(router, path, query)
  let auth = auth_headers(token, session_token, mode)
  case body {
    NoBody -> Built(method: method, url: url, headers: auth, pieces: [])
    JsonBody(value) -> {
      let pieces = [bit_array.from_string(json.to_string(value))]
      Built(
        method: method,
        url: url,
        headers: with_length(
          list.append(auth, [#("Content-Type", "application/json")]),
          pieces,
        ),
        pieces: pieces,
      )
    }
    MultipartBody(fields:, files:) -> {
      let form = multipart.encode(fields, files)
      let pieces = multipart.pieces(form.body)
      Built(
        method: method,
        url: url,
        headers: with_length(
          list.append(auth, [#("Content-Type", form.content_type)]),
          pieces,
        ),
        pieces: pieces,
      )
    }
  }
}

/// A streamed body needs its length said: the server would otherwise take it
/// as chunked, and some servers don't read that.
fn with_length(
  headers: List(#(String, String)),
  pieces: List(BitArray),
) -> List(#(String, String)) {
  let length =
    list.fold(pieces, 0, fn(total, piece) { total + bit_array.byte_size(piece) })
  list.append(headers, [#("content-length", int.to_string(length))])
}

/// The session's headers: the access token as a bearer token, and the session
/// token, each only when there is one; or a bot's token, as the API reads it,
/// with no session token.
pub fn auth_headers(
  token: String,
  session_token: String,
  mode: AuthMode,
) -> List(#(String, String)) {
  case mode {
    Bot ->
      case token == "" {
        True -> []
        False -> [#("Authorization", "Bot " <> token)]
      }
    Session -> {
      let bearer = case token == "" {
        True -> []
        False -> [#("Authorization", "Bearer " <> token)]
      }
      case session_token == "" {
        True -> bearer
        False -> list.append(bearer, [#("X-Session-Token", session_token)])
      }
    }
  }
}

fn send_once(
  core: Core,
  built: Built,
  meta: Meta(a),
) -> Result(transport.Response, DuvetError) {
  let request =
    transport.Request(
      method: built.method,
      url: built.url,
      headers: built.headers,
      body: built.pieces,
    )
  send.send_within(
    core.transport,
    request,
    meta.timeout,
    meta.abort,
    meta.on_progress,
  )
  |> map_send_error
}

fn map_send_error(value: Result(a, send.SendError)) -> Result(a, DuvetError) {
  case value {
    Ok(inner) -> Ok(inner)
    Error(failure) -> Error(error.from_send_error(failure))
  }
}

/// Answers the response when it succeeded, and the failure the status means
/// otherwise: a 401 or 403 is an auth error, anything else an API error.
pub fn assert_ok(
  response: transport.Response,
  action: String,
) -> Result(transport.Response, DuvetError) {
  let body = body_text(response)
  case response.status {
    status if status >= 200 && status < 300 -> Ok(response)
    401 | 403 -> Error(error.auth(action, response.status, body))
    status -> Error(error.api(action, status, body))
  }
}

pub fn body_text(response: transport.Response) -> String {
  case bit_array.to_string(response.body) {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}

/// The response's body as a JSON object.
pub fn decode_map(
  response: transport.Response,
) -> Result(decoding.Object, DuvetError) {
  json.parse(
    from: body_text(response),
    using: decode.dict(decode.string, decode.dynamic),
  )
  |> result_map_error(fn(_) {
    error.MalformedMessage("the API's answer isn't a JSON object")
  })
}

/// The response's body as a list, null counting as none.
pub fn decode_list(
  response: transport.Response,
  read: fn(decoding.Object) -> item,
) -> Result(List(item), DuvetError) {
  case json.parse(from: body_text(response), using: decode.dynamic) {
    Error(_) -> Error(error.MalformedMessage("the API's answer isn't JSON"))
    Ok(value) ->
      case decoding.objects_value(value) {
        [] -> Ok([])
        items -> Ok(list.map(items, read))
      }
  }
}

/// The response's body as any JSON value.
pub fn decode_json(
  response: transport.Response,
) -> Result(json.Json, DuvetError) {
  case json.parse(from: body_text(response), using: decode.dynamic) {
    Ok(value) -> Ok(json_value_from_dynamic(value))
    Error(_) -> Error(error.MalformedMessage("the API's answer isn't JSON"))
  }
}

fn json_value_from_dynamic(value: dynamic.Dynamic) -> json.Json {
  json_value.to_json(json_value.from_dynamic(value))
}

fn result_map_error(value: Result(a, b), f: fn(b) -> c) -> Result(a, c) {
  case value {
    Ok(inner) -> Ok(inner)
    Error(failure) -> Error(f(failure))
  }
}
