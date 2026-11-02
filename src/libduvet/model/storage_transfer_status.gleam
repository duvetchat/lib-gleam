/// The values a storage transfer's `status` takes.
pub const queued = 0

pub const moving = 1

pub const done = 2

/// Stopped on an error: what it didn't move stays in the source.
pub const failed = 3

/// Stopped by a person: what it moved stays in the target.
pub const cancelled = 4
