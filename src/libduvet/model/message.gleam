import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/time/timestamp.{type Timestamp}
import libduvet/model/attachment
import libduvet/model/decoding
import libduvet/model/embed
import libduvet/model/encoding
import libduvet/model/message_reference_type
import libduvet/model/message_type.{type MessageType}
import libduvet/model/user

pub type MessageReference {
  MessageReference(
    type_: Option(message_reference_type.MessageReferenceType),
    message_id: Option(String),
    room_id: Option(String),
    space_id: Option(String),
    fail_if_not_exists: Option(Bool),
  )
}

pub fn message_reference_from_json(
  object: decoding.Object,
) -> MessageReference {
  MessageReference(
    type_: Some(
      message_reference_type.MessageReferenceType(decoding.int_or(
        object,
        "type",
        0,
      )),
    ),
    message_id: decoding.optional_string(object, "message_id"),
    room_id: decoding.optional_string(object, "room_id"),
    space_id: decoding.optional_string(object, "space_id"),
    fail_if_not_exists: decoding.optional_bool(object, "fail_if_not_exists"),
  )
}

pub fn message_reference_from_message(
  message: GatewayMessage,
) -> MessageReference {
  MessageReference(
    type_: Some(message_reference_type.reply),
    message_id: Some(message.id),
    room_id: Some(message.room_id),
    space_id: None,
    fail_if_not_exists: Some(True),
  )
}

