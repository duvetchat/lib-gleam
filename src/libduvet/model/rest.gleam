import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import libduvet/json_value.{type JsonValue}
import libduvet/model/decoding
import libduvet/model/encoding
import libduvet/model/interaction_callback_type
import libduvet/model/room_type.{type RoomType}
import libduvet/model/space
import libduvet/model/user

/// What creating a space answers: the space, and the rooms the API makes with
/// it (a text and a voice room).
pub type CreatedSpace {
  CreatedSpace(
    space: space.GatewaySpace,
    /// Its text room, then its voice room.
    rooms: List(space.GatewayRoom),
  )
}

pub fn created_space_from_json(object: decoding.Object) -> CreatedSpace {
  CreatedSpace(
    space: decoding.object(object, "space")
      |> space.space_from_json,
    rooms: list.flatten([
      case decoding.optional_object(object, "text_room") {
        Some(room) -> [space.room_from_json(room)]
        None -> []
      },
      case decoding.optional_object(object, "voice_room") {
        Some(room) -> [space.room_from_json(room)]
        None -> []
      },
    ]),
  )
}

/// The space's ID.
pub fn created_space_id(created: CreatedSpace) -> String {
  created.space.id
}

pub type SpaceMemberWithUser {
  SpaceMemberWithUser(
    id: String,
    space_id: String,
    user_id: String,
    alias: Option(String),
    created_at: Timestamp,
    updated_at: Timestamp,
    deleted_at: Option(Timestamp),
    user: user.GatewayUser,
    /// The position of the member's highest role: the members list's cursor,
    /// with the member's ID.
    max_pos: Option(Int),
  )
}

pub fn space_member_with_user_from_json(
  object: decoding.Object,
) -> SpaceMemberWithUser {
  let member = space.member_from_json(object)
  SpaceMemberWithUser(
    id: member.id,
    space_id: member.space_id,
    user_id: member.user_id,
    alias: member.alias,
    created_at: member.created_at,
    updated_at: member.updated_at,
    deleted_at: member.deleted_at,
    user: decoding.object(object, "user")
      |> user.from_json,
    max_pos: decoding.optional_int(object, "max_pos"),
  )
}

/// A message search. The values of each list are alternatives; different
/// filters must all match.
pub type MessageSearch {
  MessageSearch(
    query: Option(String),
    author_ids: List(String),
    mentions: List(String),
    room_ids: List(String),
    has: List(String),
    /// Only the pinned messages (Some(True)) or only the others (Some(False)).
    pinned: Option(Bool),
    before: Option(Timestamp),
    after: Option(Timestamp),
    /// The ID of the previous page's last message.
    cursor: Option(String),
  )
}

pub fn empty_message_search() -> MessageSearch {
  MessageSearch(
    query: None,
    author_ids: [],
    mentions: [],
    room_ids: [],
    has: [],
    pinned: None,
    before: None,
    after: None,
    cursor: None,
  )
}

