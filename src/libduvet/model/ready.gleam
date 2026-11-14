import gleam/dict.{type Dict}
import gleam/json
import gleam/option.{type Option, None, Some}
import libduvet/model/decoding
import libduvet/model/encoding
import libduvet/model/space
import libduvet/model/user

/// A voice state in a conversation's call: it has no room.
pub type CallVoiceState {
  CallVoiceState(
    user_id: String,
    muted: Bool,
    deafened: Bool,
    screen_sharing: Bool,
    /// Their camera is on.
    camera: Bool,
    version: Int,
    /// Whose screen share they're watching, by user ID: none when nobody's.
    watching: List(String),
  )
}

pub fn call_voice_state_from_json(object: decoding.Object) -> CallVoiceState {
  CallVoiceState(
    user_id: decoding.string(object, "user_id"),
    muted: decoding.bool_or(object, "muted", False),
    deafened: decoding.bool_or(object, "deafened", False),
    screen_sharing: decoding.bool_or(object, "screen_sharing", False),
    camera: decoding.bool_or(object, "camera", False),
    version: decoding.int_or(object, "version", 0),
    watching: decoding.string_list_or_empty(object, "watching"),
  )
}

/// A STUN or TURN server for a peer connection, as READY hands them out.
pub type IceServer {
  IceServer(
    urls: List(String),
    username: Option(String),
    credential: Option(String),
  )
}

/// `urls` may be one URL or a list; a credential that isn't a password (an
/// OAuth one) is left out.
pub fn ice_server_from_json(object: decoding.Object) -> IceServer {
  IceServer(
    urls: case decoding.field(object, "urls") {
      Some(value) -> decoding.string_or_string_list_value(value, "urls")
      None -> []
    },
    username: decoding.optional_string(object, "username"),
    credential: decoding.optional_string_when_string(object, "credential"),
  )
}

pub fn ice_server_to_json(server: IceServer) -> json.Json {
  json.object(
    encoding.present([
      Some(#("urls", json.array(server.urls, json.string))),
      encoding.optional_string("username", server.username),
      encoding.optional_string("credential", server.credential),
    ]),
  )
}

pub type GatewayReadyActiveCall {
  GatewayReadyActiveCall(
    conversation_id: String,
    initiator_id: String,
    /// The caller's name and avatar, as CALL_INCOMING carries them.
    initiator_name: Option(String),
    initiator_avatar: Option(String),
    voice_states: Option(List(CallVoiceState)),
    /// Whether the call still rings for this user. None from a gateway that
    /// doesn't say.
    ringing: Option(Bool),
    /// Whether someone other than its caller has accepted the call. None from
    /// a gateway that doesn't say.
    answered: Option(Bool),
  )
}

pub fn ready_active_call_from_json(
  object: decoding.Object,
) -> GatewayReadyActiveCall {
  GatewayReadyActiveCall(
    conversation_id: decoding.string(object, "conversation_id"),
    initiator_id: decoding.string(object, "initiator_id"),
    initiator_name: decoding.optional_string(object, "initiator_name"),
    initiator_avatar: decoding.optional_string(object, "initiator_avatar"),
    voice_states: decoding.optional_objects(
      object,
      "voice_states",
      call_voice_state_from_json,
    ),
    ringing: decoding.optional_bool(object, "ringing"),
    answered: decoding.optional_bool(object, "answered"),
  )
}

/// READY's data.
pub type GatewayReadyData {
  GatewayReadyData(
    user: user.GatewayUser,
    /// camelCase in the payload, as the gateway writes it.
    session_token: String,
    unread_rooms: Option(List(String)),
    last_read_rooms: Option(Dict(String, String)),
    last_msg_rooms: Option(Dict(String, String)),
    unread_convs: Option(List(String)),
    /// Each conversation's read position, by conversation ID.
    last_read_convs: Option(Dict(String, String)),
    active_calls: Option(List(GatewayReadyActiveCall)),
    spaces: Option(List(space.GatewaySpace)),
    /// The STUN and TURN servers for voice and calls; none in a bot's READY.
    ice_servers: List(IceServer),
    /// The spaces whose SPACE_CREATE comes after READY, by ID.
    guild_ids: List(String),
  )
}

pub fn ready_data_from_json(object: decoding.Object) -> GatewayReadyData {
  GatewayReadyData(
    user: decoding.object(object, "user")
      |> user.from_json,
    session_token: decoding.string(object, "sessionToken"),
    unread_rooms: decoding.optional_string_list(object, "unread_rooms"),
    last_read_rooms: decoding.optional_string_map(object, "last_read_rooms"),
    last_msg_rooms: decoding.optional_string_map(object, "last_msg_rooms"),
    unread_convs: decoding.optional_string_list(object, "unread_convs"),
    last_read_convs: decoding.optional_string_map(object, "last_read_convs"),
    active_calls: decoding.optional_objects(
      object,
      "active_calls",
      ready_active_call_from_json,
    ),
    spaces: decoding.optional_objects(object, "spaces", space.space_from_json),
    ice_servers: decoding.objects_or_empty(
      object,
      "ice_servers",
      ice_server_from_json,
    ),
    guild_ids: decoding.string_list_or_empty(object, "guild_ids"),
  )
}
