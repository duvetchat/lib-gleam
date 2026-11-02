import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import libduvet/http/transport
import libduvet/model/decoding

/// A transport whose answers a function gives, recording every request it
/// gets: the equivalent of Dart's MockClient.
pub opaque type Mock {
  Mock(transport_function: transport.Transport, subject: Subject(Message))
}

type Message {
  Record(request: transport.Request)
  Sent(reply: Subject(List(transport.Request)))
}

pub fn start(
  reply: fn(transport.Request) ->
    Result(transport.Response, transport.ExchangeError),
) -> Mock {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(subject, [])
    })
  let subject = process.receive_forever(ready)
  let transport_function = fn(
    request: transport.Request,
    _on_progress: fn(Int) -> Nil,
    _on_activity: fn() -> Nil,
  ) {
    process.send(subject, Record(request))
    reply(request)
  }
  Mock(transport_function: transport_function, subject: subject)
}

/// A transport that answers [status] with [body] every time.
pub fn always(status: Int, body: String) -> Mock {
  start(fn(_) { Ok(response(status, body)) })
}

pub fn transport(mock: Mock) -> transport.Transport {
  mock.transport_function
}

/// Every request the server got, in order.
pub fn sent(mock: Mock) -> List(transport.Request) {
  let reply = process.new_subject()
  process.send(mock.subject, Sent(reply))
  process.receive_forever(reply)
}

fn loop(subject: Subject(Message), requests: List(transport.Request)) -> Nil {
  case process.receive_forever(subject) {
    Record(request) -> loop(subject, [request, ..requests])
    Sent(reply) -> {
      process.send(reply, list.reverse(requests))
      loop(subject, requests)
    }
  }
}

pub fn response(status: Int, body: String) -> transport.Response {
  transport.Response(
    status: status,
    headers: [#("content-type", "application/json")],
    body: bit_array.from_string(body),
  )
}

pub fn json_response(value: json.Json) -> transport.Response {
  response(200, json.to_string(value))
}

pub fn method(request: transport.Request) -> String {
  request.method
}

pub fn path(request: transport.Request) -> String {
  case uri.parse(request.url) {
    Ok(parsed) -> parsed.path
    Error(Nil) -> request.url
  }
}

/// The query pairs, decoded, in the order they went out.
pub fn query(request: transport.Request) -> List(#(String, String)) {
  case uri.parse(request.url) {
    Ok(parsed) ->
      case parsed.query {
        Some(query) ->
          case uri.parse_query(query) {
            Ok(pairs) -> pairs
            Error(Nil) -> []
          }
        None -> []
      }
    Error(Nil) -> []
  }
}

pub fn header(request: transport.Request, name: String) -> Result(String, Nil) {
  let wanted = string.lowercase(name)
  request.headers
  |> list.find(fn(pair) { string.lowercase(pair.0) == wanted })
  |> result.map(fn(pair) { pair.1 })
}

pub fn has_header(request: transport.Request, name: String) -> Bool {
  case header(request, name) {
    Ok(_) -> True
    Error(Nil) -> False
  }
}

pub fn body_text(request: transport.Request) -> String {
  request.body
  |> list.map(fn(piece) { bit_array.to_string(piece) })
  |> list.map(fn(piece) {
    case piece {
      Ok(text) -> text
      Error(Nil) -> ""
    }
  })
  |> string.concat
}

pub fn body_json(request: transport.Request) -> Result(decoding.Object, Nil) {
  json.parse(
    from: body_text(request),
    using: decode.dict(decode.string, decode.dynamic),
  )
  |> result.map_error(fn(_) { Nil })
}
