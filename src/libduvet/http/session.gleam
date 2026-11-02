import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import libduvet/api_router
import libduvet/error
import libduvet/http/send
import libduvet/http/sign_in.{type SignIn}
import libduvet/http/transport
import libduvet/model/decoding

/// The client's tokens, and the session's single-flight renewal: whatever
/// fails with a 401 asks here, and only the first call refreshes.
pub opaque type Session {
  Session(subject: Subject(Message))
}

type Message {
  Tokens(reply: Subject(#(String, String)))
  Set(token: String, session_token: Option(String), reply: Subject(Nil))
  Clear(reply: Subject(Nil))
  Renew(sent_token: String, reply: Subject(Result(Nil, error.DuvetError)))
  Refresh(reply: Subject(Result(SignIn, error.DuvetError)))
}

type State {
  State(
    token: String,
    session_token: String,
    router: api_router.ApiRouter,
    transport: transport.Transport,
    timeout_ms: Int,
  )
}

/// Starts the session store, resuming the tokens of a session started before.
pub fn start(
  transport: transport.Transport,
  router: api_router.ApiRouter,
  token: String,
  session_token: String,
  timeout_ms: Int,
) -> Session {
  let state =
    State(
      token: token,
      session_token: session_token,
      router: router,
      transport: transport,
      timeout_ms: timeout_ms,
    )
  let ready = process.new_subject()
  let _pid =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(state, subject)
    })
  Session(process.receive_forever(ready))
}

pub fn tokens(session: Session) -> #(String, String) {
  call(session, Tokens)
}

pub fn token(session: Session) -> String {
  let #(token, _) = tokens(session)
  token
}

pub fn session_token(session: Session) -> String {
  let #(_, session_token) = tokens(session)
  session_token
}

/// Keeps a login's tokens. A session token that comes back empty keeps the
/// one there was, as the Dart client does.
pub fn set_tokens(
  session: Session,
  token: String,
  session_token: String,
) -> Nil {
  let provided = case session_token == "" {
    True -> None
    False -> Some(session_token)
  }
  call(session, fn(reply) { Set(token, provided, reply) })
}

pub fn clear(session: Session) -> Nil {
  call(session, Clear)
}

/// Refreshes the tokens when [sent_token] is still the one in use; when it
/// isn't, a renewal already happened and nothing is done. Answers whether the
/// request may be sent again.
pub fn renew(
  session: Session,
  sent_token: String,
) -> Result(Nil, error.DuvetError) {
  call(session, fn(reply) { Renew(sent_token, reply) })
}

/// Rotates the session's tokens, as `refreshSession` does in the Dart client.
pub fn refresh(session: Session) -> Result(SignIn, error.DuvetError) {
  call(session, Refresh)
}

fn call(session: Session, message: fn(Subject(a)) -> Message) -> a {
  let reply = process.new_subject()
  process.send(session.subject, message(reply))
  process.receive_forever(reply)
}

fn loop(state: State, subject: Subject(Message)) -> Nil {
  let message = process.receive_forever(subject)
  case message {
    Tokens(reply) -> {
      process.send(reply, #(state.token, state.session_token))
      loop(state, subject)
    }
    Set(token, session_token, reply) -> {
      let session_token = case session_token {
        Some(value) -> value
        None -> state.session_token
      }
      process.send(reply, Nil)
      loop(with_tokens(state, token, session_token), subject)
    }
    Clear(reply) -> {
      process.send(reply, Nil)
      loop(with_tokens(state, "", ""), subject)
    }
    Renew(sent_token, reply) -> {
      case sent_token == state.token && state.session_token != "" {
        False -> {
          case sent_token != state.token {
            True -> process.send(reply, Ok(Nil))
            False ->
              process.send(
                reply,
                Error(
                  error.AuthError(error.AuthFailure(
                    action: "refresh session",
                    status_code: 401,
                    body: None,
                  )),
                ),
              )
          }
          loop(state, subject)
        }
        True -> {
          let #(result, state) = do_refresh(state)
          case result {
            Ok(_) -> process.send(reply, Ok(Nil))
            Error(failure) -> process.send(reply, Error(failure))
          }
          loop(state, subject)
        }
      }
    }
    Refresh(reply) -> {
      let #(result, state) = do_refresh(state)
      process.send(reply, result)
      loop(state, subject)
    }
  }
}

fn do_refresh(state: State) -> #(Result(SignIn, error.DuvetError), State) {
  let response = refresh_with_retries(state, 0)
  case response {
    Error(failure) -> #(Error(failure), state)
    Ok(response) -> finish(state, response)
  }
}

fn refresh_with_retries(
  state: State,
  attempt: Int,
) -> Result(transport.Response, error.DuvetError) {
  case refresh_once(state) {
    Error(failure) -> Error(failure)
    Ok(response) ->
      case response.status == 429 && attempt < 3 {
        True -> {
          process.sleep(retry_after_ms(response))
          refresh_with_retries(state, attempt + 1)
        }
        False -> Ok(response)
      }
  }
}

fn refresh_once(state: State) -> Result(transport.Response, error.DuvetError) {
  let url = api_router.url_from_path(state.router, "/api/auth/refresh", [])
  let headers = case state.session_token == "" {
    True -> []
    False -> [#("X-Session-Token", state.session_token)]
  }
  let request =
    transport.Request(method: "POST", url: url, headers: headers, body: [])
  send.send_within(state.transport, request, state.timeout_ms, None, None)
  |> result_map_error(error.from_send_error)
}

/// A 429 means "try again later", not an invalid session: wait as long as the
/// API says, up to 20s per attempt so queued requests aren't held for minutes.
fn retry_after_ms(response: transport.Response) -> Int {
  let raw = case transport.header(response, "retry-after") {
    Ok(value) -> value
    Error(Nil) ->
      case transport.header(response, "x-ratelimit-reset-after") {
        Ok(value) -> value
        Error(Nil) -> ""
      }
  }
  let seconds = case float.parse(raw) {
    Ok(value) -> float.truncate(float.ceiling(value))
    Error(Nil) -> 1
  }
  int.min(seconds, 20) * 1000
}

fn finish(
  state: State,
  response: transport.Response,
) -> #(Result(SignIn, error.DuvetError), State) {
  let body = transport.response_text(response)
  case response.status {
    401 | 403 -> {
      #(
        Error(error.auth("refresh session", response.status, body)),
        with_tokens(state, "", ""),
      )
    }
    status if status >= 200 && status < 300 -> {
      case json_object(body) {
        Ok(object) -> {
          let sign_in = sign_in.from_json(object)
          let session_token = case sign_in.session_token {
            Some(value) if value != "" -> value
            _ -> state.session_token
          }
          #(Ok(sign_in), with_tokens(state, sign_in.token, session_token))
        }
        Error(Nil) -> #(
          Error(error.MalformedMessage("the token answer isn't JSON")),
          state,
        )
      }
    }
    _ -> #(Error(error.api("refresh session", response.status, body)), state)
  }
}

fn with_tokens(state: State, token: String, session_token: String) -> State {
  State(
    token: token,
    session_token: session_token,
    router: state.router,
    transport: state.transport,
    timeout_ms: state.timeout_ms,
  )
}

fn json_object(text: String) -> Result(decoding.Object, Nil) {
  json.parse(from: text, using: decode.dict(decode.string, decode.dynamic))
  |> result.map_error(fn(_) { Nil })
}

fn result_map_error(value: Result(a, b), f: fn(b) -> c) -> Result(a, c) {
  case value {
    Ok(inner) -> Ok(inner)
    Error(failure) -> Error(f(failure))
  }
}
