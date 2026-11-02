import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import libduvet/api_router
import libduvet/error.{type DuvetError}
import libduvet/http/client as api_client
import libduvet/http/core
import libduvet/http/multipart.{type FilePart}
import libduvet/model/conversation
import libduvet/model/decoding
import libduvet/model/embed
import libduvet/model/message
import libduvet/model/rest

/// A page of the room's messages before [before] (the newest without it),
/// newest first: [count] of them, 1 to 100.
pub fn get_messages(
  client: api_client.RestClient,
  room_id: String,
  before: Option(String),
  count: Int,
) -> Result(List(message.GatewayMessage), DuvetError) {
  let query =
    list.flatten([
      [#("count", int.to_string(count))],
      case before {
        Some(before) -> [#("before", before)]
        None -> []
      },
    ])
  let meta =
    api_client.default_meta(client)
    |> core.with_query(query)
  request_list(
    client,
    "GET",
    "/api/rooms/" <> room_id <> "/messages",
    "get messages",
    meta,
    message.from_json,
  )
}

/// A room's pinned messages, the last pinned first.
pub fn get_room_pins(
  client: api_client.RestClient,
  room_id: String,
) -> Result(List(message.GatewayMessage), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/rooms/" <> room_id <> "/pins",
    "get room pins",
    api_client.default_meta(client),
    message.from_json,
  )
}

/// Pins a message of a room, which posts the room's pin notice.
pub fn pin_room_message(
  client: api_client.RestClient,
  room_id: String,
  message_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "PUT",
    "/api/rooms/" <> room_id <> "/pins/" <> message_id,
    "pin message",
    api_client.default_meta(client),
  )
}

pub fn leave_space(
  client: api_client.RestClient,
  space_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/spaces/" <> space_id <> "/members/@me",
    "leave space",
    api_client.default_meta(client),
  )
}

pub fn get_invite(
  client: api_client.RestClient,
  code: String,
) -> Result(rest.InviteInfo, DuvetError) {
  let meta = api_client.default_meta(client)
  api_client.request(
    client,
    "GET",
    "/api/invites/" <> api_router.encode_component(code),
    "get invite",
    core.NoBody,
    meta,
  )
  |> result.try(core.decode_map)
  |> result.map(rest.invite_info_from_json)
}

pub fn get_friends(
  client: api_client.RestClient,
) -> Result(List(conversation.Friend), DuvetError) {
  request_list(
    client,
    "GET",
    "/api/users/@me/friends",
    "get friends",
    api_client.default_meta(client),
    conversation.friend_from_json,
  )
}

pub fn invite_to_team(
  client: api_client.RestClient,
  team_id: String,
  email: String,
) -> Result(Nil, DuvetError) {
  let body = core.JsonBody(json.object([#("email", json.string(email))]))
  api_client.request(
    client,
    "POST",
    "/api/users/@me/teams/" <> team_id <> "/invites",
    "invite to team",
    body,
    api_client.default_meta(client),
  )
  |> result.map(fn(_) { Nil })
}

pub fn get_direct_messages(
  client: api_client.RestClient,
  conversation_id: String,
  before: Option(String),
  count: Int,
) -> Result(List(conversation.DirectMessage), DuvetError) {
  let query =
    list.flatten([
      [#("count", int.to_string(count))],
      case before {
        Some(before) -> [#("before", before)]
        None -> []
      },
    ])
  let meta = api_client.default_meta(client) |> core.with_query(query)
  request_list(
    client,
    "GET",
    "/api/users/@me/conversations/" <> conversation_id <> "/messages",
    "get direct messages",
    meta,
    conversation.direct_message_from_json,
  )
}

/// Makes an account; it is verified by the link the API emails.
pub fn sign_in(
  client: api_client.RestClient,
  username: String,
  alias: Option(String),
  password: String,
  email: String,
) -> Result(Nil, DuvetError) {
  let body =
    core.JsonBody(
      json.object([
        #("username", json.string(username)),
        #("alias", json.nullable(alias, json.string)),
        #("password", json.string(password)),
        #("email", json.string(email)),
      ]),
    )
  let meta =
    api_client.default_meta(client)
    |> core.with_renew(False)
  api_client.request(client, "POST", "/api/auth/signin", "sign in", body, meta)
  |> result.try(core.assert_ok(_, "sign in"))
  |> result.map(fn(_) { Nil })
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

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

pub fn send_message(
  client: api_client.RestClient,
  room_id: String,
  content: String,
  options: SendMessageOptions(a),
) -> Result(message.GatewayMessage, DuvetError) {
  let path = "/api/rooms/" <> room_id <> "/messages"
  let meta =
    api_client.default_meta(client)
    |> attach_progress(options.on_progress)
    |> attach_abort(options.abort)
  let response = case options.files {
    [] -> {
      let fields =
        list.flatten([
          [#("content", json.string(content))],
          case options.nonce {
            Some(nonce) -> [#("nonce", json.string(nonce))]
            None -> []
          },
          encoding_optional_json(
            "message_reference",
            options.message_reference,
            message.message_reference_to_json,
          ),
          encoding_optional_json(
            "allowed_mentions",
            options.allowed_mentions,
            message.allowed_mentions_to_json,
          ),
        ])
      let fields = case options.embeds {
        [] -> fields
        embeds ->
          list.append(fields, [
            #("embeds", json.array(embeds, embed.to_json)),
          ])
      }
      let fields = case options.sticker_attachment_id {
        Some(sticker) if sticker != "" ->
          list.append(fields, [#("sticker_attachment_id", json.string(sticker))])
        _ -> fields
      }
      api_client.request(
        client,
        "POST",
        path,
        "send message",
        core.JsonBody(json.object(fields)),
        meta,
      )
    }
    files -> {
      let fields =
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
      api_client.request(
        client,
        "POST",
        path,
        "send message",
        core.MultipartBody(fields: fields, files: files),
        meta,
      )
    }
  }
  response
  |> result.try(core.decode_map)
  |> result.map(message.from_json)
}

fn encoding_optional_json(
  key: String,
  value: Option(a),
  encode: fn(a) -> json.Json,
) -> List(#(String, json.Json)) {
  case value {
    Some(inner) -> [#(key, encode(inner))]
    None -> []
  }
}

fn attach_progress(
  meta: core.Meta(a),
  progress: Option(fn(Int, Int) -> Nil),
) -> core.Meta(a) {
  case progress {
    Some(progress) -> core.with_progress(meta, progress)
    None -> meta
  }
}

fn attach_abort(meta: core.Meta(a), abort: Option(Subject(a))) -> core.Meta(a) {
  case abort {
    Some(subject) -> core.with_abort(meta, subject)
    None -> meta
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn request_void(
  client: api_client.RestClient,
  method: String,
  path: String,
  action: String,
  meta: core.Meta(a),
) -> Result(Nil, DuvetError) {
  api_client.request(client, method, path, action, core.NoBody, meta)
  |> result.map(fn(_) { Nil })
}

fn request_list(
  client: api_client.RestClient,
  method: String,
  path: String,
  action: String,
  meta: core.Meta(a),
  read: fn(decoding.Object) -> item,
) -> Result(List(item), DuvetError) {
  api_client.request(client, method, path, action, core.NoBody, meta)
  |> result.try(fn(response) { core.decode_list(response, read) })
}
