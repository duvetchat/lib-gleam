import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/timestamp
import libduvet/api_router
import libduvet/error.{type DuvetError}
import libduvet/http/client
import libduvet/http/commands
import libduvet/http/core
import libduvet/http/multipart.{type FilePart}
import libduvet/json_value
import libduvet/model/attachment
import libduvet/model/conversation
import libduvet/model/conversation_type
import libduvet/model/decoding
import libduvet/model/embed
import libduvet/model/message
import libduvet/model/message_type
import libduvet/model/rest
import libduvet/model/room_type.{type RoomType}
import libduvet/model/space
import libduvet/model/user
import libduvet/model/user_status

// ---------------------------------------------------------------------------
// Auth (logging in and out is the client's, which keeps the tokens)
// ---------------------------------------------------------------------------

/// Makes an account; it is verified by the link the API emails.
pub fn sign_in(
  client: client.RestClient,
  username username: String,
  password password: String,
  email email: String,
  alias alias: Option(String),
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/auth/signin",
    "sign in",
    core.JsonBody(
      json.object([
        #("username", json.string(username)),
        #("alias", json.nullable(alias, json.string)),
        #("password", json.string(password)),
        #("email", json.string(email)),
      ]),
    ),
    without_renewal(client),
  )
}

pub fn verify_email(
  client: client.RestClient,
  token: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/auth/verify",
    "verify email",
    json_body([#("token", json.string(token))]),
    without_renewal(client),
  )
}

pub fn send_verification_email(
  client: client.RestClient,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/auth/verify/send",
    "send verification email",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn reset_password(
  client: client.RestClient,
  token: String,
  password: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/auth/reset-password",
    "reset password",
    json_body([
      #("token", json.string(token)),
      #("password", json.string(password)),
    ]),
    without_renewal(client),
  )
}

pub fn forgot_password(
  client: client.RestClient,
  email: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/auth/forgot-password",
    "send reset email",
    json_body([#("email", json.string(email))]),
    without_renewal(client),
  )
}

pub fn send_reset_password_email(
  client: client.RestClient,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/auth/reset-password/send",
    "send reset password email",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn change_email(
  client: client.RestClient,
  token: String,
  email: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/auth/change-email",
    "change email",
    json_body([
      #("token", json.string(token)),
      #("email", json.string(email)),
    ]),
    without_renewal(client),
  )
}

pub fn send_change_email(
  client: client.RestClient,
  email: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/auth/change-email/send",
    "send email change request",
    json_body([#("email", json.string(email))]),
    client_default_meta(client),
  )
}

// ---------------------------------------------------------------------------
// Spaces
// ---------------------------------------------------------------------------

/// Makes a space, with a text and a voice room; answers it with its rooms.
pub fn create_space(
  client: client.RestClient,
  name: String,
  description description: Option(String),
) -> Result(rest.CreatedSpace, DuvetError) {
  let body =
    json_body(
      list.flatten([
        [#("name", json.string(name))],
        case description {
          Some(text) if text != "" -> [#("description", json.string(text))]
          _ -> []
        },
      ]),
    )
  request_model(
    client,
    "POST",
    "/api/spaces",
    "create space",
    body,
    client_default_meta(client),
    rest.created_space_from_json,
  )
}

/// Deletes the space, which only its owner may do.
pub fn delete_space(
  client: client.RestClient,
  space_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/" <> space_id,
    "delete space",
    core.NoBody,
    client_default_meta(client),
  )
}

/// A page of the space's members, by their highest role and then their ID.
pub fn get_space_members(
  client: client.RestClient,
  space_id: String,
  after_id after_id: Option(String),
  after_pos after_pos: Option(Int),
) -> Result(List(rest.SpaceMemberWithUser), DuvetError) {
  let meta =
    client_default_meta(client)
    |> core.with_query(
      list.flatten([
        [#("count", int.to_string(multipart.members_page_size))],
        case after_id {
          Some(value) -> [#("after_id", value)]
          None -> []
        },
        case after_pos {
          Some(value) -> [#("after_pos", int.to_string(value))]
          None -> []
        },
      ]),
    )
  request_list(
    client,
    "GET",
    "/api/spaces/" <> space_id <> "/members",
    "get space members",
    meta,
    rest.space_member_with_user_from_json,
  )
}

pub fn leave_space(
  client: client.RestClient,
  space_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/" <> space_id <> "/members/@me",
    "leave space",
    core.NoBody,
    client_default_meta(client),
  )
}

/// Updates the space. A new banner or icon, or removing one, sends a multipart
/// form; anything else goes as JSON.
pub fn update_space(
  client: client.RestClient,
  space_id: String,
  name name: Option(String),
  description description: Option(String),
  locale locale: Option(String),
  banner banner: Option(FilePart),
  icon icon: Option(FilePart),
  remove_banner remove_banner: Bool,
  remove_icon remove_icon: Bool,
  on_progress on_progress: Option(fn(Int, Int) -> Nil),
) -> Result(decoding.Object, DuvetError) {
  let path = "/api/spaces/" <> space_id
  let meta = with_progress(client_default_meta(client), on_progress)
  let multipart_body =
    banner != None || icon != None || remove_banner || remove_icon
  case multipart_body {
    False -> {
      let body =
        json_body(
          list.flatten([
            case name {
              Some(value) -> [#("name", json.string(value))]
              None -> []
            },
            case description {
              Some(value) -> [#("description", json.string(value))]
              None -> []
            },
            case locale {
              Some(value) -> [#("locale", json.string(value))]
              None -> []
            },
          ]),
        )
      request_map(client, "PATCH", path, "update space", body, meta)
    }
    True -> {
      let fields =
        list.flatten([
          case name {
            Some(value) if value != "" -> [#("name", value)]
            _ -> []
          },
          case description {
            Some(value) -> [#("description", value)]
            None -> []
          },
          case locale {
            Some(value) -> [#("locale", value)]
            None -> []
          },
          case remove_banner {
            True -> [#("remove_banner", "true")]
            False -> []
          },
          case remove_icon {
            True -> [#("remove_icon", "true")]
            False -> []
          },
        ])
      let files =
        list.filter_map([banner, icon], fn(file) {
          case file {
            Some(file) -> Ok(file)
            None -> Error(Nil)
          }
        })
      request_map(
        client,
        "PATCH",
        path,
        "update space",
        core.MultipartBody(fields: fields, files: files),
        meta,
      )
    }
  }
}

pub fn get_space_attachments(
  client: client.RestClient,
  space_id: String,
) -> Result(List(attachment.Attachment), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/spaces/" <> space_id <> "/attachments",
    "get space attachments",
    client_default_meta(client),
    attachment.from_json,
  )
}

/// The bytes the space's files take.
pub fn get_space_storage_used(
  client: client.RestClient,
  space_id: String,
) -> Result(Int, DuvetError) {
  request_map(
    client,
    "GET",
    "/api/spaces/" <> space_id <> "/attachments/storage",
    "get space storage used",
    core.NoBody,
    client_default_meta(client),
  )
  |> result.map(fn(object) { decoding.int(object, "total_size") })
}

pub fn delete_space_attachment(
  client: client.RestClient,
  space_id: String,
  attachment_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/" <> space_id <> "/attachments/" <> attachment_id,
    "delete space attachment",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn delete_all_space_attachments(
  client: client.RestClient,
  space_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/" <> space_id <> "/attachments",
    "delete all space attachments",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn get_space_buckets(
  client: client.RestClient,
  space_id: String,
) -> Result(List(rest.StorageBucket), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/spaces/" <> space_id <> "/buckets",
    "get space buckets",
    client_default_meta(client),
    rest.storage_bucket_from_json,
  )
}

pub fn create_space_bucket(
  client: client.RestClient,
  space_id: String,
  data: rest.BucketPayload,
) -> Result(rest.StorageBucket, DuvetError) {
  request_model(
    client,
    "POST",
    "/api/spaces/" <> space_id <> "/buckets",
    "create space bucket",
    core.JsonBody(rest.bucket_payload_to_json(data)),
    client_default_meta(client),
    rest.storage_bucket_from_json,
  )
}

pub fn update_space_bucket(
  client: client.RestClient,
  space_id: String,
  bucket_id: String,
  data: rest.BucketPayload,
) -> Result(rest.StorageBucket, DuvetError) {
  request_model(
    client,
    "PATCH",
    "/api/spaces/" <> space_id <> "/buckets/" <> bucket_id,
    "update space bucket",
    core.JsonBody(rest.bucket_payload_to_json(data)),
    client_default_meta(client),
    rest.storage_bucket_from_json,
  )
}

pub fn delete_space_bucket(
  client: client.RestClient,
  space_id: String,
  bucket_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/" <> space_id <> "/buckets/" <> bucket_id,
    "delete space bucket",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn activate_space_bucket(
  client: client.RestClient,
  space_id: String,
  bucket_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/spaces/" <> space_id <> "/buckets/" <> bucket_id <> "/activate",
    "activate space bucket",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn deactivate_space_bucket(
  client: client.RestClient,
  space_id: String,
  bucket_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/spaces/" <> space_id <> "/buckets/" <> bucket_id <> "/deactivate",
    "deactivate space bucket",
    core.NoBody,
    client_default_meta(client),
  )
}

// ---------------------------------------------------------------------------
// Rooms
// ---------------------------------------------------------------------------

pub fn create_room(
  client: client.RestClient,
  space_id: String,
  name: String,
  room_type: RoomType,
  parent_id parent_id: Option(String),
) -> Result(space.GatewayRoom, DuvetError) {
  let body =
    json_body(
      list.flatten([
        [#("name", json.string(name))],
        [#("type", json.int(room_type_value(room_type)))],
        case parent_id {
          Some(value) if value != "" -> [#("parent_id", json.string(value))]
          _ -> []
        },
      ]),
    )
  request_model(
    client,
    "POST",
    "/api/spaces/" <> space_id <> "/rooms",
    "create room",
    body,
    client_default_meta(client),
    space.room_from_json,
  )
}

fn room_type_value(room_type: RoomType) -> Int {
  room_type.value(room_type)
}

pub fn delete_room(
  client: client.RestClient,
  space_id: String,
  room_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/" <> space_id <> "/rooms/" <> room_id,
    "delete room",
    core.NoBody,
    client_default_meta(client),
  )
}

/// Updates the room. Only the arguments given are sent; clearing sends null for
/// the description or the parent.
pub fn update_room(
  client: client.RestClient,
  space_id: String,
  room_id: String,
  name name: Option(String),
  description description: Option(String),
  clear_description clear_description: Bool,
  parent_id parent_id: Option(String),
  clear_parent clear_parent: Bool,
  position position: Option(Int),
) -> Result(space.GatewayRoom, DuvetError) {
  let body =
    json_body(
      list.flatten([
        case name {
          Some(value) -> [#("name", json.string(value))]
          None -> []
        },
        case description, clear_description {
          Some(value), _ -> [#("description", json.string(value))]
          None, True -> [#("description", json.null())]
          None, False -> []
        },
        case parent_id, clear_parent {
          Some(value), _ -> [#("parent_id", json.string(value))]
          None, True -> [#("parent_id", json.null())]
          None, False -> []
        },
        case position {
          Some(value) -> [#("position", json.int(value))]
          None -> []
        },
      ]),
    )
  request_model(
    client,
    "PATCH",
    "/api/spaces/" <> space_id <> "/rooms/" <> room_id,
    "update room",
    body,
    client_default_meta(client),
    space.room_from_json,
  )
}

pub fn upsert_room_overwrite(
  client: client.RestClient,
  space_id: String,
  room_id: String,
  target_id: String,
  target_type: Int,
  allow_flags: Int,
  deny_flags: Int,
) -> Result(space.GatewayRoomOverwrite, DuvetError) {
  let body =
    json_body([
      #("target_id", json.string(target_id)),
      #("target_type", json.int(target_type)),
      #("allow_flags", json.int(allow_flags)),
      #("deny_flags", json.int(deny_flags)),
    ])
  request_model(
    client,
    "PUT",
    "/api/spaces/" <> space_id <> "/rooms/" <> room_id <> "/overwrites",
    "upsert overwrite",
    body,
    client_default_meta(client),
    space.room_overwrite_from_json,
  )
}

pub fn delete_room_overwrite(
  client: client.RestClient,
  space_id: String,
  room_id: String,
  target_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/"
      <> space_id
      <> "/rooms/"
      <> room_id
      <> "/overwrites/"
      <> target_id,
    "delete overwrite",
    core.NoBody,
    client_default_meta(client),
  )
}

/// Makes an invite to the room that works for [max_age] seconds (0: until it is
/// revoked); answers its code.
pub fn create_room_invite(
  client: client.RestClient,
  space_id: String,
  room_id: String,
  max_age: Int,
) -> Result(String, DuvetError) {
  let body = json_body([#("max_age", json.int(max_age))])
  request_map(
    client,
    "POST",
    "/api/spaces/" <> space_id <> "/rooms/" <> room_id <> "/invites",
    "create room invite",
    body,
    client_default_meta(client),
  )
  |> result.map(fn(object) { decoding.string(object, "code") })
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

/// A page of the room's messages before [before] (the newest without it),
/// newest first: [count] of them, 1 to 100.
pub fn get_messages(
  client: client.RestClient,
  room_id: String,
  before before: Option(String),
  count count: Int,
) -> Result(List(message.GatewayMessage), DuvetError) {
  let meta =
    client_default_meta(client)
    |> core.with_query(
      list.flatten([
        [#("count", int.to_string(count))],
        case before {
          Some(value) -> [#("before", value)]
          None -> []
        },
      ]),
    )
  request_list(
    client,
    "GET",
    "/api/rooms/" <> room_id <> "/messages",
    "get messages",
    meta,
    message.from_json,
  )
}

pub fn get_messages_after(
  client: client.RestClient,
  room_id: String,
  after: String,
) -> Result(List(message.GatewayMessage), DuvetError) {
  let meta =
    client_default_meta(client)
    |> core.with_query([
      #("count", "100"),
      #("after", after),
      #("order", "asc"),
    ])
  request_list(
    client,
    "GET",
    "/api/rooms/" <> room_id <> "/messages",
    "get messages after",
    meta,
    message.from_json,
  )
}

pub fn get_message_by_id(
  client: client.RestClient,
  room_id: String,
  message_id: String,
) -> Result(message.GatewayMessage, DuvetError) {
  request_model(
    client,
    "GET",
    "/api/rooms/" <> room_id <> "/messages/" <> message_id,
    "get message by ID",
    core.NoBody,
    client_default_meta(client),
    message.from_json,
  )
}

pub fn search_space_messages(
  client: client.RestClient,
  space_id: String,
  search: rest.MessageSearch,
) -> Result(rest.MessageSearchResponse(message.GatewayMessage), DuvetError) {
  let meta =
    client_default_meta(client)
    |> core.with_query(rest.message_search_query(search))
  request_map(
    client,
    "GET",
    "/api/spaces/" <> space_id <> "/messages/search",
    "search space messages",
    core.NoBody,
    meta,
  )
  |> result.map(fn(object) {
    rest.message_search_response_from_json(object, message.from_json)
  })
}

/// A room's pinned messages, the last pinned first.
pub fn get_room_pins(
  client: client.RestClient,
  room_id: String,
) -> Result(List(message.GatewayMessage), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/rooms/" <> room_id <> "/pins",
    "get room pins",
    client_default_meta(client),
    message.from_json,
  )
}

/// Pins a message of a room, which posts the room's pin notice.
pub fn pin_room_message(
  client: client.RestClient,
  room_id: String,
  message_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "PUT",
    "/api/rooms/" <> room_id <> "/pins/" <> message_id,
    "pin message",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn unpin_room_message(
  client: client.RestClient,
  room_id: String,
  message_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/rooms/" <> room_id <> "/pins/" <> message_id,
    "unpin message",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn get_message_thread(
  client: client.RestClient,
  room_id: String,
  message_id: String,
) -> Result(List(message.GatewayMessage), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/rooms/" <> room_id <> "/messages/" <> message_id <> "/thread",
    "get message thread",
    client_default_meta(client),
    message.from_json,
  )
}

/// What sending a message may set beyond its content.
pub type SendMessageOptions(a) {
  SendMessageOptions(
    nonce: Option(String),
    message_reference: Option(message.MessageReference),
    allowed_mentions: Option(message.AllowedMentions),
    files: List(FilePart),
    embeds: List(embed.Embed),
    sticker_attachment_id: Option(String),
    on_progress: Option(fn(Int, Int) -> Nil),
    abort: Option(Subject(a)),
  )
}

pub fn send_message_options() -> SendMessageOptions(a) {
  SendMessageOptions(
    nonce: None,
    message_reference: None,
    allowed_mentions: None,
    files: [],
    embeds: [],
    sticker_attachment_id: None,
    on_progress: None,
    abort: None,
  )
}

/// Sends a message to the room. With files, it goes as a multipart form, which
/// carries no embeds or sticker.
pub fn send_message(
  client: client.RestClient,
  room_id: String,
  content: String,
  options: SendMessageOptions(a),
) -> Result(message.GatewayMessage, DuvetError) {
  let path = "/api/rooms/" <> room_id <> "/messages"
  request_message(client, path, content, options, message.from_json)
}

/// Sends a voice message to the room: [audio] is a recording in `webm`
/// (WebM/Opus, as the desktop app records), `ogg` (Ogg/Opus) or `m4a` (AAC in
/// MP4).
pub fn send_voice_note(
  client: client.RestClient,
  room_id: String,
  audio: BitArray,
  nonce nonce: Option(String),
  format format: String,
) -> Result(message.GatewayMessage, DuvetError) {
  request_voice_note(
    client,
    "/api/rooms/" <> room_id <> "/messages",
    audio,
    nonce,
    format,
    message.from_json,
  )
}

pub fn update_message(
  client: client.RestClient,
  message_id: String,
  content: String,
  room_id: String,
) -> Result(message.GatewayMessage, DuvetError) {
  request_model(
    client,
    "PATCH",
    "/api/rooms/" <> room_id <> "/messages/" <> message_id,
    "update message",
    json_body([#("content", json.string(content))]),
    client_default_meta(client),
    message.from_json,
  )
}

/// Tells the room the user is typing. Failures are ignored.
pub fn send_typing_indicator(
  client: client.RestClient,
  room_id: String,
) -> Nil {
  ignore_errors(request_void(
    client,
    "POST",
    "/api/rooms/" <> room_id <> "/typing",
    "send typing indicator",
    core.NoBody,
    client_default_meta(client),
  ))
}

/// Tells the room the user is recording a voice message. Failures are ignored.
pub fn send_recording_indicator(
  client: client.RestClient,
  room_id: String,
) -> Nil {
  ignore_errors(request_void(
    client,
    "POST",
    "/api/rooms/" <> room_id <> "/recording",
    "send recording indicator",
    core.NoBody,
    client_default_meta(client),
  ))
}

pub fn delete_message(
  client: client.RestClient,
  message_id: String,
  room_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/rooms/" <> room_id <> "/messages/" <> message_id,
    "delete message",
    core.NoBody,
    client_default_meta(client),
  )
}

/// The unread mentions of each room and conversation, by its ID. Answers none
/// when the request fails.
pub fn get_mention_counts(client: client.RestClient) -> Dict(String, Int) {
  case
    request_map(
      client,
      "GET",
      "/api/users/@me/mentions/counts",
      "get mention counts",
      core.NoBody,
      client_default_meta(client),
    )
  {
    Ok(object) ->
      object
      |> dict.to_list
      |> list.map(fn(pair) { #(pair.0, decoding.int_value(pair.1, pair.0)) })
      |> dict.from_list
    Error(_) -> dict.new()
  }
}

// ---------------------------------------------------------------------------
// Reactions
// ---------------------------------------------------------------------------

pub fn add_room_reaction(
  client: client.RestClient,
  room_id: String,
  message_id: String,
  emoji_name: String,
  emoji_id emoji_id: Option(String),
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "PUT",
    "/api/rooms/" <> room_id <> "/messages/" <> message_id <> "/reactions",
    "add reaction",
    json_body([
      #("emoji_name", json.string(emoji_name)),
      #("emoji_id", json.nullable(emoji_id, json.string)),
    ]),
    client_default_meta(client),
  )
}

pub fn remove_room_reaction(
  client: client.RestClient,
  room_id: String,
  message_id: String,
  emoji_name: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/rooms/"
      <> room_id
      <> "/messages/"
      <> message_id
      <> "/reactions/"
      <> api_router.encode_component(emoji_name),
    "remove reaction",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn add_conversation_reaction(
  client: client.RestClient,
  conv_id: String,
  message_id: String,
  emoji_name: String,
  emoji_id emoji_id: Option(String),
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "PUT",
    "/api/users/@me/conversations/"
      <> conv_id
      <> "/messages/"
      <> message_id
      <> "/reactions",
    "add conversation reaction",
    json_body([
      #("emoji_name", json.string(emoji_name)),
      #("emoji_id", json.nullable(emoji_id, json.string)),
    ]),
    client_default_meta(client),
  )
}

pub fn remove_conversation_reaction(
  client: client.RestClient,
  conv_id: String,
  message_id: String,
  emoji_name: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/conversations/"
      <> conv_id
      <> "/messages/"
      <> message_id
      <> "/reactions/"
      <> api_router.encode_component(emoji_name),
    "remove conversation reaction",
    core.NoBody,
    client_default_meta(client),
  )
}

// ---------------------------------------------------------------------------
// Roles
// ---------------------------------------------------------------------------

pub fn create_role(
  client: client.RestClient,
  space_id: String,
  name: String,
  permissions permissions: Option(Int),
  color_from color_from: Option(Int),
  color_via color_via: Option(Int),
  color_to color_to: Option(Int),
  hoisted hoisted: Option(Bool),
) -> Result(space.GatewayRole, DuvetError) {
  let body =
    json_body(
      list.flatten([
        [#("name", json.string(name))],
        optional_int("permissions", permissions),
        optional_int("color_from", color_from),
        optional_int("color_via", color_via),
        optional_int("color_to", color_to),
        optional_bool("hoisted", hoisted),
      ]),
    )
  request_model(
    client,
    "POST",
    "/api/spaces/" <> space_id <> "/roles",
    "create role",
    body,
    client_default_meta(client),
    space.role_from_json,
  )
}

/// Updates the role. Only the arguments given are sent; with clear_colors, the
/// null colors clear those of the role.
pub fn update_role(
  client: client.RestClient,
  space_id: String,
  role_id: String,
  name name: Option(String),
  permissions permissions: Option(Int),
  color_from color_from: Option(Int),
  color_via color_via: Option(Int),
  color_to color_to: Option(Int),
  hoisted hoisted: Option(Bool),
  position position: Option(Int),
  clear_colors clear_colors: Bool,
) -> Result(space.GatewayRole, DuvetError) {
  let body =
    json_body(
      list.flatten([
        optional_json_entry("name", name, json.string),
        optional_int("permissions", permissions),
        case color_from, clear_colors {
          Some(value), _ -> [#("color_from", json.int(value))]
          None, True -> [#("color_from", json.null())]
          None, False -> []
        },
        case color_via, clear_colors {
          Some(value), _ -> [#("color_via", json.int(value))]
          None, True -> [#("color_via", json.null())]
          None, False -> []
        },
        case color_to, clear_colors {
          Some(value), _ -> [#("color_to", json.int(value))]
          None, True -> [#("color_to", json.null())]
          None, False -> []
        },
        optional_bool("hoisted", hoisted),
        optional_int("position", position),
        case clear_colors {
          True -> [#("clear_colors", json.bool(True))]
          False -> []
        },
      ]),
    )
  request_model(
    client,
    "PATCH",
    "/api/spaces/" <> space_id <> "/roles/" <> role_id,
    "update role",
    body,
    client_default_meta(client),
    space.role_from_json,
  )
}

pub fn delete_role(
  client: client.RestClient,
  space_id: String,
  role_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/" <> space_id <> "/roles/" <> role_id,
    "delete role",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn assign_role_to_member(
  client: client.RestClient,
  space_id: String,
  role_id: String,
  member_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "PUT",
    "/api/spaces/"
      <> space_id
      <> "/members/"
      <> member_id
      <> "/roles/"
      <> role_id,
    "assign role to member",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn remove_role_from_member(
  client: client.RestClient,
  space_id: String,
  role_id: String,
  member_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/"
      <> space_id
      <> "/members/"
      <> member_id
      <> "/roles/"
      <> role_id,
    "remove role from member",
    core.NoBody,
    client_default_meta(client),
  )
}

// ---------------------------------------------------------------------------
// Space emojis
// ---------------------------------------------------------------------------

pub fn list_emojis(
  client: client.RestClient,
  space_id: String,
) -> Result(List(space.SpaceEmoji), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/spaces/" <> space_id <> "/emojis",
    "list emojis",
    client_default_meta(client),
    space.space_emoji_from_json,
  )
}

pub fn create_emoji(
  client: client.RestClient,
  space_id: String,
  name: String,
  file: FilePart,
  on_progress on_progress: Option(fn(Int, Int) -> Nil),
) -> Result(space.SpaceEmoji, DuvetError) {
  request_model(
    client,
    "POST",
    "/api/spaces/" <> space_id <> "/emojis",
    "create emoji",
    core.MultipartBody(fields: [#("name", name)], files: [file]),
    with_progress(client_default_meta(client), on_progress),
    space.space_emoji_from_json,
  )
}

pub fn update_emoji(
  client: client.RestClient,
  space_id: String,
  emoji_id: String,
  name: String,
) -> Result(space.SpaceEmoji, DuvetError) {
  request_model(
    client,
    "PATCH",
    "/api/spaces/" <> space_id <> "/emojis/" <> emoji_id,
    "update emoji",
    json_body([#("name", json.string(name))]),
    client_default_meta(client),
    space.space_emoji_from_json,
  )
}

pub fn delete_emoji(
  client: client.RestClient,
  space_id: String,
  emoji_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/" <> space_id <> "/emojis/" <> emoji_id,
    "delete emoji",
    core.NoBody,
    client_default_meta(client),
  )
}

// ---------------------------------------------------------------------------
// Space stickers
// ---------------------------------------------------------------------------

pub fn list_stickers(
  client: client.RestClient,
  space_id: String,
) -> Result(List(space.SpaceSticker), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/spaces/" <> space_id <> "/stickers",
    "list stickers",
    client_default_meta(client),
    space.space_sticker_from_json,
  )
}

pub fn create_sticker(
  client: client.RestClient,
  space_id: String,
  name: String,
  file: FilePart,
  on_progress on_progress: Option(fn(Int, Int) -> Nil),
) -> Result(space.SpaceSticker, DuvetError) {
  request_model(
    client,
    "POST",
    "/api/spaces/" <> space_id <> "/stickers",
    "create sticker",
    core.MultipartBody(fields: [#("name", name)], files: [file]),
    with_progress(client_default_meta(client), on_progress),
    space.space_sticker_from_json,
  )
}

pub fn update_sticker(
  client: client.RestClient,
  space_id: String,
  sticker_id: String,
  name: String,
) -> Result(space.SpaceSticker, DuvetError) {
  request_model(
    client,
    "PATCH",
    "/api/spaces/" <> space_id <> "/stickers/" <> sticker_id,
    "update sticker",
    json_body([#("name", json.string(name))]),
    client_default_meta(client),
    space.space_sticker_from_json,
  )
}

pub fn delete_sticker(
  client: client.RestClient,
  space_id: String,
  sticker_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/" <> space_id <> "/stickers/" <> sticker_id,
    "delete sticker",
    core.NoBody,
    client_default_meta(client),
  )
}

// ---------------------------------------------------------------------------
// Invites
// ---------------------------------------------------------------------------

pub fn get_invite(
  client: client.RestClient,
  code: String,
) -> Result(rest.InviteInfo, DuvetError) {
  request_model(
    client,
    "GET",
    "/api/invites/" <> api_router.encode_component(code),
    "get invite",
    core.NoBody,
    client_default_meta(client),
    rest.invite_info_from_json,
  )
}

pub fn join_invite(
  client: client.RestClient,
  code: String,
) -> Result(rest.InviteInfo, DuvetError) {
  request_model(
    client,
    "POST",
    "/api/invites/" <> api_router.encode_component(code) <> "/join",
    "join invite",
    core.NoBody,
    client_default_meta(client),
    rest.invite_info_from_json,
  )
}

/// The space's invites that still work.
pub fn list_space_invites(
  client: client.RestClient,
  space_id: String,
) -> Result(List(rest.InviteLink), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/spaces/" <> space_id <> "/invites",
    "list invites",
    client_default_meta(client),
    rest.invite_link_from_json,
  )
}

pub fn revoke_invite(
  client: client.RestClient,
  space_id: String,
  invite_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/" <> space_id <> "/invites/" <> invite_id,
    "revoke invite",
    core.NoBody,
    client_default_meta(client),
  )
}

// ---------------------------------------------------------------------------
// Webhooks
// ---------------------------------------------------------------------------

pub fn list_webhooks(
  client: client.RestClient,
  space_id: String,
  room_id: String,
) -> Result(List(rest.Webhook), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/spaces/" <> space_id <> "/rooms/" <> room_id <> "/webhooks",
    "list webhooks",
    client_default_meta(client),
    rest.webhook_from_json,
  )
}

pub fn create_webhook(
  client: client.RestClient,
  space_id: String,
  room_id: String,
  username: String,
  avatar avatar: Option(FilePart),
) -> Result(rest.WebhookCreateResponse, DuvetError) {
  request_model(
    client,
    "POST",
    "/api/spaces/" <> space_id <> "/rooms/" <> room_id <> "/webhooks",
    "create webhook",
    core.MultipartBody(
      fields: [#("username", username)],
      files: files_from([avatar]),
    ),
    client_default_meta(client),
    rest.webhook_create_response_from_json,
  )
}

pub fn update_webhook(
  client: client.RestClient,
  space_id: String,
  room_id: String,
  webhook_id: String,
  username username: Option(String),
  avatar avatar: Option(FilePart),
  remove_avatar remove_avatar: Bool,
) -> Result(rest.Webhook, DuvetError) {
  let fields =
    list.flatten([
      case username {
        Some(value) if value != "" -> [#("username", value)]
        _ -> []
      },
      case remove_avatar {
        True -> [#("remove_avatar", "true")]
        False -> []
      },
    ])
  request_model(
    client,
    "PATCH",
    "/api/spaces/"
      <> space_id
      <> "/rooms/"
      <> room_id
      <> "/webhooks/"
      <> webhook_id,
    "update webhook",
    core.MultipartBody(fields: fields, files: files_from([avatar])),
    client_default_meta(client),
    rest.webhook_from_json,
  )
}

pub fn delete_webhook(
  client: client.RestClient,
  space_id: String,
  room_id: String,
  webhook_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/"
      <> space_id
      <> "/rooms/"
      <> room_id
      <> "/webhooks/"
      <> webhook_id,
    "delete webhook",
    core.NoBody,
    client_default_meta(client),
  )
}

/// Answers the webhook's new token.
pub fn reset_webhook_token(
  client: client.RestClient,
  space_id: String,
  room_id: String,
  webhook_id: String,
) -> Result(String, DuvetError) {
  request_map(
    client,
    "POST",
    "/api/spaces/"
      <> space_id
      <> "/rooms/"
      <> room_id
      <> "/webhooks/"
      <> webhook_id
      <> "/reset-token",
    "reset webhook token",
    core.NoBody,
    client_default_meta(client),
  )
  |> result.map(fn(object) { decoding.string(object, "token") })
}

// ---------------------------------------------------------------------------
// Interactions & commands
// ---------------------------------------------------------------------------

/// Uses a component of a bot's message in a room.
pub fn use_component(
  client: client.RestClient,
  room_id: String,
  message_id: String,
  data: rest.ComponentUse,
) -> Result(rest.InteractionReply, DuvetError) {
  interact(client, "use component", [
    #("type", json.int(3)),
    #("room_id", json.string(room_id)),
    #("message_id", json.string(message_id)),
    #("data", rest.component_use_to_json(data)),
  ])
}

/// Uses an application's command in a room, and answers the bot's first
/// response.
pub fn use_command(
  client: client.RestClient,
  room_id: String,
  application_id: String,
  data: rest.CommandUse,
) -> Result(rest.InteractionReply, DuvetError) {
  let payload = [
    #("type", json.int(2)),
    #("room_id", json.string(room_id)),
    #("application_id", json.string(application_id)),
    #("data", rest.command_use_to_json(data)),
  ]
  case interact(client, "use command", payload) {
    Ok(reply) -> Ok(reply)
    Error(failure) -> {
      // The command may have changed or gone: the next use asks for the lists
      // again.
      commands.clear(client.commands_cache(client))
      Error(failure)
    }
  }
}

/// Submits a modal the application's bot opened in a room.
pub fn submit_modal(
  client: client.RestClient,
  room_id: String,
  application_id: String,
  custom_id: String,
  components: List(decoding.Object),
  message_id message_id: Option(String),
) -> Result(rest.InteractionReply, DuvetError) {
  let payload =
    list.flatten([
      [
        #("type", json.int(5)),
        #("room_id", json.string(room_id)),
        #("application_id", json.string(application_id)),
      ],
      case message_id {
        Some(value) -> [#("message_id", json.string(value))]
        None -> []
      },
      [
        #(
          "data",
          json.object([
            #("custom_id", json.string(custom_id)),
            #(
              "components",
              json.array(components, fn(component) {
                json_value.to_json(json_value.from_object(component))
              }),
            ),
          ]),
        ),
      ],
    ])
  interact(client, "submit modal", payload)
}

fn interact(
  client: client.RestClient,
  action: String,
  payload: List(#(String, json.Json)),
) -> Result(rest.InteractionReply, DuvetError) {
  request_model(
    client,
    "POST",
    "/api/interactions",
    action,
    json_body(payload),
    client_default_meta(client),
    rest.interaction_reply_from_json,
  )
}

/// The space's commands, kept for a few minutes, or until
/// [forget_space_commands] (the space's members changed: a bot came or went).
/// A failed request isn't kept.
pub fn get_space_commands(
  client: client.RestClient,
  space_id: String,
) -> Result(rest.SpaceCommands, DuvetError) {
  let now = timestamp.system_time()
  case commands.get(client.commands_cache(client), space_id, now) {
    Some(cached) -> Ok(cached)
    None ->
      case
        request_model(
          client,
          "GET",
          "/api/spaces/" <> space_id <> "/commands",
          "get space commands",
          core.NoBody,
          client_default_meta(client),
          rest.space_commands_from_json,
        )
      {
        Ok(space_commands) -> {
          commands.put(
            client.commands_cache(client),
            space_id,
            now,
            space_commands,
          )
          Ok(space_commands)
        }
        Error(failure) -> Error(failure)
      }
  }
}

pub fn forget_space_commands(
  client: client.RestClient,
  space_id: String,
) -> Nil {
  commands.forget(client.commands_cache(client), space_id)
}

// ---------------------------------------------------------------------------
// Friends
// ---------------------------------------------------------------------------

/// Answers the bare request, without the other user's details.
pub fn send_friend_request(
  client: client.RestClient,
  user_id: String,
) -> Result(conversation.FriendRequest, DuvetError) {
  request_model(
    client,
    "POST",
    "/api/users/@me/friends/requests",
    "send friend request",
    json_body([#("user_id", json.string(user_id))]),
    client_default_meta(client),
    conversation.friend_request_from_json,
  )
}

pub fn get_pending_requests(
  client: client.RestClient,
) -> Result(List(conversation.FriendRequest), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/users/@me/friends/requests",
    "get pending requests",
    client_default_meta(client),
    conversation.friend_request_from_json,
  )
}

pub fn get_sent_requests(
  client: client.RestClient,
) -> Result(List(conversation.FriendRequest), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/users/@me/friends/requests/sent",
    "get sent requests",
    client_default_meta(client),
    conversation.friend_request_from_json,
  )
}

pub fn accept_friend_request(
  client: client.RestClient,
  request_id: String,
) -> Result(conversation.Friend, DuvetError) {
  request_model(
    client,
    "POST",
    "/api/users/@me/friends/requests/" <> request_id <> "/accept",
    "accept friend request",
    core.NoBody,
    client_default_meta(client),
    conversation.friend_from_json,
  )
}

pub fn reject_friend_request(
  client: client.RestClient,
  request_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/friends/requests/" <> request_id,
    "reject friend request",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn get_friends(
  client: client.RestClient,
) -> Result(List(conversation.Friend), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/users/@me/friends",
    "get friends",
    client_default_meta(client),
    conversation.friend_from_json,
  )
}

pub fn unfriend(
  client: client.RestClient,
  user_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/friends/" <> user_id,
    "unfriend",
    core.NoBody,
    client_default_meta(client),
  )
}

// ---------------------------------------------------------------------------
// Conversations
// ---------------------------------------------------------------------------

pub fn get_conversations(
  client: client.RestClient,
) -> Result(List(conversation.Conversation), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/users/@me/conversations",
    "get conversations",
    client_default_meta(client),
    conversation.conversation_from_json,
  )
}

pub fn create_dm(
  client: client.RestClient,
  user_id: String,
) -> Result(conversation.Conversation, DuvetError) {
  request_model(
    client,
    "POST",
    "/api/users/@me/conversations",
    "create DM",
    json_body([
      #("type", json.int(conversation_type.value(conversation_type.dm))),
      #("user_id", json.string(user_id)),
    ]),
    client_default_meta(client),
    conversation.conversation_from_json,
  )
}

pub fn create_group(
  client: client.RestClient,
  name: String,
  user_ids: List(String),
) -> Result(conversation.Conversation, DuvetError) {
  request_model(
    client,
    "POST",
    "/api/users/@me/conversations",
    "create group",
    json_body([
      #("type", json.int(conversation_type.value(conversation_type.group))),
      #("name", json.string(name)),
      #("user_ids", json.array(user_ids, json.string)),
    ]),
    client_default_meta(client),
    conversation.conversation_from_json,
  )
}

pub fn update_conversation(
  client: client.RestClient,
  conversation_id: String,
  name: String,
) -> Result(conversation.Conversation, DuvetError) {
  request_model(
    client,
    "PATCH",
    "/api/users/@me/conversations/" <> conversation_id,
    "update conversation",
    json_body([#("name", json.string(name))]),
    client_default_meta(client),
    conversation.conversation_from_json,
  )
}

pub fn add_conversation_member(
  client: client.RestClient,
  conversation_id: String,
  user_id: String,
) -> Result(conversation.ConversationMember, DuvetError) {
  request_model(
    client,
    "POST",
    "/api/users/@me/conversations/" <> conversation_id <> "/members",
    "add conversation member",
    json_body([#("user_id", json.string(user_id))]),
    client_default_meta(client),
    conversation.conversation_member_from_json,
  )
}

pub fn remove_conversation_member(
  client: client.RestClient,
  conversation_id: String,
  user_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/conversations/" <> conversation_id <> "/members/" <> user_id,
    "remove conversation member",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn leave_conversation(
  client: client.RestClient,
  conversation_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/conversations/" <> conversation_id <> "/members/@me",
    "leave conversation",
    core.NoBody,
    client_default_meta(client),
  )
}

/// A page of the conversation's messages before [before] (the newest without
/// it), newest first: [count] of them, 1 to 100.
pub fn get_direct_messages(
  client: client.RestClient,
  conversation_id: String,
  before before: Option(String),
  count count: Int,
) -> Result(List(conversation.DirectMessage), DuvetError) {
  let meta =
    client_default_meta(client)
    |> core.with_query(
      list.flatten([
        [#("count", int.to_string(count))],
        case before {
          Some(value) -> [#("before", value)]
          None -> []
        },
      ]),
    )
  request_list(
    client,
    "GET",
    "/api/users/@me/conversations/" <> conversation_id <> "/messages",
    "get direct messages",
    meta,
    conversation.direct_message_from_json,
  )
}

pub fn get_direct_message_by_id(
  client: client.RestClient,
  conversation_id: String,
  message_id: String,
) -> Result(conversation.DirectMessage, DuvetError) {
  request_model(
    client,
    "GET",
    "/api/users/@me/conversations/"
      <> conversation_id
      <> "/messages/"
      <> message_id,
    "get direct message by ID",
    core.NoBody,
    client_default_meta(client),
    conversation.direct_message_from_json,
  )
}

/// A conversation message's reply thread, oldest first.
pub fn get_conversation_message_thread(
  client: client.RestClient,
  conversation_id: String,
  message_id: String,
) -> Result(List(conversation.DirectMessage), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/users/@me/conversations/"
      <> conversation_id
      <> "/messages/"
      <> message_id
      <> "/thread",
    "get conversation message thread",
    client_default_meta(client),
    conversation.direct_message_from_json,
  )
}

/// A conversation's pinned messages, the last pinned first.
pub fn get_conversation_pins(
  client: client.RestClient,
  conversation_id: String,
) -> Result(List(conversation.DirectMessage), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/users/@me/conversations/" <> conversation_id <> "/pins",
    "get conversation pins",
    client_default_meta(client),
    conversation.direct_message_from_json,
  )
}

/// Pins a message of a conversation, which posts its pin notice.
pub fn pin_conversation_message(
  client: client.RestClient,
  conversation_id: String,
  message_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "PUT",
    "/api/users/@me/conversations/" <> conversation_id <> "/pins/" <> message_id,
    "pin conversation message",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn unpin_conversation_message(
  client: client.RestClient,
  conversation_id: String,
  message_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/conversations/" <> conversation_id <> "/pins/" <> message_id,
    "unpin conversation message",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn search_conversation_messages(
  client: client.RestClient,
  conversation_id: String,
  search: rest.MessageSearch,
) -> Result(rest.MessageSearchResponse(conversation.DirectMessage), DuvetError) {
  let meta =
    client_default_meta(client)
    |> core.with_query(rest.message_search_query(search))
  request_map(
    client,
    "GET",
    "/api/users/@me/conversations/" <> conversation_id <> "/messages/search",
    "search conversation messages",
    core.NoBody,
    meta,
  )
  |> result.map(fn(object) {
    rest.message_search_response_from_json(
      object,
      conversation.direct_message_from_json,
    )
  })
}

pub fn get_direct_messages_after(
  client: client.RestClient,
  conversation_id: String,
  after: String,
) -> Result(List(conversation.DirectMessage), DuvetError) {
  let meta =
    client_default_meta(client)
    |> core.with_query([#("count", "100"), #("after", after)])
  request_list(
    client,
    "GET",
    "/api/users/@me/conversations/" <> conversation_id <> "/messages/after",
    "get direct messages after",
    meta,
    conversation.direct_message_from_json,
  )
}

/// Sends a message to the conversation. With files, it goes as a multipart
/// form, which carries no embeds or sticker.
pub fn send_direct_message(
  client: client.RestClient,
  conversation_id: String,
  content: String,
  options: SendMessageOptions(a),
) -> Result(conversation.DirectMessage, DuvetError) {
  request_message(
    client,
    "/api/users/@me/conversations/" <> conversation_id <> "/messages",
    content,
    options,
    conversation.direct_message_from_json,
  )
}

/// Sends a voice message to the conversation.
pub fn send_dm_voice_note(
  client: client.RestClient,
  conversation_id: String,
  audio: BitArray,
  nonce nonce: Option(String),
  format format: String,
) -> Result(conversation.DirectMessage, DuvetError) {
  request_voice_note(
    client,
    "/api/users/@me/conversations/" <> conversation_id <> "/messages",
    audio,
    nonce,
    format,
    conversation.direct_message_from_json,
  )
}

pub fn update_direct_message(
  client: client.RestClient,
  conversation_id: String,
  message_id: String,
  content: String,
) -> Result(conversation.DirectMessage, DuvetError) {
  request_model(
    client,
    "PATCH",
    "/api/users/@me/conversations/"
      <> conversation_id
      <> "/messages/"
      <> message_id,
    "update direct message",
    json_body([#("content", json.string(content))]),
    client_default_meta(client),
    conversation.direct_message_from_json,
  )
}

/// Tells the conversation the user is typing.
pub fn send_conversation_typing(
  client: client.RestClient,
  conversation_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/users/@me/conversations/" <> conversation_id <> "/typing",
    "send conversation typing",
    core.NoBody,
    client_default_meta(client),
  )
}

/// Tells the conversation the user is recording a voice message.
pub fn send_conversation_recording(
  client: client.RestClient,
  conversation_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/users/@me/conversations/" <> conversation_id <> "/recording",
    "send conversation recording",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn delete_direct_message(
  client: client.RestClient,
  conversation_id: String,
  message_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/conversations/"
      <> conversation_id
      <> "/messages/"
      <> message_id,
    "delete direct message",
    core.NoBody,
    client_default_meta(client),
  )
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

pub fn me(client: client.RestClient) -> Result(user.UserMeResult, DuvetError) {
  request_model(
    client,
    "GET",
    "/api/users/@me",
    "get me",
    core.NoBody,
    client_default_meta(client),
    user.user_me_from_json,
  )
}

/// Updates the user. Only the arguments given are sent, and the API keeps what
/// is left out. Clearing sends null for the alias, avatar or banner.
pub fn update_user(
  client: client.RestClient,
  username username: Option(String),
  alias alias: Option(String),
  clear_alias clear_alias: Bool,
  avatar avatar: Option(String),
  clear_avatar clear_avatar: Bool,
  banner banner: Option(String),
  clear_banner clear_banner: Bool,
  custom custom: Option(String),
) -> Result(user.UserMeResult, DuvetError) {
  let body =
    json_body(
      list.flatten([
        optional_json_entry("username", username, json.string),
        case alias, clear_alias {
          Some(value), _ -> [#("alias", json.string(value))]
          None, True -> [#("alias", json.null())]
          None, False -> []
        },
        case avatar, clear_avatar {
          Some(value), _ -> [#("avatar", json.string(value))]
          None, True -> [#("avatar", json.null())]
          None, False -> []
        },
        case banner, clear_banner {
          Some(value), _ -> [#("banner", json.string(value))]
          None, True -> [#("banner", json.null())]
          None, False -> []
        },
        optional_json_entry("custom", custom, json.string),
      ]),
    )
  request_model(
    client,
    "PATCH",
    "/api/users/@me",
    "update user",
    body,
    client_default_meta(client),
    user.user_me_from_json,
  )
}

/// Chooses the user's status: online or do not disturb. Offline isn't a
/// choice, and nothing is sent for it.
pub fn set_status(
  client: client.RestClient,
  status: user_status.UserStatus,
) -> Result(user.UserMeResult, DuvetError) {
  case status {
    user_status.UserStatus(1) | user_status.UserStatus(2) -> {
      let body = json_body([#("status", json.int(user_status.value(status)))])
      request_model(
        client,
        "PUT",
        "/api/users/@me/status",
        "set status",
        body,
        client_default_meta(client),
        user.user_me_from_json,
      )
    }
    _ -> Error(error.InvalidArgument("status must be online (1) or dnd (2)"))
  }
}

/// Which of the user's profile images to set.
pub type ProfileImageKind {
  Avatar
  Banner
}

fn profile_image_field(kind: ProfileImageKind) -> String {
  case kind {
    Avatar -> "avatar"
    Banner -> "banner"
  }
}

/// Sets the user's avatar or banner to the image as given.
pub fn upload_profile_image(
  client: client.RestClient,
  kind: ProfileImageKind,
  bytes: BitArray,
  filename: String,
  on_progress on_progress: Option(fn(Int, Int) -> Nil),
) -> Result(user.UserMeResult, DuvetError) {
  request_model(
    client,
    "PATCH",
    "/api/users/@me",
    "upload profile image",
    core.MultipartBody(fields: [], files: [
      multipart.FilePart(
        field: profile_image_field(kind),
        bytes: bytes,
        filename: filename,
      ),
    ]),
    with_progress(client_default_meta(client), on_progress),
    user.user_me_from_json,
  )
}

pub fn get_my_storage_status(
  client: client.RestClient,
) -> Result(rest.StorageStatus, DuvetError) {
  request_model(
    client,
    "GET",
    "/api/users/@me/storage",
    "get storage status",
    core.NoBody,
    client_default_meta(client),
    rest.storage_status_from_json,
  )
}

pub fn get_my_attachments(
  client: client.RestClient,
) -> Result(List(attachment.Attachment), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/users/@me/attachments",
    "get attachments",
    client_default_meta(client),
    attachment.from_json,
  )
}

pub fn delete_my_attachment(
  client: client.RestClient,
  id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/attachments/" <> id,
    "delete attachment",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn delete_all_my_attachments(
  client: client.RestClient,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/attachments",
    "delete all attachments",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn get_my_buckets(
  client: client.RestClient,
) -> Result(List(rest.StorageBucket), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/users/@me/buckets",
    "get buckets",
    client_default_meta(client),
    rest.storage_bucket_from_json,
  )
}

pub fn create_my_bucket(
  client: client.RestClient,
  data: rest.BucketPayload,
) -> Result(rest.StorageBucket, DuvetError) {
  request_model(
    client,
    "POST",
    "/api/users/@me/buckets",
    "create bucket",
    core.JsonBody(rest.bucket_payload_to_json(data)),
    client_default_meta(client),
    rest.storage_bucket_from_json,
  )
}

pub fn update_my_bucket(
  client: client.RestClient,
  id: String,
  data: rest.BucketPayload,
) -> Result(rest.StorageBucket, DuvetError) {
  request_model(
    client,
    "PATCH",
    "/api/users/@me/buckets/" <> id,
    "update bucket",
    core.JsonBody(rest.bucket_payload_to_json(data)),
    client_default_meta(client),
    rest.storage_bucket_from_json,
  )
}

pub fn delete_my_bucket(
  client: client.RestClient,
  id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/buckets/" <> id,
    "delete bucket",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn activate_my_bucket(
  client: client.RestClient,
  id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/users/@me/buckets/" <> id <> "/activate",
    "activate bucket",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn deactivate_my_bucket(
  client: client.RestClient,
  id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/users/@me/buckets/" <> id <> "/deactivate",
    "deactivate bucket",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn update_user_flags_badges(
  client: client.RestClient,
  user_id: String,
  flags flags: Option(Int),
  badges badges: Option(Int),
) -> Result(decoding.Object, DuvetError) {
  let body =
    json_body(
      list.flatten([
        optional_int("flags", flags),
        optional_int("badges", badges),
      ]),
    )
  request_map(
    client,
    "PATCH",
    "/api/internal/users/" <> user_id <> "/flags-badges",
    "update flags and badges",
    body,
    client_default_meta(client),
  )
}

// ---------------------------------------------------------------------------
// Developer: teams
// ---------------------------------------------------------------------------

pub fn create_team(
  client: client.RestClient,
  name: String,
) -> Result(rest.Team, DuvetError) {
  request_model(
    client,
    "POST",
    "/api/users/@me/teams",
    "create team",
    json_body([#("name", json.string(name))]),
    client_default_meta(client),
    rest.team_from_json,
  )
}

pub fn list_teams(
  client: client.RestClient,
) -> Result(List(rest.Team), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/users/@me/teams",
    "list teams",
    client_default_meta(client),
    rest.team_from_json,
  )
}

pub fn update_team(
  client: client.RestClient,
  team_id: String,
  name: String,
) -> Result(rest.Team, DuvetError) {
  request_model(
    client,
    "PATCH",
    "/api/users/@me/teams/" <> team_id,
    "update team",
    json_body([#("name", json.string(name))]),
    client_default_meta(client),
    rest.team_from_json,
  )
}

pub fn delete_team(
  client: client.RestClient,
  team_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/teams/" <> team_id,
    "delete team",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn list_team_members(
  client: client.RestClient,
  team_id: String,
) -> Result(List(rest.TeamMember), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/users/@me/teams/" <> team_id <> "/members",
    "list team members",
    client_default_meta(client),
    rest.team_member_from_json,
  )
}

pub fn invite_to_team(
  client: client.RestClient,
  team_id: String,
  email: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/users/@me/teams/" <> team_id <> "/invites",
    "invite to team",
    json_body([#("email", json.string(email))]),
    client_default_meta(client),
  )
}

pub fn remove_team_member(
  client: client.RestClient,
  team_id: String,
  user_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/teams/" <> team_id <> "/members/" <> user_id,
    "remove team member",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn list_my_team_invites(
  client: client.RestClient,
) -> Result(List(rest.TeamInvite), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/users/@me/team-invites",
    "list team invites",
    client_default_meta(client),
    rest.team_invite_from_json,
  )
}

pub fn accept_team_invite(
  client: client.RestClient,
  invite_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/users/@me/team-invites/" <> invite_id <> "/accept",
    "accept team invite",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn decline_team_invite(
  client: client.RestClient,
  invite_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/users/@me/team-invites/" <> invite_id <> "/decline",
    "decline team invite",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn create_application(
  client: client.RestClient,
  team_id: String,
  name: String,
  description description: Option(String),
) -> Result(rest.Application, DuvetError) {
  let body =
    json_body(
      list.flatten([
        [#("name", json.string(name))],
        optional_json_entry("description", description, json.string),
      ]),
    )
  request_model(
    client,
    "POST",
    "/api/users/@me/teams/" <> team_id <> "/applications",
    "create application",
    body,
    client_default_meta(client),
    rest.application_from_json,
  )
}

pub fn list_applications(
  client: client.RestClient,
  team_id: String,
) -> Result(List(rest.Application), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/users/@me/teams/" <> team_id <> "/applications",
    "list applications",
    client_default_meta(client),
    rest.application_from_json,
  )
}

pub fn update_application(
  client: client.RestClient,
  team_id: String,
  app_id: String,
  name name: Option(String),
  description description: Option(String),
  public public: Option(Bool),
) -> Result(rest.Application, DuvetError) {
  let body =
    json_body(
      list.flatten([
        optional_json_entry("name", name, json.string),
        optional_json_entry("description", description, json.string),
        optional_bool("public", public),
      ]),
    )
  request_model(
    client,
    "PATCH",
    "/api/users/@me/teams/" <> team_id <> "/applications/" <> app_id,
    "update application",
    body,
    client_default_meta(client),
    rest.application_from_json,
  )
}

pub fn delete_application(
  client: client.RestClient,
  team_id: String,
  app_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/teams/" <> team_id <> "/applications/" <> app_id,
    "delete application",
    core.NoBody,
    client_default_meta(client),
  )
}

// Commands, which team members list and team admins (or the application's
// bot) change. The API checks each one (a name of 1 to 32 lowercase letters of
// any script, digits, - and _; its options' rules) and answers a 400 with the
// reason.

pub fn list_commands(
  client: client.RestClient,
  team_id: String,
  app_id: String,
) -> Result(List(rest.ApplicationCommand), DuvetError) {
  request_list(
    client,
    "GET",
    commands_path(team_id, app_id),
    "list application commands",
    client_default_meta(client),
    rest.application_command_from_json,
  )
}

pub fn get_command(
  client: client.RestClient,
  team_id: String,
  app_id: String,
  command_id: String,
) -> Result(rest.ApplicationCommand, DuvetError) {
  request_model(
    client,
    "GET",
    commands_path(team_id, app_id) <> "/" <> command_id,
    "get application command",
    core.NoBody,
    client_default_meta(client),
    rest.application_command_from_json,
  )
}

pub fn create_command(
  client: client.RestClient,
  team_id: String,
  app_id: String,
  command: rest.NewCommand,
) -> Result(rest.ApplicationCommand, DuvetError) {
  request_model(
    client,
    "POST",
    commands_path(team_id, app_id),
    "create application command",
    core.JsonBody(rest.new_command_to_json(command)),
    client_default_meta(client),
    rest.application_command_from_json,
  )
}

/// Makes `commands` the application's commands, all of them: those left out
/// are deleted, and an empty list deletes every one. All or none are saved.
pub fn overwrite_commands(
  client: client.RestClient,
  team_id: String,
  app_id: String,
  commands: List(rest.NewCommand),
) -> Result(List(rest.ApplicationCommand), DuvetError) {
  client.request(
    client,
    "PUT",
    commands_path(team_id, app_id),
    "overwrite application commands",
    core.JsonBody(json.array(commands, rest.new_command_to_json)),
    client_default_meta(client),
  )
  |> result.try(fn(response) {
    core.decode_list(response, rest.application_command_from_json)
  })
}

/// Changes what's given; `options` replaces the whole list.
pub fn update_command(
  client: client.RestClient,
  team_id: String,
  app_id: String,
  command_id: String,
  name name: Option(String),
  description description: Option(String),
  options options: Option(List(rest.CommandOption)),
) -> Result(rest.ApplicationCommand, DuvetError) {
  let body =
    json_body(
      list.flatten([
        optional_json_entry("name", name, json.string),
        optional_json_entry("description", description, json.string),
        optional_json_entry("options", options, fn(options) {
          json.array(options, rest.command_option_to_json)
        }),
      ]),
    )
  request_model(
    client,
    "PATCH",
    commands_path(team_id, app_id) <> "/" <> command_id,
    "update application command",
    body,
    client_default_meta(client),
    rest.application_command_from_json,
  )
}

pub fn delete_command(
  client: client.RestClient,
  team_id: String,
  app_id: String,
  command_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    commands_path(team_id, app_id) <> "/" <> command_id,
    "delete application command",
    core.NoBody,
    client_default_meta(client),
  )
}

fn commands_path(team_id: String, app_id: String) -> String {
  "/api/users/@me/teams/"
  <> team_id
  <> "/applications/"
  <> app_id
  <> "/commands"
}

/// Makes the application's bot; answers its token.
pub fn create_bot(
  client: client.RestClient,
  team_id: String,
  app_id: String,
) -> Result(String, DuvetError) {
  request_map(
    client,
    "POST",
    "/api/users/@me/teams/" <> team_id <> "/applications/" <> app_id <> "/bot",
    "create bot",
    core.NoBody,
    client_default_meta(client),
  )
  |> result.map(fn(object) { decoding.string(object, "token") })
}

/// Answers the bot's new token.
pub fn reset_bot_token(
  client: client.RestClient,
  team_id: String,
  app_id: String,
) -> Result(String, DuvetError) {
  request_map(
    client,
    "POST",
    "/api/users/@me/teams/"
      <> team_id
      <> "/applications/"
      <> app_id
      <> "/bot/reset-token",
    "reset bot token",
    core.NoBody,
    client_default_meta(client),
  )
  |> result.map(fn(object) { decoding.string(object, "token") })
}

pub fn delete_bot(
  client: client.RestClient,
  team_id: String,
  app_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/users/@me/teams/" <> team_id <> "/applications/" <> app_id <> "/bot",
    "delete bot",
    core.NoBody,
    client_default_meta(client),
  )
}

/// Updates the application's bot. Clearing the alias removes it.
pub fn update_bot(
  client: client.RestClient,
  team_id: String,
  app_id: String,
  username username: Option(String),
  alias alias: Option(String),
  clear_alias clear_alias: Bool,
  avatar avatar: Option(FilePart),
  banner banner: Option(FilePart),
  remove_avatar remove_avatar: Bool,
  remove_banner remove_banner: Bool,
) -> Result(decoding.Object, DuvetError) {
  let fields =
    list.flatten([
      case username {
        Some(value) if value != "" -> [#("username", value)]
        _ -> []
      },
      case alias {
        Some(value) if value != "" -> [#("alias", value)]
        _ ->
          case clear_alias {
            True -> [#("alias", "")]
            False -> []
          }
      },
      case remove_avatar {
        True -> [#("remove_avatar", "true")]
        False -> []
      },
      case remove_banner {
        True -> [#("remove_banner", "true")]
        False -> []
      },
    ])
  request_map(
    client,
    "PATCH",
    "/api/users/@me/teams/" <> team_id <> "/applications/" <> app_id <> "/bot",
    "update bot",
    core.MultipartBody(fields: fields, files: files_from([avatar, banner])),
    client_default_meta(client),
  )
}

pub fn get_bot_user(
  client: client.RestClient,
  user_id: String,
) -> Result(user.BotUser, DuvetError) {
  request_model(
    client,
    "GET",
    "/api/users/" <> user_id,
    "get bot user",
    core.NoBody,
    client_default_meta(client),
    user.bot_user_from_json,
  )
}

pub fn add_bot_to_space(
  client: client.RestClient,
  space_id: String,
  bot_user_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "POST",
    "/api/spaces/" <> space_id <> "/bots/" <> bot_user_id,
    "add bot to space",
    core.NoBody,
    client_default_meta(client),
  )
}

pub fn remove_bot_from_space(
  client: client.RestClient,
  space_id: String,
  bot_user_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/" <> space_id <> "/bots/" <> bot_user_id,
    "remove bot from space",
    core.NoBody,
    client_default_meta(client),
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn client_default_meta(client: client.RestClient) -> core.Meta(a) {
  client.default_meta(client)
}

fn without_renewal(client: client.RestClient) -> core.Meta(a) {
  core.with_renew(client_default_meta(client), False)
}

fn with_progress(
  meta: core.Meta(a),
  progress: Option(fn(Int, Int) -> Nil),
) -> core.Meta(a) {
  case progress {
    Some(progress) -> core.with_progress(meta, progress)
    None -> meta
  }
}

fn json_body(entries: List(#(String, json.Json))) -> core.Body {
  core.JsonBody(json.object(entries))
}

fn optional_json_entry(
  key: String,
  value: Option(a),
  encode: fn(a) -> json.Json,
) -> List(#(String, json.Json)) {
  case value {
    Some(inner) -> [#(key, encode(inner))]
    None -> []
  }
}

fn optional_int(key: String, value: Option(Int)) -> List(#(String, json.Json)) {
  optional_json_entry(key, value, json.int)
}

fn optional_bool(
  key: String,
  value: Option(Bool),
) -> List(#(String, json.Json)) {
  optional_json_entry(key, value, json.bool)
}

fn files_from(files: List(Option(FilePart))) -> List(FilePart) {
  list.filter_map(files, fn(file) {
    case file {
      Some(file) -> Ok(file)
      None -> Error(Nil)
    }
  })
}

fn ignore_errors(_result: Result(a, DuvetError)) -> Nil {
  Nil
}

fn request_void(
  client: client.RestClient,
  method: String,
  path: String,
  action: String,
  body: core.Body,
  meta: core.Meta(a),
) -> Result(Nil, DuvetError) {
  client.request(client, method, path, action, body, meta)
  |> result.map(fn(_) { Nil })
}

fn request_map(
  client: client.RestClient,
  method: String,
  path: String,
  action: String,
  body: core.Body,
  meta: core.Meta(a),
) -> Result(decoding.Object, DuvetError) {
  client.request(client, method, path, action, body, meta)
  |> result.try(core.decode_map)
}

fn request_list(
  client: client.RestClient,
  method: String,
  path: String,
  action: String,
  meta: core.Meta(a),
  read: fn(decoding.Object) -> item,
) -> Result(List(item), DuvetError) {
  client.request(client, method, path, action, core.NoBody, meta)
  |> result.try(fn(response) { core.decode_list(response, read) })
}

fn request_model(
  client: client.RestClient,
  method: String,
  path: String,
  action: String,
  body: core.Body,
  meta: core.Meta(a),
  read: fn(decoding.Object) -> model,
) -> Result(model, DuvetError) {
  request_map(client, method, path, action, body, meta)
  |> result.map(read)
}

fn message_document(
  content: String,
  options: SendMessageOptions(a),
) -> List(#(String, json.Json)) {
  let fields =
    list.flatten([
      [#("content", json.string(content))],
      case options.nonce {
        Some(nonce) -> [#("nonce", json.string(nonce))]
        None -> []
      },
      optional_json_entry(
        "message_reference",
        options.message_reference,
        message.message_reference_to_json,
      ),
      optional_json_entry(
        "allowed_mentions",
        options.allowed_mentions,
        message.allowed_mentions_to_json,
      ),
    ])
  let fields = case options.embeds {
    [] -> fields
    embeds ->
      list.append(fields, [#("embeds", json.array(embeds, embed.to_json))])
  }
  case options.sticker_attachment_id {
    Some(sticker) if sticker != "" ->
      list.append(fields, [#("sticker_attachment_id", json.string(sticker))])
    _ -> fields
  }
}

fn message_form(
  content: String,
  options: SendMessageOptions(a),
) -> List(#(String, String)) {
  list.flatten([
    [#("content", content)],
    case options.nonce {
      Some(nonce) if nonce != "" -> [#("nonce", nonce)]
      _ -> []
    },
    case options.message_reference {
      Some(reference) -> [
        #(
          "message_reference",
          json.to_string(message.message_reference_to_json(reference)),
        ),
      ]
      None -> []
    },
    case options.allowed_mentions {
      Some(mentions) -> [
        #(
          "allowed_mentions",
          json.to_string(message.allowed_mentions_to_json(mentions)),
        ),
      ]
      None -> []
    },
  ])
}

fn request_message(
  client: client.RestClient,
  path: String,
  content: String,
  options: SendMessageOptions(a),
  read: fn(decoding.Object) -> model,
) -> Result(model, DuvetError) {
  let meta =
    client_default_meta(client)
    |> with_progress(options.on_progress)
    |> attach_abort(options.abort)
  let body = case options.files {
    [] -> json_body(message_document(content, options))
    files ->
      core.MultipartBody(fields: message_form(content, options), files: files)
  }
  request_model(client, "POST", path, "send message", body, meta, read)
}

fn attach_abort(meta: core.Meta(a), abort: Option(Subject(a))) -> core.Meta(a) {
  case abort {
    Some(subject) -> core.with_abort(meta, subject)
    None -> meta
  }
}

fn request_voice_note(
  client: client.RestClient,
  path: String,
  audio: BitArray,
  nonce: Option(String),
  format: String,
  read: fn(decoding.Object) -> model,
) -> Result(model, DuvetError) {
  case voice_note_media_type(format) {
    Error(Nil) ->
      Error(error.InvalidArgument("a voice note is webm, ogg or m4a"))
    Ok(_) -> {
      let fields =
        list.flatten([
          [#("type", int.to_string(message_type.value(message_type.voice)))],
          case nonce {
            Some(nonce) if nonce != "" -> [#("nonce", nonce)]
            _ -> []
          },
        ])
      let files = [
        multipart.FilePart(
          field: "files",
          bytes: audio,
          filename: "voice-note." <> format,
        ),
      ]
      request_model(
        client,
        "POST",
        path,
        "send voice note",
        core.MultipartBody(fields: fields, files: files),
        client_default_meta(client),
        read,
      )
    }
  }
}

fn voice_note_media_type(format: String) -> Result(String, Nil) {
  case format {
    "webm" -> Ok("audio/webm")
    "ogg" -> Ok("audio/ogg")
    "m4a" -> Ok("audio/mp4")
    _ -> Error(Nil)
  }
}
