import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}

/// A JSON object, as the API and the gateway send them.
pub type Object =
  Dict(String, Dynamic)

pub fn empty_object() -> Object {
  dict.new()
}

/// The value at [key], when the object has it and it isn't null.
pub fn field(object: Object, key: String) -> Option(Dynamic) {
  case dict.get(object, key) {
    Ok(value) ->
      case is_null(value) {
        True -> None
        False -> Some(value)
      }
    Error(Nil) -> None
  }
}

@external(erlang, "duvet_json_ffi", "is_null")
@external(javascript, "../../duvet_json_ffi.mjs", "is_null")
fn is_null(value: Dynamic) -> Bool

fn required(object: Object, key: String) -> Dynamic {
  case field(object, key) {
    Some(value) -> value
    None -> panic as "a model field is missing"
  }
}

fn decode_as(decoder: decode.Decoder(a), value: Dynamic, _key: String) -> a {
  case decode.run(value, decoder) {
    Ok(inner) -> inner
    Error(_) -> panic as "a model field has the wrong type"
  }
}

pub fn string(object: Object, key: String) -> String {
  decode_as(decode.string, required(object, key), key)
}

pub fn optional_string(object: Object, key: String) -> Option(String) {
  case field(object, key) {
    Some(value) -> Some(decode_as(decode.string, value, key))
    None -> None
  }
}

/// The field as a string, or [default] when it is null or missing.
pub fn string_or(object: Object, key: String, default: String) -> String {
  case optional_string(object, key) {
    Some(value) -> value
    None -> default
  }
}

pub fn int(object: Object, key: String) -> Int {
  decode_as(decode.int, required(object, key), key)
}

/// A value already in hand, read as an integer.
pub fn int_value(value: Dynamic, key: String) -> Int {
  decode_as(decode.int, value, key)
}

/// A value already in hand, read as an object.
pub fn object_value(value: Dynamic, key: String) -> Object {
  as_object(value, key)
}

pub fn optional_int(object: Object, key: String) -> Option(Int) {
  case field(object, key) {
    Some(value) -> Some(decode_as(decode.int, value, key))
    None -> None
  }
}

pub fn int_or(object: Object, key: String, default: Int) -> Int {
  case optional_int(object, key) {
    Some(value) -> value
    None -> default
  }
}

/// A `num` field: an integer or a decimal, as a float.
pub fn number(object: Object, key: String) -> Float {
  as_number(required(object, key), key)
}

pub fn optional_number(object: Object, key: String) -> Option(Float) {
  case field(object, key) {
    Some(value) -> Some(as_number(value, key))
    None -> None
  }
}

fn as_number(value: Dynamic, key: String) -> Float {
  let decoder =
    decode.one_of(decode.float, [decode.map(decode.int, int.to_float)])
  decode_as(decoder, value, key)
}

pub fn bool(object: Object, key: String) -> Bool {
  decode_as(decode.bool, required(object, key), key)
}

pub fn optional_bool(object: Object, key: String) -> Option(Bool) {
  case field(object, key) {
    Some(value) -> Some(decode_as(decode.bool, value, key))
    None -> None
  }
}

pub fn bool_or(object: Object, key: String, default: Bool) -> Bool {
  case optional_bool(object, key) {
    Some(value) -> value
    None -> default
  }
}

/// An object field that must be there.
pub fn object(object: Object, key: String) -> Object {
  as_object(required(object, key), key)
}

pub fn optional_object(object: Object, key: String) -> Option(Object) {
  case field(object, key) {
    Some(value) -> Some(as_object(value, key))
    None -> None
  }
}

fn as_object(value: Dynamic, key: String) -> Object {
  decode_as(decode.dict(decode.string, decode.dynamic), value, key)
}

/// A value already in hand, read as an object when it is one.
pub fn as_object_or_none(value: Dynamic) -> Option(Object) {
  case is_null(value) {
    True -> None
    False ->
      case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
        Ok(fields) -> Some(fields)
        Error(_) -> None
      }
  }
}

/// The field when it is a string, and None when it isn't (a credential that
/// isn't a password is an object, and is left out).
pub fn optional_string_when_string(
  object: Object,
  key: String,
) -> Option(String) {
  case field(object, key) {
    Some(value) -> as_string_or_none(value)
    None -> None
  }
}

