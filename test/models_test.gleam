import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit
import gleeunit/should
import libduvet/model/activity
import libduvet/model/activity_type
import libduvet/model/attachment
import libduvet/model/client_platform
import libduvet/model/client_status
import libduvet/model/conversation
import libduvet/model/decoding
import libduvet/model/envelope
import libduvet/model/event
import libduvet/model/gateway_close_code
import libduvet/model/message
import libduvet/model/message_flag
import libduvet/model/message_type
import libduvet/model/ready
import libduvet/model/rest
import libduvet/model/space
import libduvet/model/storage_transfer_status
import libduvet/model/user
import libduvet/model/user_status
import support/fixtures

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn parses(
  name: String,
  always: List(String),
  parse: fn(decoding.Object) -> a,
) -> Nil {
  list.each(fixtures.variants(name, always), fn(pair) {
    let _ = parse(pair.1)
    Nil
  })
}

fn parses_checked(
  name: String,
  always: List(String),
  parse: fn(decoding.Object) -> a,
  check: fn(a, String) -> Nil,
) -> Nil {
  list.each(fixtures.variants(name, always), fn(pair) {
    let parsed = parse(pair.1)
    check(parsed, pair.0)
    Nil
  })
}

fn fixture_time() -> timestamp.Timestamp {
  decoding.parse_time("2026-10-22T10:00:00.123456Z", "test")
}

fn dispatch(
  type_: String,
  data: decoding.Object,
) -> envelope.GatewayEventPayload {
  envelope.from_json(
    dict.from_list([
      #("event", dynamic_string("payload")),
      #("op", dynamic_int(1)),
      #(
        "d",
        dynamic_object(
          dict.from_list([
            #("type", dynamic_string(type_)),
            #("data", dynamic_object(data)),
          ]),
        ),
      ),
      #("s", dynamic_int(7)),
    ]),
  )
  |> fn(result: envelope.GatewayEnvelope) {
    let assert Some(payload) = result.d
    payload
  }
}

fn dynamic_string(text: String) -> dynamic.Dynamic {
  dynamic.string(text)
}

fn dynamic_int(value: Int) -> dynamic.Dynamic {
  dynamic.int(value)
}

