/// What a room is: text, voice, or a category of rooms.
pub type RoomType {
  RoomType(Int)
}

pub const text = RoomType(1)

pub const voice = RoomType(2)

pub const category = RoomType(3)

pub fn from_int(value: Int) -> RoomType {
  RoomType(value)
}

pub fn value(room_type: RoomType) -> Int {
  let RoomType(value) = room_type
  value
}

pub fn to_label(room_type: RoomType) -> String {
  case value(room_type) {
    2 -> "voice"
    3 -> "category"
    _ -> "text"
  }
}
