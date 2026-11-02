import gleam/dict
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import libduvet/api_router
import libduvet/error
import libduvet/http/ack
import libduvet/http/client
import libduvet/http/methods
import libduvet/http/transport
import libduvet/model/decoding
import support/cell
import support/mock_transport

pub fn main() -> Nil {
  gleeunit.main()
}

const message_time = "2026-10-22T10:00:00.123456Z"

fn message_json() -> String {
  "{\"id\":\"m1\",\"room_id\":\"r1\",\"author_id\":\"u1\",\"content\":\"hi\",\"type\":0,\"created_at\":\""
  <> message_time
  <> "\",\"updated_at\":\""
  <> message_time
  <> "\"}"
}

fn message_list_json() -> String {
  "[" <> message_json() <> "]"
}

fn router() -> api_router.ApiRouter {
  api_router.ApiRouter(
    api: "api.duvet.chat",
    ws: "ws.duvet.chat",
    base: "duvet.chat",
    cdn: "none",
    secure: True,
  )
}

fn make_client(
  transport: transport.Transport,
  token: String,
  session_token: String,
) -> client.RestClient {
  make_client_with_timeout(transport, token, session_token, 20_000)
}

fn make_client_with_timeout(
  transport: transport.Transport,
  token: String,
  session_token: String,
  timeout_ms: Int,
) -> client.RestClient {
  make_client_api(transport, router(), token, session_token, timeout_ms)
}

fn make_client_api(
  transport: transport.Transport,
  router: api_router.ApiRouter,
  token: String,
  session_token: String,
  timeout_ms: Int,
) -> client.RestClient {
  client.new(transport, router, token, session_token, timeout_ms)
}

// ---------------------------------------------------------------------------
// Headers
// ---------------------------------------------------------------------------

pub fn sends_the_access_and_session_tokens_test() {
  let mock = mock_transport.always(200, "")
  let api = make_client(mock_transport.transport(mock), "tok", "sess")
  let _ = methods.leave_space(api, "s1")
  let assert [request] = mock_transport.sent(mock)
  should.equal(
    mock_transport.header(request, "Authorization"),
    Ok("Bearer tok"),
  )
  should.equal(mock_transport.header(request, "X-Session-Token"), Ok("sess"))
}

pub fn sends_no_auth_headers_without_a_session_test() {
  let mock =
    mock_transport.always(
      200,
      "{\"code\":\"abc\",\"space_id\":\"s1\",\"space_name\":\"S\",\"description\":\"\",\"member_count\":3}",
    )
  let api = make_client(mock_transport.transport(mock), "", "")
  let _ = methods.get_invite(api, "abc")
  let assert [request] = mock_transport.sent(mock)
  should.be_false(mock_transport.has_header(request, "Authorization"))
  should.be_false(mock_transport.has_header(request, "X-Session-Token"))
}

pub fn json_bodies_say_so_and_bodiless_requests_dont_test() {
  let mock = mock_transport.always(200, "")
  let api = make_client(mock_transport.transport(mock), "tok", "sess")
  let _ = methods.pin_room_message(api, "r1", "m1")
  let _ = methods.invite_to_team(api, "t1", "a@b.c")
  let assert [pinned, invited] = mock_transport.sent(mock)
  should.be_false(mock_transport.has_header(pinned, "content-type"))
  let assert Ok(content_type) = mock_transport.header(invited, "content-type")
  should.be_true(string.starts_with(content_type, "application/json"))
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

pub fn log_in_keeps_the_tokens_of_the_body_test() {
  let mock =
    mock_transport.always(200, "{\"token\":\"A\",\"session_token\":\"S\"}")
  let api = make_client(mock_transport.transport(mock), "", "")
  let assert Ok(sign_in) = client.log_in(api, "a@b.c", "pw")
  should.equal(sign_in.token, "A")
  should.equal(client.token(api), "A")
  should.equal(client.session_token(api), "S")
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.path(request), "/api/auth/login")
  should.equal(
    mock_transport.body_json(request),
    Ok(
      dict.from_list([
        #("email", dynamic_string("a@b.c")),
        #("password", dynamic_string("pw")),
      ]),
    ),
  )
}

