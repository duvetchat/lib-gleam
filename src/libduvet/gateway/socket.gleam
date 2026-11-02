import gleam/erlang/process.{type Pid, type Subject}

/// One frame of the gateway's, as it came.
pub type Frame {
  /// A text frame: every event the gateway sends is one of these, as JSON.
  TextFrame(String)
  /// A binary frame, which the gateway doesn't send today.
  BinaryFrame(BitArray)
  /// The gateway closed the socket, saying why.
  CloseFrame(code: Int, reason: String)
  /// The socket closed without a close frame.
  SocketClosed
  Ping
  Pong
}

/// Why opening a socket didn't work.
pub type ConnectError {
  /// The gateway refused the upgrade with this HTTP status: 401 for a token
  /// it doesn't know, 503 while it can't check tokens yet.
  HttpError(status: Int)
  /// Opening took longer than the connect timeout.
  Timeout
  /// No network, a dropped connection, or another failure below HTTP.
  Network(reason: String)
}

/// What the socket tells its owner.
pub type Event {
  /// The upgrade is done: the socket can send.
  Opened
  /// It didn't open.
  OpenFailed(error: ConnectError)
  /// The frames of one read, in the order the gateway wrote them. Frames
  /// written in one burst come in one of these, so the order between them is
  /// kept as a single unit.
  Frames(frames: List(Frame))
  /// The socket failed below the WebSocket protocol.
  SocketError(reason: String)
}

/// A WebSocket socket to the gateway, owned by a process of its own that
/// forwards what it reads to [events]. The owner stops, closing the socket,
/// when the process that created the socket exits.
pub opaque type Socket {
  Socket(pid: Pid, events: Subject(Event))
}

/// Starts opening a socket. The answer comes on [events]: [Opened], or
/// [OpenFailed]. [timeout_ms] bounds each wait at the socket level; the caller
/// bounds the whole upgrade itself with [kill].
pub fn start(
  url: String,
  headers: List(#(String, String)),
  timeout_ms: Int,
) -> Socket {
  let events = process.new_subject()
  let pid = ffi_ws_start(url, headers, timeout_ms, events)
  Socket(pid: pid, events: events)
}

pub fn events(socket: Socket) -> Subject(Event) {
  socket.events
}

/// Sends one text frame: whether it went out.
pub fn send(socket: Socket, text: String) -> Bool {
  case ffi_ws_send(socket.pid, text) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Closes the socket, as the protocol asks.
pub fn close(socket: Socket) -> Nil {
  ffi_ws_close(socket.pid, 1000, "")
}

/// Drops the socket at once: what a connect timeout does to an attempt that
/// hasn't opened yet.
pub fn kill(socket: Socket) -> Nil {
  process.kill(socket.pid)
}

/// The next event, if one comes within [timeout_ms].
pub fn next_event(socket: Socket, timeout_ms: Int) -> Result(Event, Nil) {
  process.receive(socket.events, timeout_ms)
}

@external(erlang, "duvet_hackney_ffi", "ws_start")
fn ffi_ws_start(
  url: String,
  headers: List(#(String, String)),
  timeout: Int,
  events: Subject(Event),
) -> Pid

@external(erlang, "duvet_hackney_ffi", "ws_send")
fn ffi_ws_send(pid: Pid, text: String) -> Result(Nil, String)

@external(erlang, "duvet_hackney_ffi", "ws_close")
fn ffi_ws_close(pid: Pid, code: Int, reason: String) -> Nil
