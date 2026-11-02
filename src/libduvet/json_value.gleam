import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list

/// Any JSON value, kept as it came for the places the API's documents are
/// opaque (a component's payload, a command option's value), so that it can
/// go back out unchanged.
pub type JsonValue {
  JsonNull
  JsonBool(Bool)
  JsonInt(Int)
  JsonFloat(Float)
  JsonString(String)
  JsonArray(List(JsonValue))
  JsonObject(dict.Dict(String, JsonValue))
}

/// Reads [data], a value decoded from JSON, as a [JsonValue].
pub fn from_dynamic(data: Dynamic) -> JsonValue {
  let decoder =
    decode.one_of(decode.map(decode.bool, JsonBool), [
      decode.map(decode.int, JsonInt),
      decode.map(decode.float, JsonFloat),
      decode.map(decode.string, JsonString),
      decode.map(decode.list(decode.dynamic), fn(items) {
        JsonArray(list.map(items, from_dynamic))
      }),
      decode.map(decode.dict(decode.string, decode.dynamic), fn(fields) {
        JsonObject(
          fields
          |> dict.to_list
          |> list.map(fn(pair) { #(pair.0, from_dynamic(pair.1)) })
          |> dict.from_list,
        )
      }),
      // JSON null, after every other value: nothing else fails them all.
      decode.map(decode.dynamic, fn(_) { JsonNull }),
    ])
  case decode.run(data, decoder) {
    Ok(value) -> value
    Error(_) -> panic as "not a JSON value"
  }
}

/// An object already decoded, as a [JsonValue].
pub fn from_object(object: dict.Dict(String, Dynamic)) -> JsonValue {
  JsonObject(
    object
    |> dict.to_list
    |> list.map(fn(pair) { #(pair.0, from_dynamic(pair.1)) })
    |> dict.from_list,
  )
}

/// The same value as [JsonValue], for encoding with `gleam/json`.
pub fn to_json(value: JsonValue) -> json.Json {
  case value {
    JsonNull -> json.null()
    JsonBool(inner) -> json.bool(inner)
    JsonInt(inner) -> json.int(inner)
    JsonFloat(inner) -> json.float(inner)
    JsonString(inner) -> json.string(inner)
    JsonArray(items) -> json.array(items, to_json)
    JsonObject(fields) ->
      json.object(
        fields
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, to_json(pair.1)) }),
      )
  }
}
