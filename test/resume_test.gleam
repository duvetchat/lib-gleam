import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit
import gleeunit/should
import libduvet/api_router
import libduvet/gateway/client
import libduvet/gateway/feed.{
  type FeedMessage, type GatewayConnectionState, Closed, Connected, Connecting,
  Disconnected, Payload, Reconnecting, Resumed, StateChanged,
}
import libduvet/gateway/manager
import libduvet/http/client as rest
import libduvet/http/transport
import libduvet/model/client_platform
import libduvet/model/decoding
import libduvet/model/envelope
import support/fake_gateway
import support/recorder

pub fn main() -> Nil {
  gleeunit.main()
}

const token = "secret-access-token-0123"

fn router_on(server: fake_gateway.Server) -> api_router.ApiRouter {
  let port = int.to_string(fake_gateway.port(server))
  api_router.ApiRouter(
    api: "127.0.0.1:" <> port,
    ws: "127.0.0.1:" <> port,
    base: "127.0.0.1:" <> port,
    cdn: "none",
    secure: False,
  )
}

fn api_on(server: fake_gateway.Server) -> rest.RestClient {
  rest.new(transport.hackney(5000), router_on(server), token, "", 20_000)
}

fn client_on(
  server: fake_gateway.Server,
  resume: Bool,
  platform: Option(client_platform.ClientPlatform),
  shard_id: Int,
  shard_count: Int,
) -> #(client.GatewayClient, recorder.Recorder) {
  let config =
    client.config(api_on(server), feed.start())
    |> client.with_router(router_on(server))
    |> client.with_resume(resume)
    |> client.with_shard(shard_id, shard_count)
  let config = case platform {
    Some(platform) -> client.with_platform(config, platform)
    None -> config
  }
  let rec = recorder.start(config.feed)
  #(client.start(config), rec)
}

fn manager_on(
  server: fake_gateway.Server,
) -> #(manager.GatewayManager, recorder.Recorder) {
  let config = manager_config(server)
  let rec = recorder.start(manager.feed(config))
  #(manager.start(config), rec)
}

fn deleted_json(id: String) -> String {
  "{\"id\":\"" <> id <> "\",\"room_id\":\"r1\"}"
}

fn push_deleted(server: fake_gateway.Server, id: String) -> Nil {
  fake_gateway.push(server, "MESSAGE_DELETE", deleted_json(id))
}

fn identified(server: fake_gateway.Server) -> List(decoding.Object) {
  fake_gateway.identified(server)
  |> list.map(fn(text) {
    case
      json.parse(from: text, using: decode.dict(decode.string, decode.dynamic))
    {
      Ok(object) -> object
      Error(_) -> decoding.empty_object()
    }
  })
}

fn last_identified(server: fake_gateway.Server) -> decoding.Object {
  case list.last(identified(server)) {
    Ok(object) -> object
    Error(Nil) -> decoding.empty_object()
  }
}

fn log_line(message: FeedMessage) -> Result(String, Nil) {
  case message {
    Payload(envelope.ReadyEvent(data)) -> Ok("READY " <> data.session_token)
    Payload(envelope.MessageDeletedEvent(data)) -> Ok("deleted " <> data.id)
    Resumed(_) -> Ok("resumed")
    _ -> Error(Nil)
  }
}

fn log_of(rec: recorder.Recorder) -> List(String) {
  recorder.messages(rec)
  |> list.filter_map(log_line)
}

fn state_text(state: GatewayConnectionState) -> String {
  case state {
    Connecting -> "connecting"
    Connected -> "connected"
    Reconnecting -> "reconnecting"
    Disconnected -> "disconnected"
  }
}

fn states_of(rec: recorder.Recorder) -> List(String) {
  recorder.messages(rec)
  |> list.filter_map(fn(message) {
    case message {
      StateChanged(state) -> Ok(state_text(state))
      _ -> Error(Nil)
    }
  })
}

