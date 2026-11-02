/// What a message is.
pub type MessageType {
  MessageType(Int)
}

pub const text = MessageType(0)

pub const voice = MessageType(1)

/// A room's or conversation's notice that its author pinned the message it
/// references; no content.
pub const pin_notice = MessageType(2)

/// A conversation's notice that one of its calls ended: its author is the
/// caller, it has no content, and `DirectMessage.call` says who was in the
/// call and when.
pub const call = MessageType(3)

pub fn from_int(value: Int) -> MessageType {
  MessageType(value)
}

pub fn value(message_type: MessageType) -> Int {
  let MessageType(value) = message_type
  value
}
