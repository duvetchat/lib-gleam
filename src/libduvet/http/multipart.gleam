import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string

/// A file part of a multipart request.
pub type FilePart {
  FilePart(field: String, bytes: BitArray, filename: String)
}

/// A multipart form, encoded as `http.MultipartRequest` encodes it in the Dart
/// package.
pub type Form {
  Form(content_type: String, body: BitArray)
}

/// How many members a page of the space-members endpoint has.
pub const members_page_size = 50

/// How long a bio may be once trimmed, in characters as the API counts them:
/// Unicode code points, so an emoji such as 😀 is one.
pub const max_bio_length = 190

const voice_note = "voice-note"

/// A voice note goes as the file voice-note.<format>, with the media type of
/// its format: WebM/Opus as the desktop app records it, Ogg/Opus, or AAC in
/// MP4.
fn voice_note_types(extension: String) -> Result(String, Nil) {
  case extension {
    "webm" -> Ok("audio/webm")
    "ogg" -> Ok("audio/ogg")
    "m4a" -> Ok("audio/mp4")
    _ -> Error(Nil)
  }
}

/// The media types of the files the API takes, by extension: it keeps the type
/// a file part declares.
fn media_type_of_extension(extension: String) -> Result(String, Nil) {
  case extension {
    "png" -> Ok("image/png")
    "jpg" -> Ok("image/jpeg")
    "jpeg" -> Ok("image/jpeg")
    "gif" -> Ok("image/gif")
    "webp" -> Ok("image/webp")
    "avif" -> Ok("image/avif")
    "svg" -> Ok("image/svg+xml")
    "mp4" -> Ok("video/mp4")
    "webm" -> Ok("video/webm")
    "mov" -> Ok("video/quicktime")
    "mp3" -> Ok("audio/mpeg")
    "m4a" -> Ok("audio/mp4")
    "ogg" -> Ok("audio/ogg")
    "wav" -> Ok("audio/wav")
    "flac" -> Ok("audio/flac")
    "pdf" -> Ok("application/pdf")
    "txt" -> Ok("text/plain")
    "json" -> Ok("application/json")
    "zip" -> Ok("application/zip")
    _ -> Error(Nil)
  }
}

fn split_extension(filename: String) -> #(String, String) {
  case list.reverse(string.split(filename, ".")) {
    [extension, ..rest] ->
      case rest {
        [] -> #(extension, "")
        _ -> #(
          string.join(list.reverse(rest), "."),
          string.lowercase(extension),
        )
      }
    [] -> #(filename, "")
  }
}

/// The media type a file part declares, from its name.
pub fn media_type_of(filename: String) -> String {
  let #(stem, extension) = split_extension(filename)
  let voice_note = case stem == voice_note {
    True -> voice_note_types(extension)
    False -> Error(Nil)
  }
  case voice_note {
    Ok(media_type) -> media_type
    Error(Nil) ->
      case media_type_of_extension(extension) {
        Ok(media_type) -> media_type
        Error(Nil) -> "application/octet-stream"
      }
  }
}

/// A file's name without its folders: on Windows a path may separate them with
/// either slash.
pub fn basename(path: String) -> String {
  case string.split(path, "/") {
    [] -> path
    parts -> last(parts)
  }
}

fn last(parts: List(String)) -> String {
  case parts {
    [] -> ""
    [only] -> only
    [_, ..rest] -> last(rest)
  }
}

/// Encodes the form, with the fields first and the files after, as Dart's
/// multipart encoder writes it.
pub fn encode(fields: List(#(String, String)), files: List(FilePart)) -> Form {
  let boundary = "dart-http-boundary-" <> unique_integer()
  let parts =
    list.append(
      list.map(fields, fn(field) { field_part(boundary, field.0, field.1) }),
      list.map(files, fn(file) { file_part(boundary, file) }),
    )
  let body =
    bit_array.concat(
      list.append(parts, [bit_array.from_string("--" <> boundary <> "--\r\n")]),
    )
  Form(content_type: "multipart/form-data; boundary=" <> boundary, body: body)
}

fn field_part(boundary: String, name: String, value: String) -> BitArray {
  bit_array.from_string(
    "--"
    <> boundary
    <> "\r\ncontent-disposition: form-data; name=\""
    <> name
    <> "\"\r\n\r\n"
    <> value
    <> "\r\n",
  )
}

fn file_part(boundary: String, file: FilePart) -> BitArray {
  bit_array.concat([
    bit_array.from_string(
      "--"
      <> boundary
      <> "\r\ncontent-type: "
      <> media_type_of(file.filename)
      <> "\r\ncontent-disposition: form-data; name=\""
      <> file.field
      <> "\"; filename=\""
      <> file.filename
      <> "\"\r\n\r\n",
    ),
    file.bytes,
    bit_array.from_string("\r\n"),
  ])
}

/// A request body's bytes in pieces of at most this many bytes, so that
/// progress and the idle timeout follow what the socket takes.
pub const piece_size = 65_536

pub fn pieces(body: BitArray) -> List(BitArray) {
  split(body, 0, [])
}

fn split(body: BitArray, offset: Int, acc: List(BitArray)) -> List(BitArray) {
  case offset >= bit_array.byte_size(body) {
    True -> list.reverse(acc)
    False -> {
      let size = int.min(piece_size, bit_array.byte_size(body) - offset)
      let assert Ok(piece) = bit_array.slice(body, offset, size)
      split(body, offset + size, [piece, ..acc])
    }
  }
}

@external(erlang, "duvet_json_ffi", "unique_integer")
fn unique_integer() -> String