fn dynamic_object(object: decoding.Object) -> dynamic.Dynamic {
  dynamic.properties(
    dict.to_list(object)
    |> list.map(fn(pair) { #(dynamic.string(pair.0), pair.1) }),
  )
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

pub fn user_me_parses_test() {
  parses_checked("user_me", [], user.user_me_from_json, fn(parsed, variant) {
    should.equal(parsed.created_at, fixture_time())
    case variant {
      "full" -> should.equal(parsed.status, Some(user_status.dnd))
      _ -> should.equal(parsed.status, None)
    }
  })
}

pub fn user_parses_as_gateway_user_and_bot_test() {
  parses("user", [], user.from_json)
  parses("user", [], user.bot_user_from_json)
}

pub fn storage_status_parses_test() {
  parses("storage_status", [], rest.storage_status_from_json)
}

pub fn attachment_parses_test() {
  parses("attachment", [], attachment.from_json)
}

pub fn storage_bucket_parses_test() {
  parses("bucket_list_row", [], rest.storage_bucket_from_json)
  parses("bucket_create_row", [], rest.storage_bucket_from_json)
}

pub fn team_parses_test() {
  parses("team", [], rest.team_from_json)
  parses("team_member", [], rest.team_member_from_json)
  parses("team_invite", [], rest.team_invite_from_json)
  parses("application", [], rest.application_from_json)
}

// ---------------------------------------------------------------------------
// Room messages
// ---------------------------------------------------------------------------

pub fn room_message_parses_test() {
  let room = ["room_id"]
  parses("message_response", room, message.from_json)
  parses("thread_message", room, message.from_json)
  parses("message_create", room, message.from_json)
  parses("message_update", room, message.from_json)
  parses("message_model", room, message.from_json)
}

pub fn embeds_and_components_can_be_null_test() {
  let full = fixtures.load("message_response", "full")
  let parsed =
    message.from_json(fixtures.with_null(
      fixtures.with_null(full, "embeds"),
      "components",
    ))
  should.equal(parsed.embeds, None)
  should.equal(parsed.components, None)
}

pub fn a_webhook_message_has_no_author_test() {
  let full = fixtures.load("message_response", "full")
  let parsed = message.from_json(fixtures.with_null(full, "author_id"))
  should.equal(parsed.author_id, None)
  should.be_true(parsed.webhook_id != None)
}

pub fn the_user_of_a_history_message_has_zero_times_test() {
  let full = fixtures.load("message_response", "full")
  let user_object = decoding.object(full, "user")
  let zeroed =
    dict.merge(
      user_object,
      dict.from_list([
        #("created_at", dynamic.string("0001-01-01T00:00:00Z")),
        #("updated_at", dynamic.string("0001-01-01T00:00:00Z")),
      ]),
    )
  let parsed =
    message.from_json(dict.insert(full, "user", dynamic_object(zeroed)))
  let assert Some(author) = parsed.user
  let #(date, _) = timestamp.to_calendar(author.created_at, duration.seconds(0))
  should.equal(date.year, 1)
}

pub fn omitempty_fields_can_be_missing_test() {
  let full = fixtures.load("message_response", "full")
  let json =
    list.fold(
      [
        "webhook_id",
        "user",
        "referenced_message",
        "interaction_metadata",
        "nonce",
      ],
      full,
      fixtures.without,
    )
  let _ = message.from_json(json)
  Nil
}

pub fn a_referenced_message_can_carry_only_its_ids_test() {
  let full = fixtures.load("message_response", "full")
  let reference =
    dict.from_list([
      #("type", dynamic.int(0)),
      #("message_id", dynamic.string("m")),
      #("room_id", dynamic.string("r")),
      #("space_id", dynamic.nil()),
    ])
  let parsed =
    message.from_json(dict.insert(
      full,
      "referenced_message",
      dynamic_object(reference),
    ))
  let assert Some(referenced) = parsed.referenced_message
  should.equal(referenced.message_id, Some("m"))
  // An API from before mention_author.
  should.equal(referenced.mention_author, False)
}

pub fn a_reply_says_whether_it_mentions_the_author_test() {
  list.each(["message_create", "message_response"], fn(name) {
    let mentions = message.from_json(fixtures.load(name, "full"))
    let assert Some(referenced) = mentions.referenced_message
    should.be_true(referenced.mention_author)
    let silent =
      message.from_json(dict.insert(
        fixtures.load(name, "partial"),
        "room_id",
        dynamic.string("r1"),
      ))
    let assert Some(silent_reference) = silent.referenced_message
    should.be_false(silent_reference.mention_author)
  })
}

pub fn flags_and_interaction_metadata_test() {
  list.each(["message_create", "message_update", "message_response"], fn(name) {
    let parsed = message.from_json(fixtures.load(name, "full"))
    should.equal(parsed.flags, 2)
    let assert Some(metadata) = parsed.interaction_metadata
    should.equal(metadata.type_, 2)
    should.equal(metadata.user.username, "s-string")
    should.equal(metadata.name, Some("s-string"))
    let none =
      message.from_json(dict.insert(
        fixtures.load(name, "nulls"),
        "room_id",
        dynamic.string("r1"),
      ))
    should.equal(none.interaction_metadata, None)
  })
}

pub fn an_ephemeral_message_and_a_deferred_one_loading_test() {
  should.equal(#(message_flag.ephemeral, message_flag.loading), #(64, 128))
  let full = fixtures.load("message_response", "full")
  let parsed =
    message.from_json(dict.insert(
      full,
      "flags",
      dynamic.int(bitwise_or(message_flag.ephemeral, message_flag.loading)),
    ))
  should.be_true(bitwise_and(parsed.flags, message_flag.ephemeral) != 0)
  should.be_true(bitwise_and(parsed.flags, message_flag.loading) != 0)
  should.equal(bitwise_and(parsed.flags, message_flag.is_components_v2), 0)
  let no_flags = message.from_json(fixtures.without(full, "flags"))
  should.equal(no_flags.flags, 0)
}

pub fn message_search_parses_test() {
  list.each(fixtures.variants("message_search", []), fn(pair) {
    let response =
      rest.message_search_response_from_json(pair.1, fn(item) {
        message.from_json(case dict.get(item, "room_id") {
          Ok(value) ->
            case value == dynamic.nil() {
              True -> dict.insert(item, "room_id", dynamic.string("r1"))
              False -> item
            }
          Error(Nil) -> dict.insert(item, "room_id", dynamic.string("r1"))
        })
      })
    should.be_true(response.total_results >= 0)
  })
}

// ---------------------------------------------------------------------------
// Direct messages
// ---------------------------------------------------------------------------

pub fn direct_message_parses_test() {
  let author = ["author_id"]
  parses("message_response", author, conversation.direct_message_from_json)
  parses("dm_message_create", author, conversation.direct_message_from_json)
  parses("dm_message_update", author, conversation.direct_message_from_json)
  // A conversation's thread has a room's thread's shape.
  parses("thread_message", author, conversation.direct_message_from_json)
}

pub fn direct_message_search_parses_test() {
  list.each(fixtures.variants("message_search", []), fn(pair) {
    let _ =
      rest.message_search_response_from_json(pair.1, fn(item) {
        conversation.direct_message_from_json(dict.insert(
          item,
          "author_id",
          dynamic.string("u1"),
        ))
      })
    Nil
  })
}

pub fn a_call_notice_carries_its_call_test() {
  let at = fixture_time()
  list.each(
    ["dm_message_create", "message_response", "thread_message"],
    fn(name) {
      let json = fixtures.load(name, "full")
      let assert Some(call) = conversation.direct_message_from_json(json).call
      should.equal(
        call.participants,
        decoding.string_list(decoding.object(json, "call"), "participants"),
      )
      should.equal(#(call.started_at, call.ended_at), #(at, at))
      // The API leaves it out of every other message.
      let other =
        conversation.direct_message_from_json(dict.insert(
          fixtures.load(name, "nulls"),
          "author_id",
          dynamic.string("u1"),
        ))
      should.equal(other.call, None)
    },
  )
}

pub fn a_call_notice_as_the_api_posts_it_test() {
  let notice = fn(participants: List(String)) {
    dict.from_list([
      #("id", dynamic.string("01a1896a-f55e-7c3e-8f1d-2b4c6d8e0a1b")),
      #("conversation_id", dynamic.string("c1")),
      #("author_id", dynamic.string("u1")),
      #("content", dynamic.nil()),
      #("type", dynamic.int(3)),
      #("created_at", dynamic.string("2026-10-29T20:47:30.702Z")),
      #("updated_at", dynamic.string("2026-10-29T20:47:30.702Z")),
      #("attachments", dynamic.list([])),
      #("reactions", dynamic.list([])),
      #("sticker_attachment_id", dynamic.nil()),
      #("embeds", dynamic.nil()),
      #(
        "call",
        dynamic_object(
          dict.from_list([
            #(
              "participants",
              dynamic.list(list.map(participants, dynamic.string)),
            ),
            #("started_at", dynamic.string("2026-10-29T20:45:00.123456Z")),
            #("ended_at", dynamic.string("2026-10-29T20:47:30.654321Z")),
          ]),
        ),
      ),
    ])
  }
  let talked = conversation.direct_message_from_json(notice(["u1", "u2"]))
  should.equal(talked.type_, message_type.call)
  should.equal(talked.author_id, "u1")
  should.equal(talked.content, None)
  let assert Some(call) = talked.call
  should.equal(call.participants, ["u1", "u2"])
  should.equal(
    call.started_at,
    decoding.parse_time("2026-10-29T20:45:00.123456Z", "test"),
  )
  should.equal(
    call.ended_at,
    decoding.parse_time("2026-10-29T20:47:30.654321Z", "test"),
  )
  should.equal(
    conversation.call_notice_duration(call),
    duration.nanoseconds(150_530_865_000),
  )
  // Its caller alone: nobody else got into the call.
  let alone = conversation.direct_message_from_json(notice(["u1"]))
  let assert Some(alone_call) = alone.call
  should.equal(alone_call.participants, ["u1"])
  // The API always sends the caller, but its type allows null.
  let none = conversation.direct_message_from_json(notice([]))
  let assert Some(none_call) = none.call
  should.equal(none_call.participants, [])
}

// ---------------------------------------------------------------------------
// Spaces
// ---------------------------------------------------------------------------

pub fn space_parses_test() {
  parses("space", [], space.space_from_json)
  parses("room", [], space.room_from_json)
  parses("room_read_state", [], space.room_read_state_from_json)
  parses("role", [], space.role_from_json)
  parses("room_overwrite", [], space.room_overwrite_from_json)
  parses("invite_link", [], rest.invite_link_from_json)
  parses("invite_info", [], rest.invite_info_from_json)
  parses("space_emoji", [], space.space_emoji_from_json)
  parses("space_sticker", [], space.space_sticker_from_json)
  parses("webhook", [], rest.webhook_from_json)
  parses("webhook_create", [], rest.webhook_create_response_from_json)
  parses("space_member", [], rest.space_member_with_user_from_json)
  parses("space_commands", [], rest.space_commands_from_json)
  parses_checked(
    "application_command",
    [],
    rest.application_command_from_json,
    fn(command, variant) {
      should.equal(command.name, "s-string")
      should.equal(list.length(command.options), case variant {
        "full" -> 1
        _ -> 0
      })
    },
  )
  parses_checked(
    "create_space_result",
    [],
    rest.created_space_from_json,
    fn(created, _variant) {
      should.equal(rest.created_space_id(created), created.space.id)
      should.equal(list.length(created.rooms), 2)
    },
  )
}

pub fn a_created_space_needs_only_the_space_and_its_rooms_test() {
  let full = fixtures.load("create_space_result", "full")
  let json =
    dict.from_list(
      list.filter_map(["space", "text_room", "voice_room"], fn(key) {
        case dict.get(full, key) {
          Ok(value) -> Ok(#(key, value))
          Error(Nil) -> Error(Nil)
        }
      }),
    )
  let created = rest.created_space_from_json(json)
  should.equal(list.map(created.rooms, fn(room) { room.id }), [
    decoding.string(decoding.object(full, "text_room"), "id"),
    decoding.string(decoding.object(full, "voice_room"), "id"),
  ])
}

// ---------------------------------------------------------------------------
// Interactions
// ---------------------------------------------------------------------------

pub fn interaction_reply_parses_test() {
  parses_checked(
    "interaction_created",
    [],
    rest.interaction_reply_from_json,
    fn(reply, _variant) {
      should.equal(reply.type_, 2)
      should.be_false(rest.interaction_reply_is_modal(reply))
    },
  )
}

pub fn a_modal_has_its_data_and_application_test() {
  let json =
    dict.insert(
      fixtures.load("interaction_created", "full"),
      "type",
      dynamic.int(9),
    )
  let reply = rest.interaction_reply_from_json(json)
  should.be_true(rest.interaction_reply_is_modal(reply))
  let assert Some(modal) = reply.modal
  should.equal(decoding.string(modal, "custom_id"), "s-string")
  should.be_true(decoding.list(modal, "components", fn(value) { value }) != [])
  should.be_true(reply.application_id != None)
}

pub fn a_modal_without_its_application_is_not_one_to_open_test() {
  let json =
    dict.insert(
      fixtures.load("interaction_created", "partial"),
      "type",
      dynamic.int(9),
    )
  let reply = rest.interaction_reply_from_json(json)
  should.be_true(reply.modal != None)
  should.be_false(rest.interaction_reply_is_modal(reply))
}

// ---------------------------------------------------------------------------
// Conversations and friends
// ---------------------------------------------------------------------------

pub fn conversation_parses_test() {
  parses("conversation", [], conversation.conversation_from_json)
  parses_checked(
    "conversation_member_row",
    [],
    conversation.conversation_member_from_json,
    fn(member, _variant) {
      should.equal(member.status_id, Some(user_status.dnd))
    },
  )
  parses_checked(
    "conversation_member",
    [],
    conversation.conversation_member_from_json,
    fn(member, _variant) { should.equal(member.status_id, None) },
  )
  parses_checked(
    "friend",
    [],
    conversation.friend_from_json,
    fn(friend, _variant) {
      should.equal(friend.status_id, Some(user_status.dnd))
    },
  )
}

pub fn a_friends_status_none_from_an_older_api_test() {
  let json = fixtures.without(fixtures.load("friend", "full"), "status_id")
  should.equal(conversation.friend_from_json(json).status_id, None)
}

pub fn the_other_users_banner_and_none_from_an_older_api_test() {
  let friend = fixtures.load("friend", "full")
  let request = fixtures.load("friend_request_row", "full")
  should.equal(
    conversation.friend_from_json(friend).user_banner,
    decoding.optional_string(friend, "user_banner"),
  )
  should.equal(
    conversation.friend_request_from_json(request).user_banner,
    decoding.optional_string(request, "user_banner"),
  )
  should.equal(
    conversation.friend_from_json(fixtures.load("friend", "nulls")).user_banner,
    None,
  )
  should.equal(
    conversation.friend_request_from_json(fixtures.load(
      "friend_request_row",
      "nulls",
    )).user_banner,
    None,
  )
  should.equal(conversation.friend_from_json(older_friend()).user_banner, None)
  should.equal(
    conversation.friend_request_from_json(older_request()).user_banner,
    None,
  )
}

fn older_friend() -> decoding.Object {
  dict.from_list([
    #("id", dynamic.string("f1")),
    #("request_id", dynamic.string("r1")),
    #("sender_id", dynamic.string("u1")),
    #("recipient_id", dynamic.string("u2")),
    #("user_username", dynamic.string("gaby")),
    #("user_alias", dynamic.nil()),
    #("user_avatar", dynamic.nil()),
    #("status_id", dynamic.int(1)),
  ])
}

fn older_request() -> decoding.Object {
  dict.from_list([
    #("id", dynamic.string("r1")),
    #("sender_id", dynamic.string("u1")),
    #("recipient_id", dynamic.string("u2")),
    #("created_at", dynamic.string("2026-10-22T10:00:00Z")),
    #("updated_at", dynamic.string("2026-10-22T10:00:00Z")),
    #("user_username", dynamic.string("gaby")),
    #("user_alias", dynamic.nil()),
    #("user_avatar", dynamic.nil()),
  ])
}

pub fn the_other_users_public_profile_and_none_from_an_older_api_test() {
  let json = fixtures.load("friend", "full")
  let friend = conversation.friend_from_json(json)
  let assert Some(profile) = friend.user
  should.equal(#(profile.id, profile.custom, profile.flags, profile.badges), #(
    decoding.string(decoding.object(json, "user"), "id"),
    decoding.string(decoding.object(json, "user"), "custom"),
    decoding.int(decoding.object(json, "user"), "flags"),
    decoding.int(decoding.object(json, "user"), "badges"),
  ))
  // It carries no status: the friend's is the list's.
  should.equal(#(friend.status_id, profile.status_id), #(
    Some(user_status.dnd),
    user_status.offline,
  ))
  let request = fixtures.load("friend_request_row", "full")
  let assert Some(requested) =
    conversation.friend_request_from_json(request).user
  let other = decoding.object(request, "user")
  should.equal(#(requested.id, requested.banner), #(
    decoding.string(other, "id"),
    decoding.optional_string(other, "banner"),
  ))
  should.equal(conversation.friend_from_json(older_friend()).user, None)
  should.equal(
    conversation.friend_request_from_json(older_request()).user,
    None,
  )
}

pub fn friend_request_parses_test() {
  parses("friend_request_row", [], conversation.friend_request_from_json)
  parses("friend_request", [], conversation.friend_request_from_json)
}

pub fn a_conversations_members_can_be_null_test() {
  let json =
    fixtures.with_null(fixtures.load("conversation", "full"), "members")
  should.equal(conversation.conversation_from_json(json).members, [])
}

pub fn members_statuses_offline_as_zero_and_none_from_an_older_api_test() {
  let conversation_json =
    conversation.conversation_from_json(fixtures.load("conversation", "full"))
  let assert [member] = conversation_json.members
  should.equal(member.status_id, Some(user_status.dnd))
  let row = fixtures.load("conversation_member_row", "full")
  should.equal(
    conversation.conversation_member_from_json(dict.insert(
      row,
      "status_id",
      dynamic.int(0),
    )).status_id,
    Some(user_status.offline),
  )
  should.equal(
    conversation.conversation_member_from_json(fixtures.without(
      row,
      "status_id",
    )).status_id,
    None,
  )
}

pub fn a_members_and_a_dms_user_the_whole_public_user_test() {
  let member_user =
    conversation.conversation_member_from_json(fixtures.load(
      "conversation_member_row",
      "full",
    )).user
  let dm_user =
    conversation.direct_message_from_json(fixtures.load(
      "dm_message_create",
      "full",
    )).user
  let assert [Some(first), Some(second)] = [member_user, dm_user]
  list.each([first, second], fn(author) {
    should.equal(#(author.custom, author.flags, author.email_verified), #(
      "s-string",
      2,
      Some(True),
    ))
    should.equal(#(author.created_at, author.updated_at, author.deleted_at), #(
      Some(fixture_time()),
      Some(fixture_time()),
      Some(fixture_time()),
    ))
  })
  let alive =
    conversation.conversation_member_from_json(fixtures.load(
      "conversation_member_row",
      "nulls",
    )).user
  let assert Some(alive_user) = alive
  should.equal(#(alive_user.deleted_at, alive_user.email_verified), #(
    None,
    Some(False),
  ))
  // Without them: their defaults.
  let bare =
    conversation.conversation_user_from_json(
      dict.from_list([
        #("id", dynamic.string("u1")),
        #("username", dynamic.string("maya")),
      ]),
    )
  should.equal(#(bare.custom, bare.flags, bare.created_at), #("", 0, None))
}

