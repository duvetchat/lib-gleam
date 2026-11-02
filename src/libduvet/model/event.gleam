import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import libduvet/model/activity
import libduvet/model/client_status.{type ClientStatus}
import libduvet/model/decoding
import libduvet/model/encoding
import libduvet/model/ready
import libduvet/model/space
import libduvet/model/user
import libduvet/model/user_status.{type UserStatus}

pub type GatewaySpaceCreatePayload {
  GatewaySpaceCreatePayload(
    space: space.GatewaySpace,
    rooms: Dict(String, space.GatewayRoom),
    roles_permissions: Dict(String, space.GatewayRole),
    member_roles: Dict(String, List(String)),
    overwrites: Option(Dict(String, List(space.GatewayRoomOverwrite))),
    owner_id: String,
    voice_states: Option(List(space.GatewayVoiceState)),
    /// The members who aren't offline as the event is sent, by user ID.
    member_statuses: Dict(String, UserStatus),
    /// The client status of each member `member_statuses` has, by user ID.
    member_client_status: Dict(String, ClientStatus),
    /// What the space's members connected now are doing, by user ID.
    activities: Dict(String, List(activity.Activity)),
    /// The user's read state in each room of the space they can view, by room
    /// ID.
    read_states: Dict(String, space.RoomReadState),
  )
}

pub fn space_create_payload_from_json(
  object: decoding.Object,
) -> GatewaySpaceCreatePayload {
  GatewaySpaceCreatePayload(
    space: decoding.object(object, "space")
      |> space.space_from_json,
    rooms: decoding.map_objects(object, "rooms", space.room_from_json),
    roles_permissions: decoding.map_objects(
      object,
      "roles_permissions",
      space.role_from_json,
    ),
    member_roles: decoding.map_or_empty(object, "member_roles", fn(value) {
      decoding.string_list_value(value, "member_roles")
    }),
    overwrites: decoding.optional_map(object, "overwrites", fn(value) {
      decoding.objects_value(value)
      |> list.map(space.room_overwrite_from_json)
    }),
    owner_id: decoding.string(object, "owner_id"),
    voice_states: decoding.optional_objects(
      object,
      "voice_states",
      space.voice_state_from_json,
    ),
    member_statuses: decoding.map_or_empty(object, "member_statuses", fn(value) {
      user_status.from_int(decoding.int_value(value, "member_statuses"))
    }),
    member_client_status: decoding.map_or_empty(
      object,
      "member_client_status",
      fn(value) {
        client_status.from_json(decoding.object_value(
          value,
          "member_client_status",
        ))
      },
    ),
    activities: decoding.map_or_empty(object, "activities", activity.from_list),
    read_states: decoding.map_objects_or_empty(
      object,
      "read_states",
      space.room_read_state_from_json,
    ),
  )
}

pub type GatewayMessageDelete {
  GatewayMessageDelete(id: String, room_id: String)
}

pub fn message_delete_from_json(
  object: decoding.Object,
) -> GatewayMessageDelete {
  GatewayMessageDelete(
    id: decoding.string(object, "id"),
    room_id: decoding.string(object, "room_id"),
  )
}

pub type GatewayUserStatusUpdate {
  GatewayUserStatusUpdate(
    user_id: String,
    status_id: UserStatus,
    /// The space this status is for: a bot also has one per space. None for a
    /// status that holds everywhere: a person's, or a bot's overall one.
    space_id: Option(String),
    /// The platforms the user is connected on now, with their status.
    client_status: Option(ClientStatus),
  )
}

pub fn user_status_update_from_json(
  object: decoding.Object,
) -> GatewayUserStatusUpdate {
  GatewayUserStatusUpdate(
    user_id: decoding.string(object, "user_id"),
    status_id: user_status.from_int(decoding.int(object, "status_id")),
    space_id: decoding.optional_string(object, "space_id"),
    client_status: client_status.from_field(object, "client_status"),
  )
}

