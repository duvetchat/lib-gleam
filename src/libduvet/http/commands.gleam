import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import libduvet/model/rest

/// The space-command lists the client keeps for a few minutes, so that a room
/// full of command uses doesn't fetch them every time.
pub opaque type Cache {
  Cache(subject: Subject(Message))
}

type Message {
  Get(
    space_id: String,
    now: Timestamp,
    reply: Subject(Option(rest.SpaceCommands)),
  )
  Put(
    space_id: String,
    at: Timestamp,
    list: rest.SpaceCommands,
    reply: Subject(Nil),
  )
  Forget(space_id: String, reply: Subject(Nil))
  Clear(reply: Subject(Nil))
}

const ttl_ms = 300_000

type Entry {
  Entry(at: Timestamp, list: rest.SpaceCommands)
}

pub fn start() -> Cache {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(dict.new(), subject)
    })
  Cache(process.receive_forever(ready))
}

pub fn get(
  cache: Cache,
  space_id: String,
  now: Timestamp,
) -> Option(rest.SpaceCommands) {
  let reply = process.new_subject()
  process.send(cache.subject, Get(space_id, now, reply))
  process.receive_forever(reply)
}

pub fn put(
  cache: Cache,
  space_id: String,
  at: Timestamp,
  list: rest.SpaceCommands,
) -> Nil {
  let reply = process.new_subject()
  process.send(cache.subject, Put(space_id, at, list, reply))
  process.receive_forever(reply)
}

pub fn forget(cache: Cache, space_id: String) -> Nil {
  let reply = process.new_subject()
  process.send(cache.subject, Forget(space_id, reply))
  process.receive_forever(reply)
}

pub fn clear(cache: Cache) -> Nil {
  let reply = process.new_subject()
  process.send(cache.subject, Clear(reply))
  process.receive_forever(reply)
}

fn loop(entries: dict.Dict(String, Entry), subject: Subject(Message)) -> Nil {
  case process.receive_forever(subject) {
    Get(space_id, now, reply) -> {
      let entry = dict.get(entries, space_id)
      let fresh = case entry {
        Ok(entry) ->
          timestamp.difference(entry.at, now)
          |> duration.compare(duration.milliseconds(ttl_ms))
          == order.Lt
        Error(Nil) -> False
      }
      case entry, fresh {
        Ok(entry), True -> {
          process.send(reply, Some(entry.list))
          loop(entries, subject)
        }
        _, _ -> {
          process.send(reply, None)
          loop(dict.delete(entries, space_id), subject)
        }
      }
    }
    Put(space_id, at, list, reply) -> {
      process.send(reply, Nil)
      loop(dict.insert(entries, space_id, Entry(at: at, list: list)), subject)
    }
    Forget(space_id, reply) -> {
      process.send(reply, Nil)
      loop(dict.delete(entries, space_id), subject)
    }
    Clear(reply) -> {
      process.send(reply, Nil)
      loop(dict.new(), subject)
    }
  }
}
