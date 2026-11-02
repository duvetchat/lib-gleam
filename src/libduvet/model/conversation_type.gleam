/// The values of a conversation's `type`: a direct message or a group.
pub type ConversationType {
  ConversationType(Int)
}

pub const dm = ConversationType(1)

pub const group = ConversationType(2)

pub fn from_int(value: Int) -> ConversationType {
  ConversationType(value)
}

pub fn value(conversation_type: ConversationType) -> Int {
  let ConversationType(value) = conversation_type
  value
}
