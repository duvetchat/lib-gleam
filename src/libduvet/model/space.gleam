import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import gleam/time/timestamp.{type Timestamp}
import libduvet/model/decoding
import libduvet/model/room_type.{type RoomType}
import libduvet/model/user

/// Someone in a space's voice room, as SPACE_CREATE lists them.
pub type GatewayVoiceState {
  GatewayVoiceState(
    room_id: String,
    user_id: String,
    muted: Bool,
    deafened: Bool,
    screen_sharing: Bool,
    /// Their camera is on.
    camera: Bool,
    /// Orders this state among VOICE_STATE_UPDATEs.
    version: Int,
    /// Whose screen share they're watching, by user ID: none when nobody's.
    watching: List(String),
  )
}

pub fn voice_state_from_json(object: decoding.Object) -> GatewayVoiceState {
  GatewayVoiceState(
    room_id: decoding.string(object, "room_id"),
    user_id: decoding.string(object, "user_id"),
    muted: decoding.bool_or(object, "muted", False),
    deafened: decoding.bool_or(object, "deafened", False),
    screen_sharing: decoding.bool_or(object, "screen_sharing", False),
    camera: decoding.bool_or(object, "camera", False),
    version: decoding.int_or(object, "version", 0),
    watching: decoding.string_list_or_empty(object, "watching"),
  )
}

pub type GatewayRoomOverwrite {
  GatewayRoomOverwrite(
    id: String,
    room_id: String,
    target_id: String,
    target_type: Int,
    deny_flags: Int,
    allow_flags: Int,
    created_at: Timestamp,
    updated_at: Timestamp,
    deleted_at: Option(Timestamp),
  )
}

pub fn room_overwrite_from_json(
  object: decoding.Object,
) -> GatewayRoomOverwrite {
  GatewayRoomOverwrite(
    id: decoding.string(object, "id"),
    room_id: decoding.string(object, "room_id"),
    target_id: decoding.string(object, "target_id"),
    target_type: decoding.int(object, "target_type"),
    deny_flags: decoding.int(object, "deny_flags"),
    allow_flags: decoding.int(object, "allow_flags"),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    deleted_at: decoding.optional_time(object, "deleted_at"),
  )
}

/// A user's read state in a room, as READY's `unread_rooms`,
/// `last_read_rooms` and `last_msg_rooms` give it for the rooms READY sends.
pub type RoomReadState {
  RoomReadState(
    /// The room has a message the user hasn't read.
    unread: Bool,
    /// The last message the user read in the room; None when never read.
    last_read: Option(String),
    /// The room's newest message; None when it has none.
    last_msg: Option(String),
  )
}

pub fn room_read_state_from_json(object: decoding.Object) -> RoomReadState {
  RoomReadState(
    unread: decoding.bool_or(object, "unread", False),
    last_read: decoding.optional_string(object, "last_read"),
    last_msg: decoding.optional_string(object, "last_msg"),
  )
}

pub type GatewayRoom {
  GatewayRoom(
    id: String,
    space_id: Option(String),
    parent_id: Option(String),
    type_: RoomType,
    name: String,
    description: Option(String),
    position: Int,
    nsfw: Bool,
    created_at: Timestamp,
    updated_at: Timestamp,
    deleted_at: Option(Timestamp),
    /// The user's read state in the room, on a ROOM_CREATE for a room they can
    /// view since a change, which READY didn't have.
    read_state: Option(RoomReadState),
  )
}

pub fn room_from_json(object: decoding.Object) -> GatewayRoom {
  GatewayRoom(
    id: decoding.string(object, "id"),
    space_id: decoding.optional_string(object, "space_id"),
    parent_id: decoding.optional_string(object, "parent_id"),
    type_: room_type.from_int(decoding.int(object, "type")),
    name: decoding.string(object, "name"),
    description: decoding.optional_string(object, "description"),
    position: decoding.int(object, "position"),
    nsfw: decoding.bool_or(object, "nsfw", False),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    deleted_at: decoding.optional_time(object, "deleted_at"),
    read_state: decoding.optional_object(object, "read_state")
      |> option_map(room_read_state_from_json),
  )
}

pub type GatewayMember {
  GatewayMember(
    id: String,
    space_id: String,
    user_id: String,
    alias: Option(String),
    created_at: Timestamp,
    updated_at: Timestamp,
    deleted_at: Option(Timestamp),
  )
}

pub fn member_from_json(object: decoding.Object) -> GatewayMember {
  GatewayMember(
    id: decoding.string(object, "id"),
    space_id: decoding.string(object, "space_id"),
    user_id: decoding.string(object, "user_id"),
    alias: decoding.optional_string(object, "alias"),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    deleted_at: decoding.optional_time(object, "deleted_at"),
  )
}

