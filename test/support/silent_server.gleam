import gleam/erlang/process.{type Pid}

/// A server on 127.0.0.1 for the timeout tests: see duvet_silent_server.erl.
pub type Server =
  Pid

/// Takes connections and never answers; while [reading] is false it doesn't
/// read either, so what a client sends backs up.
@external(erlang, "duvet_silent_server", "start")
pub fn start(reading: Bool) -> Server

/// Reads a request's body a piece at a time, 5ms apart, then answers [body].
@external(erlang, "duvet_silent_server", "start_slow")
pub fn start_slow(body: String) -> Server

@external(erlang, "duvet_silent_server", "port")
pub fn port(server: Server) -> Int

/// Waits until a client closes its connection.
@external(erlang, "duvet_silent_server", "dropped")
pub fn dropped(server: Server) -> Nil

/// Reads again what's waiting.
@external(erlang, "duvet_silent_server", "resume")
pub fn resume(server: Server) -> Nil

/// The bytes of the request body read so far.
@external(erlang, "duvet_silent_server", "received")
pub fn received(server: Server) -> Int

@external(erlang, "duvet_silent_server", "stop")
pub fn stop(server: Server) -> Nil