fn bitwise_or(left: Int, right: Int) -> Int {
  int.bitwise_or(left, right)
}

fn bitwise_and(left: Int, right: Int) -> Int {
  int.bitwise_and(left, right)
}

// ---------------------------------------------------------------------------
// Gateway events
// ---------------------------------------------------------------------------

fn events_table() -> List(#(String, String, List(String))) {
  [
    #("READY", "ready_event", []),
    #("SPACE_CREATE", "space_create_event", []),
    #("SPACE_UPDATE", "space", []),
    #("SPACE_DELETE", "space_delete_event", []),
    #("ROOM_CREATE", "room", []),
    #("ROOM_UPDATE", "room", []),
    #("ROOM_DELETE", "room_delete_event", []),
    #("ROOM_OVERWRITE_UPDATE", "room_overwrite", []),
    #("ROOM_OVERWRITE_DELETE", "room_overwrite_delete_event", []),
    #("MESSAGE_CREATE", "message_create", ["room_id"]),
    #("MESSAGE_UPDATE", "message_update", ["room_id"]),
    #("MESSAGE_DELETE", "message_delete", []),
    #("MENTION_CREATE", "mention_create_event", []),
    #("DM_MENTION_CREATE", "dm_mention_create_event", []),
    #("USER_UPDATE", "user_update_event", []),
    #("USER_STATUS_UPDATE", "user_status_update_event", []),
    #("VOICE_STATE_UPDATE", "voice_state_update_event", []),
    #("VOICE_JOINED", "voice_joined_event", []),
    #("VOICE_SESSION_REPLACED", "voice_session_replaced_event", []),
    #("WEBRTC_ICE_CANDIDATE", "webrtc_ice_candidate_event", []),
    #("WEBRTC_RENEGOTIATE", "webrtc_renegotiate_event", []),
    #("WEBRTC_RENEGOTIATE_ANSWER", "webrtc_renegotiate_answer_event", []),
    #("ROLE_CREATE", "role", []),
    #("ROLE_UPDATE", "role", []),
    #("ROLE_DELETE", "role_delete_event", []),
    #("MEMBER_ROLE_ADD", "member_role_add_event", []),
    #("MEMBER_ROLE_REMOVE", "member_role_remove_event", []),
    #("SPACE_MEMBER_ADD", "space_member_add_event", []),
    #("SPACE_MEMBER_REMOVE", "space_member_remove_event", []),
    #("SPACE_EMOJI_CREATE", "space_emoji", []),
    #("SPACE_EMOJI_UPDATE", "space_emoji", []),
    #("SPACE_EMOJI_DELETE", "space_emoji", []),
    #("SPACE_STICKER_CREATE", "space_sticker", []),
    #("SPACE_STICKER_UPDATE", "space_sticker", []),
    #("SPACE_STICKER_DELETE", "space_sticker", []),
    #("REACTION_ADD", "reaction_add_event", []),
    #("REACTION_REMOVE", "reaction_remove_event", []),
    #("FRIEND_REQUEST_CREATE", "friend_request_create_event", []),
    #("FRIEND_REQUEST_ACCEPT", "friend_request_accept_event", []),
    #("FRIEND_REQUEST_REJECT", "friend_request_reject_event", []),
    #("FRIEND_REMOVE", "friend_remove_event", []),
    #("CONVERSATION_CREATE", "conversation", []),
    #("CONVERSATION_UPDATE", "conversation_update_event", []),
    #("CONVERSATION_MEMBER_ADD", "conversation_member_add_event", []),
    #("CONVERSATION_MEMBER_REMOVE", "conversation_member_remove_event", []),
    #("DM_MESSAGE_CREATE", "dm_message_create", ["author_id"]),
    #("DM_MESSAGE_UPDATE", "dm_message_update", ["author_id"]),
    #("DM_MESSAGE_DELETE", "dm_message_delete_event", []),
    #("DM_REACTION_ADD", "dm_reaction_add_event", []),
    #("DM_REACTION_REMOVE", "dm_reaction_remove_event", []),
    #("TYPING", "typing_event", []),
    #("DM_TYPING", "dm_typing_event", []),
    #("CALL_INCOMING", "call_incoming_event", []),
    #("CALL_OUTGOING", "call_outgoing_event", []),
    #("CALL_ONGOING", "call_ongoing_event", []),
    #("CALL_ACCEPTED", "call_member_event", []),
    #("CALL_DECLINED", "call_member_event", []),
    #("CALL_ENDED", "call_ended_event", []),
    #("MESSAGE_PIN_UPDATE", "message_pin_update_event", []),
    #("DM_MESSAGE_PIN_UPDATE", "dm_message_pin_update_event", []),
    // The API's Recording and DMRecording are Typing and DMTyping.
    #("RECORDING", "typing_event", []),
    #("DM_RECORDING", "dm_typing_event", []),
    #("ROOM_REORDER", "room_reorder_event", []),
    #("USER_ACTIVITY_UPDATE", "user_activity_update_event", []),
    #("TEAM_INVITE_CREATE", "team_invite_create_event", []),
    #("VOICE_VIDEO_REFUSED", "voice_video_refused_event", []),
    #("STORAGE_TRANSFER_UPDATE", "storage_transfer_update_event", []),
  ]
}

/// Handled by the client, but neither the API nor the gateway sends them.
fn unpublished_events() -> List(String) {
  ["CONVERSATION_DELETE", "GUILD_MEMBER_ADD", "GUILD_MEMBER_REMOVE"]
}

