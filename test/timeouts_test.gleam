import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/order
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import gleeunit
import gleeunit/should
import libduvet/api_router
import libduvet/error
import libduvet/http/client
import libduvet/http/methods
import libduvet/http/multipart
import libduvet/http/transport
import support/cell
import support/silent_server

pub fn main() -> Nil {
  gleeunit.main()
}

const message_time = "2026-10-22T10:00:00.123456Z"

fn message_json() -> String {
  "{\"id\":\"m1\",\"room_id\":\"r1\",\"author_id\":\"u1\",\"content\":\"look\",\"type\":0,\"created_at\":\""
  <> message_time
  <> "\",\"updated_at\":\""
  <> message_time
  <> "\"}"
}

fn router_on(port: Int) -> api_router.ApiRouter {
  api_router.ApiRouter(
    api: "127.0.0.1:" <> int.to_string(port),
    ws: "ws.duvet.chat",
    base: "duvet.chat",
    cdn: "none",
    secure: False,
  )
}

fn client_on(
  transport: transport.Transport,
  port: Int,
  token: String,
  session_token: String,
  timeout_ms: Int,
) -> client.RestClient {
  client.new(transport, router_on(port), token, session_token, timeout_ms)
}

fn zeros(size: Int) -> BitArray {
  zeroes(size)
}

@external(erlang, "duvet_json_ffi", "zeroes")
fn zeroes(size: Int) -> BitArray

fn elapsed(start: timestamp.Timestamp) -> Duration {
  timestamp.difference(start, timestamp.system_time())
}

pub fn a_request_with_no_answer_times_out_and_drops_its_connection_test() {
  let server = silent_server.start(True)
  let api =
    client_on(
      transport.hackney(300),
      silent_server.port(server),
      "tok",
      "",
      300,
    )
  let watch = timestamp.system_time()
  case methods.get_friends(api) {
    Error(error.RequestTimeout(..)) -> Nil
    _ -> should.fail()
  }
  let took = elapsed(watch)
  should.be_true(duration.compare(took, duration.milliseconds(300)) != order.Lt)
  should.be_true(duration.compare(took, duration.seconds(5)) == order.Lt)
  silent_server.dropped(server)
  silent_server.stop(server)
}

pub fn a_session_refresh_with_no_answer_times_out_keeping_the_tokens_test() {
  let server = silent_server.start(True)
  let api =
    client_on(
      transport.hackney(300),
      silent_server.port(server),
      "tok",
      "sess",
      300,
    )
  case client.refresh_session(api) {
    Error(error.RequestTimeout(..)) -> Nil
    _ -> should.fail()
  }
  should.equal(client.token(api), "tok")
  should.equal(client.session_token(api), "sess")
  silent_server.stop(server)
}

pub fn a_cancelled_upload_stops_mid_way_and_drops_its_connection_test() {
  let server = silent_server.start(False)
  let api =
    client_on(
      transport.hackney(20_000),
      silent_server.port(server),
      "tok",
      "",
      20_000,
    )
  let progress = cell.new(#(0, 0))
  let abort = process.new_subject()
  let options = methods.send_message_options()
  let options =
    methods.SendMessageOptions(
      ..options,
      files: [
        multipart.FilePart(
          field: "files",
          bytes: zeros(8 * 1024 * 1024),
          filename: "big.bin",
        ),
      ],
      on_progress: Some(fn(sent, total) {
        cell.update(progress, fn(_) { #(sent, total) })
      }),
      abort: Some(abort),
    )
  let _ =
    process.spawn(fn() {
      process.sleep(500)
      process.send(abort, Nil)
    })
  case methods.send_message(api, "r1", "look", options) {
    Error(error.RequestAborted) -> Nil
    _ -> should.fail()
  }
  let #(sent, total) = cell.get(progress)
  should.be_true(sent > 0)
  should.be_true(sent < total)
  silent_server.resume(server)
  silent_server.dropped(server)
  silent_server.stop(server)
}

pub fn an_upload_to_a_slow_server_reports_its_progress_and_finishes_test() {
  let server = silent_server.start_slow(message_json())
  let api =
    client_on(
      transport.hackney(20_000),
      silent_server.port(server),
      "tok",
      "",
      20_000,
    )
  let progress = cell.new([])
  let options = methods.send_message_options()
  let options =
    methods.SendMessageOptions(
      ..options,
      files: [
        multipart.FilePart(
          field: "files",
          bytes: zeros(4 * 1024 * 1024),
          filename: "big.bin",
        ),
      ],
      on_progress: Some(fn(sent, total) {
        cell.update(progress, fn(values) {
          list.append(values, [#(sent, total)])
        })
      }),
    )
  let assert Ok(message) = methods.send_message(api, "r1", "look", options)
  should.equal(message.id, "m1")
  let values = cell.get(progress)
  let assert [#(_, total), ..] = values
  should.equal(silent_server.received(server), total)
  should.be_true(list.length(values) > 10)
  let #(last, last_total) = case list.reverse(values) {
    [pair, ..] -> pair
    [] -> #(0, 0)
  }
  should.equal(last, last_total)
  let sent = list.map(values, fn(pair) { pair.0 })
  let assert [first, ..rest] = sent
  let increasing =
    list.fold(rest, #(first, True), fn(state, value) {
      let #(previous, ok) = state
      #(value, ok && value > previous)
    })
  let #(_, rose) = increasing
  should.be_true(rose)
  silent_server.stop(server)
}

// ---------------------------------------------------------------------------
// The timeout counts from the last progress
// ---------------------------------------------------------------------------

fn upload_files() -> List(multipart.FilePart) {
  [
    multipart.FilePart(
      field: "files",
      bytes: zeros(10 * 64 * 1024),
      filename: "a.bin",
    ),
  ]
}

/// A transport that takes each piece of a request's body after [pause] (by
/// the piece's number), reporting progress, then answers a message.
fn slow_client(pause: fn(Int) -> Int) -> transport.Transport {
  fn(
    request: transport.Request,
    on_progress: fn(Int) -> Nil,
    _on_activity: fn() -> Nil,
  ) {
    let pieces =
      list.index_map(request.body, fn(piece, index) {
        #(index, bit_array.byte_size(piece))
      })
    let _ =
      list.fold(pieces, 0, fn(sent, piece) {
        process.sleep(pause(piece.0))
        let sent = sent + piece.1
        on_progress(sent)
        sent
      })
    Ok(transport.Response(
      status: 200,
      headers: [#("content-type", "application/json")],
      body: bit_array.from_string(message_json()),
    ))
  }
}

pub fn an_upload_longer_than_the_timeout_goes_through_test() {
  let api =
    client.new(
      slow_client(fn(_) { 100 }),
      api_router.default_router(),
      "tok",
      "",
      400,
    )
  let watch = timestamp.system_time()
  let options = methods.send_message_options()
  let options = methods.SendMessageOptions(..options, files: upload_files())
  let assert Ok(message) = methods.send_message(api, "r1", "look", options)
  should.equal(message.id, "m1")
  should.be_true(
    duration.compare(elapsed(watch), duration.milliseconds(800)) == order.Gt,
  )
}

pub fn an_upload_that_stalls_for_longer_fails_test() {
  let api =
    client.new(
      slow_client(fn(index) {
        case index {
          3 -> 900
          _ -> 50
        }
      }),
      api_router.default_router(),
      "tok",
      "",
      400,
    )
  let options = methods.send_message_options()
  let options = methods.SendMessageOptions(..options, files: upload_files())
  case methods.send_message(api, "r1", "look", options) {
    Error(error.RequestTimeout(..)) -> Nil
    _ -> should.fail()
  }
}
