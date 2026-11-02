import gleam/json
import gleam/option.{type Option, None, Some}
import libduvet/api_router
import libduvet/error.{type DuvetError}
import libduvet/http/ack
import libduvet/http/core
import libduvet/http/session
import libduvet/http/sign_in.{type SignIn}
import libduvet/http/transport

/// A client for the API: the session's tokens, the router, the transport and
/// the throttles for read acks.
pub opaque type RestClient {
  RestClient(
    core: core.Core,
    room_acks: ack.AckThrottle,
    conversation_acks: ack.AckThrottle,
  )
}

/// A client for the API; the tokens resume a session a login started before.
/// A request fails once the timeout passes without progress.
pub fn new(
  transport: transport.Transport,
  router: api_router.ApiRouter,
  token: String,
  session_token: String,
  timeout_ms: Int,
) -> RestClient {
  let core = core.start(transport, router, token, session_token, timeout_ms)
  let ack_meta = core.default_meta(core)
  let room_acks =
    ack.start(fn(key, message_id) {
      let _ =
        core.request(
          core,
          "POST",
          "/api/rooms/" <> key <> "/ack",
          "ack room",
          core.JsonBody(json.object([#("message_id", json.string(message_id))])),
          ack_meta,
        )
      Nil
    })
  let conversation_acks =
    ack.start(fn(key, message_id) {
      let _ =
        core.request(
          core,
          "POST",
          "/api/users/@me/conversations/" <> key <> "/ack",
          "ack conversation",
          core.JsonBody(json.object([#("message_id", json.string(message_id))])),
          ack_meta,
        )
      Nil
    })
  RestClient(
    core: core,
    room_acks: room_acks,
    conversation_acks: conversation_acks,
  )
}

pub fn router(client: RestClient) -> api_router.ApiRouter {
  client.core.router
}

pub fn request(
  client: RestClient,
  method: String,
  path: String,
  action: String,
  body: core.Body,
  meta: core.Meta(a),
) -> Result(transport.Response, DuvetError) {
  core.request(client.core, method, path, action, body, meta)
}

pub fn default_meta(client: RestClient) -> core.Meta(a) {
  core.default_meta(client.core)
}

pub fn token(client: RestClient) -> String {
  session.token(client.core.session)
}

pub fn session_token(client: RestClient) -> String {
  session.session_token(client.core.session)
}

pub fn is_authenticated(client: RestClient) -> Bool {
  token(client) != ""
}

/// Marks the room read up to [message_id]. Acks go out at most once per room
/// every [ack.ack_interval], with the newest message ID; failures are ignored.
pub fn ack_room(
  client: RestClient,
  room_id: String,
  message_id: String,
) -> Nil {
  ack.ack(client.room_acks, room_id, message_id)
}

/// Marks the conversation read up to [message_id], as [ack_room] does.
pub fn ack_conversation(
  client: RestClient,
  conversation_id: String,
  message_id: String,
) -> Nil {
  ack.ack(client.conversation_acks, conversation_id, message_id)
}

pub fn dispose(client: RestClient) -> Nil {
  ack.dispose(client.room_acks)
  ack.dispose(client.conversation_acks)
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

pub fn log_in(
  client: RestClient,
  email: String,
  password: String,
) -> Result(SignIn, DuvetError) {
  let body =
    core.JsonBody(
      json.object([
        #("email", json.string(email)),
        #("password", json.string(password)),
      ]),
    )
  let meta = core.with_renew(core.default_meta(client.core), False)
  case
    core.request(client.core, "POST", "/api/auth/login", "log in", body, meta)
  {
    Error(failure) -> Error(failure)
    Ok(response) ->
      case core.decode_map(response) {
        Error(failure) -> Error(failure)
        Ok(object) -> {
          let sign_in = sign_in.from_json(object)
          session.set_tokens(
            client.core.session,
            sign_in.token,
            session_token_text(sign_in.session_token),
          )
          Ok(sign_in)
        }
      }
  }
}

/// Ends the session. Best effort: the tokens are forgotten either way.
pub fn log_out(client: RestClient) -> Nil {
  let meta = core.with_renew(core.default_meta(client.core), False)
  let _ =
    core.request(
      client.core,
      "POST",
      "/api/auth/logout",
      "log out",
      core.NoBody,
      meta,
    )
  session.clear(client.core.session)
  Nil
}

/// Rotates the session's tokens.
pub fn refresh_session(client: RestClient) -> Result(SignIn, DuvetError) {
  session.refresh(client.core.session)
}

/// Renews the session's tokens, answering whether it did.
pub fn renew_session(client: RestClient) -> Bool {
  case session.session_token(client.core.session) == "" {
    True -> False
    False ->
      case session.refresh(client.core.session) {
        Ok(_) -> True
        Error(_) -> False
      }
  }
}

fn session_token_text(value: Option(String)) -> String {
  case value {
    Some(text) -> text
    None -> ""
  }
}