fn is_known(payload: envelope.GatewayEventPayload) -> Bool {
  case payload {
    envelope.UnknownEvent(_, _) -> False
    _ -> True
  }
}

pub fn every_event_the_client_handles_has_a_fixture_test() {
  let handled = handled_event_names()
  let tested = list.map(events_table(), fn(row) { row.0 })
  let missing =
    handled
    |> list.filter(fn(type_) {
      !list.contains(unpublished_events(), type_)
      && !list.contains(tested, type_)
    })
  should.equal(missing, [])
}

fn handled_event_names() -> List(String) {
  fixtures.read_text("src/libduvet/model/envelope.gleam")
  |> string.split("\"")
  |> list.index_map(fn(part, index) { #(index, part) })
  |> list.filter(fn(pair) { pair.0 % 2 == 1 })
  |> list.map(fn(pair) { pair.1 })
  |> list.filter(fn(part) { is_event_name(part) })
  |> list.unique
}

fn is_event_name(text: String) -> Bool {
  let letters = string.to_graphemes(text)
  list.length(letters) >= 2
  && list.all(letters, fn(letter) {
    case letter {
      "A"
      | "B"
      | "C"
      | "D"
      | "E"
      | "F"
      | "G"
      | "H"
      | "I"
      | "J"
      | "K"
      | "L"
      | "M"
      | "N"
      | "O"
      | "P"
      | "Q"
      | "R"
      | "S"
      | "T"
      | "U"
      | "V"
      | "W"
      | "X"
      | "Y"
      | "Z"
      | "_" -> True
      _ -> False
    }
  })
  && list.any(letters, fn(letter) { letter != "_" })
}

pub fn every_event_of_the_table_parses_test() {
  list.each(events_table(), fn(row) {
    let #(type_, name, always) = row
    list.each(fixtures.variants(name, always), fn(pair) {
      let payload = dispatch(type_, pair.1)
      should.be_true(is_known(payload))
    })
  })
}

pub fn the_events_added_after_1_0_1_are_their_own_test() {
  let added = [
    #("MESSAGE_PIN_UPDATE", "message_pin_update_event"),
    #("DM_MESSAGE_PIN_UPDATE", "dm_message_pin_update_event"),
    #("RECORDING", "typing_event"),
    #("DM_RECORDING", "dm_typing_event"),
    #("ROOM_REORDER", "room_reorder_event"),
    #("USER_ACTIVITY_UPDATE", "user_activity_update_event"),
    #("TEAM_INVITE_CREATE", "team_invite_create_event"),
    #("VOICE_VIDEO_REFUSED", "voice_video_refused_event"),
    #("STORAGE_TRANSFER_UPDATE", "storage_transfer_update_event"),
    #("CALL_OUTGOING", "call_outgoing_event"),
    #("CALL_ONGOING", "call_ongoing_event"),
  ]
  list.each(added, fn(row) {
    let #(type_, name) = row
    let payload = dispatch(type_, fixtures.load(name, "full"))
    should.be_true(is_known(payload))
  })
}

pub fn message_pin_update_carries_the_message_and_when_test() {
  let json = fixtures.load("message_pin_update_event", "full")
  let payload = dispatch("MESSAGE_PIN_UPDATE", json)
  let assert envelope.MessagePinUpdatedEvent(pinned) = payload
  should.equal(#(pinned.id, pinned.room_id), #(
    decoding.string(json, "id"),
    decoding.string(json, "room_id"),
  ))
  should.equal(pinned.pinned_at, Some(fixture_time()))
  let unpinned =
    dispatch(
      "MESSAGE_PIN_UPDATE",
      fixtures.load("message_pin_update_event", "nulls"),
    )
  let assert envelope.MessagePinUpdatedEvent(silent) = unpinned
  should.equal(silent.pinned_at, None)
}

pub fn dm_message_pin_update_carries_the_message_and_when_test() {
  let json = fixtures.load("dm_message_pin_update_event", "full")
  let payload = dispatch("DM_MESSAGE_PIN_UPDATE", json)
  let assert envelope.DMMessagePinUpdatedEvent(pinned) = payload
  should.equal(#(pinned.id, pinned.conversation_id), #(
    decoding.string(json, "id"),
    decoding.string(json, "conversation_id"),
  ))
  should.be_true(pinned.pinned_at != None)
  let unpinned =
    dispatch(
      "DM_MESSAGE_PIN_UPDATE",
      fixtures.load("dm_message_pin_update_event", "nulls"),
    )
  let assert envelope.DMMessagePinUpdatedEvent(silent) = unpinned
  should.equal(silent.pinned_at, None)
}

pub fn dm_message_create_a_call_notice_with_its_call_test() {
  let json =
    dict.insert(
      fixtures.load("dm_message_create", "full"),
      "type",
      dynamic.int(3),
    )
  let payload = dispatch("DM_MESSAGE_CREATE", json)
  let assert envelope.DMMessageCreatedEvent(message_) = payload
  should.equal(message_.type_, message_type.call)
  let assert Some(call) = message_.call
  should.equal(
    call.participants,
    decoding.string_list(decoding.object(json, "call"), "participants"),
  )
}

pub fn recording_and_dm_recording_are_not_typing_test() {
  let room =
    dispatch(
      "RECORDING",
      dict.from_list([
        #("user_id", dynamic.string("u2")),
        #("username", dynamic.string("maya")),
        #("alias", dynamic.string("Maya")),
        #("avatar", dynamic.nil()),
        #("room_id", dynamic.string("r1")),
      ]),
    )
  let assert envelope.RecordingStartedEvent(recording) = room
  should.equal(
    #(recording.user_id, recording.username, recording.alias, recording.room_id),
    #("u2", "maya", Some("Maya"), "r1"),
  )
  let dm = dispatch("DM_RECORDING", fixtures.load("dm_typing_event", "nulls"))
  let assert envelope.DMRecordingStartedEvent(dm_recording) = dm
  should.equal(#(dm_recording.conversation_id, dm_recording.alias), #(
    "s-string",
    None,
  ))
  let typing = dispatch("TYPING", fixtures.load("typing_event", "full"))
  case typing {
    envelope.RecordingStartedEvent(_) -> should.fail()
    _ -> Nil
  }
}

pub fn room_reorder_carries_every_room_test() {
  let json = fixtures.load("room_reorder_event", "full")
  let payload = dispatch("ROOM_REORDER", json)
  let assert envelope.RoomReorderedEvent(reordered) = payload
  let assert [room] = reordered.rooms
  let sent = case decoding.list(json, "rooms", fn(value) { value }) {
    [first, ..] -> decoding.object_value(first, "room")
    [] -> panic as "no rooms in the reorder"
  }
  should.equal(#(room.id, room.space_id, room.parent_id, room.position), #(
    decoding.string(sent, "id"),
    decoding.optional_string(sent, "space_id"),
    decoding.optional_string(sent, "parent_id"),
    2,
  ))
  let none =
    dispatch("ROOM_REORDER", fixtures.load("room_reorder_event", "nulls"))
  let assert envelope.RoomReorderedEvent(empty) = none
  should.equal(empty.rooms, [])
}

pub fn user_activity_update_carries_the_activities_test() {
  let payload =
    dispatch(
      "USER_ACTIVITY_UPDATE",
      fixtures.load("user_activity_update_event", "full"),
    )
  let assert envelope.UserActivityUpdatedEvent(update) = payload
  should.equal(update.user_id, "s-string")
  let assert [activity_] = update.activities
  should.equal(activity_.type_, activity_type.listening)
  should.equal(#(activity_.name, activity_.details, activity_.state), #(
    "s-string",
    Some("s-string"),
    Some("s-string"),
  ))
  let assert Some(timestamps) = activity_.timestamps
  should.equal(#(timestamps.start, timestamps.end), #(Some(2), Some(2)))
  let assert Some(assets) = activity_.assets
  should.equal(
    #(
      assets.large_image,
      assets.large_text,
      assets.small_image,
      assets.small_text,
    ),
    #(Some("s-string"), Some("s-string"), Some("s-string"), Some("s-string")),
  )

  // Cleared: an empty list, or null.
  let nulls = fixtures.load("user_activity_update_event", "nulls")
  list.each([nulls, fixtures.with_null(nulls, "activities")], fn(json) {
    let payload = dispatch("USER_ACTIVITY_UPDATE", json)
    let assert envelope.UserActivityUpdatedEvent(cleared) = payload
    should.equal(cleared.activities, [])
  })
}

pub fn an_activity_as_the_gateway_leaves_it_test() {
  let parsed =
    activity.from_json(
      dict.from_list([#("name", dynamic.string("Visual Studio Code"))]),
    )
  should.equal(#(parsed.type_, parsed.name), #(
    activity_type.playing,
    "Visual Studio Code",
  ))
  should.equal(
    #(parsed.details, parsed.state, parsed.timestamps, parsed.assets),
    #(None, None, None, None),
  )
}

pub fn team_invite_create_carries_the_invite_test() {
  let json = fixtures.load("team_invite_create_event", "full")
  let payload = dispatch("TEAM_INVITE_CREATE", json)
  let assert envelope.TeamInviteCreatedEvent(invite) = payload
  should.equal(#(invite.id, invite.team_name, invite.invited_by_username), #(
    decoding.string(json, "id"),
    decoding.string(json, "team_name"),
    decoding.string(json, "invited_by_username"),
  ))
  should.equal(invite.created_at, fixture_time())
}

