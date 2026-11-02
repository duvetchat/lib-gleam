import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import libduvet/api_router
import libduvet/error
import libduvet/http/bot
import libduvet/http/client
import libduvet/http/transport
import libduvet/model/decoding
import support/mock_transport

pub fn main() -> Nil {
  gleeunit.main()
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

fn make_bot(transport: transport.Transport) -> client.RestClient {
  client.new_bot(transport, router(), "bottok", 20_000)
}

fn application_json() -> String {
  "{\"id\":\"app1\",\"team_id\":\"team1\",\"name\":\"chisato\",\"description\":null,\"icon\":null,\"bot_user_id\":\"bot1\",\"public\":true,\"created_at\":\"2026-11-02T00:00:00Z\",\"updated_at\":\"2026-11-02T00:00:00Z\",\"deleted_at\":null}"
}

pub fn bot_auth_is_the_bot_token_alone_test() {
  let mock = mock_transport.always(200, "")
  let api = make_bot(mock_transport.transport(mock))
  let _ = bot.delete_message_in_room(api, "r1", "m1")
  let assert [request] = mock_transport.sent(mock)
  should.equal(
    mock_transport.header(request, "Authorization"),
    Ok("Bot bottok"),
  )
  should.be_false(mock_transport.has_header(request, "X-Session-Token"))
}

pub fn a_bot_401_does_not_renew_a_session_test() {
  let mock = mock_transport.always(401, "{\"error\":\"invalid bot token\"}")
  let api = make_bot(mock_transport.transport(mock))
  let result = bot.get_application(api)
  should.be_true(is_auth_error(result))
  // No refresh: a bot has no session to renew.
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.path(request), "/api/applications/@me")
}

pub fn get_application_is_the_bots_own_test() {
  let mock = mock_transport.always(200, application_json())
  let api = make_bot(mock_transport.transport(mock))
  let assert Ok(_) = bot.get_application(api)
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.method(request), "GET")
  should.equal(mock_transport.path(request), "/api/applications/@me")
}

pub fn next_interaction_asks_for_the_short_wait_test() {
  let mock =
    mock_transport.always(
      200,
      "{\"id\":\"i1\",\"application_id\":\"app1\",\"type\":2,\"space_id\":\"s1\",\"room_id\":\"r1\",\"token\":\"t\"}",
    )
  let api = make_bot(mock_transport.transport(mock))
  let assert Ok(Some(_)) = bot.next_interaction(api, "app1", True)
  let assert [request] = mock_transport.sent(mock)
  should.equal(
    mock_transport.path(request),
    "/api/applications/app1/interactions/next",
  )
  should.equal(mock_transport.query(request), [#("wait", "short")])
}

pub fn next_interaction_without_one_is_none_test() {
  let mock = mock_transport.always(204, "")
  let api = make_bot(mock_transport.transport(mock))
  should.equal(bot.next_interaction(api, "app1", False), Ok(None))
}

pub fn respond_sends_type_data_and_with_response_test() {
  let mock = mock_transport.always(200, "{\"interaction\":{\"id\":\"i1\"}}")
  let api = make_bot(mock_transport.transport(mock))
  let data = json.object([#("content", json.string("pong"))])
  let assert Ok(Some(_)) = bot.respond(api, "i1", "itok", 4, Some(data), True)
  let assert [request] = mock_transport.sent(mock)
  should.equal(
    mock_transport.path(request),
    "/api/interactions/i1/itok/callback",
  )
  should.equal(mock_transport.query(request), [#("with_response", "true")])
  let assert Ok(body) = mock_transport.body_json(request)
  should.equal(body |> decoding.int("type"), 4)
  let assert Some(payload) = decoding.optional_object(body, "data")
  should.equal(decoding.string(payload, "content"), "pong")
}

pub fn respond_without_a_response_answers_none_test() {
  let mock = mock_transport.always(204, "")
  let api = make_bot(mock_transport.transport(mock))
  let assert Ok(None) = bot.respond(api, "i1", "itok", 5, None, False)
  let assert [request] = mock_transport.sent(mock)
  let assert Ok(body) = mock_transport.body_json(request)
  should.equal(body |> decoding.int("type"), 5)
  should.equal(decoding.field(body, "data"), None)
}

pub fn follow_ups_use_the_app_id_as_the_webhook_id_test() {
  let mock = mock_transport.always(200, "{\"id\":\"m2\"}")
  let api = make_bot(mock_transport.transport(mock))
  let message = json.object([#("content", json.string("more"))])
  let assert Ok(_) = bot.follow_up(api, "app1", "itok", message)
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.method(request), "POST")
  should.equal(mock_transport.path(request), "/api/webhooks/app1/itok")
}

pub fn interaction_messages_are_reached_by_ref_test() {
  let mock = mock_transport.always(200, "{\"id\":\"m1\"}")
  let api = make_bot(mock_transport.transport(mock))
  let edited = json.object([#("content", json.string("edited"))])
  let _ = bot.get_message(api, "app1", "itok", "@original")
  let _ = bot.edit_message(api, "app1", "itok", "m2", edited)
  let _ = bot.delete_message(api, "app1", "itok", "m2")
  let assert [get, edit, delete] = mock_transport.sent(mock)
  should.equal(
    mock_transport.path(get),
    "/api/webhooks/app1/itok/messages/@original",
  )
  should.equal(mock_transport.method(edit), "PATCH")
  should.equal(mock_transport.path(edit), "/api/webhooks/app1/itok/messages/m2")
  should.equal(mock_transport.method(delete), "DELETE")
}

pub fn commands_are_listed_and_overwritten_test() {
  let mock = mock_transport.always(200, "[{\"id\":\"c1\",\"name\":\"ping\"}]")
  let api = make_bot(mock_transport.transport(mock))
  let command =
    json.object([
      #("name", json.string("ping")),
      #("description", json.string("Pong")),
    ])
  let assert Ok([_]) = bot.overwrite_commands(api, "team1", "app1", [command])
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.method(request), "PUT")
  should.equal(
    mock_transport.path(request),
    "/api/users/@me/teams/team1/applications/app1/commands",
  )
  should.be_true(mock_transport.body_text(request) |> string.starts_with("["))
}

pub fn room_messages_go_through_the_bot_test() {
  let mock = mock_transport.always(200, "{\"id\":\"m1\"}")
  let api = make_bot(mock_transport.transport(mock))
  let message =
    json.object([
      #("content", json.string("hi")),
      #("components", json.array([], fn(value) { value })),
    ])
  let assert Ok(_) = bot.send_message(api, "r1", message)
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.method(request), "POST")
  should.equal(mock_transport.path(request), "/api/rooms/r1/messages")
}

fn is_auth_error(result: Result(a, error.DuvetError)) -> Bool {
  case result {
    Error(error.AuthError(_)) -> True
    _ -> False
  }
}
