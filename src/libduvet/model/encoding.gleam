import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

/// The entries that are set, for `json.object`: a nullable field that is
/// absent stays out of the document, as Dart's `if (x != null)` maps do.
pub fn present(
  entries: List(Option(#(String, json.Json))),
) -> List(#(String, json.Json)) {
  list.filter_map(entries, fn(entry) {
    case entry {
      Some(pair) -> Ok(pair)
      None -> Error(Nil)
    }
  })
}

pub fn optional_string(
  key: String,
  value: Option(String),
) -> Option(#(String, json.Json)) {
  case value {
    Some(inner) -> Some(#(key, json.string(inner)))
    None -> None
  }
}

pub fn optional_int(
  key: String,
  value: Option(Int),
) -> Option(#(String, json.Json)) {
  case value {
    Some(inner) -> Some(#(key, json.int(inner)))
    None -> None
  }
}

pub fn optional_bool(
  key: String,
  value: Option(Bool),
) -> Option(#(String, json.Json)) {
  case value {
    Some(inner) -> Some(#(key, json.bool(inner)))
    None -> None
  }
}

pub fn optional_json(
  key: String,
  value: Option(a),
  encode: fn(a) -> json.Json,
) -> Option(#(String, json.Json)) {
  case value {
    Some(inner) -> Some(#(key, encode(inner)))
    None -> None
  }
}

pub fn optional_list_json(
  key: String,
  value: Option(List(a)),
  encode: fn(a) -> json.Json,
) -> Option(#(String, json.Json)) {
  case value {
    Some(items) -> Some(#(key, json.array(items, encode)))
    None -> None
  }
}

/// The field when it is set, encoded as [None] stays absent.
pub fn nullable(
  key: String,
  value: List(json.Json),
) -> Option(#(String, json.Json)) {
  case value {
    [] -> None
    items -> Some(#(key, json.preprocessed_array(items)))
  }
}
