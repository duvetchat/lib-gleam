import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import libduvet/gateway/socket
import support/fake_gateway

pub fn main() -> Nil {
  gleeunit.main()
}

// Phase 0's smoke test: the FFI, the socket owner and its subject carry a
// real upgrade and a real READY, against the fake gateway.
pub fn hears_ready_from_the_fake_gateway_test() {
  let server = fake_gateway.start()
  let port = fake_gateway.port(server)
  let url = "ws://127.0.0.1:" <> int.to_string(port) <> "/gateway?token=tok"
  let stream = socket.start(url, [#("Authorization", "Bearer tok")], 5000)

  await_opened(stream)
  should.be_true(socket.send(stream, identify_json()))

  let ready = await_text(stream, 50)
  should.be_true(string.contains(ready, "\"READY\""))
  should.equal(fake_gateway.tokens(server), ["tok"])

  socket.close(stream)
  fake_gateway.stop(server)
}

fn identify_json() -> String {
  "{\"type\":\"identify\",\"data\":{\"token\":\"tok\"}}"
}

fn await_opened(stream: socket.Socket) -> Nil {
  case socket.next_event(stream, 5000) {
    Ok(socket.Opened) -> Nil
    Ok(other) -> {
      io.println(string.inspect(other))
      await_opened(stream)
    }
    Error(_) -> panic as "the socket didn't open"
  }
}

fn await_text(stream: socket.Socket, attempts: Int) -> String {
  case socket.next_event(stream, 5000) {
    Ok(socket.Frames(frames)) -> {
      case first_text(frames) {
        Ok(text) -> text
        Error(_) -> await_text(stream, attempts - 1)
      }
    }
    Ok(_) -> await_text(stream, attempts - 1)
    Error(_) -> panic as "no READY came"
  }
}

fn first_text(frames: List(socket.Frame)) -> Result(String, Nil) {
  list.find_map(frames, fn(frame) {
    case frame {
      socket.TextFrame(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}
