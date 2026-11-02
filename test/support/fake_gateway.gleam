import gleam/erlang/process.{type Pid}

/// The test's gateway on 127.0.0.1: see duvet_fake_gateway.erl.
pub type Server =
  Pid

/// What to do with the next upgrade request.
pub type Answer {
  Upgrade
  Refuse(status: Int)
  Hold
}

/// A frame to write raw, for bursts the gateway writes in one write.
pub type RawFrame {
  RawText(json: String)
  RawClose(code: Int)
}

@external(erlang, "duvet_fake_gateway", "start")
pub fn start() -> Server

@external(erlang, "duvet_fake_gateway", "port")
pub fn port(server: Server) -> Int

@external(erlang, "duvet_fake_gateway", "stop")
pub fn stop(server: Server) -> Nil

@external(erlang, "duvet_fake_gateway", "set_plan")
pub fn set_plan(server: Server, plan: List(Answer)) -> Nil

/// Each upgrade request's token, in order.
@external(erlang, "duvet_fake_gateway", "tokens")
pub fn tokens(server: Server) -> List(String)

/// When each upgrade request came, in milliseconds.
@external(erlang, "duvet_fake_gateway", "token_times")
pub fn token_times(server: Server) -> List(Int)

/// The identify payloads, in order, as JSON.
@external(erlang, "duvet_fake_gateway", "identified")
pub fn identified(server: Server) -> List(String)

@external(erlang, "duvet_fake_gateway", "wait_identifies")
pub fn wait_identifies(server: Server, count: Int) -> Nil

@external(erlang, "duvet_fake_gateway", "open_count")
pub fn open_count(server: Server) -> Int

@external(erlang, "duvet_fake_gateway", "most_open")
pub fn most_open(server: Server) -> Int

@external(erlang, "duvet_fake_gateway", "connection_count")
pub fn connection_count(server: Server) -> Int

/// Pushes an event into the current session, with its next sequence number.
@external(erlang, "duvet_fake_gateway", "push")
pub fn push(server: Server, event_type: String, data_json: String) -> Nil

/// Sends an event with no sequence number, on the open socket only.
@external(erlang, "duvet_fake_gateway", "push_bare")
pub fn push_bare(server: Server, event_type: String, data_json: String) -> Nil

/// Closes the socket with no close frame, as a network failure does.
@external(erlang, "duvet_fake_gateway", "drop")
pub fn drop(server: Server) -> Nil

/// Says why, then closes the socket, as SendCloseReason does.
@external(erlang, "duvet_fake_gateway", "close_with_reason")
pub fn close_with_reason(server: Server, code: Int, reason: String) -> Nil

/// Writes the frames in one write.
@external(erlang, "duvet_fake_gateway", "write_batch")
pub fn write_batch(server: Server, frames: List(RawFrame)) -> Nil

@external(erlang, "duvet_fake_gateway", "set_resumes")
pub fn set_resumes(server: Server, resumes: Bool) -> Nil

@external(erlang, "duvet_fake_gateway", "set_answers_resumes")
pub fn set_answers_resumes(server: Server, answers: Bool) -> Nil

@external(erlang, "duvet_fake_gateway", "heartbeats")
pub fn heartbeats(server: Server) -> Int

@external(erlang, "duvet_fake_gateway", "wait_heartbeats")
pub fn wait_heartbeats(server: Server, count: Int) -> Nil