pub fn space_create_member_activities_test() {
  let full =
    dispatch("SPACE_CREATE", fixtures.load("space_create_event", "full"))
  let assert envelope.SpaceCreateEvent(created) = full
  let assert Ok(activities) = dict.get(created.activities, "s-string")
  let assert [activity_] = activities
  should.equal(#(activity_.type_, activity_.name), #(
    activity_type.listening,
    "s-string",
  ))
  let nulls =
    dispatch("SPACE_CREATE", fixtures.load("space_create_event", "nulls"))
  let assert envelope.SpaceCreateEvent(empty) = nulls
  should.equal(empty.activities, dict.new())
}

pub fn space_member_add_carries_who_joined_test() {
  let json = fixtures.load("space_member_add_event", "full")
  let payload = dispatch("SPACE_MEMBER_ADD", json)
  let assert envelope.SpaceMemberAddedEvent(added) = payload
  should.equal(#(added.user_id, added.member_id, added.space_id), #(
    decoding.optional_string(json, "user_id"),
    decoding.string(json, "member_id"),
    decoding.string(json, "space_id"),
  ))
  should.equal(added.status_id, Some(user_status.dnd))
  let assert Some(added_user) = added.user
  should.equal(
    added_user.id,
    decoding.string(decoding.object(json, "user"), "id"),
  )
  // omitempty: the user when the API has it.
  let bare =
    dispatch(
      "SPACE_MEMBER_ADD",
      fixtures.load("space_member_add_event", "nulls"),
    )
  let assert envelope.SpaceMemberAddedEvent(bare_added) = bare
  should.equal(#(bare_added.status_id, bare_added.user), #(
    Some(user_status.dnd),
    None,
  ))

  let removed =
    dispatch(
      "SPACE_MEMBER_REMOVE",
      fixtures.load("space_member_remove_event", "full"),
    )
  let assert envelope.SpaceMemberRemovedEvent(left) = removed
  should.be_true(left.user_id != None)
  should.equal(#(left.status_id, left.user), #(None, None))
}

pub fn user_status_update_a_bots_carries_its_space_test() {
  let json = fixtures.load("user_status_update_event", "full")
  let payload = dispatch("USER_STATUS_UPDATE", json)
  let assert envelope.UserStatusUpdatedEvent(bot) = payload
  should.equal(bot.space_id, decoding.optional_string(json, "space_id"))
  let person =
    dispatch(
      "USER_STATUS_UPDATE",
      fixtures.load("user_status_update_event", "nulls"),
    )
  let assert envelope.UserStatusUpdatedEvent(person_update) = person
  should.equal(#(person_update.space_id, person_update.status_id), #(
    None,
    user_status.dnd,
  ))
}

pub fn ready_active_calls_can_be_null_and_the_token_is_camel_case_test() {
  let payload =
    dispatch(
      "READY",
      fixtures.with_null(fixtures.load("ready_event", "full"), "active_calls"),
    )
  let assert envelope.ReadyEvent(ready_data) = payload
  should.equal(ready_data.active_calls, None)
  should.be_true(!string.is_empty(ready_data.session_token))
}

pub fn ready_says_whether_each_call_rings_and_who_calls_test() {
  let payload = dispatch("READY", fixtures.load("ready_event", "full"))
  let assert envelope.ReadyEvent(ready_data) = payload
  let assert Some(calls) = ready_data.active_calls
  let assert [call] = calls
  should.equal(
    #(call.initiator_name, call.initiator_avatar, call.ringing, call.answered),
    #(Some("s-string"), Some("s-string"), Some(True), Some(True)),
  )

  // A gateway from before them leaves them out.
  let json = fixtures.load("ready_event", "full")
  let assert Ok(call_list) = dict.get(json, "active_calls")
  let assert Ok(raw_calls) = dynamic_list(call_list)
  let assert [first_call] = raw_calls
  let stripped =
    list.fold(
      ["initiator_name", "initiator_avatar", "ringing", "answered"],
      decoding.object_value(first_call, "active call"),
      fixtures.without,
    )
  let older =
    dispatch(
      "READY",
      dict.insert(
        json,
        "active_calls",
        dynamic.list([dynamic_object(stripped)]),
      ),
    )
  let assert envelope.ReadyEvent(older_ready) = older
  let assert Some(older_calls) = older_ready.active_calls
  let assert [old_call] = older_calls
  should.equal(
    #(
      old_call.initiator_name,
      old_call.initiator_avatar,
      old_call.ringing,
      old_call.answered,
    ),
    #(None, None, None, None),
  )
}

fn dynamic_list(value: dynamic.Dynamic) -> Result(List(dynamic.Dynamic), Nil) {
  case decode.run(value, decode.list(decode.dynamic)) {
    Ok(items) -> Ok(items)
    Error(_) -> Error(Nil)
  }
}

pub fn a_bots_ready_test() {
  list.each(fixtures.variants("bot_ready_event", []), fn(pair) {
    let payload = dispatch("READY", pair.1)
    case payload {
      envelope.ReadyEvent(_) -> Nil
      _ -> should.fail()
    }
  })
}

pub fn ready_lists_the_spaces_whose_space_create_follows_test() {
  list.each(["ready_event", "bot_ready_event"], fn(name) {
    let full = dispatch("READY", fixtures.load(name, "full"))
    let assert envelope.ReadyEvent(full_ready) = full
    should.equal(full_ready.guild_ids, ["s-string"])
    let none = dispatch("READY", fixtures.load(name, "nulls"))
    let assert envelope.ReadyEvent(none_ready) = none
    should.equal(none_ready.guild_ids, [])
  })
  let older =
    dispatch(
      "READY",
      fixtures.without(fixtures.load("ready_event", "full"), "guild_ids"),
    )
  let assert envelope.ReadyEvent(older_ready) = older
  should.equal(older_ready.guild_ids, [])
}

pub fn ready_carries_the_status_the_user_chose_test() {
  let payload = dispatch("READY", fixtures.load("ready_event", "full"))
  let assert envelope.ReadyEvent(ready_data) = payload
  should.equal(ready_data.user.status, Some(user_status.dnd))

  let json = fixtures.load("ready_event", "full")
  let user_without_status =
    fixtures.without(decoding.object(json, "user"), "status")
  let older =
    dispatch(
      "READY",
      dict.insert(json, "user", dynamic_object(user_without_status)),
    )
  let assert envelope.ReadyEvent(older_ready) = older
  should.equal(older_ready.user.status, None)
}

