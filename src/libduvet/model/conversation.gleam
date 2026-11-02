import gleam/option.{type Option, None, Some}
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import libduvet/model/attachment
import libduvet/model/client_status.{type ClientStatus}
import libduvet/model/conversation_type.{type ConversationType}
import libduvet/model/decoding
import libduvet/model/embed
import libduvet/model/message
import libduvet/model/message_type.{type MessageType}
import libduvet/model/user
import libduvet/model/user_status.{type UserStatus}

/// The user that conversation members and DMs carry: the API's public user.
pub type ConversationUser {
  ConversationUser(
    id: String,
    username: String,
    alias: Option(String),
    avatar: Option(String),
    banner: Option(String),
    badges: Option(Int),
    is_bot: Bool,
    /// The bio, empty when there's none.
    custom: String,
    flags: Int,
    email_verified: Option(Bool),
    /// When the account was made and last changed: None only in a user built
    /// without them, as the API always sends them.
    created_at: Option(Timestamp),
    updated_at: Option(Timestamp),
    /// When the account was deleted; None while it isn't.
    deleted_at: Option(Timestamp),
  )
}

pub fn conversation_user_from_json(
  object: decoding.Object,
) -> ConversationUser {
  ConversationUser(
    id: decoding.string(object, "id"),
    username: decoding.string(object, "username"),
    alias: decoding.optional_string(object, "alias"),
    avatar: decoding.optional_string(object, "avatar"),
    banner: decoding.optional_string(object, "banner"),
    badges: decoding.optional_int(object, "badges"),
    is_bot: decoding.bool_or(object, "is_bot", False),
    custom: decoding.string_or(object, "custom", ""),
    flags: decoding.int_or(object, "flags", 0),
    email_verified: decoding.optional_bool(object, "email_verified"),
    created_at: decoding.optional_time(object, "created_at"),
    updated_at: decoding.optional_time(object, "updated_at"),
    deleted_at: decoding.optional_time(object, "deleted_at"),
  )
}

pub type ConversationMember {
  ConversationMember(
    id: String,
    conversation_id: String,
    user_id: String,
    created_at: Timestamp,
    updated_at: Timestamp,
    /// The platforms the member is connected on, with their status. None
    /// while they're offline, and from a server before client statuses.
    client_status: Option(ClientStatus),
    /// None in the member that adding one answers when the conversation's
    /// list doesn't have them yet.
    user: Option(ConversationUser),
    /// The member's status when the API handed them out. None where the API
    /// leaves it out.
    status_id: Option(UserStatus),
  )
}

pub fn conversation_member_from_json(
  object: decoding.Object,
) -> ConversationMember {
  ConversationMember(
    id: decoding.string(object, "id"),
    conversation_id: decoding.string(object, "conversation_id"),
    user_id: decoding.string(object, "user_id"),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    client_status: client_status.from_field(object, "client_status"),
    user: decoding.optional_object(object, "user")
      |> option_map(conversation_user_from_json),
    status_id: decoding.optional_int(object, "status_id")
      |> option_map(user_status.from_int),
  )
}

pub type Conversation {
  Conversation(
    id: String,
    type_: ConversationType,
    name: Option(String),
    owner_id: String,
    created_at: Timestamp,
    updated_at: Timestamp,
    deleted_at: Option(Timestamp),
    members: List(ConversationMember),
  )
}

pub fn conversation_from_json(object: decoding.Object) -> Conversation {
  Conversation(
    id: decoding.string(object, "id"),
    type_: conversation_type.from_int(decoding.int(object, "type")),
    name: decoding.optional_string(object, "name"),
    owner_id: decoding.string(object, "owner_id"),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    deleted_at: decoding.optional_time(object, "deleted_at"),
    members: decoding.objects_or_empty(
      object,
      "members",
      conversation_member_from_json,
    ),
  )
}

/// What a call notice ([message_type.call]) says about its call: who was in
/// it, and when.
pub type CallNotice {
  CallNotice(
    /// Who was in the call, by user ID: its caller first, whether or not they
    /// joined its voice, then each member who joined its voice, once.
    participants: List(String),
    /// When the call started: when it began to ring.
    started_at: Timestamp,
    /// When the call ended.
    ended_at: Timestamp,
  )
}

pub fn call_notice_from_json(object: decoding.Object) -> CallNotice {
  CallNotice(
    participants: decoding.string_list(object, "participants"),
    started_at: decoding.time(object, "started_at"),
    ended_at: decoding.time(object, "ended_at"),
  )
}

/// How long the call lasted, ringing included.
pub fn call_notice_duration(notice: CallNotice) -> Duration {
  timestamp_difference(notice.started_at, notice.ended_at)
}

pub type DirectMessage {
  DirectMessage(
    id: String,
    conversation_id: Option(String),
    /// Always set for a DM: the API's type allows null only because webhook
    /// room messages share the table.
    author_id: String,
    content: Option(String),
    type_: MessageType,
    created_at: Timestamp,
    updated_at: Timestamp,
    nonce: Option(String),
    user: Option(ConversationUser),
    referenced_message: Option(message.ReferencedMessage),
    embeds: Option(List(embed.Embed)),
    attachments: Option(List(attachment.Attachment)),
    reactions: Option(List(message.MessageReaction)),
    sticker_attachment_id: Option(String),
    /// When it was pinned; None while it isn't.
    pinned_at: Option(Timestamp),
    /// What a call notice says about its call; None on every other message.
    call: Option(CallNotice),
  )
}