/// A value already in hand, read as a string when it is one.
pub fn as_string_or_none(value: Dynamic) -> Option(String) {
  case is_null(value) {
    True -> None
    False ->
      case decode.run(value, decode.string) {
        Ok(text) -> Some(text)
        Error(_) -> None
      }
  }
}

/// Turns a model's decoder into one for the model's position in a list or a
/// map, where the value arrives still untyped.
pub fn on_object(read: fn(Object) -> item) -> fn(Dynamic) -> item {
  fn(value) { read(as_object(value, "an object in a list")) }
}

/// A value already in hand, read as a list of objects; null reads as none.
pub fn objects_value(value: Dynamic) -> List(Object) {
  case is_null(value) {
    True -> []
    False ->
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) ->
          list.map(items, fn(item) { as_object(item, "an object in a list") })
        Error(_) -> []
      }
  }
}

/// A list of objects, each read by [read].
pub fn objects(
  object: Object,
  key: String,
  read: fn(Object) -> item,
) -> List(item) {
  list(object, key, on_object(read))
}

pub fn optional_objects(
  object: Object,
  key: String,
  read: fn(Object) -> item,
) -> Option(List(item)) {
  optional_list(object, key, on_object(read))
}

pub fn objects_or_empty(
  object: Object,
  key: String,
  read: fn(Object) -> item,
) -> List(item) {
  list_or_empty(object, key, on_object(read))
}

/// A list whose items [decode] reads, when the field is there and not null.
pub fn optional_list(
  object: Object,
  key: String,
  decode decode: fn(Dynamic) -> item,
) -> Option(List(item)) {
  case field(object, key) {
    Some(value) -> Some(as_list(value, key, decode))
    None -> None
  }
}

/// A list that must be there, whose items [decode] reads.
pub fn list(
  object: Object,
  key: String,
  decode decode: fn(Dynamic) -> item,
) -> List(item) {
  as_list(required(object, key), key, decode)
}

/// The field as a list, or [] when it is null or missing.
pub fn list_or_empty(
  object: Object,
  key: String,
  decode decode: fn(Dynamic) -> item,
) -> List(item) {
  case optional_list(object, key, decode) {
    Some(items) -> items
    None -> []
  }
}

fn as_list(
  value: Dynamic,
  key: String,
  decode: fn(Dynamic) -> item,
) -> List(item) {
  let items: List(Dynamic) = decode_as(decode.list(decode.dynamic), value, key)
  list.map(items, decode)
}

pub fn string_list(object: Object, key: String) -> List(String) {
  list(object, key, fn(value) { decode_as(decode.string, value, key) })
}

/// A value already in hand, read as a list of strings.
pub fn string_list_value(value: Dynamic, key: String) -> List(String) {
  as_list(value, key, fn(item) { decode_as(decode.string, item, key) })
}

/// A value already in hand, read as a list of integers.
pub fn int_list_value(value: Dynamic, key: String) -> List(Int) {
  as_list(value, key, fn(item) { decode_as(decode.int, item, key) })
}

/// A value already in hand, read as one string or a list of them (a "urls"
/// field takes either); anything else reads as [].
pub fn string_or_string_list_value(
  value: Dynamic,
  key: String,
) -> List(String) {
  case decode.run(value, decode.string) {
    Ok(url) -> [url]
    Error(_) ->
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) ->
          list.map(items, fn(item) { decode_as(decode.string, item, key) })
        Error(_) -> []
      }
  }
}

pub fn optional_string_list(
  object: Object,
  key: String,
) -> Option(List(String)) {
  optional_list(object, key, fn(value) { decode_as(decode.string, value, key) })
}

pub fn string_list_or_empty(object: Object, key: String) -> List(String) {
  list_or_empty(object, key, fn(value) { decode_as(decode.string, value, key) })
}

pub fn string_map(object: Object, key: String) -> Dict(String, String) {
  as_string_map(required(object, key), key)
}

pub fn optional_string_map(
  object: Object,
  key: String,
) -> Option(Dict(String, String)) {
  case field(object, key) {
    Some(value) -> Some(as_string_map(value, key))
    None -> None
  }
}

