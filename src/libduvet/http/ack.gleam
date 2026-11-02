import gleam/dict
import gleam/erlang/process.{type Subject, type Timer}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string

/// Read acks go out at most once per room or conversation every
/// [ack_interval]: reading a busy room would otherwise send one per message.
/// The first goes out at once; later ones within the interval merge into one
/// trailing ack with the newest message ID. IDs are UUIDv7, so they compare by
/// time as strings.
pub const ack_interval = 3000

/// Wraps a send so each key gets at most one ack per interval, never one older
/// than what was sent.
pub opaque type AckThrottle {
  AckThrottle(subject: Subject(Message))
}

type Message {
  Ack(key: String, message_id: String, reply: Subject(Nil))
  Flush(key: String)
  Dispose(reply: Subject(Nil))
}

type State {
  State(
    sent_id: Option(String),
    sent_at: Option(Int),
    pending_id: Option(String),
    timer: Option(Timer),
  )
}

/// Starts the throttle; [send] performs an ack, and its failures are the
/// caller's to swallow.
pub fn start(send: fn(String, String) -> Nil) -> AckThrottle {
  let ready = process.new_subject()
  let _pid =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(send, dict.new(), subject)
    })
  AckThrottle(process.receive_forever(ready))
}

/// Records an ack, sending it now or merging it with the next one.
pub fn ack(throttle: AckThrottle, key: String, message_id: String) -> Nil {
  let reply = process.new_subject()
  process.send(throttle.subject, Ack(key, message_id, reply))
  process.receive_forever(reply)
}

/// Cancels the trailing acks still waiting.
pub fn dispose(throttle: AckThrottle) -> Nil {
  let reply = process.new_subject()
  process.send(throttle.subject, Dispose(reply))
  process.receive_forever(reply)
}

fn loop(
  send: fn(String, String) -> Nil,
  states: dict.Dict(String, State),
  subject: Subject(Message),
) -> Nil {
  case process.receive_forever(subject) {
    Ack(key, message_id, reply) -> {
      let state = case dict.get(states, key) {
        Ok(state) -> state
        Error(Nil) ->
          State(sent_id: None, sent_at: None, pending_id: None, timer: None)
      }
      let pending_id = newest(state.pending_id, message_id)
      let state =
        State(
          sent_id: state.sent_id,
          sent_at: state.sent_at,
          pending_id: pending_id,
          timer: state.timer,
        )
      case state.timer {
        Some(_) -> {
          process.send(reply, Nil)
          loop(send, dict.insert(states, key, state), subject)
        }
        None -> {
          let wait = case state.sent_at {
            None -> 0
            Some(sent_at) -> sent_at + ack_interval - now_ms()
          }
          case wait <= 0 {
            True -> {
              let state = flush(send, key, state)
              process.send(reply, Nil)
              loop(send, dict.insert(states, key, state), subject)
            }
            False -> {
              let timer = process.send_after(subject, wait, Flush(key))
              let state =
                State(
                  sent_id: state.sent_id,
                  sent_at: state.sent_at,
                  pending_id: state.pending_id,
                  timer: Some(timer),
                )
              process.send(reply, Nil)
              loop(send, dict.insert(states, key, state), subject)
            }
          }
        }
      }
    }
    Flush(key) -> {
      let state = case dict.get(states, key) {
        Ok(state) -> state
        Error(Nil) ->
          State(sent_id: None, sent_at: None, pending_id: None, timer: None)
      }
      let state =
        State(
          sent_id: state.sent_id,
          sent_at: state.sent_at,
          pending_id: state.pending_id,
          timer: None,
        )
      let state = flush(send, key, state)
      loop(send, dict.insert(states, key, state), subject)
    }
    Dispose(reply) -> {
      states
      |> dict.values
      |> list.each(fn(state) {
        case state.timer {
          Some(timer) -> {
            let _ = process.cancel_timer(timer)
            Nil
          }
          None -> Nil
        }
      })
      process.send(reply, Nil)
      loop(send, dict.new(), subject)
    }
  }
}

fn flush(send: fn(String, String) -> Nil, key: String, state: State) -> State {
  case state.pending_id {
    None -> state
    Some(id) -> {
      let send_now = case state.sent_id {
        Some(sent) ->
          case string.compare(id, sent) {
            order.Gt -> True
            _ -> False
          }
        None -> True
      }
      case send_now {
        False -> state
        True -> {
          send(key, id)
          State(
            sent_id: Some(id),
            sent_at: Some(now_ms()),
            pending_id: None,
            timer: None,
          )
        }
      }
    }
  }
}

fn newest(pending: Option(String), message_id: String) -> Option(String) {
  case pending {
    None -> Some(message_id)
    Some(current) ->
      case string.compare(message_id, current) {
        order.Gt -> Some(message_id)
        _ -> Some(current)
      }
  }
}

@external(erlang, "duvet_json_ffi", "now_ms")
fn now_ms() -> Int
