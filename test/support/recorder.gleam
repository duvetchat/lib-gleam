import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/order
import gleam/time/duration
import gleam/time/timestamp
import libduvet/gateway/feed.{type Feed, type FeedMessage}

/// Records everything a feed publishes, in order, so a test can assert the
/// order a listener hears things in.
pub opaque type Recorder {
  Recorder(subject: Subject(Message))
}

type Message {
  Record(FeedMessage)
  Messages(reply: Subject(List(FeedMessage)))
}

pub fn start(feed: Feed) -> Recorder {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let listener = feed.subscribe(feed)
      let subject = process.new_subject()
      process.send(ready, subject)
      collect(listener, subject, [])
    })
  Recorder(process.receive_forever(ready))
}

fn collect(
  listener: Subject(FeedMessage),
  subject: Subject(Message),
  messages: List(FeedMessage),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(listener, Record)
    |> process.select(subject)
  case process.selector_receive_forever(selector) {
    Record(message) -> collect(listener, subject, [message, ..messages])
    Messages(reply) -> {
      process.send(reply, list.reverse(messages))
      collect(listener, subject, messages)
    }
  }
}

pub fn messages(recorder: Recorder) -> List(FeedMessage) {
  let reply = process.new_subject()
  process.send(recorder.subject, Messages(reply))
  process.receive_forever(reply)
}

/// Waits until a message matching [wanted] came, then returns every message
/// recorded so far.
pub fn until(
  recorder: Recorder,
  timeout_ms: Int,
  wanted: fn(FeedMessage) -> Bool,
) -> List(FeedMessage) {
  let deadline =
    timestamp.add(timestamp.system_time(), duration.milliseconds(timeout_ms))
  until_loop(recorder, deadline, wanted)
}

/// Waits until everything recorded so far satisfies [done].
pub fn poll_until(
  recorder: Recorder,
  timeout_ms: Int,
  done: fn(List(FeedMessage)) -> Bool,
) -> List(FeedMessage) {
  let deadline =
    timestamp.add(timestamp.system_time(), duration.milliseconds(timeout_ms))
  poll_loop(recorder, deadline, done)
}

fn poll_loop(
  recorder: Recorder,
  deadline: timestamp.Timestamp,
  done: fn(List(FeedMessage)) -> Bool,
) -> List(FeedMessage) {
  let all = messages(recorder)
  case done(all) {
    True -> all
    False -> {
      let left = remaining_ms(deadline)
      case left <= 0 {
        True -> all
        False -> {
          process.sleep(10)
          poll_loop(recorder, deadline, done)
        }
      }
    }
  }
}

fn until_loop(
  recorder: Recorder,
  deadline: timestamp.Timestamp,
  wanted: fn(FeedMessage) -> Bool,
) -> List(FeedMessage) {
  let all = messages(recorder)
  case list.any(all, wanted) {
    True -> all
    False -> {
      let left = remaining_ms(deadline)
      case left <= 0 {
        True -> all
        False -> {
          process.sleep(10)
          until_loop(recorder, deadline, wanted)
        }
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
