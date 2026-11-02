/// What a `MessageReference` refers to.
pub type MessageReferenceType {
  MessageReferenceType(Int)
}

pub const reply = MessageReferenceType(0)

pub fn value(reference_type: MessageReferenceType) -> Int {
  let MessageReferenceType(value) = reference_type
  value
}
