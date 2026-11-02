import gleam/dict
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
  type FeedMessage, type GatewayConnectionState, ConnectFailed, Connected,
  Connecting, Disconnected, Payload, Reconnecting, StateChanged,
}
import libduvet/gateway/manager
import libduvet/http/client as rest
import libduvet/http/transport
import libduvet/model/client_platform
import libduvet/model/decoding
import libduvet/model/envelope
import libduvet/model/ready
import support/cell
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

type Harness {
  Harness(
    manager: manager.GatewayManager,
    recorder: recorder.Recorder,
    logs: cell.Cell(List(String)),
  )
}

fn manager_on(
  server: fake_gateway.Server,
  connect_timeout: Int,
  platform: Option(client_platform.ClientPlatform),
  resume: Bool,
) -> Harness {
  let logs = cell.new([])
  let config =
    manager.config(api_on(server))
    |> manager.with_router(router_on(server))
    |> manager.with_connect_timeout(connect_timeout)
    |> manager.with_resume(resume)
    |> manager.with_log(fn(_shard, message) {
      cell.update(logs, fn(messages) { list.append(messages, [message]) })
    })
  let config = case platform {
    Some(platform) -> manager.with_platform(config, platform)
    None -> config
  }
  let mgr = manager.start(config)
  let rec = recorder.start(manager.feed(mgr))
  Harness(manager: mgr, recorder: rec, logs: logs)
}

fn client_on(
  server: fake_gateway.Server,
  connect_timeout: Int,
  resume: Bool,
  platform: Option(client_platform.ClientPlatform),
  logs: cell.Cell(List(String)),
) -> #(client.GatewayClient, recorder.Recorder) {
  let config =
    client.config(api_on(server), feed.start())
    |> client.with_router(router_on(server))
    |> client.with_connect_timeout(connect_timeout)
    |> client.with_resume(resume)
    |> client.with_log(fn(message) {
      cell.update(logs, fn(messages) { list.append(messages, [message]) })
    })
  let config = case platform {
    Some(platform) -> client.with_platform(config, platform)
    None -> config
  }
  let rec = recorder.start(config.feed)
  #(client.start(config), rec)
}

fn state_text(state: GatewayConnectionState) -> String {
  case state {
    Connecting -> "connecting"
    Connected -> "connected"
    Reconnecting -> "reconnecting"
    Disconnected -> "disconnected"
  }
}

fn states_of(messages: List(FeedMessage)) -> List(String) {
  messages
  |> list.filter_map(fn(message) {
    case message {
      StateChanged(state) -> Ok(state_text(state))
      _ -> Error(Nil)
    }
  })
}

fn states(rec: recorder.Recorder) -> List(String) {
  states_of(recorder.messages(rec))
}

fn await_states(
  rec: recorder.Recorder,
  expected: List(String),
  timeout_ms: Int,
) -> List(String) {
  recorder.poll_until(rec, timeout_ms, fn(messages) {
    states_of(messages) == expected
  })
  |> states_of
}

fn wrote_log(
  logs: cell.Cell(List(String)),
  wanted: fn(String) -> Bool,
) -> Bool {
  cell.get(logs) |> list.any(wanted)
}

fn log_contains(logs: cell.Cell(List(String)), text: String) -> Bool {
  wrote_log(logs, fn(message) { string.contains(message, text) })
}