pub fn a_failed_log_in_is_an_auth_error_without_refreshing_test() {
  let mock = mock_transport.always(401, "{\"error\":\"bad\"}")
  let api = make_client(mock_transport.transport(mock), "", "")
  case client.log_in(api, "a@b.c", "pw") {
    Error(error.AuthError(_)) -> Nil
    _ -> should.fail()
  }
  should.equal(list.length(mock_transport.sent(mock)), 1)
}

pub fn sign_in_sends_the_account_test() {
  let mock = mock_transport.always(200, "")
  let api = make_client(mock_transport.transport(mock), "tok", "sess")
  let _ =
    methods.sign_in(
      api,
      username: "u",
      password: "p",
      email: "e@x.y",
      alias: None,
    )
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.path(request), "/api/auth/signin")
  let assert Ok(body) = mock_transport.body_json(request)
  should.equal(decoding.optional_string(body, "username"), Some("u"))
  should.equal(decoding.optional_string(body, "alias"), None)
  should.equal(decoding.optional_string(body, "password"), Some("p"))
  should.equal(decoding.optional_string(body, "email"), Some("e@x.y"))
}

pub fn logout_forgets_the_tokens_even_when_it_fails_test() {
  let mock = mock_transport.always(500, "")
  let api = make_client(mock_transport.transport(mock), "tok", "sess")
  let _ = client.log_out(api)
  should.equal(client.token(api), "")
  should.equal(client.session_token(api), "")
}

pub fn a_401_refreshes_once_for_concurrent_requests_test() {
  let mock =
    mock_transport.start(fn(request) {
      case mock_transport.path(request) {
        "/api/auth/refresh" ->
          Ok(mock_transport.response(
            200,
            "{\"token\":\"new\",\"session_token\":\"sess2\"}",
          ))
        _ ->
          case mock_transport.header(request, "Authorization") {
            Ok("Bearer new") ->
              Ok(mock_transport.response(200, message_list_json()))
            _ -> Ok(mock_transport.response(401, "{\"error\":\"expired\"}"))
          }
      }
    })
  let api = make_client(mock_transport.transport(mock), "tok", "sess")
  let #(first, second) =
    in_parallel(
      fn() { methods.get_messages(api, "r1", before: None, count: 100) },
      fn() { methods.get_messages(api, "r1", before: Some("m9"), count: 100) },
    )
  let assert Ok([first_page]) = first
  should.equal(first_page.id, "m1")
  let assert Ok([second_page]) = second
  should.equal(second_page.id, "m1")
  let refreshes =
    mock_transport.sent(mock)
    |> list.filter(fn(request) {
      mock_transport.path(request) == "/api/auth/refresh"
    })
  should.equal(list.length(refreshes), 1)
  let assert [refresh] = refreshes
  should.equal(mock_transport.header(refresh, "X-Session-Token"), Ok("sess"))
  should.equal(client.session_token(api), "sess2")
}

pub fn a_request_is_retried_only_once_test() {
  let mock =
    mock_transport.start(fn(request) {
      case mock_transport.path(request) {
        "/api/auth/refresh" ->
          Ok(mock_transport.response(200, "{\"token\":\"new\"}"))
        _ -> Ok(mock_transport.response(401, ""))
      }
    })
  let api = make_client(mock_transport.transport(mock), "tok", "sess")
  case methods.get_friends(api) {
    Error(error.AuthError(_)) -> Nil
    _ -> should.fail()
  }
  should.equal(list.map(mock_transport.sent(mock), mock_transport.path), [
    "/api/users/@me/friends",
    "/api/auth/refresh",
    "/api/users/@me/friends",
  ])
}