/// The search's query parameters: each list's values repeat its key.
pub fn message_search_query(search: MessageSearch) -> List(#(String, String)) {
  list.flatten([
    case search.query {
      Some(query) ->
        case string.is_empty(query) {
          True -> []
          False -> [#("query", query)]
        }
      None -> []
    },
    repeated("author_id", search.author_ids),
    repeated("mentions", search.mentions),
    repeated("room_id", search.room_ids),
    repeated("has", search.has),
    case search.pinned {
      Some(pinned) -> [#("pinned", bool_text(pinned))]
      None -> []
    },
    case search.before {
      Some(at) -> [#("before", decoding.format_time(at))]
      None -> []
    },
    case search.after {
      Some(at) -> [#("after", decoding.format_time(at))]
      None -> []
    },
    case search.cursor {
      Some(cursor) ->
        case string.is_empty(cursor) {
          True -> []
          False -> [#("cursor", cursor)]
        }
      None -> []
    },
  ])
}

fn repeated(key: String, values: List(String)) -> List(#(String, String)) {
  list.map(values, fn(value) { #(key, value) })
}

fn bool_text(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

pub type MessageSearchResponse(t) {
  MessageSearchResponse(
    /// All the pages' messages, counted up to 1000.
    total_results: Int,
    /// This page, newest first.
    messages: List(t),
  )
}

pub fn message_search_response_from_json(
  object: decoding.Object,
  read: fn(decoding.Object) -> t,
) -> MessageSearchResponse(t) {
  MessageSearchResponse(
    total_results: decoding.int_or(object, "total_results", 0),
    messages: decoding.objects_or_empty(object, "messages", read),
  )
}

pub type StorageStatus {
  StorageStatus(
    used_bytes: Int,
    max_bytes: Int,
    upload_limit_bytes: Int,
    percentage_used: Float,
  )
}

pub fn storage_status_from_json(object: decoding.Object) -> StorageStatus {
  StorageStatus(
    used_bytes: decoding.int(object, "used_bytes"),
    max_bytes: decoding.int(object, "max_bytes"),
    upload_limit_bytes: decoding.int(object, "upload_limit_bytes"),
    percentage_used: decoding.number(object, "percentage_used"),
  )
}

/// An S3-compatible bucket a user or a space keeps its files in.
pub type StorageBucket {
  StorageBucket(
    id: String,
    owner_id: String,
    name: String,
    endpoint: String,
    region: String,
    bucket_name: String,
    access_key_id: String,
    is_active: Bool,
    is_default: Bool,
    use_path_style: Bool,
    max_bytes: Option(Int),
    upload_limit_bytes: Option(Int),
    used_bytes: Int,
    created_at: Timestamp,
    updated_at: Timestamp,
  )
}

pub fn storage_bucket_from_json(object: decoding.Object) -> StorageBucket {
  StorageBucket(
    id: decoding.string(object, "id"),
    owner_id: decoding.string(object, "owner_id"),
    name: decoding.string(object, "name"),
    endpoint: decoding.string(object, "endpoint"),
    region: decoding.string_or(object, "region", ""),
    bucket_name: decoding.string(object, "bucket_name"),
    access_key_id: decoding.string(object, "access_key_id"),
    is_active: decoding.bool_or(object, "is_active", False),
    is_default: decoding.bool_or(object, "is_default", False),
    use_path_style: decoding.bool_or(object, "use_path_style", False),
    max_bytes: decoding.optional_int(object, "max_bytes"),
    upload_limit_bytes: decoding.optional_int(object, "upload_limit_bytes"),
    used_bytes: decoding.int_or(object, "used_bytes", 0),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
  )
}

/// A move of a user's or a space's files from one of its storages to another.
pub type StorageTransfer {
  StorageTransfer(
    id: String,
    /// The user or the space whose files move.
    owner_id: String,
    /// Who started it: the only one its STORAGE_TRANSFER_UPDATEs reach.
    started_by: String,
    source_bucket_id: Option(String),
    target_bucket_id: Option(String),
    /// The originals stay in the source.
    keep_source: Bool,
    /// The source and the target are one bucket under two configurations.
    same_bucket: Bool,
    /// A [storage_transfer_status] value.
    status: Int,
    /// Why it failed; None otherwise.
    error: Option(String),
    total_files: Int,
    total_bytes: Int,
    moved_files: Int,
    moved_bytes: Int,
    /// Left where they were: deleted meanwhile, moved by something else, or
    /// too large for the target.
    skipped_files: Int,
    failed_files: Int,
    created_at: Timestamp,
    started_at: Option(Timestamp),
    finished_at: Option(Timestamp),
    updated_at: Timestamp,
  )
}

pub fn storage_transfer_from_json(object: decoding.Object) -> StorageTransfer {
  StorageTransfer(
    id: decoding.string(object, "id"),
    owner_id: decoding.string(object, "owner_id"),
    started_by: decoding.string(object, "started_by"),
    source_bucket_id: decoding.optional_string(object, "source_bucket_id"),
    target_bucket_id: decoding.optional_string(object, "target_bucket_id"),
    keep_source: decoding.bool_or(object, "keep_source", False),
    same_bucket: decoding.bool_or(object, "same_bucket", False),
    status: decoding.int(object, "status"),
    error: decoding.optional_string(object, "error"),
    total_files: decoding.int_or(object, "total_files", 0),
    total_bytes: decoding.int_or(object, "total_bytes", 0),
    moved_files: decoding.int_or(object, "moved_files", 0),
    moved_bytes: decoding.int_or(object, "moved_bytes", 0),
    skipped_files: decoding.int_or(object, "skipped_files", 0),
    failed_files: decoding.int_or(object, "failed_files", 0),
    created_at: decoding.time(object, "created_at"),
    started_at: decoding.optional_time(object, "started_at"),
    finished_at: decoding.optional_time(object, "finished_at"),
    updated_at: decoding.time(object, "updated_at"),
  )
}

/// What creating or updating a storage bucket takes.
pub type BucketPayload {
  BucketPayload(
    name: String,
    endpoint: String,
    region: Option(String),
    bucket_name: String,
    access_key_id: String,
    secret_access_key: String,
    use_path_style: Option(Bool),
    max_bytes: Option(Int),
    upload_limit_bytes: Option(Int),
  )
}

pub fn bucket_payload_to_json(payload: BucketPayload) -> json.Json {
  json.object(
    list.flatten([
      [
        #("name", json.string(payload.name)),
        #("endpoint", json.string(payload.endpoint)),
      ],
      encoding.present([
        encoding.optional_string("region", payload.region),
        encoding.optional_bool("use_path_style", payload.use_path_style),
      ]),
      [
        #("bucket_name", json.string(payload.bucket_name)),
        #("access_key_id", json.string(payload.access_key_id)),
        #("secret_access_key", json.string(payload.secret_access_key)),
        #("max_bytes", json.nullable(payload.max_bytes, json.int)),
        #(
          "upload_limit_bytes",
          json.nullable(payload.upload_limit_bytes, json.int),
        ),
      ],
    ]),
  )
}

pub type Team {
  Team(
    id: String,
    name: String,
    owner_id: String,
    created_at: Timestamp,
    updated_at: Timestamp,
  )
}

pub fn team_from_json(object: decoding.Object) -> Team {
  Team(
    id: decoding.string(object, "id"),
    name: decoding.string(object, "name"),
    owner_id: decoding.string(object, "owner_id"),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
  )
}

pub type TeamMember {
  TeamMember(
    team_id: String,
    user_id: String,
    /// A [team_role] value.
    role: Int,
    username: String,
    avatar: Option(String),
  )
}

pub fn team_member_from_json(object: decoding.Object) -> TeamMember {
  TeamMember(
    team_id: decoding.string(object, "team_id"),
    user_id: decoding.string(object, "user_id"),
    role: decoding.int(object, "role"),
    username: decoding.string(object, "username"),
    avatar: decoding.optional_string(object, "avatar"),
  )
}

pub type TeamInvite {
  TeamInvite(
    id: String,
    team_id: String,
    user_id: String,
    invited_by: String,
    created_at: Timestamp,
    team_name: String,
    invited_by_username: String,
  )
}

pub fn team_invite_from_json(object: decoding.Object) -> TeamInvite {
  TeamInvite(
    id: decoding.string(object, "id"),
    team_id: decoding.string(object, "team_id"),
    user_id: decoding.string(object, "user_id"),
    invited_by: decoding.string(object, "invited_by"),
    created_at: decoding.time(object, "created_at"),
    team_name: decoding.string(object, "team_name"),
    invited_by_username: decoding.string(object, "invited_by_username"),
  )
}

pub type Application {
  Application(
    id: String,
    team_id: String,
    name: String,
    description: Option(String),
    icon: Option(String),
    public: Bool,
    bot_user_id: Option(String),
    bot_token_hash: Option(String),
    created_at: Timestamp,
    updated_at: Timestamp,
  )
}

pub fn application_from_json(object: decoding.Object) -> Application {
  Application(
    id: decoding.string(object, "id"),
    team_id: decoding.string(object, "team_id"),
    name: decoding.string(object, "name"),
    description: decoding.optional_string(object, "description"),
    icon: decoding.optional_string(object, "icon"),
    public: decoding.bool_or(object, "public", False),
    bot_user_id: decoding.optional_string(object, "bot_user_id"),
    bot_token_hash: decoding.optional_string(object, "bot_token_hash"),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
  )
}

pub type InviteInfo {
  InviteInfo(
    code: String,
    space_id: String,
    space_name: String,
    description: String,
    member_count: Int,
  )
}

pub fn invite_info_from_json(object: decoding.Object) -> InviteInfo {
  InviteInfo(
    code: decoding.string(object, "code"),
    space_id: decoding.string(object, "space_id"),
    space_name: decoding.string(object, "space_name"),
    description: decoding.string_or(object, "description", ""),
    member_count: decoding.int_or(object, "member_count", 0),
  )
}

pub type InviteLink {
  InviteLink(
    id: String,
    code: String,
    room_id: String,
    created_by: String,
    created_at: Timestamp,
    updated_at: Timestamp,
    /// When it stops working; None for one that works until it is revoked.
    expires_at: Option(Timestamp),
  )
}

pub fn invite_link_from_json(object: decoding.Object) -> InviteLink {
  InviteLink(
    id: decoding.string(object, "id"),
    code: decoding.string(object, "code"),
    room_id: decoding.string(object, "room_id"),
    created_by: decoding.string(object, "created_by"),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    expires_at: decoding.optional_time(object, "expires_at"),
  )
}

pub type Webhook {
  Webhook(
    id: String,
    room_id: String,
    username: String,
    avatar: Option(String),
    created_at: Timestamp,
    updated_at: Timestamp,
  )
}

pub fn webhook_from_json(object: decoding.Object) -> Webhook {
  Webhook(
    id: decoding.string(object, "id"),
    room_id: decoding.string(object, "room_id"),
    username: decoding.string(object, "username"),
    avatar: decoding.optional_string(object, "avatar"),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
  )
}

pub type WebhookCreateResponse {
  WebhookCreateResponse(webhook: Webhook, token: String)
}

pub fn webhook_create_response_from_json(
  object: decoding.Object,
) -> WebhookCreateResponse {
  WebhookCreateResponse(
    webhook: decoding.object(object, "webhook")
      |> webhook_from_json,
    token: decoding.string(object, "token"),
  )
}

pub type CommandChoice {
  CommandChoice(
    name: String,
    /// A string or a number.
    value: JsonValue,
  )
}

pub fn command_choice_from_json(object: decoding.Object) -> CommandChoice {
  CommandChoice(
    name: decoding.string(object, "name"),
    value: case decoding.field(object, "value") {
      Some(value) -> json_value.from_dynamic(value)
      None -> panic as "a command choice has no value"
    },
  )
}

/// What a command takes; the required ones come first.
pub type CommandOption {
  CommandOption(
    /// A [command_option_type] value.
    type_: Int,
    name: String,
    description: String,
    required: Bool,
    /// The only values it takes, for string, integer and number options.
    choices: Option(List(CommandChoice)),
    min_value: Option(Float),
    max_value: Option(Float),
    min_length: Option(Int),
    max_length: Option(Int),
    room_types: Option(List(RoomType)),
  )
}

pub fn command_option_from_json(object: decoding.Object) -> CommandOption {
  CommandOption(
    type_: decoding.int(object, "type"),
    name: decoding.string(object, "name"),
    description: decoding.string_or(object, "description", ""),
    required: decoding.bool_or(object, "required", False),
    choices: decoding.optional_objects(
      object,
      "choices",
      command_choice_from_json,
    ),
    min_value: decoding.optional_number(object, "min_value"),
    max_value: decoding.optional_number(object, "max_value"),
    min_length: decoding.optional_int(object, "min_length"),
    max_length: decoding.optional_int(object, "max_length"),
    room_types: decoding.optional_list(object, "room_types", fn(value) {
      room_type.from_int(decoding.int_value(value, "room_types"))
    }),
  )
}

/// A chat command an application registers.
pub type ApplicationCommand {
  ApplicationCommand(
    id: String,
    /// 1, a chat command.
    type_: Int,
    application_id: String,
    name: String,
    description: String,
    options: List(CommandOption),
    version: String,
  )
}

pub fn application_command_from_json(
  object: decoding.Object,
) -> ApplicationCommand {
  ApplicationCommand(
    id: decoding.string(object, "id"),
    type_: decoding.int_or(object, "type", 1),
    application_id: decoding.string(object, "application_id"),
    name: decoding.string(object, "name"),
    description: decoding.string_or(object, "description", ""),
    options: decoding.objects_or_empty(
      object,
      "options",
      command_option_from_json,
    ),
    version: decoding.string_or(object, "version", ""),
  )
}

pub type SpaceCommandApplication {
  SpaceCommandApplication(id: String, name: String, bot: user.InteractionUser)
}

pub fn space_command_application_from_json(
  object: decoding.Object,
) -> SpaceCommandApplication {
  SpaceCommandApplication(
    id: decoding.string(object, "id"),
    name: decoding.string(object, "name"),
    bot: decoding.object(object, "bot")
      |> user.interaction_user_from_json,
  )
}

/// The commands a member can use in a space: those of the applications whose
/// bots are in it.
pub type SpaceCommands {
  SpaceCommands(
    applications: List(SpaceCommandApplication),
    commands: List(ApplicationCommand),
  )
}

pub fn space_commands_from_json(object: decoding.Object) -> SpaceCommands {
  SpaceCommands(
    applications: decoding.objects_or_empty(
      object,
      "applications",
      space_command_application_from_json,
    ),
    commands: decoding.objects_or_empty(
      object,
      "commands",
      application_command_from_json,
    ),
  )
}

/// What a person's interaction answers: the type of the bot's first response
/// and, when the bot opened a modal, the modal and the application its submit
/// goes to.
pub type InteractionReply {
  InteractionReply(
    /// An [interaction_callback_type] value.
    type_: Int,
    /// The modal, as the API sends it: its `custom_id`, `title` and
    /// `components`.
    modal: Option(decoding.Object),
    /// The application whose bot opened the modal.
    application_id: Option(String),
  )
}

pub fn interaction_reply_from_json(
  object: decoding.Object,
) -> InteractionReply {
  InteractionReply(
    type_: decoding.int(object, "type"),
    modal: decoding.optional_object(object, "data"),
    application_id: decoding.optional_string(object, "application_id"),
  )
}

/// Whether the bot opened a modal: then `modal` and `application_id` are set.
pub fn interaction_reply_is_modal(reply: InteractionReply) -> Bool {
  reply.type_ == interaction_callback_type.modal
  && case reply.modal, reply.application_id {
    Some(_), Some(_) -> True
    _, _ -> False
  }
}

/// What a person sends about the component of a bot's message they used.
pub type ComponentUse {
  ComponentUse(
    custom_id: String,
    component_type: Int,
    /// What a select's choice was: its options' values, or the IDs of the
    /// members, roles or rooms.
    values: Option(List(String)),
  )
}

pub fn component_use_to_json(component: ComponentUse) -> json.Json {
  json.object(
    encoding.present([
      Some(#("custom_id", json.string(component.custom_id))),
      Some(#("component_type", json.int(component.component_type))),
      encoding.optional_list_json("values", component.values, json.string),
    ]),
  )
}

/// A command option's value, as it is sent.
pub type UsedOption {
  UsedOption(
    name: String,
    /// A [command_option_type] value.
    type_: Int,
    /// A string, a number or a bool.
    value: JsonValue,
  )
}

pub fn used_option_to_json(option: UsedOption) -> json.Json {
  json.object([
    #("name", json.string(option.name)),
    #("type", json.int(option.type_)),
    #("value", json_value.to_json(option.value)),
  ])
}

/// What a person sends about the command they used.
pub type CommandUse {
  CommandUse(id: String, name: String, options: List(UsedOption))
}

pub fn command_use_to_json(command: CommandUse) -> json.Json {
  json.object([
    #("id", json.string(command.id)),
    #("name", json.string(command.name)),
    #("type", json.int(1)),
    #("options", json.array(command.options, used_option_to_json)),
  ])
}