fn ready_of(
  messages: List(FeedMessage),
) -> Result(ready.GatewayReadyData, Nil) {
  messages
  |> list.find_map(fn(message) {
    case message {
      Payload(envelope.ReadyEvent(data)) -> Ok(data)
      _ -> Error(Nil)
    }
  })
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

// ---------------------------------------------------------------------------
// The tests
// ---------------------------------------------------------------------------

pub fn connects_identifies_with_the_token_and_hears_ready_test() {
  let server = fake_gateway.start()
  let harness = manager_on(server, client.default_connect_timeout, None, False)
  let assert Ok(Nil) = manager.connect_all(harness.manager, 1)
  let messages =
    recorder.until(harness.recorder, 5000, fn(message) {
      case message {
        Payload(envelope.ReadyEvent(_)) -> True
        _ -> False
      }
    })
  let assert Ok(ready) = ready_of(messages)
  should.equal(ready.user.id, "u1")
  should.equal(fake_gateway.tokens(server), [token])
  // A person's: no shard, which the gateway would refuse (4000).
  should.equal(list.map(identified(server), fn(object) { object }), [
    dict.from_list([#("token", dynamic.string(token))]),
  ])
  should.equal(
    await_states(harness.recorder, ["connecting", "connected"], 5000),
    ["connecting", "connected"],
  )
  should.be_true(log_contains(harness.logs, "connecting to ws://127.0.0.1:"))
  should.be_false(log_contains(harness.logs, token))
  manager.destroy(harness.manager)
  fake_gateway.stop(server)
}

pub fn a_dropped_socket_is_replaced_by_one_new_socket_test() {
  let server = fake_gateway.start()
  let harness = manager_on(server, client.default_connect_timeout, None, False)
  let assert Ok(Nil) = manager.connect_all(harness.manager, 1)
  fake_gateway.wait_identifies(server, 1)
  let _ = await_states(harness.recorder, ["connecting", "connected"], 5000)

  fake_gateway.drop(server)
  let _ =
    await_states(
      harness.recorder,
      ["connecting", "connected", "reconnecting"],
      5000,
    )
  fake_gateway.wait_identifies(server, 2)
  let _ =
    await_states(
      harness.recorder,
      ["connecting", "connected", "reconnecting", "connected"],
      5000,
    )
  process.sleep(1000)
  should.equal(fake_gateway.tokens(server), [token, token])
  should.equal(fake_gateway.most_open(server), 1)
  should.equal(fake_gateway.open_count(server), 1)
  should.equal(
    await_states(
      harness.recorder,
      ["connecting", "connected", "reconnecting", "connected"],
      2000,
    ),
    ["connecting", "connected", "reconnecting", "connected"],
  )
  manager.destroy(harness.manager)
  fake_gateway.stop(server)
}

pub fn the_first_connection_keeps_trying_until_the_gateway_takes_it_test() {
  let server = fake_gateway.start()
  fake_gateway.set_plan(server, [
    fake_gateway.Refuse(503),
    fake_gateway.Refuse(503),
  ])
  let harness = manager_on(server, client.default_connect_timeout, None, False)
  let assert Ok(Nil) = manager.connect_all(harness.manager, 1)
  fake_gateway.wait_identifies(server, 1)
  should.equal(list.length(fake_gateway.tokens(server)), 3)
  should.equal(
    await_states(
      harness.recorder,
      ["connecting", "disconnected", "reconnecting", "connected"],
      5000,
    ),
    ["connecting", "disconnected", "reconnecting", "connected"],
  )
  should.be_true(
    wrote_log(harness.logs, fn(message) {
      string.contains(message, "reconnecting in ")
    }),
  )
  should.be_false(log_contains(harness.logs, token))
  let times = fake_gateway.token_times(server)
  let assert [first, second, third] = times
  should.be_true(second - first >= 1000)
  should.be_true(third - second >= 2000)
  manager.destroy(harness.manager)
  fake_gateway.stop(server)
}

pub fn the_wait_before_each_attempt_grows_to_30_seconds_test() {
  let checks = [
    #(0, 1),
    #(1, 2),
    #(2, 4),
    #(3, 8),
    #(4, 16),
    #(5, 30),
    #(6, 30),
    #(100, 30),
  ]
  list.each(checks, fn(check) {
    let #(failed, seconds) = check
    let wait = client.reconnect_delay(failed, 0)
    should.be_true(wait >= seconds * 1000)
    should.be_true(wait < { seconds + 1 } * 1000)
  })
  // Up to a second at random, not the same for every client.
  let jitters =
    [
      0, 50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 550, 600, 650, 700,
      750, 800, 850, 900, 950,
    ]
    |> list.map(fn(jitter) { client.reconnect_delay(0, jitter) })
    |> list.unique
  should.be_true(list.length(jitters) > 1)
}

pub fn the_apps_platform_goes_in_each_identify_test() {
  let server = fake_gateway.start()
  let harness =
    manager_on(
      server,
      client.default_connect_timeout,
      Some(client_platform.mobile),
      False,
    )
  let assert Ok(Nil) = manager.connect_all(harness.manager, 1)
  fake_gateway.wait_identifies(server, 1)
  fake_gateway.drop(server)
  fake_gateway.wait_identifies(server, 2)
  let payloads = identified(server)
  let assert [first, second] = payloads
  should.equal(decoding.optional_string(first, "platform"), Some("mobile"))
  should.equal(decoding.optional_string(second, "platform"), Some("mobile"))
  manager.destroy(harness.manager)
  fake_gateway.stop(server)
}

pub fn a_bots_shards_send_theirs_in_identify_test() {
  let server = fake_gateway.start()
  // The second shard's first attempt is refused.
  fake_gateway.set_plan(server, [
    fake_gateway.Upgrade,
    fake_gateway.Refuse(401),
  ])
  let harness = manager_on(server, client.default_connect_timeout, None, False)
  let assert Ok(Nil) = manager.connect_all(harness.manager, 2)
  fake_gateway.wait_identifies(server, 2)
  let payloads = identified(server)
  let assert [first, second] = payloads
  should.equal(
    #(
      decoding.optional_int(first, "shard_id"),
      decoding.optional_int(first, "num_shards"),
    ),
    #(Some(0), Some(2)),
  )
  should.equal(
    #(
      decoding.optional_int(second, "shard_id"),
      decoding.optional_int(second, "num_shards"),
    ),
    #(Some(1), Some(2)),
  )
  let failures =
    recorder.messages(harness.recorder)
    |> list.filter_map(fn(message) {
      case message {
        ConnectFailed(failure) -> Ok(failure)
        _ -> Error(Nil)
      }
    })
  let assert [failure] = failures
  should.equal(#(failure.shard_id, failure.failures, failure.http_status), #(
    1,
    1,
    Some(401),
  ))
  manager.destroy(harness.manager)
  fake_gateway.stop(server)
}