/// MESSAGE_PIN_UPDATE: a message of a room was pinned or unpinned.
pub type MessagePinUpdateEvent {
  MessagePinUpdateEvent(
    id: String,
    room_id: String,
    /// When it was pinned; None once it's unpinned.
    pinned_at: Option(Timestamp),
  )
}

pub fn message_pin_update_from_json(
  object: decoding.Object,
) -> MessagePinUpdateEvent {
  MessagePinUpdateEvent(
    id: decoding.string(object, "id"),
    room_id: decoding.string(object, "room_id"),
    pinned_at: decoding.optional_time(object, "pinned_at"),
  )
}

/// DM_MESSAGE_PIN_UPDATE: a message of a conversation was pinned or unpinned.
pub type DMMessagePinUpdateEvent {
  DMMessagePinUpdateEvent(
    id: String,
    conversation_id: String,
    /// When it was pinned; None once it's unpinned.
    pinned_at: Option(Timestamp),
  )
}

pub fn dm_message_pin_update_from_json(
  object: decoding.Object,
) -> DMMessagePinUpdateEvent {
  DMMessagePinUpdateEvent(
    id: decoding.string(object, "id"),
    conversation_id: decoding.string(object, "conversation_id"),
    pinned_at: decoding.optional_time(object, "pinned_at"),
  )
}

/// ROOM_REORDER: every room of a space, with its position and parent, after
/// one of them moved.
pub type RoomReorderEvent {
  RoomReorderEvent(rooms: List(space.GatewayRoom))
}

pub fn room_reorder_from_json(object: decoding.Object) -> RoomReorderEvent {
  RoomReorderEvent(rooms: decoding.objects_or_empty(
    object,
    "rooms",
    space.room_from_json,
  ))
}

/// USER_ACTIVITY_UPDATE: a user's activities changed.
pub type UserActivityUpdateEvent {
  UserActivityUpdateEvent(
    user_id: String,
    /// Empty when they cleared them.
    activities: List(activity.Activity),
  )
}

pub fn user_activity_update_from_json(
  object: decoding.Object,
) -> UserActivityUpdateEvent {
  UserActivityUpdateEvent(
    user_id: decoding.string(object, "user_id"),
    activities: activity.from_list(field_or_null(object, "activities")),
  )
}

pub type SpaceDeleteEvent {
  SpaceDeleteEvent(id: String)
}

pub fn space_delete_from_json(object: decoding.Object) -> SpaceDeleteEvent {
  SpaceDeleteEvent(id: decoding.string(object, "id"))
}

pub type RoomDeleteEvent {
  RoomDeleteEvent(id: String, space_id: String)
}

pub fn room_delete_from_json(object: decoding.Object) -> RoomDeleteEvent {
  RoomDeleteEvent(
    id: decoding.string(object, "id"),
    space_id: decoding.string(object, "space_id"),
  )
}

pub type OverwriteDeleteEvent {
  OverwriteDeleteEvent(room_id: String, target_id: String)
}

pub fn overwrite_delete_from_json(
  object: decoding.Object,
) -> OverwriteDeleteEvent {
  OverwriteDeleteEvent(
    room_id: decoding.string(object, "room_id"),
    target_id: decoding.string(object, "target_id"),
  )
}

/// MENTION_CREATE: the user was mentioned in a message of a room.
pub type MentionCreateEvent {
  MentionCreateEvent(
    message_id: String,
    room_id: String,
    /// Who wrote the message.
    author_id: String,
    /// Never set by the API: a conversation's mentions come as
    /// DM_MENTION_CREATE.
    conversation_id: Option(String),
  )
}

pub fn mention_create_from_json(object: decoding.Object) -> MentionCreateEvent {
  MentionCreateEvent(
    message_id: decoding.string(object, "message_id"),
    room_id: decoding.string(object, "room_id"),
    author_id: decoding.string(object, "author_id"),
    conversation_id: decoding.optional_string(object, "conversation_id"),
  )
}

/// DM_MENTION_CREATE: the user was mentioned in a message of a conversation.
pub type DMMentionCreateEvent {
  DMMentionCreateEvent(
    message_id: String,
    conversation_id: String,
    /// Who wrote the message.
    author_id: String,
  )
}

