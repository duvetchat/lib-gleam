import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import libduvet/model/client_platform
import libduvet/model/decoding
import libduvet/model/user_status.{type UserStatus}

/// A user's client status (`client_status`): each platform they're connected
/// on, with their status there. A person shows one status, so each of their
/// platforms has it; a bot's connections all count as desktop, as does a
/// client that doesn't say its platform. Servers leave it out while the user
/// is offline, and ones from before it always do.
pub type ClientStatus {
  ClientStatus(platforms: Dict(client_platform.ClientPlatform, UserStatus))
}

/// A platform this package doesn't name is kept as the server gave it.
pub fn from_json(object: decoding.Object) -> ClientStatus {
  ClientStatus(
    object
    |> dict.to_list
    |> list.map(fn(pair) {
      #(
        client_platform.ClientPlatform(pair.0),
        user_status.from_int(decoding.int_value(pair.1, pair.0)),
      )
    })
    |> dict.from_list,
  )
}

/// The field's client status, when it is there and not null.
pub fn from_field(
  object: decoding.Object,
  key: String,
) -> Option(ClientStatus) {
  case decoding.optional_object(object, key) {
    Some(inner) -> Some(from_json(inner))
    None -> None
  }
}

/// The user's status on [platform], when they're connected there.
pub fn status_on(
  status: ClientStatus,
  platform: client_platform.ClientPlatform,
) -> Result(UserStatus, Nil) {
  let ClientStatus(platforms) = status
  dict.get(platforms, platform)
}

/// They're connected only from the mobile app: the apps show a phone for them
/// rather than the presence dot.
pub fn is_mobile_only(status: ClientStatus) -> Bool {
  let ClientStatus(platforms) = status
  case dict.size(platforms) {
    1 -> dict.has_key(platforms, client_platform.mobile)
    _ -> False
  }
}
