import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit
import gleeunit/should
import libduvet/api_router
import libduvet/gateway/client
import libduvet/gateway/feed.{
  type Feed, type FeedMessage, Payload, Resumed, StateChanged,
}
import libduvet/gateway/manager
import libduvet/http/client as rest
import libduvet/http/transport
import libduvet/model/decoding
import libduvet/model/envelope
import support/fake_gateway
import support/recorder

pub fn main() -> Nil {
  gleeunit.main()
}

const token = "secret-access-token-0123"

/// How many events the gateway replays: enough for a resume heard too early to
/// land among them.
const replayed = 20

type Opened {
  Opened(connect: fn() -> Bool, feed: Feed, destroy: fn() -> Nil)
}

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

fn open_client(server: fake_gateway.Server) -> Opened {
  let config =
    client.config(api_on(server), feed.start())
    |> client.with_router(router_on(server))
    |> client.with_resume(True)
  let gateway = client.start(config)
  Opened(
    connect: fn() {
      case client.connect(gateway) {
        Ok(_) -> True
        Error(_) -> False
      }
    },
    feed: config.feed,
    destroy: fn() { client.destroy(gateway) },
  )
}

fn open_manager(server: fake_gateway.Server) -> Opened {
  let config =
    manager.config(api_on(server))
    |> manager.with_router(router_on(server))
    |> manager.with_resume(True)
  let mgr = manager.start(config)
  Opened(
    connect: fn() {
      case manager.connect_all(mgr, 1) {
        Ok(_) -> True
        Error(_) -> False
      }
    },
    feed: manager.feed(config),
    destroy: fn() { manager.destroy(mgr) },
  )
}

fn range(start: Int, end: Int) -> List(Int) {
  case start > end {
    True -> []
    False -> [start, ..range(start + 1, end)]
  }
}

fn deleted_frame(s: Int, id: String) -> fake_gateway.RawFrame {
  let data = "{\"id\":\"" <> id <> "\",\"room_id\":\"r1\"}"
  let json =
    "{\"event\":\"payload\",\"op\":1,\"s\":"
    <> int.to_string(s)
    <> ",\"d\":{\"type\":\"MESSAGE_DELETE\",\"data\":"
    <> data
    <> "}}"
  fake_gateway.RawText(json)
}

fn replay() -> List(fake_gateway.RawFrame) {
  list.map(range(1, replayed), fn(index) {
    deleted_frame(index + 1, "m" <> int.to_string(index))
  })
}

fn ack_frame() -> fake_gateway.RawFrame {
  fake_gateway.RawText("{\"event\":\"heartbeat_ack\"}")
}

fn wait_identified(server: fake_gateway.Server, count: Int) -> Nil {
  fake_gateway.wait_identifies(server, count)
}

fn await_ready(rec: recorder.Recorder, timeout_ms: Int) -> Nil {
  let _ =
    recorder.poll_until(rec, timeout_ms, fn(messages) {
      list.any(messages, fn(message) {
        case message {
          Payload(envelope.ReadyEvent(_)) -> True
          _ -> False
        }
      })
    })
  Nil
}

fn last_identified(server: fake_gateway.Server) -> decoding.Object {
  let texts = fake_gateway.identified(server)
  case list.last(texts) {
    Ok(text) ->
      case
        json.parse(
          from: text,
          using: decode.dict(decode.string, decode.dynamic),
        )
      {
        Ok(object) -> object
        Error(_) -> decoding.empty_object()
      }
    Error(Nil) -> decoding.empty_object()
  }
}

fn log_line(message: FeedMessage) -> Result(String, Nil) {
  case message {
    Payload(envelope.ReadyEvent(data)) -> Ok("READY " <> data.session_token)
    Payload(envelope.MessageDeletedEvent(data)) -> Ok("deleted " <> data.id)
    Resumed(_) -> Ok("resumed")
    StateChanged(state) -> Ok(state_text(state))
    _ -> Error(Nil)
  }
}

fn state_text(state: feed.GatewayConnectionState) -> String {
  case state {
    feed.Connecting -> "connecting"
    feed.Connected -> "connected"
    feed.Reconnecting -> "reconnecting"
    feed.Disconnected -> "disconnected"
  }
}

fn log_of(rec: recorder.Recorder) -> List(String) {
  recorder.messages(rec) |> list.filter_map(log_line)
}