pub fn dm_mention_create_from_json(
  object: decoding.Object,
) -> DMMentionCreateEvent {
  DMMentionCreateEvent(
    message_id: decoding.string(object, "message_id"),
    conversation_id: decoding.string(object, "conversation_id"),
    author_id: decoding.string(object, "author_id"),
  )
}

pub type UserUpdateEvent {
  UserUpdateEvent(
    id: String,
    username: String,
    alias: Option(String),
    avatar: Option(String),
    banner: Option(String),
    /// The bio, empty when there's none. None from an API from before bios.
    custom: Option(String),
    /// The flags and badges as they are now. None from an API that leaves
    /// them out.
    flags: Option(Int),
    badges: Option(Int),
  )
}

pub fn user_update_from_json(object: decoding.Object) -> UserUpdateEvent {
  UserUpdateEvent(
    id: decoding.string(object, "id"),
    username: decoding.string(object, "username"),
    alias: decoding.optional_string(object, "alias"),
    avatar: decoding.optional_string(object, "avatar"),
    banner: decoding.optional_string(object, "banner"),
    custom: decoding.optional_string(object, "custom"),
    flags: decoding.optional_int(object, "flags"),
    badges: decoding.optional_int(object, "badges"),
  )
}

/// VOICE_STATE_UPDATE: a user's whole voice state in a space's voice room or
/// a conversation's call, or that they left it (`joined` false).
pub type VoiceStateEvent {
  VoiceStateEvent(
    room_id: String,
    user_id: String,
    joined: Bool,
    muted: Bool,
    deafened: Bool,
    screen_sharing: Bool,
    /// Their camera is on.
    camera: Bool,
    version: Int,
  )
}

pub fn voice_state_update_from_json(
  object: decoding.Object,
) -> VoiceStateEvent {
  VoiceStateEvent(
    room_id: decoding.string(object, "room_id"),
    user_id: decoding.string(object, "user_id"),
    joined: decoding.bool_or(object, "joined", False),
    muted: decoding.bool_or(object, "muted", False),
    deafened: decoding.bool_or(object, "deafened", False),
    screen_sharing: decoding.bool_or(object, "screen_sharing", False),
    camera: decoding.bool_or(object, "camera", False),
    version: decoding.int_or(object, "version", 0),
  )
}

/// A WebRTC session description: an offer or an answer.
pub type SessionDescription {
  SessionDescription(
    /// "offer", "pranswer", "answer" or "rollback".
    type_: String,
    sdp: String,
  )
}

pub fn session_description_from_json(
  object: decoding.Object,
) -> SessionDescription {
  SessionDescription(
    type_: decoding.string(object, "type"),
    sdp: decoding.string(object, "sdp"),
  )
}

pub fn session_description_to_json(
  description: SessionDescription,
) -> json.Json {
  json.object([
    #("type", json.string(description.type_)),
    #("sdp", json.string(description.sdp)),
  ])
}

/// An ICE candidate, as `RTCIceCandidateInit` (and pion's `ICECandidateInit`)
/// write it.
pub type IceCandidateInit {
  IceCandidateInit(
    /// The `candidate:` attribute line.
    candidate: String,
    sdp_mid: Option(String),
    sdp_m_line_index: Option(Int),
    username_fragment: Option(String),
  )
}

pub fn ice_candidate_init_from_json(
  object: decoding.Object,
) -> IceCandidateInit {
  IceCandidateInit(
    candidate: decoding.string_or(object, "candidate", ""),
    sdp_mid: decoding.optional_string(object, "sdpMid"),
    sdp_m_line_index: decoding.optional_int(object, "sdpMLineIndex"),
    username_fragment: decoding.optional_string(object, "usernameFragment"),
  )
}