pub fn a_socket_the_app_opens_while_the_client_waits_is_the_one_kept_test() {
  let server = fake_gateway.start()
  let logs = cell.new([])
  let #(gateway, rec) =
    client_on(server, client.default_connect_timeout, False, None, logs)
  let assert Ok(Nil) = client.connect(gateway)
  fake_gateway.wait_identifies(server, 1)
  recorder.until(rec, 5000, fn(message) {
    case message {
      StateChanged(Connected) -> True
      _ -> False
    }
  })
  fake_gateway.drop(server)
  recorder.until(rec, 5000, fn(message) {
    case message {
      StateChanged(Reconnecting) -> True
      _ -> False
    }
  })
  // The app, back in the foreground.
  let assert Ok(Nil) = client.connect(gateway)
  fake_gateway.wait_identifies(server, 2)
  let kept = client.connection(gateway)
  process.sleep(2500)
  should.equal(list.length(fake_gateway.identified(server)), 2)
  should.equal(fake_gateway.open_count(server), 1)
  should.equal(client.connection(gateway), kept)
  should.equal(client.connection_state(gateway), Connected)
  client.destroy(gateway)
  fake_gateway.stop(server)
}

pub fn retry_now_ends_the_wait_test() {
  let server = fake_gateway.start()
  let harness = manager_on(server, client.default_connect_timeout, None, False)
  let assert Ok(Nil) = manager.connect_all(harness.manager, 1)
  fake_gateway.wait_identifies(server, 1)
  should.be_false(manager.retry_now(harness.manager))
  fake_gateway.drop(server)
  recorder.until(harness.recorder, 5000, fn(message) {
    case message {
      StateChanged(Reconnecting) -> True
      _ -> False
    }
  })
  let watch = timestamp.system_time()
  should.be_true(manager.retry_now(harness.manager))
  fake_gateway.wait_identifies(server, 2)
  let took = timestamp.difference(watch, timestamp.system_time())
  should.be_true(duration.compare(took, duration.milliseconds(900)) == order.Lt)
  should.be_false(manager.retry_now(harness.manager))
  manager.destroy(harness.manager)
  fake_gateway.stop(server)
}

pub fn an_attempt_that_hangs_is_dropped_after_the_connect_timeout_test() {
  let server = fake_gateway.start()
  fake_gateway.set_plan(server, [fake_gateway.Hold])
  let harness = manager_on(server, 300, None, False)
  let watch = timestamp.system_time()
  let assert Ok(Nil) = manager.connect_all(harness.manager, 1)
  let took = timestamp.difference(watch, timestamp.system_time())
  should.be_true(duration.compare(took, duration.milliseconds(300)) != order.Lt)
  fake_gateway.wait_identifies(server, 1)
  should.equal(list.length(fake_gateway.tokens(server)), 2)
  should.equal(fake_gateway.most_open(server), 1)
  should.be_true(log_contains(harness.logs, "Timeout"))
  manager.destroy(harness.manager)
  fake_gateway.stop(server)
}

