import gleam/int
import gleam/option.{type Option, None, Some}
import libduvet/http/send

/// Everything a request can fail with. Dart's package throws exceptions; here
/// every call answers a `Result`, and the failure carries what the exception
/// carried.
pub type DuvetError {
  /// The API answered 2xx-but-an-error, or any status but 401 and 403.
  ApiError(failure: ApiFailure)
  /// The API answered 401 or 403: the session is missing, expired or not
  /// allowed.
  AuthError(failure: AuthFailure)
  /// Nothing moved for the request's timeout.
  RequestTimeout(method: String, path: String, timeout_ms: Int)
  /// The caller's abort trigger completed first.
  RequestAborted
  /// The connection failed or was closed.
  NetworkError(reason: String)
  /// The API or the gateway sent something this package couldn't read.
  MalformedMessage(cause: String)
  /// The arguments themselves are wrong, and nothing was sent.
  InvalidArgument(message: String)
}

pub type ApiFailure {
  ApiFailure(action: String, status_code: Int, body: Option(String))
}

pub type AuthFailure {
  AuthFailure(action: String, status_code: Int, body: Option(String))
}

pub fn from_send_error(error: send.SendError) -> DuvetError {
  case error {
    send.TimedOut(method:, path:, timeout_ms:) ->
      RequestTimeout(method: method, path: path, timeout_ms: timeout_ms)
    send.Aborted -> RequestAborted
    send.Network(reason) -> NetworkError(reason)
  }
}

pub fn api(action: String, status_code: Int, body: String) -> DuvetError {
  ApiError(ApiFailure(
    action: action,
    status_code: status_code,
    body: Some(body),
  ))
}

pub fn auth(action: String, status_code: Int, body: String) -> DuvetError {
  AuthError(AuthFailure(
    action: action,
    status_code: status_code,
    body: Some(body),
  ))
}

/// The failure's message, as the Dart exception's `message` reads.
pub fn message(error: DuvetError) -> String {
  case error {
    ApiError(failure) ->
      "Failed to " <> failure.action <> ": " <> int_text(failure.status_code)
    AuthError(failure) ->
      "Failed to "
      <> failure.action
      <> ": "
      <> int_text(failure.status_code)
      <> " Unauthorized"
    RequestTimeout(method:, path:, timeout_ms:) ->
      "Failed to "
      <> method
      <> " "
      <> path
      <> ": no progress for "
      <> int_text(timeout_ms)
      <> "ms"
    RequestAborted -> "The request was aborted"
    NetworkError(reason) -> "Network error: " <> reason
    MalformedMessage(cause) -> "Received malformed message: " <> cause
    InvalidArgument(message) -> "Invalid argument: " <> message
  }
}

/// The failure's text, as the Dart exception's `toString` reads (for logs).
pub fn to_string(error: DuvetError) -> String {
  case error {
    ApiError(failure) ->
      "DuvetApiException["
      <> int_text(failure.status_code)
      <> "]: "
      <> message(error)
      <> "\n"
      <> body_text(failure.body)
    AuthError(failure) ->
      "DuvetAuthException["
      <> int_text(failure.status_code)
      <> "]: "
      <> message(error)
      <> "\n"
      <> body_text(failure.body)
    _ -> message(error)
  }
}

fn body_text(body: Option(String)) -> String {
  case body {
    Some(text) -> text
    None -> ""
  }
}

fn int_text(value: Int) -> String {
  int.to_string(value)
}

pub fn is_timeout(error: DuvetError) -> Bool {
  case error {
    RequestTimeout(..) -> True
    _ -> False
  }
}

pub fn is_aborted(error: DuvetError) -> Bool {
  case error {
    RequestAborted -> True
    _ -> False
  }
}

pub fn status_code(error: DuvetError) -> Option(Int) {
  case error {
    ApiError(failure) -> Some(failure.status_code)
    AuthError(failure) -> Some(failure.status_code)
    _ -> None
  }
}
