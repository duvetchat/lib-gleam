import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}
import libduvet/model/decoding

/// A file: one sent with a message, or one of a user's or a space's files
/// (their attachment lists).
pub type Attachment {
  Attachment(
    id: String,
    message_id: Option(String),
    filename: String,
    content_type: String,
    size_bytes: Int,
    width: Option(Int),
    height: Option(Int),
    created_at: Timestamp,
    deleted_at: Option(Timestamp),
    deleted: Option(Bool),
    pending: Option(Bool),
    url: Option(String),
  )
}

pub fn from_json(object: decoding.Object) -> Attachment {
  Attachment(
    id: decoding.string(object, "id"),
    message_id: decoding.optional_string(object, "message_id"),
    filename: decoding.string(object, "filename"),
    content_type: decoding.string(object, "content_type"),
    size_bytes: decoding.int(object, "size_bytes"),
    width: decoding.optional_int(object, "width"),
    height: decoding.optional_int(object, "height"),
    created_at: decoding.time(object, "created_at"),
    deleted_at: decoding.optional_time(object, "deleted_at"),
    deleted: decoding.optional_bool(object, "deleted"),
    pending: decoding.optional_bool(object, "pending"),
    url: decoding.optional_string(object, "url"),
  )
}