fn await_log(
  rec: recorder.Recorder,
  wanted: List(String),
  timeout_ms: Int,
) -> Nil {
  let _ =
    recorder.poll_until(rec, timeout_ms, fn(messages) {
      list.filter_map(messages, log_line) == wanted
    })
  Nil
}

fn await_resumed(rec: recorder.Recorder, count: Int, timeout_ms: Int) -> Nil {
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
      >= count
    })
  Nil
}

/// Connects, hears READY on the first socket, drops it, and answers the second
/// socket's resuming identify with nothing: the test writes what comes.
fn resume_on_second(
  opened: Opened,
  server: fake_gateway.Server,
  rec: recorder.Recorder,
) -> Nil {
  should.be_true(opened.connect())
  wait_identified(server, 1)
  await_ready(rec, 5000)
  // From here the gateway answers a resuming identify with nothing, as if it
  // were slow: the test writes the replay, the ack and any close itself.
  fake_gateway.set_answers_resumes(server, False)
  fake_gateway.drop(server)
  wait_identified(server, 2)
  fake_gateway.wait_heartbeats(server, 1)
}

fn tail_from_last(items: List(String), marker: String) -> List(String) {
  let reversed = list.reverse(items)
  list.reverse(take_through(reversed, marker))
}

fn take_through(items: List(String), marker: String) -> List(String) {
  case items {
    [] -> []
    [item, ..rest] ->
      case item == marker {
        True -> [item]
        False -> [item, ..take_through(rest, marker)]
      }
  }
}

// ---------------------------------------------------------------------------
// The tests
// ---------------------------------------------------------------------------

pub fn the_ack_in_the_same_read_as_the_replay_test() {
  list.each([False, True], fn(as_manager) {
    let server = fake_gateway.start()
    let opened = case as_manager {
      True -> open_manager(server)
      False -> open_client(server)
    }
    let rec = recorder.start(opened.feed)
    resume_on_second(opened, server, rec)

    fake_gateway.write_batch(server, list.append(replay(), [ack_frame()]))
    await_resumed(rec, 1, 5000)
    // A live event after it, in a read of its own.
    fake_gateway.write_batch(server, [deleted_frame(replayed + 2, "live")])
    let _ =
      recorder.poll_until(rec, 5000, fn(messages) {
        list.any(messages, fn(message) {
          case message {
            Payload(envelope.MessageDeletedEvent(data)) -> data.id == "live"
            _ -> False
          }
        })
      })
    let expected =
      list.flatten([
        [
          "connecting",
          "connected",
          "READY session-1",
          "reconnecting",
          "connected",
        ],
        list.map(range(1, replayed), fn(index) {
          "deleted m" <> int.to_string(index)
        }),
        ["resumed", "deleted live"],
      ])
    await_log(rec, expected, 2000)
    should.equal(log_of(rec), expected)
    opened.destroy()
    fake_gateway.stop(server)
  })
}

pub fn a_close_in_the_same_read_as_the_ack_test() {
  list.each([False, True], fn(as_manager) {
    let server = fake_gateway.start()
    let opened = case as_manager {
      True -> open_manager(server)
      False -> open_client(server)
    }
    let rec = recorder.start(opened.feed)
    resume_on_second(opened, server, rec)

    fake_gateway.write_batch(
      server,
      list.append(replay(), [ack_frame(), fake_gateway.RawClose(1000)]),
    )
    wait_identified(server, 3)
    // The replay came through: the session goes on from its last event.
    let resume_identify = last_identified(server)
    should.equal(
      decoding.optional_int(resume_identify, "last_seq"),
      Some(replayed + 1),
    )
    should.equal(
      decoding.optional_string(resume_identify, "session_token"),
      Some("session-1"),
    )
    fake_gateway.write_batch(server, [ack_frame()])
    await_resumed(rec, 1, 5000)
    let deletes =
      log_of(rec)
      |> list.filter(fn(line) { string.starts_with(line, "deleted") })
    should.equal(
      deletes,
      list.map(range(1, replayed), fn(index) {
        "deleted m" <> int.to_string(index)
      }),
    )
    // As an app reads them, the last of the two says whether the session is
    // live: from the close on, not before the next socket resumed it.
    let tail = tail_from_last(log_of(rec), "reconnecting")
    should.equal(
      list.filter(tail, fn(line) { !string.starts_with(line, "deleted") }),
      ["reconnecting", "connected", "resumed"],
    )
    opened.destroy()
    fake_gateway.stop(server)
  })
}