pub fn ready_carries_each_conversations_read_position_test() {
  let json = fixtures.load("ready_event", "full")
  let payload = dispatch("READY", json)
  let assert envelope.ReadyEvent(ready_data) = payload
  should.equal(
    ready_data.last_read_convs,
    decoding.optional_string_map(json, "last_read_convs"),
  )
  let read =
    dispatch(
      "READY",
      dict.insert(
        json,
        "last_read_convs",
        dynamic_object(
          dict.from_list([
            #("conversation-1", dynamic.string("message-9")),
          ]),
        ),
      ),
    )
  let assert envelope.ReadyEvent(read_ready) = read
  should.equal(
    read_ready.last_read_convs,
    Some(dict.from_list([#("conversation-1", "message-9")])),
  )
  // None read yet: empty, not null.
  let none = dispatch("READY", fixtures.load("ready_event", "nulls"))
  let assert envelope.ReadyEvent(none_ready) = none
  should.equal(none_ready.last_read_convs, Some(dict.new()))
  // A gateway before it leaves it out.
  let older = dispatch("READY", fixtures.without(json, "last_read_convs"))
  let assert envelope.ReadyEvent(older_ready) = older
  should.equal(older_ready.last_read_convs, None)
  let bot = dispatch("READY", fixtures.load("bot_ready_event", "full"))
  let assert envelope.ReadyEvent(bot_ready) = bot
  should.equal(bot_ready.last_read_convs, None)
}

pub fn user_update_carries_the_bio_test() {
  let json = fixtures.load("user_update_event", "full")
  let payload = dispatch("USER_UPDATE", json)
  let assert envelope.UserUpdatedEvent(update) = payload
  should.equal(update.custom, decoding.optional_string(json, "custom"))
  let older = dispatch("USER_UPDATE", fixtures.without(json, "custom"))
  let assert envelope.UserUpdatedEvent(older_update) = older
  should.equal(older_update.custom, None)
}

pub fn user_update_carries_the_flags_and_badges_test() {
  let json = fixtures.load("user_update_event", "full")
  let payload = dispatch("USER_UPDATE", json)
  let assert envelope.UserUpdatedEvent(update) = payload
  should.equal(#(update.flags, update.badges), #(Some(2), Some(2)))
  let older =
    dispatch(
      "USER_UPDATE",
      fixtures.without(fixtures.without(json, "flags"), "badges"),
    )
  let assert envelope.UserUpdatedEvent(older_update) = older
  should.equal(#(older_update.flags, older_update.badges), #(None, None))
}

pub fn conversation_update_carries_the_name_and_owner_test() {
  let json = fixtures.load("conversation_update_event", "full")
  let payload = dispatch("CONVERSATION_UPDATE", json)
  let assert envelope.ConversationUpdatedEvent(update) = payload
  should.equal(#(update.id, update.name, update.owner_id), #(
    decoding.string(json, "id"),
    decoding.optional_string(json, "name"),
    decoding.optional_string(json, "owner_id"),
  ))
  let older =
    dispatch("CONVERSATION_UPDATE", fixtures.without(json, "owner_id"))
  let assert envelope.ConversationUpdatedEvent(older_update) = older
  should.equal(older_update.owner_id, None)
}

pub fn conversation_create_carries_each_members_status_test() {
  let json = fixtures.load("conversation", "full")
  let payload = dispatch("CONVERSATION_CREATE", json)
  let assert envelope.ConversationCreatedEvent(created) = payload
  let assert [member] = created.members
  should.equal(member.status_id, Some(user_status.dnd))
  let assert Ok(members) = dict.get(json, "members")
  let assert Ok(raw_members) = dynamic_list(members)
  let assert [raw_member] = raw_members
  let older =
    dispatch(
      "CONVERSATION_CREATE",
      dict.insert(
        json,
        "members",
        dynamic.list([
          dynamic_object(fixtures.without(
            decoding.object_value(raw_member, "member"),
            "status_id",
          )),
        ]),
      ),
    )
  let assert envelope.ConversationCreatedEvent(older_created) = older
  let assert [older_member] = older_created.members
  should.equal(older_member.status_id, None)
}

pub fn conversation_member_add_carries_the_added_members_status_test() {
  let json = fixtures.load("conversation_member_add_event", "full")
  let payload = dispatch("CONVERSATION_MEMBER_ADD", json)
  let assert envelope.ConversationMemberAddedEvent(added) = payload
  should.equal(added.status_id, Some(user_status.dnd))
  let offline =
    dispatch(
      "CONVERSATION_MEMBER_ADD",
      dict.insert(json, "status_id", dynamic.int(0)),
    )
  let assert envelope.ConversationMemberAddedEvent(offline_added) = offline
  should.equal(offline_added.status_id, Some(user_status.offline))
  // An API before members' statuses leaves it out while they're offline.
  let older =
    dispatch("CONVERSATION_MEMBER_ADD", fixtures.without(json, "status_id"))
  let assert envelope.ConversationMemberAddedEvent(older_added) = older
  should.equal(older_added.status_id, None)
}

pub fn friend_request_accept_carries_the_new_friends_status_test() {
  let json = fixtures.load("friend_request_accept_event", "full")
  let payload = dispatch("FRIEND_REQUEST_ACCEPT", json)
  let assert envelope.FriendRequestAcceptedEvent(accepted) = payload
  should.equal(accepted.status_id, Some(user_status.dnd))
  let older =
    dispatch("FRIEND_REQUEST_ACCEPT", fixtures.without(json, "status_id"))
  let assert envelope.FriendRequestAcceptedEvent(older_accepted) = older
  should.equal(older_accepted.status_id, None)
}

fn request_created(to_sender: Bool) -> conversation.FriendRequestCreateEvent {
  let json = fixtures.load("friend_request_create_event", "full")
  let user_json =
    dict.from_list([
      #("id", dynamic.string(bool_choice(to_sender, "u2", "u1"))),
      #(
        "username",
        dynamic.string(bool_choice(to_sender, "recipient", "sender")),
      ),
    ])
  let user_object = dict.merge(decoding.object(json, "user"), user_json)
  let payload =
    dispatch(
      "FRIEND_REQUEST_CREATE",
      dict.merge(
        json,
        dict.from_list([
          #("sender_id", dynamic.string("u1")),
          #("recipient_id", dynamic.string("u2")),
          #("username", dynamic.string("sender")),
          #("banner", dynamic.string("sender-banner")),
          #("user", dynamic_object(user_object)),
        ]),
      ),
    )
  let assert envelope.FriendRequestCreatedEvent(created) = payload
  created
}

fn bool_choice(condition: Bool, when_true: a, when_false: a) -> a {
  case condition {
    True -> when_true
    False -> when_false
  }
}

pub fn friend_request_create_to_the_recipient_test() {
  let created = request_created(False)
  should.equal(
    #(created.sender_id, created.recipient_id, created.username, created.banner),
    #("u1", Some("u2"), "sender", Some("sender-banner")),
  )
  let assert Some(sender) = created.user
  should.equal(#(sender.id, sender.username), #("u1", "sender"))
}

pub fn friend_request_create_to_the_senders_sessions_test() {
  let created = request_created(True)
  should.equal(
    #(created.sender_id, created.recipient_id, created.username, created.banner),
    #("u1", Some("u2"), "sender", Some("sender-banner")),
  )
  let assert Some(recipient) = created.user
  should.equal(#(recipient.id, recipient.username), #("u2", "recipient"))
}

pub fn friend_request_create_from_an_older_api_test() {
  let payload =
    dispatch(
      "FRIEND_REQUEST_CREATE",
      dict.from_list([
        #("id", dynamic.string("r1")),
        #("sender_id", dynamic.string("u1")),
        #("username", dynamic.string("gaby")),
        #("alias", dynamic.nil()),
        #("avatar", dynamic.nil()),
      ]),
    )
  let assert envelope.FriendRequestCreatedEvent(created) = payload
  should.equal(
    #(created.sender_id, created.recipient_id, created.banner, created.user),
    #("u1", None, None, None),
  )
}

pub fn storage_transfer_update_carries_the_transfer_test() {
  let at = fixture_time()
  let full_payload =
    dispatch(
      "STORAGE_TRANSFER_UPDATE",
      fixtures.load("storage_transfer_update_event", "full"),
    )
  let assert envelope.StorageTransferUpdatedEvent(full) = full_payload
  should.equal(full.status, storage_transfer_status.done)
  should.equal(#(full.keep_source, full.same_bucket, full.error), #(
    True,
    True,
    Some("s-string"),
  ))
  should.equal(
    #(
      full.total_files,
      full.total_bytes,
      full.moved_files,
      full.moved_bytes,
      full.skipped_files,
      full.failed_files,
    ),
    #(2, 2, 2, 2, 2, 2),
  )
  should.equal(
    #(full.created_at, full.started_at, full.finished_at, full.updated_at),
    #(at, Some(at), Some(at), at),
  )
  should.be_true(full.source_bucket_id != None)
  should.be_true(full.target_bucket_id != None)

  let queued_payload =
    dispatch(
      "STORAGE_TRANSFER_UPDATE",
      fixtures.load("storage_transfer_update_event", "nulls"),
    )
  let assert envelope.StorageTransferUpdatedEvent(queued) = queued_payload
  should.equal(#(queued.source_bucket_id, queued.target_bucket_id), #(
    None,
    None,
  ))
  should.equal(#(queued.error, queued.started_at, queued.finished_at), #(
    None,
    None,
    None,
  ))
  should.equal(
    #(
      storage_transfer_status.queued,
      storage_transfer_status.moving,
      storage_transfer_status.failed,
      storage_transfer_status.cancelled,
    ),
    #(0, 1, 3, 4),
  )
}

pub fn space_create_rooms_and_roles_are_maps_by_id_test() {
  let payload =
    dispatch("SPACE_CREATE", fixtures.load("space_create_event", "full"))
  let assert envelope.SpaceCreateEvent(created) = payload
  should.be_true(!dict.is_empty(created.rooms))
  should.be_true(!dict.is_empty(created.roles_permissions))
}

pub fn space_create_member_statuses_test() {
  let full =
    dispatch("SPACE_CREATE", fixtures.load("space_create_event", "full"))
  let assert envelope.SpaceCreateEvent(created) = full
  should.equal(
    created.member_statuses,
    dict.from_list([#("s-string", user_status.dnd)]),
  )
  let nulls =
    dispatch("SPACE_CREATE", fixtures.load("space_create_event", "nulls"))
  let assert envelope.SpaceCreateEvent(empty) = nulls
  should.equal(empty.member_statuses, dict.new())
}

pub fn space_create_room_read_states_test() {
  let full =
    dispatch("SPACE_CREATE", fixtures.load("space_create_event", "full"))
  let assert envelope.SpaceCreateEvent(created) = full
  let assert Ok(state) =
    dict.get(created.read_states, "12020202-0202-7002-8002-020202020202")
  should.equal(#(state.unread, state.last_read, state.last_msg), #(
    True,
    Some("10020202-0202-7002-8002-020202020202"),
    Some("11020202-0202-7002-8002-020202020202"),
  ))
  let nulls =
    dispatch("SPACE_CREATE", fixtures.load("space_create_event", "nulls"))
  let assert envelope.SpaceCreateEvent(empty) = nulls
  should.equal(empty.read_states, dict.new())
}

pub fn room_create_carries_the_rooms_read_state_test() {
  let full = dispatch("ROOM_CREATE", fixtures.load("room", "full"))
  let assert envelope.RoomCreateEvent(room) = full
  let assert Some(read_state) = room.read_state
  should.be_true(read_state.unread)
  let nulls = dispatch("ROOM_CREATE", fixtures.load("room", "nulls"))
  let assert envelope.RoomCreateEvent(plain) = nulls
  should.equal(plain.read_state, None)
}

pub fn mentions_carry_their_message_and_author_test() {
  let room =
    dispatch("MENTION_CREATE", fixtures.load("mention_create_event", "full"))
  let assert envelope.MentionCreatedEvent(mention) = room
  should.equal(#(mention.message_id, mention.room_id, mention.author_id), #(
    "s-string",
    "s-string",
    "s-string",
  ))
  should.equal(mention.conversation_id, None)

  let json = fixtures.load("dm_mention_create_event", "full")
  let dm = dispatch("DM_MENTION_CREATE", json)
  let assert envelope.DMMentionCreatedEvent(dm_mention) = dm
  should.equal(
    #(dm_mention.message_id, dm_mention.conversation_id, dm_mention.author_id),
    #(
      decoding.string(json, "message_id"),
      decoding.string(json, "conversation_id"),
      decoding.string(json, "author_id"),
    ),
  )
}