pub fn a_rejected_refresh_forgets_the_tokens_test() {
  let mock = mock_transport.always(401, "")
  let api = make_client(mock_transport.transport(mock), "tok", "sess")
  case methods.get_friends(api) {
    Error(error.AuthError(_)) -> Nil
    _ -> should.fail()
  }
  should.equal(client.token(api), "")
  should.equal(client.session_token(api), "")
}

pub fn a_rate_limited_refresh_waits_and_tries_again_test() {
  let refreshes = cell.new(0)
  let mock =
    mock_transport.start(fn(request) {
      case mock_transport.path(request) {
        "/api/auth/refresh" -> {
          cell.update(refreshes, fn(count) { count + 1 })
          case cell.get(refreshes) == 1 {
            True -> Ok(mock_transport.response(429, ""))
            False -> Ok(mock_transport.response(200, "{\"token\":\"new\"}"))
          }
        }
        _ ->
          case mock_transport.header(request, "Authorization") {
            Ok("Bearer new") -> Ok(mock_transport.response(200, "[]"))
            _ -> Ok(mock_transport.response(401, ""))
          }
      }
    })
  let api = make_client(mock_transport.transport(mock), "tok", "sess")
  // The retry waits a second, as the API said.
  should.equal(methods.get_friends(api), Ok([]))
  should.equal(cell.get(refreshes), 2)
  should.equal(client.session_token(api), "sess")
}

pub fn without_a_session_token_a_401_just_fails_test() {
  let mock = mock_transport.always(401, "")
  let api = make_client(mock_transport.transport(mock), "tok", "")
  case methods.get_friends(api) {
    Error(error.AuthError(_)) -> Nil
    _ -> should.fail()
  }
  should.equal(list.length(mock_transport.sent(mock)), 1)
}

pub fn other_failures_carry_the_status_and_body_test() {
  let mock = mock_transport.always(404, "{\"error\":\"nope\"}")
  let api = make_client(mock_transport.transport(mock), "tok", "sess")
  case methods.get_room_pins(api, "r1") {
    Error(error.ApiError(failure)) -> {
      should.equal(failure.status_code, 404)
      should.equal(failure.body, Some("{\"error\":\"nope\"}"))
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Acks
// ---------------------------------------------------------------------------

pub fn acks_at_most_one_per_room_every_interval_test() {
  let mock = mock_transport.always(200, "")
  let api = make_client(mock_transport.transport(mock), "tok", "sess")
  let _ = client.ack_room(api, "r1", "01")
  client.ack_room(api, "r1", "03")
  client.ack_room(api, "r1", "02")
  client.ack_conversation(api, "c1", "01")
  should.equal(list.map(mock_transport.sent(mock), message_id_of), ["01", "01"])
  process.sleep(ack.ack_interval + 200)
  should.equal(
    list.map(mock_transport.sent(mock), fn(request) {
      mock_transport.path(request) <> " " <> message_id_of(request)
    }),
    [
      "/api/rooms/r1/ack 01",
      "/api/users/@me/conversations/c1/ack 01",
      "/api/rooms/r1/ack 03",
    ],
  )
}

pub fn ack_failures_are_swallowed_test() {
  let mock = mock_transport.always(500, "")
  let api = make_client(mock_transport.transport(mock), "tok", "sess")
  let _ = client.ack_room(api, "r1", "01")
  should.equal(list.length(mock_transport.sent(mock)), 1)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn message_id_of(request: transport.Request) -> String {
  case mock_transport.body_json(request) {
    Ok(body) -> decoding.string_or(body, "message_id", "")
    Error(Nil) -> ""
  }
}

fn dynamic_string(text: String) -> dynamic.Dynamic {
  dynamic.string(text)
}

fn in_parallel(first: fn() -> a, second: fn() -> a) -> #(a, a) {
  let subject = process.new_subject()
  let _ = process.spawn(fn() { process.send(subject, first()) })
  let one = second()
  let two = process.receive_forever(subject)
  #(two, one)
}