pub fn string_map_or_empty(
  object: Object,
  key: String,
) -> Dict(String, String) {
  case optional_string_map(object, key) {
    Some(value) -> value
    None -> dict.new()
  }
}

fn as_string_map(value: Dynamic, key: String) -> Dict(String, String) {
  let fields: Dict(String, Dynamic) =
    decode_as(decode.dict(decode.string, decode.dynamic), value, key)
  fields
  |> dict.to_list
  |> list.map(fn(pair) { #(pair.0, decode_as(decode.string, pair.1, key)) })
  |> dict.from_list
}

pub fn map(
  object: Object,
  key: String,
  decode decode: fn(Dynamic) -> item,
) -> Dict(String, item) {
  as_map(required(object, key), key, decode)
}

/// A map of objects, each read by [read].
pub fn map_objects(
  object: Object,
  key: String,
  read: fn(Object) -> item,
) -> Dict(String, item) {
  map(object, key, on_object(read))
}

pub fn map_objects_or_empty(
  object: Object,
  key: String,
  read: fn(Object) -> item,
) -> Dict(String, item) {
  map_or_empty(object, key, on_object(read))
}

pub fn map_or_empty(
  object: Object,
  key: String,
  decode decode: fn(Dynamic) -> item,
) -> Dict(String, item) {
  case optional_map(object, key, decode) {
    Some(value) -> value
    None -> dict.new()
  }
}

pub fn optional_map(
  object: Object,
  key: String,
  decode decode: fn(Dynamic) -> item,
) -> Option(Dict(String, item)) {
  case field(object, key) {
    Some(value) -> Some(as_map(value, key, decode))
    None -> None
  }
}

fn as_map(
  value: Dynamic,
  key: String,
  decode: fn(Dynamic) -> item,
) -> Dict(String, item) {
  let fields: Dict(String, Dynamic) =
    decode_as(decode.dict(decode.string, decode.dynamic), value, key)
  fields
  |> dict.to_list
  |> list.map(fn(pair) { #(pair.0, decode(pair.1)) })
  |> dict.from_list
}

/// A timestamp, as `DateTime.parse` reads one.
///
/// Dart keeps microseconds, so anything finer is dropped here too: two
/// timestamps that differ only below a microsecond are the same one.
pub fn time(object: Object, key: String) -> Timestamp {
  parse_time(string(object, key), key)
}

pub fn optional_time(object: Object, key: String) -> Option(Timestamp) {
  case optional_string(object, key) {
    Some(text) -> Some(parse_time(text, key))
    None -> None
  }
}

pub fn parse_time(text: String, _key: String) -> Timestamp {
  case timestamp.parse_rfc3339(text) {
    Ok(parsed) -> truncate_to_microseconds(parsed)
    Error(Nil) -> panic as "a model timestamp is not RFC 3339"
  }
}

fn truncate_to_microseconds(parsed: Timestamp) -> Timestamp {
  let #(seconds, nanoseconds) =
    timestamp.to_unix_seconds_and_nanoseconds(parsed)
  let micros = 1000
  timestamp.from_unix_seconds_and_nanoseconds(
    seconds,
    nanoseconds - { nanoseconds % micros },
  )
}

/// A timestamp as Dart's `DateTime.toUtc().toIso8601String()` writes it:
/// microseconds when there are any, milliseconds otherwise.
pub fn format_time(parsed: Timestamp) -> String {
  let #(seconds, nanoseconds) =
    timestamp.to_unix_seconds_and_nanoseconds(parsed)
  let base =
    timestamp.to_rfc3339(
      timestamp.from_unix_seconds(seconds),
      duration.seconds(0),
    )
  let without_z = string.drop_end(base, 1)
  without_z <> fraction(nanoseconds) <> "Z"
}

fn fraction(nanoseconds: Int) -> String {
  let milliseconds = nanoseconds / 1_000_000
  case nanoseconds % 1000 {
    0 -> "." <> pad(milliseconds, 3)
    _ -> "." <> pad(nanoseconds / 1000, 6)
  }
}

fn pad(value: Int, digits: Int) -> String {
  let text = int.to_string(value)
  string.repeat("0", digits - string.length(text)) <> text
}