pub fn an_event_the_client_does_not_know_test() {
  let payload =
    dispatch("SOMETHING_NEW", dict.from_list([#("a", dynamic.int(1))]))
  case payload {
    envelope.UnknownEvent(type_, _) -> should.equal(type_, "SOMETHING_NEW")
    _ -> should.fail()
  }
}

pub fn the_reason_the_gateway_closes_a_socket_with_test() {
  let close =
    envelope.close_reason_from_json(
      dict.from_list([
        #("event", dynamic.string("close-with-reason")),
        #("code", dynamic.int(4004)),
        #("reason", dynamic.string("session ended")),
      ]),
      0,
    )
  should.equal(#(close.code, close.reason, close.shard_id), #(
    gateway_close_code.invalid_credentials,
    "session ended",
    0,
  ))
  let sharded =
    envelope.close_reason_from_json(
      dict.from_list([#("code", dynamic.int(4000))]),
      3,
    )
  should.equal(sharded.shard_id, 3)
  should.equal(
    #(
      gateway_close_code.invalid_shard,
      gateway_close_code.not_identified,
      gateway_close_code.already_identified,
    ),
    #(4000, 4003, 4005),
  )
}

// ---------------------------------------------------------------------------
// Voice and calls
// ---------------------------------------------------------------------------

pub fn ready_ice_servers_test() {
  let payload = dispatch("READY", fixtures.load("ready_event", "full"))
  let assert envelope.ReadyEvent(ready_data) = payload
  let assert [server] = ready_data.ice_servers
  should.equal(server.urls, ["s-string"])
  should.equal(server.username, Some("s-string"))
  // pion's credential is `any`: the fixture leaves it out.
  should.equal(server.credential, None)

  // As the gateway sends them: the STUN server, then the relay.
  let document =
    dict.insert(
      fixtures.load("ready_event", "nulls"),
      "ice_servers",
      dynamic.list([
        dynamic_object(
          dict.from_list([
            #(
              "urls",
              dynamic.list([dynamic.string("stun:stun.l.google.com:19302")]),
            ),
            #("credentialType", dynamic.string("password")),
          ]),
        ),
        dynamic_object(
          dict.from_list([
            #(
              "urls",
              dynamic.list([
                dynamic.string("turn:turn.duvet.chat:3478?transport=udp"),
                dynamic.string("turns:turn.duvet.chat:5349?transport=tcp"),
              ]),
            ),
            #("username", dynamic.string("1761300000:u1")),
            #("credential", dynamic.string("c2VjcmV0")),
            #("credentialType", dynamic.string("password")),
          ]),
        ),
      ]),
    )
  let ready_payload = dispatch("READY", document)
  let assert envelope.ReadyEvent(named) = ready_payload
  should.equal(list.map(named.ice_servers, ready.ice_server_to_json), [
    json.object([
      #("urls", json.array(["stun:stun.l.google.com:19302"], json.string)),
    ]),
    json.object([
      #(
        "urls",
        json.array(
          [
            "turn:turn.duvet.chat:3478?transport=udp",
            "turns:turn.duvet.chat:5349?transport=tcp",
          ],
          json.string,
        ),
      ),
      #("username", json.string("1761300000:u1")),
      #("credential", json.string("c2VjcmV0")),
    ]),
  ])

  let nulls = dispatch("READY", fixtures.load("ready_event", "nulls"))
  let assert envelope.ReadyEvent(null_ready) = nulls
  should.equal(null_ready.ice_servers, [])
  let bot = dispatch("READY", fixtures.load("bot_ready_event", "full"))
  let assert envelope.ReadyEvent(bot_ready) = bot
  should.equal(bot_ready.ice_servers, [])
}

pub fn an_ice_server_with_one_url_or_an_oauth_credential_test() {
  let server =
    ready.ice_server_from_json(
      dict.from_list([
        #("urls", dynamic.string("stun:example.invalid")),
        #(
          "credential",
          dynamic_object(
            dict.from_list([
              #("macKey", dynamic.string("k")),
              #("accessToken", dynamic.string("t")),
            ]),
          ),
        ),
      ]),
    )
  should.equal(server.urls, ["stun:example.invalid"])
  should.equal(server.credential, None)
}

pub fn ready_a_calls_voice_states_have_their_camera_and_version_test() {
  let payload = dispatch("READY", fixtures.load("ready_event", "full"))
  let assert envelope.ReadyEvent(ready_data) = payload
  let assert Some(calls) = ready_data.active_calls
  let assert [call] = calls
  let assert Some(states) = call.voice_states
  let assert [state] = states
  should.equal(#(state.camera, state.version), #(True, 2))
}

pub fn space_create_voice_room_states_test() {
  let payload =
    dispatch("SPACE_CREATE", fixtures.load("space_create_event", "full"))
  let assert envelope.SpaceCreateEvent(created) = payload
  let assert Some(states) = created.voice_states
  let assert [state] = states
  should.equal(#(state.muted, state.camera, state.version), #(True, True, 2))
  let nulls =
    dispatch("SPACE_CREATE", fixtures.load("space_create_event", "nulls"))
  let assert envelope.SpaceCreateEvent(empty) = nulls
  should.equal(empty.voice_states, Some([]))
}

pub fn voice_state_update_carries_the_whole_state_test() {
  let joined =
    dispatch(
      "VOICE_STATE_UPDATE",
      fixtures.load("voice_state_update_event", "full"),
    )
  let assert envelope.VoiceStateUpdatedEvent(joined_state) = joined
  should.equal(
    #(
      joined_state.joined,
      joined_state.muted,
      joined_state.deafened,
      joined_state.screen_sharing,
      joined_state.camera,
      joined_state.version,
    ),
    #(True, True, True, True, True, 2),
  )
  let left =
    dispatch(
      "VOICE_STATE_UPDATE",
      fixtures.load("voice_state_update_event", "nulls"),
    )
  let assert envelope.VoiceStateUpdatedEvent(left_state) = left
  should.equal(#(left_state.joined, left_state.muted), #(False, False))
}

pub fn voice_joined_and_the_renegotiations_carry_their_descriptions_test() {
  let joined =
    dispatch("VOICE_JOINED", fixtures.load("voice_joined_event", "full"))
  let assert envelope.VoiceJoinedPayloadEvent(joined_event) = joined
  let assert Some(answer) = joined_event.answer
  should.equal(answer.sdp, "s-string")
  let offer =
    dispatch(
      "WEBRTC_RENEGOTIATE",
      fixtures.load("webrtc_renegotiate_event", "full"),
    )
  let assert envelope.WebRTCRenegotiateEvent(offer_event) = offer
  should.equal(#(offer_event.room_id, offer_event.offer.sdp), #(
    "s-string",
    "s-string",
  ))
  let answer_event =
    dispatch(
      "WEBRTC_RENEGOTIATE_ANSWER",
      fixtures.load("webrtc_renegotiate_answer_event", "nulls"),
    )
  let assert envelope.WebRTCRenegotiateAnswerEvent(renegotiation) = answer_event
  should.equal(renegotiation.answer, None)
}

pub fn webrtc_ice_candidate_the_candidate_is_a_json_string_test() {
  // What webrtc.go sends: json.Marshal(candidate.ToJSON()) as a string.
  let init =
    "{\"candidate\":\"candidate:1 1 udp 2130706431 45.77.6.83 50000 typ host\",\"sdpMid\":\"0\",\"sdpMLineIndex\":0,\"usernameFragment\":null}"
  let payload =
    dispatch(
      "WEBRTC_ICE_CANDIDATE",
      dict.from_list([
        #("candidate", dynamic.string(init)),
        #("room_id", dynamic.string("r1")),
      ]),
    )
  let assert envelope.WebRTCIceCandidateEvent(candidate_event) = payload
  should.equal(candidate_event.room_id, "r1")
  should.equal(
    candidate_event.candidate.candidate,
    "candidate:1 1 udp 2130706431 45.77.6.83 50000 typ host",
  )
  should.equal(
    #(
      candidate_event.candidate.sdp_mid,
      candidate_event.candidate.sdp_m_line_index,
    ),
    #(Some("0"), Some(0)),
  )
  should.equal(
    event.ice_candidate_init_to_json(candidate_event.candidate),
    json.object([
      #(
        "candidate",
        json.string("candidate:1 1 udp 2130706431 45.77.6.83 50000 typ host"),
      ),
      #("sdpMid", json.string("0")),
      #("sdpMLineIndex", json.int(0)),
    ]),
  )
}

