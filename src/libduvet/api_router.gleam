import gleam/list
import gleam/string

/// Where the API, the gateway and the other services live.
pub type ApiRouter {
  ApiRouter(
    api: String,
    ws: String,
    base: String,
    cdn: String,
    /// Whether the API and the gateway are reached over TLS (https, wss), as
    /// the hosted ones are; a local server (e.g. `localhost:9876`) may not be.
    secure: Bool,
  )
}

/// The hosted service.
pub fn default_router() -> ApiRouter {
  ApiRouter(
    api: "api.duvet.chat",
    ws: "ws.duvet.chat",
    base: "duvet.chat",
    cdn: "none",
    secure: True,
  )
}

pub const api_base_path = "/api"

pub fn custom_api_url(router: ApiRouter, protocol: String) -> String {
  case protocol {
    "http" -> router.api
    "ws" -> router.ws
    _ -> router.base
  }
}

/// The API's URL for [path], whose segments must already be encoded, with
/// [query]'s values; a key repeated repeats in the query.
pub fn url_from_path(
  router: ApiRouter,
  path: String,
  query: List(#(String, String)),
) -> String {
  let full = case string.starts_with(path, api_base_path) {
    True -> path
    False -> api_base_path <> path
  }
  let base = case router.secure {
    True -> "https://" <> router.api <> full
    False -> "http://" <> router.api <> full
  }
  case query {
    [] -> base
    pairs -> base <> "?" <> query_string(pairs)
  }
}

/// Encodes query pairs the way Dart's `Uri.replace(queryParameters:)` does:
/// space as `+`, and everything but the unreserved characters escaped as
/// uppercase UTF-8 percent escapes.
pub fn query_string(pairs: List(#(String, String))) -> String {
  pairs
  |> list.map(fn(pair) {
    encode_query_component(pair.0) <> "=" <> encode_query_component(pair.1)
  })
  |> string.join("&")
}

/// Encodes one path segment, as Dart's `Uri.encodeComponent` does: a space is
/// `%20`, and the unreserved characters stay as they are.
pub fn encode_component(text: String) -> String {
  text
  |> utf8_bytes
  |> list.map(fn(byte) {
    case is_unreserved(byte) {
      True -> byte_to_string(byte)
      False ->
        "%"
        <> string.slice(hex_digits, byte / 16, 1)
        <> string.slice(hex_digits, byte % 16, 1)
    }
  })
  |> string.concat
}

pub fn encode_query_component(text: String) -> String {
  text
  |> utf8_bytes
  |> list.map(encode_byte)
  |> string.concat
}

fn encode_byte(byte: Int) -> String {
  case byte {
    32 -> "+"
    _ ->
      case is_unreserved(byte) {
        True -> byte_to_string(byte)
        False ->
          "%"
          <> string.slice(hex_digits, byte / 16, 1)
          <> string.slice(hex_digits, byte % 16, 1)
      }
  }
}

fn is_unreserved(byte: Int) -> Bool {
  case byte {
    _ if byte >= 48 && byte <= 57 -> True
    _ if byte >= 65 && byte <= 90 -> True
    _ if byte >= 97 && byte <= 122 -> True
    45 | 46 | 95 | 126 -> True
    _ -> False
  }
}

const hex_digits = "0123456789ABCDEF"

@external(erlang, "duvet_json_ffi", "bytes")
fn utf8_bytes(text: String) -> List(Int)

@external(erlang, "duvet_json_ffi", "byte_to_string")
fn byte_to_string(byte: Int) -> String
