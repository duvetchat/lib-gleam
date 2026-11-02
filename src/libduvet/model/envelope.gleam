import gleam/option.{type Option, None, Some}
import gleam/string
import libduvet/model/conversation
import libduvet/model/decoding
import libduvet/model/event
import libduvet/model/message
import libduvet/model/ready
import libduvet/model/rest
import libduvet/model/space

/// The payload of a gateway event: one variant per event type, and
/// [UnknownEvent] for one this package doesn't parse.
pub type GatewayEventPayload {
  ReadyEvent(data: ready.GatewayReadyData)
  SpaceCreateEvent(data: event.GatewaySpaceCreatePayload)
  SpaceUpdateEvent(data: space.GatewaySpace)
  SpaceDeletedEvent(data: event.SpaceDeleteEvent)
  RoomCreateEvent(data: space.GatewayRoom)
  RoomUpdateEvent(data: space.GatewayRoom)
  RoomDeletedEvent(data: event.RoomDeleteEvent)
  RoomReorderedEvent(data: event.RoomReorderEvent)
  RoomOverwriteUpdateEvent(data: space.GatewayRoomOverwrite)
  RoomOverwriteDeletedEvent(data: event.OverwriteDeleteEvent)
  MessageCreateEvent(data: message.GatewayMessage)
  MessageUpdateEvent(data: message.GatewayMessage)
  MessageDeletedEvent(data: event.GatewayMessageDelete)
  MessagePinUpdatedEvent(data: event.MessagePinUpdateEvent)
  MentionCreatedEvent(data: event.MentionCreateEvent)
  DMMentionCreatedEvent(data: event.DMMentionCreateEvent)
  UserUpdatedEvent(data: event.UserUpdateEvent)
  UserStatusUpdatedEvent(data: event.GatewayUserStatusUpdate)
  UserActivityUpdatedEvent(data: event.UserActivityUpdateEvent)
  VoiceStateUpdatedEvent(data: event.VoiceStateEvent)
  VoiceJoinedPayloadEvent(data: event.VoiceJoinedEvent)
  VoiceSessionReplacedPayloadEvent(data: event.VoiceSessionReplacedEvent)
  VoiceVideoRefusedPayloadEvent(data: event.VoiceVideoRefusedEvent)
  WebRTCIceCandidateEvent(data: event.IceCandidateEvent)
  WebRTCRenegotiateEvent(data: event.RenegotiateOfferEvent)
  WebRTCRenegotiateAnswerEvent(data: event.RenegotiateAnswerEvent)
  RoleCreatedEvent(data: space.GatewayRole)
  RoleUpdatedEvent(data: space.GatewayRole)
  RoleDeletedEvent(data: event.RoleDeleteEvent)
  MemberRoleAddedEvent(data: event.MemberRoleEvent)
  MemberRoleRemovedEvent(data: event.MemberRoleEvent)
  SpaceMemberAddedEvent(data: event.SpaceMemberEvent)
  SpaceMemberRemovedEvent(data: event.SpaceMemberEvent)
  GuildMemberAddedEvent(data: event.GuildMemberAddEvent)
  GuildMemberRemovedEvent(data: event.GuildMemberRemoveEvent)
  SpaceEmojiCreatedEvent(data: space.SpaceEmoji)
  SpaceEmojiUpdatedEvent(data: space.SpaceEmoji)
  SpaceEmojiDeletedEvent(data: event.SpaceAssetDeleteEvent)
  SpaceStickerCreatedEvent(data: space.SpaceSticker)
  SpaceStickerUpdatedEvent(data: space.SpaceSticker)
  SpaceStickerDeletedEvent(data: event.SpaceAssetDeleteEvent)
  ReactionAddedEvent(data: event.ReactionEvent)
  ReactionRemovedEvent(data: event.ReactionRemoveEvent)
  FriendRequestCreatedEvent(data: conversation.FriendRequestCreateEvent)
  FriendRequestAcceptedEvent(data: conversation.FriendRequestAcceptEvent)
  FriendRequestRejectedEvent(data: event.FriendRequestRejectEvent)
  FriendRemovedEvent(data: event.FriendRemoveEvent)
  ConversationCreatedEvent(data: conversation.Conversation)
  ConversationUpdatedEvent(data: event.ConversationUpdateEvent)
  ConversationDeletedEvent(data: event.ConversationDeleteEvent)
  ConversationMemberAddedEvent(data: event.ConversationMemberAddEvent)
  ConversationMemberRemovedEvent(data: event.ConversationMemberRemoveEvent)
  DMMessageCreatedEvent(data: conversation.DirectMessage)
  DMMessageUpdatedEvent(data: conversation.DirectMessage)
  DMMessageDeletedEvent(data: event.DMMessageDeleteEvent)
  DMReactionAddedEvent(data: event.ReactionEvent)
  DMReactionRemovedEvent(data: event.ReactionRemoveEvent)
  TypingStartedEvent(data: event.TypingEvent)
  DMTypingStartedEvent(data: event.DMTypingEvent)
  CallIncomingPayloadEvent(data: event.CallIncomingEvent)
  CallAcceptedEvent(data: event.CallResponseEvent)
  CallDeclinedEvent(data: event.CallResponseEvent)
  CallEndedPayloadEvent(data: event.CallEndedEvent)
  CallOutgoingPayloadEvent(data: event.CallOutgoingEvent)
  CallOngoingPayloadEvent(data: event.CallOngoingEvent)
  DMMessagePinUpdatedEvent(data: event.DMMessagePinUpdateEvent)
  /// RECORDING: someone is recording a voice message in a room.
  RecordingStartedEvent(data: event.TypingEvent)
  /// DM_RECORDING: [RecordingStartedEvent] for a conversation.
  DMRecordingStartedEvent(data: event.DMTypingEvent)
  TeamInviteCreatedEvent(data: rest.TeamInvite)
  StorageTransferUpdatedEvent(data: rest.StorageTransfer)
  /// An event this package doesn't parse: its type and data as they came.
  UnknownEvent(type_: String, raw_data: Option(decoding.Object))
}

