import gleam/option.{type Option}
import libduvet/model/decoding

/// The tokens logging in or refreshing the session gives.
pub type SignIn {
  SignIn(
    /// The access token, sent as `Authorization: Bearer`.
    token: String,
    /// The session (refresh) token, sent as `X-Session-Token`.
    session_token: Option(String),
  )
}

pub fn from_json(object: decoding.Object) -> SignIn {
  SignIn(
    token: decoding.string(object, "token"),
    session_token: decoding.optional_string(object, "session_token"),
  )
}
