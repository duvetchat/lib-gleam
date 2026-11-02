import gleam/option.{type Option, None, Some}
import gleam/time/timestamp.{type Timestamp}
import libduvet/model/decoding
import libduvet/model/user_status.{type UserStatus}

pub type GatewayUser {
  GatewayUser(
    id: String,
    username: String,
    email_verified: Option(Bool),
    alias: Option(String),
    avatar: Option(String),
    banner: Option(String),
    custom: String,
    flags: Int,
    badges: Int,
    is_bot: Bool,
    status_id: UserStatus,
    /// The status the user chose ([online] or [dnd]): only on their own user,
    /// in READY. None elsewhere, for a bot, and from a gateway from before
    /// statuses.
    status: Option(UserStatus),
    created_at: Timestamp,
    updated_at: Timestamp,
    deleted_at: Option(Timestamp),
  )
}

pub fn from_json(object: decoding.Object) -> GatewayUser {
  GatewayUser(
    id: decoding.string(object, "id"),
    username: decoding.string(object, "username"),
    email_verified: decoding.optional_bool(object, "email_verified"),
    alias: decoding.optional_string(object, "alias"),
    avatar: decoding.optional_string(object, "avatar"),
    banner: decoding.optional_string(object, "banner"),
    custom: decoding.string_or(object, "custom", ""),
    flags: decoding.int_or(object, "flags", 0),
    badges: decoding.int_or(object, "badges", 0),
    is_bot: decoding.bool_or(object, "is_bot", False),
    status_id: user_status.from_int(decoding.int_or(object, "status_id", 0)),
    status: decoding.optional_int(object, "status")
      |> option_map(user_status.from_int),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    deleted_at: decoding.optional_time(object, "deleted_at"),
  )
}

/// The user's own profile: the public user plus the fields hidden from
/// everyone else. The API doesn't send the email.
pub type UserMeResult {
  UserMeResult(
    id: String,
    username: String,
    email_verified: Bool,
    alias: Option(String),
    birthdate: Option(Timestamp),
    phone: Option(String),
    avatar: Option(String),
    banner: Option(String),
    custom: String,
    flags: Int,
    badges: Int,
    is_bot: Bool,
    created_at: Timestamp,
    updated_at: Timestamp,
    /// The status the user chose: [online] or [dnd]. None for a bot, and from
    /// an API from before statuses.
    status: Option(UserStatus),
  )
}

pub fn user_me_from_json(object: decoding.Object) -> UserMeResult {
  UserMeResult(
    id: decoding.string(object, "id"),
    username: decoding.string(object, "username"),
    email_verified: decoding.bool_or(object, "email_verified", False),
    alias: decoding.optional_string(object, "alias"),
    birthdate: decoding.optional_time(object, "birthdate"),
    phone: decoding.optional_string(object, "phone"),
    avatar: decoding.optional_string(object, "avatar"),
    banner: decoding.optional_string(object, "banner"),
    custom: decoding.string_or(object, "custom", ""),
    flags: decoding.int_or(object, "flags", 0),
    badges: decoding.int_or(object, "badges", 0),
    is_bot: decoding.bool_or(object, "is_bot", False),
    created_at: decoding.time(object, "created_at"),
    updated_at: decoding.time(object, "updated_at"),
    status: decoding.optional_int(object, "status")
      |> option_map(user_status.from_int),
  )
}

pub type BotUser {
  BotUser(
    id: String,
    username: String,
    alias: Option(String),
    avatar: Option(String),
    banner: Option(String),
    is_bot: Bool,
  )
}

pub fn bot_user_from_json(object: decoding.Object) -> BotUser {
  BotUser(
    id: decoding.string(object, "id"),
    username: decoding.string(object, "username"),
    alias: decoding.optional_string(object, "alias"),
    avatar: decoding.optional_string(object, "avatar"),
    banner: decoding.optional_string(object, "banner"),
    is_bot: decoding.bool_or(object, "is_bot", False),
  )
}

/// The short form of a user that interactions and command lists carry.
pub type InteractionUser {
  InteractionUser(
    id: String,
    username: String,
    alias: Option(String),
    avatar: Option(String),
  )
}

pub fn interaction_user_from_json(object: decoding.Object) -> InteractionUser {
  InteractionUser(
    id: decoding.string(object, "id"),
    username: decoding.string(object, "username"),
    alias: decoding.optional_string(object, "alias"),
    avatar: decoding.optional_string(object, "avatar"),
  )
}

fn option_map(value: Option(a), with: fn(a) -> b) -> Option(b) {
  case value {
    Some(inner) -> Some(with(inner))
    None -> None
  }
}