pub fn direct_message_from_json(object: decoding.Object) -> DirectMessage {
  DirectMessage(
    id: decoding.string(object, "id"),
    conversation_id: decoding.optional_string(object, "conversation_id"),
    author_id: decoding.string(object, "author_id"),
    content: decoding.optional_string(object, "content"),
    type_: message_type.from_int(decoding.int_or(object, "type", 0)),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    nonce: decoding.optional_string(object, "nonce"),
    user: decoding.optional_object(object, "user")
      |> option_map(conversation_user_from_json),
    referenced_message: decoding.optional_object(object, "referenced_message")
      |> option_map(message.referenced_message_from_json),
    embeds: decoding.optional_objects(object, "embeds", embed.from_json),
    attachments: decoding.optional_objects(
      object,
      "attachments",
      attachment.from_json,
    ),
    reactions: decoding.optional_objects(
      object,
      "reactions",
      message.message_reaction_from_json,
    ),
    sticker_attachment_id: decoding.optional_string(
      object,
      "sticker_attachment_id",
    ),
    pinned_at: decoding.optional_time(object, "pinned_at"),
    call: decoding.optional_object(object, "call")
      |> option_map(call_notice_from_json),
  )
}

/// A friend request, with the other user's details. The request that sending
/// one answers is the bare request, without them.
pub type FriendRequest {
  FriendRequest(
    id: String,
    sender_id: String,
    recipient_id: String,
    created_at: Timestamp,
    updated_at: Timestamp,
    user_username: Option(String),
    user_alias: Option(String),
    user_avatar: Option(String),
    user_banner: Option(String),
    user: Option(user.GatewayUser),
  )
}

pub fn friend_request_from_json(object: decoding.Object) -> FriendRequest {
  FriendRequest(
    id: decoding.string(object, "id"),
    sender_id: decoding.string(object, "sender_id"),
    recipient_id: decoding.string(object, "recipient_id"),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    user_username: decoding.optional_string(object, "user_username"),
    user_alias: decoding.optional_string(object, "user_alias"),
    user_avatar: decoding.optional_string(object, "user_avatar"),
    user_banner: decoding.optional_string(object, "user_banner"),
    user: decoding.optional_object(object, "user")
      |> option_map(user.from_json),
  )
}

pub type Friend {
  Friend(
    id: String,
    request_id: String,
    sender_id: String,
    recipient_id: String,
    user_username: String,
    user_alias: Option(String),
    user_avatar: Option(String),
    user_banner: Option(String),
    user: Option(user.GatewayUser),
    status_id: Option(UserStatus),
    client_status: Option(ClientStatus),
  )
}

pub fn friend_from_json(object: decoding.Object) -> Friend {
  Friend(
    id: decoding.string(object, "id"),
    request_id: decoding.string(object, "request_id"),
    sender_id: decoding.string(object, "sender_id"),
    recipient_id: decoding.string(object, "recipient_id"),
    user_username: decoding.string(object, "user_username"),
    user_alias: decoding.optional_string(object, "user_alias"),
    user_avatar: decoding.optional_string(object, "user_avatar"),
    user_banner: decoding.optional_string(object, "user_banner"),
    user: decoding.optional_object(object, "user")
      |> option_map(user.from_json),
    status_id: decoding.optional_int(object, "status_id")
      |> option_map(user_status.from_int),
    client_status: client_status.from_field(object, "client_status"),
  )
}

/// FRIEND_REQUEST_CREATE: a friend request was sent. Both sides get it.
pub type FriendRequestCreateEvent {
  FriendRequestCreateEvent(
    id: String,
    sender_id: String,
    /// The user the request was sent to. None from an API before it.
    recipient_id: Option(String),
    username: String,
    alias: Option(String),
    avatar: Option(String),
    banner: Option(String),
    /// The other side's public profile.
    user: Option(user.GatewayUser),
  )
}

pub fn friend_request_create_event_from_json(
  object: decoding.Object,
) -> FriendRequestCreateEvent {
  FriendRequestCreateEvent(
    id: decoding.string(object, "id"),
    sender_id: decoding.string(object, "sender_id"),
    recipient_id: decoding.optional_string(object, "recipient_id"),
    username: decoding.string(object, "username"),
    alias: decoding.optional_string(object, "alias"),
    avatar: decoding.optional_string(object, "avatar"),
    banner: decoding.optional_string(object, "banner"),
    user: decoding.optional_object(object, "user")
      |> option_map(user.from_json),
  )
}

/// FRIEND_REQUEST_ACCEPT: the friendship the request made.
pub type FriendRequestAcceptEvent {
  FriendRequestAcceptEvent(
    id: String,
    request_id: String,
    sender_id: String,
    recipient_id: String,
    user: Option(user.GatewayUser),
    /// The status the user shows. None from an API before it.
    status_id: Option(UserStatus),
    /// The platforms the user is connected on, with their status.
    client_status: Option(ClientStatus),
  )
}

pub fn friend_request_accept_event_from_json(
  object: decoding.Object,
) -> FriendRequestAcceptEvent {
  FriendRequestAcceptEvent(
    id: decoding.string(object, "id"),
    request_id: decoding.string(object, "request_id"),
    sender_id: decoding.string(object, "sender_id"),
    recipient_id: decoding.string(object, "recipient_id"),
    user: decoding.optional_object(object, "user")
      |> option_map(user.from_json),
    status_id: decoding.optional_int(object, "status_id")
      |> option_map(user_status.from_int),
    client_status: client_status.from_field(object, "client_status"),
  )
}

fn option_map(value: Option(a), with: fn(a) -> b) -> Option(b) {
  case value {
    Some(inner) -> Some(with(inner))
    None -> None
  }
}

fn timestamp_difference(left: Timestamp, right: Timestamp) -> Duration {
  timestamp.difference(left, right)
}