pub fn webrtc_ice_candidate_an_object_or_a_bare_line_test() {
  let object_payload =
    dispatch(
      "WEBRTC_ICE_CANDIDATE",
      dict.from_list([
        #(
          "candidate",
          dynamic_object(
            dict.from_list([
              #("candidate", dynamic.string("candidate:x")),
              #("sdpMLineIndex", dynamic.int(1)),
            ]),
          ),
        ),
        #("room_id", dynamic.string("r1")),
      ]),
    )
  let assert envelope.WebRTCIceCandidateEvent(object_event) = object_payload
  should.equal(
    #(object_event.candidate.candidate, object_event.candidate.sdp_mid),
    #("candidate:x", None),
  )
  // The fixture's string isn't JSON: the line itself.
  let line =
    dispatch(
      "WEBRTC_ICE_CANDIDATE",
      fixtures.load("webrtc_ice_candidate_event", "full"),
    )
  let assert envelope.WebRTCIceCandidateEvent(line_event) = line
  should.equal(line_event.candidate.candidate, "s-string")
  let broken =
    dispatch(
      "WEBRTC_ICE_CANDIDATE",
      dict.from_list([
        #("candidate", dynamic.string("{not json")),
        #("room_id", dynamic.string("r1")),
      ]),
    )
  let assert envelope.WebRTCIceCandidateEvent(broken_event) = broken
  should.equal(broken_event.candidate.candidate, "{not json")
}

pub fn voice_session_replaced_another_device_or_lost_access_test() {
  let json = fixtures.load("voice_session_replaced_event", "full")
  let lost = dispatch("VOICE_SESSION_REPLACED", json)
  let assert envelope.VoiceSessionReplacedPayloadEvent(lost_event) = lost
  should.equal(lost_event.reason, Some("s-string"))
  // omitempty: no reason when another device took the voice.
  let moved =
    dispatch("VOICE_SESSION_REPLACED", fixtures.without(json, "reason"))
  let assert envelope.VoiceSessionReplacedPayloadEvent(moved_event) = moved
  should.equal(#(moved_event.room_id, moved_event.reason), #("s-string", None))
}

pub fn voice_video_refused_which_video_and_why_test() {
  let limit =
    dispatch(
      "VOICE_VIDEO_REFUSED",
      dict.from_list([
        #("room_id", dynamic.string("r1")),
        #("kind", dynamic.string("camera")),
        #("reason", dynamic.string("limit")),
        #("limit", dynamic.int(8)),
      ]),
    )
  let assert envelope.VoiceVideoRefusedPayloadEvent(limit_event) = limit
  should.equal(#(limit_event.room_id, limit_event.kind, limit_event.reason), #(
    "r1",
    "camera",
    "limit",
  ))
  should.equal(limit_event.limit, Some(8))
  // omitempty: no limit for another reason.
  let screen =
    dispatch(
      "VOICE_VIDEO_REFUSED",
      fixtures.load("voice_video_refused_event", "nulls"),
    )
  let assert envelope.VoiceVideoRefusedPayloadEvent(screen_event) = screen
  should.equal(screen_event.limit, None)
}

pub fn calls_incoming_outgoing_ongoing_and_answered_test() {
  let incoming =
    dispatch("CALL_INCOMING", fixtures.load("call_incoming_event", "nulls"))
  let assert envelope.CallIncomingPayloadEvent(incoming_event) = incoming
  should.equal(incoming_event.initiator_avatar, None)
  let outgoing =
    dispatch("CALL_OUTGOING", fixtures.load("call_outgoing_event", "full"))
  let assert envelope.CallOutgoingPayloadEvent(outgoing_event) = outgoing
  should.equal(outgoing_event.conversation_id, "s-string")
  let ongoing =
    dispatch("CALL_ONGOING", fixtures.load("call_ongoing_event", "full"))
  let assert envelope.CallOngoingPayloadEvent(ongoing_event) = ongoing
  let ongoing_states = case ongoing_event.voice_states {
    Some([state]) -> Some(state.camera)
    _ -> None
  }
  should.equal(#(ongoing_event.initiator_id, ongoing_states), #(
    "s-string",
    Some(True),
  ))
  // Null while nobody is in the call's voice.
  let empty =
    dispatch(
      "CALL_ONGOING",
      fixtures.with_null(
        fixtures.load("call_ongoing_event", "full"),
        "voice_states",
      ),
    )
  let assert envelope.CallOngoingPayloadEvent(empty_event) = empty
  should.equal(empty_event.voice_states, None)
  let accepted =
    dispatch("CALL_ACCEPTED", fixtures.load("call_member_event", "full"))
  let assert envelope.CallAcceptedEvent(accepted_event) = accepted
  let declined =
    dispatch("CALL_DECLINED", fixtures.load("call_member_event", "full"))
  let assert envelope.CallDeclinedEvent(declined_event) = declined
  should.equal(#(accepted_event.user_id, declined_event.user_id), #(
    "s-string",
    "s-string",
  ))
  let ended = dispatch("CALL_ENDED", fixtures.load("call_ended_event", "full"))
  case ended {
    envelope.CallEndedPayloadEvent(_) -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Client status
// ---------------------------------------------------------------------------

pub fn client_status_each_platform_and_a_phone_only_when_just_mobile_test() {
  let both =
    client_status.from_json(
      dict.from_list([
        #("desktop", dynamic.int(1)),
        #("mobile", dynamic.int(1)),
      ]),
    )
  should.equal(
    client_status.status_on(both, client_platform.desktop),
    Ok(user_status.online),
  )
  should.equal(
    client_status.status_on(both, client_platform.mobile),
    Ok(user_status.online),
  )
  should.equal(client_status.status_on(both, client_platform.web), Error(Nil))
  should.be_false(client_status.is_mobile_only(both))

  let mobile =
    client_status.from_json(dict.from_list([#("mobile", dynamic.int(2))]))
  should.equal(
    client_status.status_on(mobile, client_platform.mobile),
    Ok(user_status.dnd),
  )
  should.be_true(client_status.is_mobile_only(mobile))
  // A platform the package doesn't name is kept, and isn't mobile.
  let other =
    client_status.from_json(dict.from_list([#("watch", dynamic.int(1))]))
  should.equal(
    client_status.status_on(other, client_platform.ClientPlatform("watch")),
    Ok(user_status.online),
  )
  should.be_false(client_status.is_mobile_only(other))
  should.be_false(
    client_status.is_mobile_only(client_status.ClientStatus(dict.new())),
  )
}

pub fn client_status_wherever_a_status_goes_test() {
  let reads = [
    #("user_status_update_event", fn(json: decoding.Object) {
      event.user_status_update_from_json(json).client_status
    }),
    #("friend", fn(json: decoding.Object) {
      conversation.friend_from_json(json).client_status
    }),
    #("friend_request_accept_event", fn(json: decoding.Object) {
      conversation.friend_request_accept_event_from_json(json).client_status
    }),
    #("space_member_add_event", fn(json: decoding.Object) {
      event.space_member_from_json(json).client_status
    }),
    #("conversation_member_add_event", fn(json: decoding.Object) {
      event.conversation_member_add_from_json(json).client_status
    }),
    #("conversation_member_row", fn(json: decoding.Object) {
      conversation.conversation_member_from_json(json).client_status
    }),
  ]
  list.each(reads, fn(row) {
    let #(name, read) = row
    let json = fixtures.load(name, "full")
    let status =
      read(dict.insert(
        json,
        "client_status",
        dynamic_object(dict.from_list([#("mobile", dynamic.int(1))])),
      ))
    let assert Some(mobile) = status
    should.equal(
      client_status.status_on(mobile, client_platform.mobile),
      Ok(user_status.online),
    )
    should.be_true(client_status.is_mobile_only(mobile))
    // Left out while the user is offline, and by an older server.
    should.be_none(read(fixtures.without(json, "client_status")))
  })
}

pub fn space_create_each_connected_members_client_status_test() {
  let json = fixtures.load("space_create_event", "full")
  let created =
    event.space_create_payload_from_json(dict.insert(
      json,
      "member_client_status",
      dynamic_object(
        dict.from_list([
          #(
            "u1",
            dynamic_object(
              dict.from_list([
                #("desktop", dynamic.int(2)),
                #("web", dynamic.int(2)),
              ]),
            ),
          ),
          #("u2", dynamic_object(dict.from_list([#("mobile", dynamic.int(1))]))),
        ]),
      ),
    ))
  let assert Ok(u1) = dict.get(created.member_client_status, "u1")
  should.equal(
    client_status.status_on(u1, client_platform.desktop),
    Ok(user_status.dnd),
  )
  should.equal(
    client_status.status_on(u1, client_platform.web),
    Ok(user_status.dnd),
  )
  let assert Ok(u2) = dict.get(created.member_client_status, "u2")
  should.be_true(client_status.is_mobile_only(u2))
  // None from a gateway before it.
  let older =
    event.space_create_payload_from_json(fixtures.without(
      json,
      "member_client_status",
    ))
  should.equal(older.member_client_status, dict.new())
}