pub type GatewayRole {
  GatewayRole(
    id: String,
    space_id: String,
    name: String,
    color_from: Option(Int),
    color_via: Option(Int),
    color_to: Option(Int),
    flags: Int,
    permissions: Int,
    hoisted: Bool,
    position: Int,
    created_at: Timestamp,
    updated_at: Timestamp,
    deleted_at: Option(Timestamp),
  )
}

pub fn role_from_json(object: decoding.Object) -> GatewayRole {
  GatewayRole(
    id: decoding.string(object, "id"),
    space_id: decoding.string(object, "space_id"),
    name: decoding.string(object, "name"),
    color_from: decoding.optional_int(object, "color_from"),
    color_via: decoding.optional_int(object, "color_via"),
    color_to: decoding.optional_int(object, "color_to"),
    flags: decoding.int_or(object, "flags", 0),
    permissions: decoding.int_or(object, "permissions", 0),
    hoisted: decoding.bool_or(object, "hoisted", False),
    position: decoding.int_or(object, "position", 0),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    deleted_at: decoding.optional_time(object, "deleted_at"),
  )
}

pub type GatewaySpace {
  GatewaySpace(
    id: String,
    name: String,
    description: Option(String),
    banner: Option(String),
    icon: Option(String),
    owner_id: String,
    locale: Option(String),
    member: Option(GatewayMember),
    member_roles: Dict(String, List(String)),
    room_overwrites: List(GatewayRoomOverwrite),
    rooms: List(GatewayRoom),
    members: List(GatewayMember),
    roles: List(GatewayRole),
    users: List(user.GatewayUser),
    voice_states: Option(List(GatewayVoiceState)),
    created_at: Timestamp,
    updated_at: Timestamp,
    deleted_at: Option(Timestamp),
  )
}

pub fn space_from_json(object: decoding.Object) -> GatewaySpace {
  GatewaySpace(
    id: decoding.string(object, "id"),
    name: decoding.string(object, "name"),
    description: decoding.optional_string(object, "description"),
    banner: decoding.optional_string(object, "banner"),
    icon: decoding.optional_string(object, "icon"),
    owner_id: decoding.string(object, "owner_id"),
    locale: decoding.optional_string(object, "locale"),
    member: decoding.optional_object(object, "member")
      |> option_map(member_from_json),
    member_roles: decoding.map_or_empty(object, "member_roles", fn(value) {
      decoding.string_list_value(value, "member_roles")
    }),
    room_overwrites: decoding.objects_or_empty(
      object,
      "room_overwrites",
      room_overwrite_from_json,
    ),
    rooms: decoding.objects_or_empty(object, "rooms", room_from_json),
    members: decoding.objects_or_empty(object, "members", member_from_json),
    roles: decoding.objects_or_empty(object, "roles", role_from_json),
    users: decoding.objects_or_empty(object, "users", user.from_json),
    voice_states: decoding.optional_objects(
      object,
      "voice_states",
      voice_state_from_json,
    ),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    deleted_at: decoding.optional_time(object, "deleted_at"),
  )
}

pub type SpaceEmoji {
  SpaceEmoji(
    id: String,
    name: String,
    space_id: String,
    attachment_id: String,
    created_at: Timestamp,
    updated_at: Timestamp,
    deleted_at: Option(Timestamp),
  )
}

pub fn space_emoji_from_json(object: decoding.Object) -> SpaceEmoji {
  SpaceEmoji(
    id: decoding.string(object, "id"),
    name: decoding.string(object, "name"),
    space_id: decoding.string(object, "space_id"),
    attachment_id: decoding.string(object, "attachment_id"),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    deleted_at: decoding.optional_time(object, "deleted_at"),
  )
}

pub type SpaceSticker {
  SpaceSticker(
    id: String,
    name: String,
    space_id: String,
    attachment_id: String,
    created_at: Timestamp,
    updated_at: Timestamp,
    deleted_at: Option(Timestamp),
  )
}

pub fn space_sticker_from_json(object: decoding.Object) -> SpaceSticker {
  SpaceSticker(
    id: decoding.string(object, "id"),
    name: decoding.string(object, "name"),
    space_id: decoding.string(object, "space_id"),
    attachment_id: decoding.string(object, "attachment_id"),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    deleted_at: decoding.optional_time(object, "deleted_at"),
  )
}

fn option_map(value: Option(a), with: fn(a) -> b) -> Option(b) {
  case value {
    Some(inner) -> Some(with(inner))
    None -> None
  }
}