pub fn message_reference_to_json(reference: MessageReference) -> json.Json {
  json.object(
    encoding.present([
      case reference.type_ {
        Some(reference_type) ->
          Some(#("type", json.int(message_reference_type.value(reference_type))))
        None -> None
      },
      encoding.optional_string("message_id", reference.message_id),
      encoding.optional_string("room_id", reference.room_id),
      encoding.optional_string("space_id", reference.space_id),
      encoding.optional_bool("fail_if_not_exists", reference.fail_if_not_exists),
    ]),
  )
}

/// What a new message says about the mentions it makes beyond the users its
/// text names (`allowed_mentions`).
pub type AllowedMentions {
  /// Whether a reply mentions the author of the message it replies to. A
  /// reply sent without allowed mentions does; false sends it without
  /// notifying them.
  AllowedMentions(replied_user: Bool)
}

pub fn allowed_mentions_to_json(mentions: AllowedMentions) -> json.Json {
  json.object([#("replied_user", json.bool(mentions.replied_user))])
}

pub type ReferencedMessage {
  ReferencedMessage(
    type_: Option(Int),
    message_id: Option(String),
    room_id: Option(String),
    space_id: Option(String),
    content: Option(String),
    author_id: Option(String),
    author_name: Option(String),
    author_avatar: Option(String),
    created_at: Option(Timestamp),
    /// Whether the reply mentions the author of the message it replies to.
    /// False from an API from before it.
    mention_author: Bool,
  )
}

pub fn referenced_message_from_json(
  object: decoding.Object,
) -> ReferencedMessage {
  ReferencedMessage(
    type_: decoding.optional_int(object, "type"),
    message_id: decoding.optional_string(object, "message_id"),
    room_id: decoding.optional_string(object, "room_id"),
    space_id: decoding.optional_string(object, "space_id"),
    content: decoding.optional_string(object, "content"),
    author_id: decoding.optional_string(object, "author_id"),
    author_name: decoding.optional_string(object, "author_name"),
    author_avatar: decoding.optional_string(object, "author_avatar"),
    created_at: decoding.optional_time(object, "created_at"),
    mention_author: decoding.bool_or(object, "mention_author", False),
  )
}

pub type MessageReaction {
  MessageReaction(
    emoji_name: String,
    emoji_id: Option(String),
    count: Int,
    users: List(String),
  )
}

pub fn message_reaction_from_json(object: decoding.Object) -> MessageReaction {
  MessageReaction(
    emoji_name: decoding.string(object, "emoji_name"),
    emoji_id: decoding.optional_string(object, "emoji_id"),
    count: decoding.int(object, "count"),
    users: decoding.string_list(object, "users"),
  )
}

/// What a message a bot sends for an interaction says about it.
pub type InteractionMetadata {
  InteractionMetadata(
    id: String,
    /// 2 for a command, 3 for a component.
    type_: Int,
    /// Who used it, as they were when the message was made.
    user: user.InteractionUser,
    /// The message whose component was used, for a component's interaction.
    interacted_message_id: Option(String),
    /// The interaction's first response, on its follow-ups.
    original_response_message_id: Option(String),
    /// The command's name, for a command's interaction.
    name: Option(String),
  )
}

pub fn interaction_metadata_from_json(
  object: decoding.Object,
) -> InteractionMetadata {
  InteractionMetadata(
    id: decoding.string(object, "id"),
    type_: decoding.int(object, "type"),
    user: decoding.object(object, "user")
      |> user.interaction_user_from_json,
    interacted_message_id: decoding.optional_string(
      object,
      "interacted_message_id",
    ),
    original_response_message_id: decoding.optional_string(
      object,
      "original_response_message_id",
    ),
    name: decoding.optional_string(object, "name"),
  )
}

pub type GatewayMessage {
  GatewayMessage(
    id: String,
    room_id: String,
    /// None for webhook messages, which carry `webhook_id` instead.
    author_id: Option(String),
    webhook_id: Option(String),
    content: Option(String),
    type_: MessageType,
    created_at: Timestamp,
    updated_at: Timestamp,
    deleted_at: Option(Timestamp),
    nonce: Option(String),
    user: Option(user.GatewayUser),
    member_alias: Option(String),
    referenced_message: Option(ReferencedMessage),
    ref_message_id: Option(String),
    embeds: Option(List(embed.Embed)),
    attachments: Option(List(attachment.Attachment)),
    reactions: Option(List(MessageReaction)),
    sticker_attachment_id: Option(String),
    /// When it was pinned; None while it isn't. Events that create or edit a
    /// message leave it out.
    pinned_at: Option(Timestamp),
    flags: Int,
    /// The message's components, as the API sends them.
    components: Option(List(decoding.Object)),
    interaction_metadata: Option(InteractionMetadata),
  )
}

pub fn from_json(object: decoding.Object) -> GatewayMessage {
  GatewayMessage(
    id: decoding.string(object, "id"),
    room_id: decoding.string(object, "room_id"),
    author_id: decoding.optional_string(object, "author_id"),
    webhook_id: decoding.optional_string(object, "webhook_id"),
    content: decoding.optional_string(object, "content"),
    type_: message_type.from_int(decoding.int_or(object, "type", 0)),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    deleted_at: decoding.optional_time(object, "deleted_at"),
    nonce: decoding.optional_string(object, "nonce"),
    user: decoding.optional_object(object, "user")
      |> option_map(user.from_json),
    member_alias: decoding.optional_string(object, "member_alias"),
    referenced_message: decoding.optional_object(object, "referenced_message")
      |> option_map(referenced_message_from_json),
    ref_message_id: decoding.optional_string(object, "ref_message_id"),
    embeds: decoding.optional_objects(object, "embeds", embed.from_json),
    attachments: decoding.optional_objects(
      object,
      "attachments",
      attachment.from_json,
    ),
    reactions: decoding.optional_objects(
      object,
      "reactions",
      message_reaction_from_json,
    ),
    sticker_attachment_id: decoding.optional_string(
      object,
      "sticker_attachment_id",
    ),
    pinned_at: decoding.optional_time(object, "pinned_at"),
    flags: decoding.int_or(object, "flags", 0),
    components: decoding.optional_list(object, "components", fn(value) {
      decoding.object_value(value, "components")
    }),
    interaction_metadata: decoding.optional_object(
      object,
      "interaction_metadata",
    )
      |> option_map(interaction_metadata_from_json),
  )
}

pub type Message {
  Message(
    id: String,
    content: String,
    type_: MessageType,
    author_id: String,
    author_name: String,
    author_avatar_url: Option(String),
    created_at: Timestamp,
    updated_at: Timestamp,
    nonce: Option(String),
    referenced_message: Option(ReferencedMessage),
    ref_message_id: Option(String),
    embeds: Option(List(embed.Embed)),
    attachments: Option(List(attachment.Attachment)),
    reactions: Option(List(MessageReaction)),
    sticker_attachment_id: Option(String),
  )
}

pub fn message_from_json(object: decoding.Object) -> Message {
  Message(
    id: decoding.string(object, "id"),
    content: decoding.string_or(object, "content", ""),
    type_: message_type.from_int(decoding.int_or(object, "type", 0)),
    author_id: decoding.string(object, "author_id"),
    author_name: decoding.string(object, "author_name"),
    author_avatar_url: decoding.optional_string(object, "author_avatar_url"),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    nonce: decoding.optional_string(object, "nonce"),
    referenced_message: decoding.optional_object(object, "referenced_message")
      |> option_map(referenced_message_from_json),
    ref_message_id: decoding.optional_string(object, "ref_message_id"),
    embeds: decoding.optional_objects(object, "embeds", embed.from_json),
    attachments: decoding.optional_objects(
      object,
      "attachments",
      attachment.from_json,
    ),
    reactions: decoding.optional_objects(
      object,
      "reactions",
      message_reaction_from_json,
    ),
    sticker_attachment_id: decoding.optional_string(
      object,
      "sticker_attachment_id",
    ),
  )
}

fn option_map(value: Option(a), with: fn(a) -> b) -> Option(b) {
  case value {
    Some(inner) -> Some(with(inner))
    None -> None
  }
}
