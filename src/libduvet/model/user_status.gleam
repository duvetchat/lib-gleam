/// A user's presence: `status_id` in the API, and the status they chose in
/// `status`.
pub type UserStatus {
  UserStatus(Int)
}

pub const offline = UserStatus(0)

pub const online = UserStatus(1)

pub const dnd = UserStatus(2)

pub fn from_int(value: Int) -> UserStatus {
  UserStatus(value)
}

pub fn value(status: UserStatus) -> Int {
  let UserStatus(value) = status
  value
}

/// The status's name, as apps write it.
pub fn to_label(status: UserStatus) -> String {
  case value(status) {
    1 -> "online"
    2 -> "dnd"
    _ -> "offline"
  }
}
