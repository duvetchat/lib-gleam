import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

/// One HTTP exchange, as the transport sees it: everything already encoded,
/// with no interpretation of the answer.
pub type Request {
  Request(
    method: String,
    url: String,
    headers: List(#(String, String)),
    /// The body, in pieces of at most 64 KiB: [] for none.
    body: List(BitArray),
  )
}

pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: BitArray)
}

/// Why an exchange didn't finish.
pub type ExchangeError {
  /// No progress for the transport's timeout.
  Timeout
  /// The connection failed, was closed, or something else went wrong. The
  /// string is the lower-level reason, for logs.
  Network(String)
}

/// Performs one exchange. Reports the bytes of the request body sent and of
/// the answer received so far through the callback, which is how the caller's
/// idle timeout follows progress.
///
/// The real transport blocks: the caller runs it in a process it can kill to
/// abort the exchange, which closes the connection.
pub type Transport =
  fn(Request, fn(Int) -> Nil) -> Result(Response, ExchangeError)

/// The body of [response] as a string, when it's valid UTF-8.
pub fn response_text(response: Response) -> String {
  let assert Ok(text) = bit_array.to_string(response.body)
  text
}

/// A header's value, case-insensitively, as HTTP has them.
pub fn header(response: Response, name: String) -> Result(String, Nil) {
  let wanted = string.lowercase(name)
  response.headers
  |> list.find(fn(pair) { string.lowercase(pair.0) == wanted })
  |> result.map(fn(pair) { pair.1 })
}

/// The transport the library ships: hackney, through duvet_hackney_ffi.
///
/// [timeout_ms] bounds each wait for progress at the socket level as well as
/// the caller's own timer, so a stuck exchange can't outlive it if the caller
/// is killed at an awkward moment.
pub fn hackney(timeout_ms: Int) -> Transport {
  fn(request: Request, on_progress: fn(Int) -> Nil) {
    ffi_request(
      request.method,
      request.url,
      request.headers,
      request.body,
      timeout_ms,
      on_progress,
    )
    |> result.map(fn(answer) {
      let #(status, headers, body) = answer
      Response(status: status, headers: headers, body: body)
    })
  }
}

@external(erlang, "duvet_hackney_ffi", "request")
fn ffi_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  pieces: List(BitArray),
  timeout: Int,
  on_progress: fn(Int) -> Nil,
) -> Result(#(Int, List(#(String, String)), BitArray), ExchangeError)
