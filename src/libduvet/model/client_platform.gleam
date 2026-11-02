/// What a client runs on, which it tells the gateway when it identifies: a
/// user's `ClientStatus` says on which of them they're connected.
pub type ClientPlatform {
  ClientPlatform(String)
}

pub const desktop = ClientPlatform("desktop")

pub const web = ClientPlatform("web")

pub const mobile = ClientPlatform("mobile")

/// The platform's name, as the API writes it.
pub fn name(platform: ClientPlatform) -> String {
  let ClientPlatform(name) = platform
  name
}
