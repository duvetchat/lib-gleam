import gleam/bit_array
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import libduvet/model/decoding

/// The fixture for [name] and [variant], as a JSON object.
@external(erlang, "duvet_fixtures", "read")
fn read(name: String, variant: String) -> BitArray

pub fn load(name: String, variant: String) -> decoding.Object {
  case
    json.parse(
      from: bit_array_to_string(read(name, variant)),
      using: decode.dict(decode.string, decode.dynamic),
    )
  {
    Ok(object) -> object
    Error(_) -> panic as "a fixture is not JSON"
  }
}

/// An environment variable, or "" when it isn't set.
@external(erlang, "duvet_fixtures", "env")
pub fn env(name: String) -> String

/// Reads a text file of the repository, for the checks that look at sources.
@external(erlang, "duvet_fixtures", "read_text")
pub fn read_text(path: String) -> String

fn bit_array_to_string(bits: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(bits)
  text
}

/// The three variants of [name], each with the keys the server always sets
/// (although its type allows null) taken from the full one.
pub fn variants(
  name: String,
  always: List(String),
) -> List(#(String, decoding.Object)) {
  let full = load(name, "full")
  let fixed = fn(object: decoding.Object) {
    list.fold(always, object, fn(object, key) {
      case dict.get(full, key) {
        Ok(value) -> dict.insert(object, key, value)
        Error(Nil) -> object
      }
    })
  }
  [
    #("full", full),
    #("nulls", fixed(load(name, "nulls"))),
    #("partial", fixed(load(name, "partial"))),
  ]
}

/// [object] with [key] set to null, as the server sends it in some cases.
pub fn with_null(object: decoding.Object, key: String) -> decoding.Object {
  dict.insert(object, key, dynamic.nil())
}

/// [object] without [key], as an omitempty field leaves it.
pub fn without(object: decoding.Object, key: String) -> decoding.Object {
  dict.delete(object, key)
}
