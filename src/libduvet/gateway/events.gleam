import gleam/erlang/process.{type Subject}
import gleam/order
import gleam/time/duration
import gleam/time/timestamp
import libduvet/gateway/feed.{
  type FeedMessage, type GatewayConnectFailure, type GatewayConnectionState,
  Closed, ConnectFailed, Payload, Resumed, StateChanged,
}
import libduvet/model/envelope
import libduvet/model/event
import libduvet/model/ready

/// A listener's own subject, as `feed.subscribe` makes it.
pub type Listener =
  Subject(FeedMessage)

/// Typed ways to wait for what a client publishes, the counterpart of the
/// Dart package's `GatewayEvents` streams. Each call drops what it isn't
/// waiting for, so use one listener per kind (or read the feed with [next]).
pub fn await_payload(
  listener: Listener,
  timeout_ms: Int,
) -> Result(envelope.GatewayEventPayload, Nil) {
  await_matching(listener, timeout_ms, fn(message) {
    case message {
      Payload(payload) -> Ok(payload)
      _ -> Error(Nil)
    }
  })
}

pub fn await_ready(
  listener: Listener,
  timeout_ms: Int,
) -> Result(ready.GatewayReadyData, Nil) {
  await_matching(listener, timeout_ms, fn(message) {
    case message {
      Payload(envelope.ReadyEvent(data)) -> Ok(data)
      _ -> Error(Nil)
    }
  })
}

pub fn await_message_delete(
  listener: Listener,
  timeout_ms: Int,
) -> Result(event.GatewayMessageDelete, Nil) {
  await_matching(listener, timeout_ms, fn(message) {
    case message {
      Payload(envelope.MessageDeletedEvent(data)) -> Ok(data)
      _ -> Error(Nil)
    }
  })
}

pub fn await_call_incoming(
  listener: Listener,
  timeout_ms: Int,
) -> Result(event.CallIncomingEvent, Nil) {
  await_matching(listener, timeout_ms, fn(message) {
    case message {
      Payload(envelope.CallIncomingPayloadEvent(data)) -> Ok(data)
      _ -> Error(Nil)
    }
  })
}

pub fn await_call_outgoing(
  listener: Listener,
  timeout_ms: Int,
) -> Result(event.CallOutgoingEvent, Nil) {
  await_matching(listener, timeout_ms, fn(message) {
    case message {
      Payload(envelope.CallOutgoingPayloadEvent(data)) -> Ok(data)
      _ -> Error(Nil)
    }
  })
}

pub fn await_call_ongoing(
  listener: Listener,
  timeout_ms: Int,
) -> Result(event.CallOngoingEvent, Nil) {
  await_matching(listener, timeout_ms, fn(message) {
    case message {
      Payload(envelope.CallOngoingPayloadEvent(data)) -> Ok(data)
      _ -> Error(Nil)
    }
  })
}

pub fn await_call_ended(
  listener: Listener,
  timeout_ms: Int,
) -> Result(event.CallEndedEvent, Nil) {
  await_matching(listener, timeout_ms, fn(message) {
    case message {
      Payload(envelope.CallEndedPayloadEvent(data)) -> Ok(data)
      _ -> Error(Nil)
    }
  })
}

pub fn await_voice_video_refused(
  listener: Listener,
  timeout_ms: Int,
) -> Result(event.VoiceVideoRefusedEvent, Nil) {
  await_matching(listener, timeout_ms, fn(message) {
    case message {
      Payload(envelope.VoiceVideoRefusedPayloadEvent(data)) -> Ok(data)
      _ -> Error(Nil)
    }
  })
}

pub fn await_voice_state_update(
  listener: Listener,
  timeout_ms: Int,
) -> Result(event.VoiceStateEvent, Nil) {
  await_matching(listener, timeout_ms, fn(message) {
    case message {
      Payload(envelope.VoiceStateUpdatedEvent(data)) -> Ok(data)
      _ -> Error(Nil)
    }
  })
}

pub fn await_state(
  listener: Listener,
  timeout_ms: Int,
) -> Result(GatewayConnectionState, Nil) {
  await_matching(listener, timeout_ms, fn(message) {
    case message {
      StateChanged(state) -> Ok(state)
      _ -> Error(Nil)
    }
  })
}

pub fn await_resumed(listener: Listener, timeout_ms: Int) -> Result(Int, Nil) {
  await_matching(listener, timeout_ms, fn(message) {
    case message {
      Resumed(shard_id) -> Ok(shard_id)
      _ -> Error(Nil)
    }
  })
}

pub fn await_close(
  listener: Listener,
  timeout_ms: Int,
) -> Result(envelope.GatewayCloseReason, Nil) {
  await_matching(listener, timeout_ms, fn(message) {
    case message {
      Closed(close) -> Ok(close)
      _ -> Error(Nil)
    }
  })
}

pub fn await_failure(
  listener: Listener,
  timeout_ms: Int,
) -> Result(GatewayConnectFailure, Nil) {
  await_matching(listener, timeout_ms, fn(message) {
    case message {
      ConnectFailed(failure) -> Ok(failure)
      _ -> Error(Nil)
    }
  })
}

/// The next message, whatever it is.
pub fn next(listener: Listener, timeout_ms: Int) -> Result(FeedMessage, Nil) {
  process.receive(listener, timeout_ms)
}

fn await_matching(
  listener: Listener,
  timeout_ms: Int,
  matches: fn(FeedMessage) -> Result(a, Nil),
) -> Result(a, Nil) {
  let deadline =
    timestamp.add(timestamp.system_time(), duration.milliseconds(timeout_ms))
  await_loop(listener, deadline, matches)
}

fn await_loop(
  listener: Listener,
  deadline: timestamp.Timestamp,
  matches: fn(FeedMessage) -> Result(a, Nil),
) -> Result(a, Nil) {
  let left = remaining_ms(deadline)
  case left <= 0 {
    True -> Error(Nil)
    False ->
      case process.receive(listener, left) {
        Error(Nil) -> Error(Nil)
        Ok(message) ->
          case matches(message) {
            Ok(value) -> Ok(value)
            Error(Nil) -> await_loop(listener, deadline, matches)
          }
      }
  }
}

fn remaining_ms(deadline: timestamp.Timestamp) -> Int {
  let left = timestamp.difference(timestamp.system_time(), deadline)
  case duration.compare(left, duration.milliseconds(0)) {
    order.Gt -> duration.to_milliseconds(left)
    _ -> 0
  }
}