pub fn a_clients_connect_fails_within_its_timeout_token_masked_test() {
  let server = fake_gateway.start()
  fake_gateway.set_plan(server, [fake_gateway.Hold, fake_gateway.Refuse(503)])
  let logs = cell.new([])
  let #(gateway, rec) = client_on(server, 200, False, None, logs)
  let watch = timestamp.system_time()
  case client.connect(gateway) {
    Error(client.Failed(failure)) -> {
      should.equal(failure.http_status, None)
      should.be_true(string.contains(failure.error, "Timeout"))
    }
    _ -> should.fail()
  }
  let took = timestamp.difference(watch, timestamp.system_time())
  should.be_true(duration.compare(took, duration.seconds(5)) == order.Lt)
  case client.connect(gateway) {
    Error(client.Failed(failure)) -> {
      should.equal(failure.http_status, Some(503))
      should.be_true(string.contains(failure.error, "HTTP status code: 503"))
      should.be_false(string.contains(failure.error, token))
    }
    _ -> should.fail()
  }
  should.equal(client.connection_state(gateway), Disconnected)
  let failures =
    recorder.messages(rec)
    |> list.filter_map(fn(message) {
      case message {
        ConnectFailed(failure) -> Ok(#(failure.failures, failure.http_status))
        _ -> Error(Nil)
      }
    })
  should.equal(failures, [#(1, None), #(2, Some(503))])
  client.destroy(gateway)
  fake_gateway.stop(server)
}

pub fn each_failed_attempt_reaches_the_app_with_the_gateways_status_test() {
  let server = fake_gateway.start()
  fake_gateway.set_plan(server, [
    fake_gateway.Refuse(401),
    fake_gateway.Refuse(503),
    fake_gateway.Upgrade,
    fake_gateway.Refuse(401),
  ])
  let harness = manager_on(server, client.default_connect_timeout, None, False)
  let assert Ok(Nil) = manager.connect_all(harness.manager, 1)
  fake_gateway.wait_identifies(server, 1)
  let failures =
    recorder.messages(harness.recorder)
    |> list.filter_map(fn(message) {
      case message {
        ConnectFailed(failure) -> Ok(failure)
        _ -> Error(Nil)
      }
    })
  let assert [first, second] = failures
  should.equal(#(first.failures, first.http_status, first.shard_id), #(
    1,
    Some(401),
    0,
  ))
  should.equal(#(second.failures, second.http_status), #(2, Some(503)))
  should.be_false(string.contains(first.error, token))
  let assert [_, _, _] = list.take(fake_gateway.tokens(server), 3)

  fake_gateway.drop(server)
  fake_gateway.wait_identifies(server, 2)
  let again =
    recorder.until(harness.recorder, 5000, fn(message) {
      case message {
        ConnectFailed(failure) ->
          failure.failures == 1 && failure.http_status == Some(401)
        _ -> False
      }
    })
    |> list.filter_map(fn(message) {
      case message {
        ConnectFailed(failure) -> Ok(failure)
        _ -> Error(Nil)
      }
    })
  let assert [_, _, last] = again
  should.equal(#(last.failures, last.http_status), #(1, Some(401)))
  manager.destroy(harness.manager)
  fake_gateway.stop(server)
}

pub fn destroy_while_waiting_to_reconnect_opens_no_socket_test() {
  let server = fake_gateway.start()
  let harness = manager_on(server, client.default_connect_timeout, None, False)
  let assert Ok(Nil) = manager.connect_all(harness.manager, 1)
  fake_gateway.wait_identifies(server, 1)
  fake_gateway.drop(server)
  recorder.until(harness.recorder, 5000, fn(message) {
    case message {
      StateChanged(Reconnecting) -> True
      _ -> False
    }
  })
  manager.destroy(harness.manager)
  process.sleep(2500)
  should.equal(list.length(fake_gateway.tokens(server)), 1)
  should.equal(fake_gateway.open_count(server), 0)
  should.equal(list.last(states(harness.recorder)), Ok("disconnected"))
}

pub fn destroy_while_a_socket_opens_makes_connect_all_fail_test() {
  let server = fake_gateway.start()
  fake_gateway.set_plan(server, [fake_gateway.Hold])
  let harness = manager_on(server, client.default_connect_timeout, None, False)
  let result = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(result, manager.connect_all(harness.manager, 1))
    })
  recorder.until(harness.recorder, 5000, fn(message) {
    case message {
      StateChanged(Connecting) -> True
      _ -> False
    }
  })
  process.sleep(100)
  manager.destroy(harness.manager)
  let assert Error(manager.Destroyed) = process.receive_forever(result)
  process.sleep(500)
  should.equal(fake_gateway.identified(server), [])
  should.equal(list.length(fake_gateway.tokens(server)), 1)
}

pub fn a_destroyed_client_neither_connects_nor_sends_test() {
  let server = fake_gateway.start()
  let logs = cell.new([])
  let #(gateway, _rec) =
    client_on(server, client.default_connect_timeout, False, None, logs)
  should.equal(client.connection_state(gateway), Disconnected)
  should.be_false(client.send_message(gateway, "heartbeat", json.object([])))
  client.destroy(gateway)
  should.be_false(client.wait_for_connection(gateway))
  case client.connect(gateway) {
    Error(client.Destroyed) -> Nil
    _ -> should.fail()
  }
  should.equal(fake_gateway.tokens(server), [])
  should.be_true(log_contains(logs, "cannot send \"heartbeat\""))
  fake_gateway.stop(server)
}
