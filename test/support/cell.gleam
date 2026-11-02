import gleam/erlang/process.{type Subject}

/// A value a test's closures can share and change, like a mutable cell.
pub opaque type Cell(a) {
  Cell(subject: Subject(Message(a)))
}

type Message(a) {
  Get(reply: Subject(a))
  Update(change: fn(a) -> a, reply: Subject(Nil))
}

pub fn new(value: a) -> Cell(a) {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(value, subject)
    })
  Cell(process.receive_forever(ready))
}

pub fn get(cell: Cell(a)) -> a {
  let reply = process.new_subject()
  process.send(cell.subject, Get(reply))
  process.receive_forever(reply)
}

pub fn update(cell: Cell(a), change: fn(a) -> a) -> Nil {
  let reply = process.new_subject()
  process.send(cell.subject, Update(change, reply))
  process.receive_forever(reply)
}

fn loop(value: a, subject: Subject(Message(a))) -> Nil {
  case process.receive_forever(subject) {
    Get(reply) -> {
      process.send(reply, value)
      loop(value, subject)
    }
    Update(change, reply) -> {
      process.send(reply, Nil)
      loop(change(value), subject)
    }
  }
}