/// A frame of the gateway's.
pub type GatewayEnvelope {
  GatewayEnvelope(
    op: Int,
    d: Option(GatewayEventPayload),
    s: Int,
    event: String,
  )
}

pub fn from_json(object: decoding.Object) -> GatewayEnvelope {
  let data = case decoding.optional_object(object, "d") {
    Some(d) -> d
    None -> decoding.empty_object()
  }
  GatewayEnvelope(
    op: decoding.int_or(object, "op", 0),
    s: decoding.int_or(object, "s", 0),
    event: decoding.string_or(object, "event", ""),
    d: parse_payload(
      decoding.optional_string(data, "type"),
      decoding.optional_object(data, "data"),
    ),
  )
}

fn parse_payload(
  type_: Option(String),
  data: Option(decoding.Object),
) -> Option(GatewayEventPayload) {
  case type_ {
    None -> None
    Some(type_) ->
      case string.is_empty(type_) {
        True -> None
        False -> {
          let data = case data {
            Some(data) -> data
            None -> decoding.empty_object()
          }
          Some(parse_event(string.uppercase(type_), data))
        }
      }
  }
}

fn parse_event(type_: String, data: decoding.Object) -> GatewayEventPayload {
  case type_ {
    "READY" -> ReadyEvent(ready.ready_data_from_json(data))
    "SPACE_CREATE" ->
      SpaceCreateEvent(event.space_create_payload_from_json(data))
    "SPACE_UPDATE" -> SpaceUpdateEvent(space.space_from_json(data))
    "SPACE_DELETE" -> SpaceDeletedEvent(event.space_delete_from_json(data))
    "ROOM_CREATE" -> RoomCreateEvent(space.room_from_json(data))
    "ROOM_UPDATE" -> RoomUpdateEvent(space.room_from_json(data))
    "ROOM_DELETE" -> RoomDeletedEvent(event.room_delete_from_json(data))
    "ROOM_REORDER" -> RoomReorderedEvent(event.room_reorder_from_json(data))
    "ROOM_OVERWRITE_UPDATE" ->
      RoomOverwriteUpdateEvent(space.room_overwrite_from_json(data))
    "ROOM_OVERWRITE_DELETE" ->
      RoomOverwriteDeletedEvent(event.overwrite_delete_from_json(data))
    "MESSAGE_CREATE" -> MessageCreateEvent(message.from_json(data))
    "MESSAGE_UPDATE" -> MessageUpdateEvent(message.from_json(data))
    "MESSAGE_DELETE" ->
      MessageDeletedEvent(event.message_delete_from_json(data))
    "MESSAGE_PIN_UPDATE" ->
      MessagePinUpdatedEvent(event.message_pin_update_from_json(data))
    "MENTION_CREATE" ->
      MentionCreatedEvent(event.mention_create_from_json(data))
    "DM_MENTION_CREATE" ->
      DMMentionCreatedEvent(event.dm_mention_create_from_json(data))
    "USER_UPDATE" -> UserUpdatedEvent(event.user_update_from_json(data))
    "USER_STATUS_UPDATE" ->
      UserStatusUpdatedEvent(event.user_status_update_from_json(data))
    "USER_ACTIVITY_UPDATE" ->
      UserActivityUpdatedEvent(event.user_activity_update_from_json(data))
    "VOICE_STATE_UPDATE" ->
      VoiceStateUpdatedEvent(event.voice_state_update_from_json(data))
    "VOICE_JOINED" ->
      VoiceJoinedPayloadEvent(event.voice_joined_from_json(data))
    "VOICE_SESSION_REPLACED" ->
      VoiceSessionReplacedPayloadEvent(event.voice_session_replaced_from_json(
        data,
      ))
    "VOICE_VIDEO_REFUSED" ->
      VoiceVideoRefusedPayloadEvent(event.voice_video_refused_from_json(data))
    "WEBRTC_ICE_CANDIDATE" ->
      WebRTCIceCandidateEvent(event.ice_candidate_from_json(data))
    "WEBRTC_RENEGOTIATE" ->
      WebRTCRenegotiateEvent(event.renegotiate_offer_from_json(data))
    "WEBRTC_RENEGOTIATE_ANSWER" ->
      WebRTCRenegotiateAnswerEvent(event.renegotiate_answer_from_json(data))
    "ROLE_CREATE" -> RoleCreatedEvent(space.role_from_json(data))
    "ROLE_UPDATE" -> RoleUpdatedEvent(space.role_from_json(data))
    "ROLE_DELETE" -> RoleDeletedEvent(event.role_delete_from_json(data))
    "MEMBER_ROLE_ADD" -> MemberRoleAddedEvent(event.member_role_from_json(data))
    "MEMBER_ROLE_REMOVE" ->
      MemberRoleRemovedEvent(event.member_role_from_json(data))
    "SPACE_MEMBER_ADD" ->
      SpaceMemberAddedEvent(event.space_member_from_json(data))
    "SPACE_MEMBER_REMOVE" ->
      SpaceMemberRemovedEvent(event.space_member_from_json(data))
    "GUILD_MEMBER_ADD" ->
      GuildMemberAddedEvent(event.guild_member_add_from_json(data))
    "GUILD_MEMBER_REMOVE" ->
      GuildMemberRemovedEvent(event.guild_member_remove_from_json(data))
    "SPACE_EMOJI_CREATE" ->
      SpaceEmojiCreatedEvent(space.space_emoji_from_json(data))
    "SPACE_EMOJI_UPDATE" ->
      SpaceEmojiUpdatedEvent(space.space_emoji_from_json(data))
    "SPACE_EMOJI_DELETE" ->
      SpaceEmojiDeletedEvent(event.space_asset_delete_from_json(data))
    "SPACE_STICKER_CREATE" ->
      SpaceStickerCreatedEvent(space.space_sticker_from_json(data))
    "SPACE_STICKER_UPDATE" ->
      SpaceStickerUpdatedEvent(space.space_sticker_from_json(data))
    "SPACE_STICKER_DELETE" ->
      SpaceStickerDeletedEvent(event.space_asset_delete_from_json(data))
    "REACTION_ADD" -> ReactionAddedEvent(event.reaction_from_json(data))
    "REACTION_REMOVE" ->
      ReactionRemovedEvent(event.reaction_remove_from_json(data))
    "FRIEND_REQUEST_CREATE" ->
      FriendRequestCreatedEvent(
        conversation.friend_request_create_event_from_json(data),
      )
    "FRIEND_REQUEST_ACCEPT" ->
      FriendRequestAcceptedEvent(
        conversation.friend_request_accept_event_from_json(data),
      )
    "FRIEND_REQUEST_REJECT" ->
      FriendRequestRejectedEvent(event.friend_request_reject_from_json(data))
    "FRIEND_REMOVE" -> FriendRemovedEvent(event.friend_remove_from_json(data))
    "CONVERSATION_CREATE" ->
      ConversationCreatedEvent(conversation.conversation_from_json(data))
    "CONVERSATION_UPDATE" ->
      ConversationUpdatedEvent(event.conversation_update_from_json(data))
    "CONVERSATION_DELETE" ->
      ConversationDeletedEvent(event.conversation_delete_from_json(data))
    "CONVERSATION_MEMBER_ADD" ->
      ConversationMemberAddedEvent(event.conversation_member_add_from_json(data))
    "CONVERSATION_MEMBER_REMOVE" ->
      ConversationMemberRemovedEvent(event.conversation_member_remove_from_json(
        data,
      ))
    "DM_MESSAGE_CREATE" ->
      DMMessageCreatedEvent(conversation.direct_message_from_json(data))
    "DM_MESSAGE_UPDATE" ->
      DMMessageUpdatedEvent(conversation.direct_message_from_json(data))
    "DM_MESSAGE_DELETE" ->
      DMMessageDeletedEvent(event.dm_message_delete_from_json(data))
    "DM_MESSAGE_PIN_UPDATE" ->
      DMMessagePinUpdatedEvent(event.dm_message_pin_update_from_json(data))
    "DM_REACTION_ADD" -> DMReactionAddedEvent(event.reaction_from_json(data))
    "DM_REACTION_REMOVE" ->
      DMReactionRemovedEvent(event.reaction_remove_from_json(data))
    "TYPING" -> TypingStartedEvent(event.typing_from_json(data))
    "DM_TYPING" -> DMTypingStartedEvent(event.dm_typing_from_json(data))
    "RECORDING" -> RecordingStartedEvent(event.typing_from_json(data))
    "DM_RECORDING" -> DMRecordingStartedEvent(event.dm_typing_from_json(data))
    "CALL_INCOMING" ->
      CallIncomingPayloadEvent(event.call_incoming_from_json(data))
    "CALL_OUTGOING" ->
      CallOutgoingPayloadEvent(event.call_outgoing_from_json(data))
    "CALL_ONGOING" ->
      CallOngoingPayloadEvent(event.call_ongoing_from_json(data))
    "CALL_ACCEPTED" -> CallAcceptedEvent(event.call_response_from_json(data))
    "CALL_DECLINED" -> CallDeclinedEvent(event.call_response_from_json(data))
    "CALL_ENDED" -> CallEndedPayloadEvent(event.call_ended_from_json(data))
    "TEAM_INVITE_CREATE" ->
      TeamInviteCreatedEvent(rest.team_invite_from_json(data))
    "STORAGE_TRANSFER_UPDATE" ->
      StorageTransferUpdatedEvent(rest.storage_transfer_from_json(data))
    _ -> UnknownEvent(type_, Some(data))
  }
}

/// Why the gateway closes a socket, which it says just before it does
/// (`{"event": "close-with-reason", "code": …, "reason": …}`).
pub type GatewayCloseReason {
  GatewayCloseReason(
    /// A [gateway_close_code] value.
    code: Int,
    reason: String,
    /// The shard whose socket it is: 0 without sharding.
    shard_id: Int,
  )
}

pub fn close_reason_from_json(
  object: decoding.Object,
  shard_id: Int,
) -> GatewayCloseReason {
  GatewayCloseReason(
    code: decoding.int_or(object, "code", 0),
    reason: decoding.string_or(object, "reason", ""),
    shard_id: shard_id,
  )
}