fn await_ready_count(
  rec: recorder.Recorder,
  count: Int,
  timeout_ms: Int,
) -> Nil {
  let _ =
    recorder.poll_until(rec, timeout_ms, fn(messages) {
      list.length(
        list.filter_map(messages, fn(message) {
          case message {
            Payload(envelope.ReadyEvent(_)) -> Ok(Nil)
            _ -> Error(Nil)
          }
        }),
      )
      == count
    })
  Nil
}

fn await_resumed(rec: recorder.Recorder, timeout_ms: Int) -> Nil {
  let _ =
    recorder.poll_until(rec, timeout_ms, fn(messages) {
      list.any(messages, fn(message) {
        case message {
          Resumed(_) -> True
          _ -> False
        }
      })
    })
  Nil
}

fn await_disconnected(rec: recorder.Recorder, timeout_ms: Int) -> Nil {
  let _ =
    recorder.poll_until(rec, timeout_ms, fn(messages) {
      case list.last(states_of_from(messages)) {
        Ok("disconnected") -> True
        _ -> False
      }
    })
  Nil
}

fn states_of_from(messages: List(FeedMessage)) -> List(String) {
  messages
  |> list.filter_map(fn(message) {
    case message {
      StateChanged(state) -> Ok(state_text(state))
      _ -> Error(Nil)
    }
  })
}

fn await_deleted(rec: recorder.Recorder, id: String, timeout_ms: Int) -> Nil {
  let _ =
    recorder.poll_until(rec, timeout_ms, fn(messages) {
      list.any(messages, fn(message) {
        case message {
          Payload(envelope.MessageDeletedEvent(data)) -> data.id == id
          _ -> False
        }
      })
    })
  Nil
}

