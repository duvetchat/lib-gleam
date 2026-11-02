import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option}
import libduvet/model/envelope

/// Where a gateway connection is.
pub type GatewayConnectionState {
  /// Opening the first socket.
  Connecting
  /// A socket is open and the client identified on it; READY follows, or,
  /// when the gateway resumes the session, the events it missed and
  /// [FeedMessage.Resumed].
  Connected
  /// The socket closed, or couldn't open, and the client is opening another.
  Reconnecting
  /// No socket, and none opening: before connecting, after a connect that
  /// failed with nothing trying again, after the gateway refused the shard,
  /// or once destroyed.
  Disconnected
}

/// An attempt to open a socket to the gateway that failed.
pub type GatewayConnectFailure {
  GatewayConnectFailure(
    /// The shard that tried: 0 without sharding.
    shard_id: Int,
    /// How many attempts in a row failed, this one included, since a socket
    /// last opened: 1 for the first.
    failures: Int,
    /// The HTTP status the gateway refused the upgrade with, when it answered.
    http_status: Option(Int),
    /// What stopped it.
    error: String,
  )
}

/// What a gateway client tells its listeners.
pub type FeedMessage {
  /// A decoded event from the gateway, including READY.
  Payload(payload: envelope.GatewayEventPayload)
  /// A frame exactly as the gateway sent it: what a client that decodes events
  /// itself (a bot, say) reads, without this package's models in between.
  RawFrame(text: String)
  /// Something the client couldn't read.
  Malformed(cause: String)
  /// The connection's state changed.
  StateChanged(state: GatewayConnectionState)
  /// The gateway resumed a shard's session on a new socket.
  Resumed(shard_id: Int)
  /// The reason the gateway gave before it closed the socket.
  Closed(close: envelope.GatewayCloseReason)
  /// An attempt to open a socket failed.
  ConnectFailed(failure: GatewayConnectFailure)
  /// The client was destroyed; no other message comes.
  FeedClosed
}

/// One ordered feed for every listener: what its client or manager publishes
/// reaches all of them, in the order it was published.
pub opaque type Feed {
  Feed(subject: Subject(Message))
}

type Message {
  Subscribe(who: Subject(FeedMessage), reply: Subject(Nil))
  Publish(message: FeedMessage)
  Close(reply: Subject(Nil))
}

pub fn start() -> Feed {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop([], subject)
    })
  Feed(process.receive_forever(ready))
}

/// A subject of its own for one listener, registered before this returns, so
/// nothing published after it is missed. The caller owns it.
pub fn subscribe(feed: Feed) -> Subject(FeedMessage) {
  let who = process.new_subject()
  let reply = process.new_subject()
  process.send(feed.subject, Subscribe(who, reply))
  process.receive_forever(reply)
  who
}

/// Publishes to every listener; returns at once.
pub fn publish(feed: Feed, message: FeedMessage) -> Nil {
  process.send(feed.subject, Publish(message))
}

/// Sends [FeedClosed] to every listener and forgets them.
pub fn close(feed: Feed) -> Nil {
  let reply = process.new_subject()
  process.send(feed.subject, Close(reply))
  process.receive_forever(reply)
}

fn loop(
  subscribers: List(Subject(FeedMessage)),
  subject: Subject(Message),
) -> Nil {
  case process.receive_forever(subject) {
    Subscribe(who, reply) -> {
      process.send(reply, Nil)
      loop([who, ..subscribers], subject)
    }
    Publish(message) -> {
      list.each(subscribers, fn(who) { process.send(who, message) })
      loop(subscribers, subject)
    }
    Close(reply) -> {
      list.each(subscribers, fn(who) { process.send(who, FeedClosed) })
      process.send(reply, Nil)
      loop([], subject)
    }
  }
}