pub fn ice_candidate_init_to_json(candidate: IceCandidateInit) -> json.Json {
  json.object(
    encoding.present([
      Some(#("candidate", json.string(candidate.candidate))),
      encoding.optional_string("sdpMid", candidate.sdp_mid),
      encoding.optional_int("sdpMLineIndex", candidate.sdp_m_line_index),
      encoding.optional_string("usernameFragment", candidate.username_fragment),
    ]),
  )
}

/// VOICE_JOINED: the gateway's answer to joining a voice room or a call.
pub type VoiceJoinedEvent {
  VoiceJoinedEvent(room_id: String, answer: Option(SessionDescription))
}

pub fn voice_joined_from_json(object: decoding.Object) -> VoiceJoinedEvent {
  VoiceJoinedEvent(
    room_id: decoding.string(object, "room_id"),
    answer: decoding.optional_object(object, "answer")
      |> option_map(session_description_from_json),
  )
}

/// WEBRTC_ICE_CANDIDATE: one of the gateway's ICE candidates.
pub type IceCandidateEvent {
  IceCandidateEvent(room_id: String, candidate: IceCandidateInit)
}

pub fn ice_candidate_from_json(object: decoding.Object) -> IceCandidateEvent {
  IceCandidateEvent(
    room_id: decoding.string(object, "room_id"),
    candidate: candidate_from_raw(field_or_null(object, "candidate")),
  )
}

/// The gateway sends the candidate as a JSON string of its
/// `ICECandidateInit`; an object, or a bare `candidate:` line, is taken too.
fn candidate_from_raw(raw: Dynamic) -> IceCandidateInit {
  case decoding.as_object_or_none(raw) {
    Some(object) -> ice_candidate_init_from_json(object)
    None -> {
      let text = case decoding.as_string_or_none(raw) {
        Some(text) -> text
        None -> ""
      }
      case string.starts_with(string.trim_start(text), "{") {
        True ->
          case
            json.parse(
              from: text,
              using: decode.dict(decode.string, decode.dynamic),
            )
          {
            Ok(object) -> ice_candidate_init_from_json(object)
            Error(_) -> IceCandidateInit(text, None, None, None)
          }
        False -> IceCandidateInit(text, None, None, None)
      }
    }
  }
}

/// WEBRTC_RENEGOTIATE: the gateway's offer for a room's or call's peer
/// connection.
pub type RenegotiateOfferEvent {
  RenegotiateOfferEvent(room_id: String, offer: SessionDescription)
}

pub fn renegotiate_offer_from_json(
  object: decoding.Object,
) -> RenegotiateOfferEvent {
  RenegotiateOfferEvent(
    room_id: decoding.string(object, "room_id"),
    offer: decoding.object(object, "offer")
      |> session_description_from_json,
  )
}

/// WEBRTC_RENEGOTIATE_ANSWER: the gateway's answer to the client's own
/// renegotiation.
pub type RenegotiateAnswerEvent {
  RenegotiateAnswerEvent(room_id: String, answer: Option(SessionDescription))
}

pub fn renegotiate_answer_from_json(
  object: decoding.Object,
) -> RenegotiateAnswerEvent {
  RenegotiateAnswerEvent(
    room_id: decoding.string(object, "room_id"),
    answer: decoding.optional_object(object, "answer")
      |> option_map(session_description_from_json),
  )
}

/// VOICE_SESSION_REPLACED: this session is no longer in a room or call's
/// voice.
pub type VoiceSessionReplacedEvent {
  VoiceSessionReplacedEvent(
    room_id: String,
    /// None when another device of the user's joined it.
    reason: Option(String),
  )
}

pub fn voice_session_replaced_from_json(
  object: decoding.Object,
) -> VoiceSessionReplacedEvent {
  VoiceSessionReplacedEvent(
    room_id: decoding.string(object, "room_id"),
    reason: decoding.optional_string(object, "reason"),
  )
}

/// VOICE_VIDEO_REFUSED: the gateway refused or stopped one of the user's
/// videos.
pub type VoiceVideoRefusedEvent {
  VoiceVideoRefusedEvent(
    room_id: String,
    /// "camera" or "screen".
    kind: String,
    reason: String,
    /// How many cameras the room can have on: with "limit" only.
    limit: Option(Int),
  )
}

pub fn voice_video_refused_from_json(
  object: decoding.Object,
) -> VoiceVideoRefusedEvent {
  VoiceVideoRefusedEvent(
    room_id: decoding.string(object, "room_id"),
    kind: decoding.string(object, "kind"),
    reason: decoding.string(object, "reason"),
    limit: decoding.optional_int(object, "limit"),
  )
}

pub type RoleDeleteEvent {
  RoleDeleteEvent(id: String, space_id: String)
}

pub fn role_delete_from_json(object: decoding.Object) -> RoleDeleteEvent {
  RoleDeleteEvent(
    id: decoding.string(object, "id"),
    space_id: decoding.string(object, "space_id"),
  )
}

pub type MemberRoleEvent {
  MemberRoleEvent(
    member_id: String,
    role_id: String,
    /// None in MEMBER_ROLE_REMOVE, which doesn't carry it.
    space_id: Option(String),
  )
}

pub fn member_role_from_json(object: decoding.Object) -> MemberRoleEvent {
  MemberRoleEvent(
    member_id: decoding.string(object, "member_id"),
    role_id: decoding.string(object, "role_id"),
    space_id: decoding.optional_string(object, "space_id"),
  )
}

/// SPACE_MEMBER_ADD and SPACE_MEMBER_REMOVE: someone joined or left a space.
pub type SpaceMemberEvent {
  SpaceMemberEvent(
    member_id: String,
    space_id: String,
    /// Who joined or left: both events carry it.
    user_id: Option(String),
    /// SPACE_MEMBER_ADD's: the new member's status.
    status_id: Option(UserStatus),
    /// SPACE_MEMBER_ADD's: the platforms the new member is connected on.
    client_status: Option(ClientStatus),
    /// SPACE_MEMBER_ADD's: the new member's user, when the API has it.
    user: Option(user.GatewayUser),
  )
}

pub fn space_member_from_json(object: decoding.Object) -> SpaceMemberEvent {
  SpaceMemberEvent(
    member_id: decoding.string(object, "member_id"),
    space_id: decoding.string(object, "space_id"),
    user_id: decoding.optional_string(object, "user_id"),
    status_id: decoding.optional_int(object, "status_id")
      |> option_map(user_status.from_int),
    client_status: client_status.from_field(object, "client_status"),
    user: decoding.optional_object(object, "user")
      |> option_map(user.from_json),
  )
}

pub type GuildMemberAddEvent {
  GuildMemberAddEvent(
    space_id: String,
    user_id: String,
    member_id: String,
    user: Option(user.GatewayUser),
  )
}

pub fn guild_member_add_from_json(
  object: decoding.Object,
) -> GuildMemberAddEvent {
  GuildMemberAddEvent(
    space_id: decoding.string(object, "space_id"),
    user_id: decoding.string(object, "user_id"),
    member_id: decoding.string(object, "member_id"),
    user: decoding.optional_object(object, "user")
      |> option_map(user.from_json),
  )
}

pub type GuildMemberRemoveEvent {
  GuildMemberRemoveEvent(space_id: String, user_id: String, member_id: String)
}

pub fn guild_member_remove_from_json(
  object: decoding.Object,
) -> GuildMemberRemoveEvent {
  GuildMemberRemoveEvent(
    space_id: decoding.string(object, "space_id"),
    user_id: decoding.string(object, "user_id"),
    member_id: decoding.string(object, "member_id"),
  )
}

pub type SpaceAssetDeleteEvent {
  SpaceAssetDeleteEvent(id: String, space_id: String)
}

pub fn space_asset_delete_from_json(
  object: decoding.Object,
) -> SpaceAssetDeleteEvent {
  SpaceAssetDeleteEvent(
    id: decoding.string(object, "id"),
    space_id: decoding.string(object, "space_id"),
  )
}

pub type ReactionEvent {
  ReactionEvent(
    message_id: String,
    user_id: String,
    emoji_name: String,
    emoji_id: Option(String),
  )
}

pub fn reaction_from_json(object: decoding.Object) -> ReactionEvent {
  ReactionEvent(
    message_id: decoding.string(object, "message_id"),
    user_id: decoding.string(object, "user_id"),
    emoji_name: decoding.string(object, "emoji_name"),
    emoji_id: decoding.optional_string(object, "emoji_id"),
  )
}

pub type ReactionRemoveEvent {
  ReactionRemoveEvent(message_id: String, user_id: String, emoji_name: String)
}

pub fn reaction_remove_from_json(
  object: decoding.Object,
) -> ReactionRemoveEvent {
  ReactionRemoveEvent(
    message_id: decoding.string(object, "message_id"),
    user_id: decoding.string(object, "user_id"),
    emoji_name: decoding.string(object, "emoji_name"),
  )
}

pub type TypingEvent {
  TypingEvent(
    user_id: String,
    username: String,
    alias: Option(String),
    avatar: Option(String),
    room_id: String,
  )
}

pub fn typing_from_json(object: decoding.Object) -> TypingEvent {
  TypingEvent(
    user_id: decoding.string(object, "user_id"),
    username: decoding.string(object, "username"),
    alias: decoding.optional_string(object, "alias"),
    avatar: decoding.optional_string(object, "avatar"),
    room_id: decoding.string(object, "room_id"),
  )
}

pub type DMTypingEvent {
  DMTypingEvent(
    conversation_id: String,
    user_id: String,
    username: String,
    alias: Option(String),
    avatar: Option(String),
  )
}

pub fn dm_typing_from_json(object: decoding.Object) -> DMTypingEvent {
  DMTypingEvent(
    conversation_id: decoding.string(object, "conversation_id"),
    user_id: decoding.string(object, "user_id"),
    username: decoding.string(object, "username"),
    alias: decoding.optional_string(object, "alias"),
    avatar: decoding.optional_string(object, "avatar"),
  )
}

pub type CallIncomingEvent {
  CallIncomingEvent(
    conversation_id: String,
    initiator_id: String,
    initiator_name: String,
    initiator_avatar: Option(String),
  )
}

pub fn call_incoming_from_json(object: decoding.Object) -> CallIncomingEvent {
  CallIncomingEvent(
    conversation_id: decoding.string(object, "conversation_id"),
    initiator_id: decoding.string(object, "initiator_id"),
    initiator_name: decoding.string(object, "initiator_name"),
    initiator_avatar: decoding.optional_string(object, "initiator_avatar"),
  )
}

pub type CallResponseEvent {
  CallResponseEvent(conversation_id: String, user_id: String)
}

pub fn call_response_from_json(object: decoding.Object) -> CallResponseEvent {
  CallResponseEvent(
    conversation_id: decoding.string(object, "conversation_id"),
    user_id: decoding.string(object, "user_id"),
  )
}

pub type CallEndedEvent {
  CallEndedEvent(conversation_id: String)
}

pub fn call_ended_from_json(object: decoding.Object) -> CallEndedEvent {
  CallEndedEvent(conversation_id: decoding.string(object, "conversation_id"))
}

/// CALL_OUTGOING: a call the user started, sent to each of their sessions.
pub type CallOutgoingEvent {
  CallOutgoingEvent(conversation_id: String)
}

pub fn call_outgoing_from_json(object: decoding.Object) -> CallOutgoingEvent {
  CallOutgoingEvent(conversation_id: decoding.string(object, "conversation_id"))
}

/// CALL_ONGOING: a call goes on in one of the user's conversations without
/// ringing them.
pub type CallOngoingEvent {
  CallOngoingEvent(
    conversation_id: String,
    initiator_id: String,
    /// Who is in the call's voice: None while nobody is.
    voice_states: Option(List(ready.CallVoiceState)),
  )
}

pub fn call_ongoing_from_json(object: decoding.Object) -> CallOngoingEvent {
  CallOngoingEvent(
    conversation_id: decoding.string(object, "conversation_id"),
    initiator_id: decoding.string(object, "initiator_id"),
    voice_states: decoding.optional_objects(
      object,
      "voice_states",
      ready.call_voice_state_from_json,
    ),
  )
}

/// FRIEND_REQUEST_REJECT: the request, rejected by its recipient or cancelled
/// by its sender.
pub type FriendRequestRejectEvent {
  FriendRequestRejectEvent(id: String)
}

pub fn friend_request_reject_from_json(
  object: decoding.Object,
) -> FriendRequestRejectEvent {
  FriendRequestRejectEvent(id: decoding.string(object, "id"))
}

pub type FriendRemoveEvent {
  FriendRemoveEvent(user_id: String)
}

pub fn friend_remove_from_json(object: decoding.Object) -> FriendRemoveEvent {
  FriendRemoveEvent(user_id: decoding.string(object, "user_id"))
}

/// CONVERSATION_UPDATE: a group's name and owner as they are now.
pub type ConversationUpdateEvent {
  ConversationUpdateEvent(
    id: String,
    name: Option(String),
    /// The member who took over, when a group's owner left. None from an API
    /// before it.
    owner_id: Option(String),
  )
}

pub fn conversation_update_from_json(
  object: decoding.Object,
) -> ConversationUpdateEvent {
  ConversationUpdateEvent(
    id: decoding.string(object, "id"),
    name: decoding.optional_string(object, "name"),
    owner_id: decoding.optional_string(object, "owner_id"),
  )
}

pub type ConversationDeleteEvent {
  ConversationDeleteEvent(id: String)
}

pub fn conversation_delete_from_json(
  object: decoding.Object,
) -> ConversationDeleteEvent {
  ConversationDeleteEvent(id: decoding.string(object, "id"))
}

pub type ConversationMemberAddEvent {
  ConversationMemberAddEvent(
    conversation_id: String,
    user_id: String,
    member_id: String,
    username: Option(String),
    alias: Option(String),
    avatar: Option(String),
    banner: Option(String),
    status_id: Option(UserStatus),
    user: Option(user.GatewayUser),
    client_status: Option(ClientStatus),
  )
}

pub fn conversation_member_add_from_json(
  object: decoding.Object,
) -> ConversationMemberAddEvent {
  ConversationMemberAddEvent(
    conversation_id: decoding.string(object, "conversation_id"),
    user_id: decoding.string(object, "user_id"),
    member_id: decoding.string(object, "member_id"),
    username: decoding.optional_string(object, "username"),
    alias: decoding.optional_string(object, "alias"),
    avatar: decoding.optional_string(object, "avatar"),
    banner: decoding.optional_string(object, "banner"),
    status_id: decoding.optional_int(object, "status_id")
      |> option_map(user_status.from_int),
    user: decoding.optional_object(object, "user")
      |> option_map(user.from_json),
    client_status: client_status.from_field(object, "client_status"),
  )
}

pub type ConversationMemberRemoveEvent {
  ConversationMemberRemoveEvent(conversation_id: String, user_id: String)
}

pub fn conversation_member_remove_from_json(
  object: decoding.Object,
) -> ConversationMemberRemoveEvent {
  ConversationMemberRemoveEvent(
    conversation_id: decoding.string(object, "conversation_id"),
    user_id: decoding.string(object, "user_id"),
  )
}

pub type DMMessageDeleteEvent {
  DMMessageDeleteEvent(id: String, conversation_id: String)
}

pub fn dm_message_delete_from_json(
  object: decoding.Object,
) -> DMMessageDeleteEvent {
  DMMessageDeleteEvent(
    id: decoding.string(object, "id"),
    conversation_id: decoding.string(object, "conversation_id"),
  )
}

fn option_map(value: Option(a), with: fn(a) -> b) -> Option(b) {
  case value {
    Some(inner) -> Some(with(inner))
    None -> None
  }
}

fn field_or_null(object: decoding.Object, key: String) -> Dynamic {
  case decoding.field(object, key) {
    Some(value) -> value
    None -> dynamic.nil()
  }
}