fn assert_identify(
  object: decoding.Object,
  expected: List(#(String, dynamic.Dynamic)),
) -> Nil {
  list.each(expected, fn(pair) {
    let #(key, value) = pair
    should.equal(decoding.field(object, key), Some(value))
  })
  let unexpected =
    list.filter(
      [
        "token",
        "last_seq",
        "session_token",
        "shard_id",
        "num_shards",
        "platform",
      ],
      fn(key) { !list.any(expected, fn(pair) { pair.0 == key }) },
    )
  list.each(unexpected, fn(key) {
    should.equal(decoding.field(object, key), None)
  })
}

// ---------------------------------------------------------------------------
// Resuming
// ---------------------------------------------------------------------------

pub fn without_resume_each_socket_starts_a_new_session_test() {
  let server = fake_gateway.start()
  let #(gateway, rec) = client_on(server, False, None, 0, 1)
  let assert Ok(Nil) = client.connect(gateway)
  fake_gateway.wait_identifies(server, 1)
  push_deleted(server, "m1")
  await_deleted(rec, "m1", 5000)

  fake_gateway.drop(server)
  await_ready_count(rec, 2, 5000)
  let payloads = identified(server)
  let assert [first, second] = payloads
  assert_identify(first, [#("token", dynamic.string(token))])
  assert_identify(second, [
    #("token", dynamic.string(token)),
    #("last_seq", dynamic.int(2)),
  ])
  should.equal(log_of(rec), [
    "READY session-1",
    "deleted m1",
    "READY session-2",
  ])
  client.destroy(gateway)
  fake_gateway.stop(server)
}

pub fn with_resume_the_session_goes_on_test() {
  let server = fake_gateway.start()
  let #(mgr, rec) = manager_on(server)
  let assert Ok(Nil) = manager.connect_all(mgr, 1)
  await_ready_count(rec, 1, 5000)
  push_deleted(server, "m1")
  await_deleted(rec, "m1", 5000)

  fake_gateway.drop(server)
  // Sent while no socket was open: the session keeps them.
  push_deleted(server, "m2")
  push_deleted(server, "m3")
  await_resumed(rec, 5000)
  assert_identify(last_identified(server), [
    #("token", dynamic.string(token)),
    #("last_seq", dynamic.int(2)),
    #("session_token", dynamic.string("session-1")),
  ])
  should.equal(manager.connection(mgr), Some(2))

  push_deleted(server, "m4")
  await_deleted(rec, "m4", 5000)
  should.equal(log_of(rec), [
    "READY session-1",
    "deleted m1",
    "deleted m2",
    "deleted m3",
    "resumed",
    "deleted m4",
  ])
  should.equal(states_of(rec), [
    "connecting",
    "connected",
    "reconnecting",
    "connected",
  ])

  // A resumed session keeps its token: it resumes again.
  fake_gateway.drop(server)
  await_resumed_twice(rec, 5000)
  assert_identify(last_identified(server), [
    #("token", dynamic.string(token)),
    #("last_seq", dynamic.int(5)),
    #("session_token", dynamic.string("session-1")),
  ])
  should.equal(
    list.length(
      list.filter(log_of(rec), fn(line) { string.starts_with(line, "READY") }),
    ),
    1,
  )
  manager.destroy(mgr)
  fake_gateway.stop(server)
}

fn manager_config(server: fake_gateway.Server) -> manager.Config {
  manager.config(api_on(server))
  |> manager.with_router(router_on(server))
  |> manager.with_resume(True)
}

fn await_resumed_twice(rec: recorder.Recorder, timeout_ms: Int) -> Nil {
  let _ =
    recorder.poll_until(rec, timeout_ms, fn(messages) {
      list.length(
        list.filter(messages, fn(message) {
          case message {
            Resumed(_) -> True
            _ -> False
          }
        }),
      )
      >= 2
    })
  Nil
}

pub fn a_session_the_gateway_cannot_resume_test() {
  let server = fake_gateway.start()
  fake_gateway.set_resumes(server, False)
  let #(gateway, rec) = client_on(server, True, None, 0, 1)
  let assert Ok(Nil) = client.connect(gateway)
  await_ready_count(rec, 1, 5000)

  fake_gateway.drop(server)
  await_ready_count(rec, 2, 5000)
  should.equal(
    decoding.optional_string(last_identified(server), "session_token"),
    Some("session-1"),
  )
  fake_gateway.wait_heartbeats(server, 1)
  process.sleep(200)
  should.equal(log_of(rec), ["READY session-1", "READY session-2"])

  // The new session is the one to resume from now on.
  fake_gateway.set_resumes(server, True)
  fake_gateway.drop(server)
  await_resumed(rec, 5000)
  assert_identify(last_identified(server), [
    #("token", dynamic.string(token)),
    #("last_seq", dynamic.int(1)),
    #("session_token", dynamic.string("session-2")),
  ])
  client.destroy(gateway)
  fake_gateway.stop(server)
}

pub fn an_identify_that_resumes_says_the_apps_platform_test() {
  let server = fake_gateway.start()
  fake_gateway.set_resumes(server, False)
  let #(gateway, rec) =
    client_on(server, True, Some(client_platform.mobile), 0, 1)
  let assert Ok(Nil) = client.connect(gateway)
  await_ready_count(rec, 1, 5000)

  fake_gateway.drop(server)
  await_ready_count(rec, 2, 5000)
  assert_identify(last_identified(server), [
    #("token", dynamic.string(token)),
    #("last_seq", dynamic.int(1)),
    #("session_token", dynamic.string("session-1")),
    #("platform", dynamic.string("mobile")),
  ])
  fake_gateway.wait_heartbeats(server, 1)
  client.destroy(gateway)
  fake_gateway.stop(server)
}

pub fn want_fresh_session_starts_a_new_one_then_resumes_test() {
  let server = fake_gateway.start()
  let #(gateway, rec) = client_on(server, True, None, 0, 1)
  let assert Ok(Nil) = client.connect(gateway)
  await_ready_count(rec, 1, 5000)

  client.want_fresh_session(gateway)
  fake_gateway.drop(server)
  await_ready_count(rec, 2, 5000)
  assert_identify(last_identified(server), [
    #("token", dynamic.string(token)),
    #("last_seq", dynamic.int(1)),
  ])

  // READY ends the wish.
  fake_gateway.drop(server)
  await_resumed(rec, 5000)
  assert_identify(last_identified(server), [
    #("token", dynamic.string(token)),
    #("last_seq", dynamic.int(1)),
    #("session_token", dynamic.string("session-2")),
  ])
  should.equal(log_of(rec), [
    "READY session-1",
    "READY session-2",
    "resumed",
  ])
  client.destroy(gateway)
  fake_gateway.stop(server)
}

pub fn a_socket_gone_before_answered_with_nothing_resumes_from_the_same_place_test() {
  let server = fake_gateway.start()
  let #(gateway, rec) = client_on(server, True, None, 0, 1)
  let assert Ok(Nil) = client.connect(gateway)
  fake_gateway.wait_identifies(server, 1)
  push_deleted(server, "m1")
  await_deleted(rec, "m1", 5000)

  fake_gateway.set_answers_resumes(server, False)
  fake_gateway.drop(server)
  fake_gateway.wait_identifies(server, 2)
  should.equal(
    decoding.optional_string(last_identified(server), "session_token"),
    Some("session-1"),
  )
  // Nothing came on it, so the sequence number didn't move.
  fake_gateway.set_answers_resumes(server, True)
  fake_gateway.drop(server)
  await_resumed(rec, 5000)
  assert_identify(last_identified(server), [
    #("token", dynamic.string(token)),
    #("last_seq", dynamic.int(2)),
    #("session_token", dynamic.string("session-1")),
  ])
  should.equal(log_of(rec), ["READY session-1", "deleted m1", "resumed"])
  client.destroy(gateway)
  fake_gateway.stop(server)
}

pub fn a_socket_gone_before_answered_with_an_event_starts_a_new_session_test() {
  let server = fake_gateway.start()
  let #(gateway, rec) = client_on(server, True, None, 0, 1)
  let assert Ok(Nil) = client.connect(gateway)
  fake_gateway.wait_identifies(server, 1)
  push_deleted(server, "m1")
  await_deleted(rec, "m1", 5000)

  fake_gateway.set_answers_resumes(server, False)
  fake_gateway.drop(server)
  fake_gateway.wait_identifies(server, 2)
  // It may have been a new session's, whose number would resume the old one
  // at the wrong place.
  push_deleted(server, "m2")
  await_deleted(rec, "m2", 5000)
  fake_gateway.drop(server)
  await_ready_count(rec, 2, 5000)
  assert_identify(last_identified(server), [
    #("token", dynamic.string(token)),
    #("last_seq", dynamic.int(3)),
  ])
  should.equal(log_of(rec), [
    "READY session-1",
    "deleted m1",
    "deleted m2",
    "READY session-2",
  ])
  client.destroy(gateway)
  fake_gateway.stop(server)
}

pub fn an_event_without_a_sequence_number_leaves_where_a_resume_starts_test() {
  let server = fake_gateway.start()
  let #(gateway, rec) = client_on(server, True, None, 0, 1)
  let assert Ok(Nil) = client.connect(gateway)
  await_ready_count(rec, 1, 5000)
  push_deleted(server, "m1")
  fake_gateway.push_bare(server, "MESSAGE_DELETE", deleted_json("m2"))
  let _ =
    recorder.poll_until(rec, 5000, fn(messages) {
      list.length(
        list.filter(messages, fn(message) {
          case message {
            Payload(envelope.MessageDeletedEvent(_)) -> True
            _ -> False
          }
        }),
      )
      >= 2
    })

  fake_gateway.drop(server)
  await_resumed(rec, 5000)
  assert_identify(last_identified(server), [
    #("token", dynamic.string(token)),
    #("last_seq", dynamic.int(2)),
    #("session_token", dynamic.string("session-1")),
  ])
  client.destroy(gateway)
  fake_gateway.stop(server)
}

pub fn a_close_with_4000_stops_the_client_until_the_app_connects_again_test() {
  let server = fake_gateway.start()
  let #(gateway, rec) = client_on(server, False, None, 1, 2)
  let assert Ok(Nil) = client.connect(gateway)
  await_ready_count(rec, 1, 5000)

  fake_gateway.close_with_reason(server, 4000, "shard_id out of range")
  let _ =
    recorder.poll_until(rec, 5000, fn(messages) {
      list.any(messages, fn(message) {
        case message {
          Closed(close) -> close.code == 4000
          _ -> False
        }
      })
    })
  let closes =
    recorder.messages(rec)
    |> list.filter_map(fn(message) {
      case message {
        Closed(close) -> Ok(#(close.code, close.reason, close.shard_id))
        _ -> Error(Nil)
      }
    })
  should.equal(closes, [#(4000, "shard_id out of range", 1)])
  await_disconnected(rec, 5000)
  process.sleep(2500)
  should.equal(list.length(fake_gateway.identified(server)), 1)
  should.equal(client.connection_state(gateway), Disconnected)
  should.be_false(client.retry_now(gateway))

  let assert Ok(Nil) = client.connect(gateway)
  fake_gateway.wait_identifies(server, 2)
  should.equal(client.connection_state(gateway), Connected)
  assert_identify(last_identified(server), [
    #("token", dynamic.string(token)),
    #("last_seq", dynamic.int(1)),
    #("shard_id", dynamic.int(1)),
    #("num_shards", dynamic.int(2)),
  ])
  // Going again: a drop is followed by another socket, as before.
  fake_gateway.drop(server)
  fake_gateway.wait_identifies(server, 3)
  client.destroy(gateway)
  fake_gateway.stop(server)
}

pub fn close_with_reason_then_another_socket_that_resumes_test() {
  let server = fake_gateway.start()
  let #(mgr, rec) = manager_on(server)
  let assert Ok(Nil) = manager.connect_all(mgr, 1)
  await_ready_count(rec, 1, 5000)
  push_deleted(server, "m1")
  await_deleted(rec, "m1", 5000)

  fake_gateway.close_with_reason(server, 4004, "session ended")
  await_resumed(rec, 5000)
  let closes =
    recorder.messages(rec)
    |> list.filter_map(fn(message) {
      case message {
        Closed(close) -> Ok(#(close.code, close.reason))
        _ -> Error(Nil)
      }
    })
  should.equal(closes, [#(4004, "session ended")])
  // The close frame is no event, and left the sequence number alone.
  assert_identify(last_identified(server), [
    #("token", dynamic.string(token)),
    #("last_seq", dynamic.int(2)),
    #("session_token", dynamic.string("session-1")),
  ])
  manager.destroy(mgr)
  fake_gateway.stop(server)
}

pub fn a_close_with_reason_is_not_hearing_from_the_gateway_test() {
  let server = fake_gateway.start()
  let #(gateway, rec) = client_on(server, False, None, 0, 1)
  let assert Ok(Nil) = client.connect(gateway)
  await_ready_count(rec, 1, 5000)
  let heard = timestamp.system_time()

  process.sleep(1000)
  fake_gateway.close_with_reason(server, 4004, "authentication failed")
  await_ready_count(rec, 2, 5000)
  let since_heard = timestamp.difference(heard, timestamp.system_time())
  let silence = client.silence_before_ready(gateway)
  should.be_true(
    duration.compare(
      silence,
      duration.subtract(since_heard, duration.milliseconds(300)),
    )
    == order.Gt,
  )
  client.destroy(gateway)
  fake_gateway.stop(server)
}
