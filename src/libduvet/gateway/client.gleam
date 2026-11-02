import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import libduvet/api_router
import libduvet/gateway/feed.{
  type Feed, type GatewayConnectFailure, type GatewayConnectionState, Closed,
  ConnectFailed, Connected, Connecting, Disconnected, Malformed, Payload,
  RawFrame, Reconnecting, Resumed, StateChanged,
}
import libduvet/gateway/socket
import libduvet/http/client
import libduvet/http/core
import libduvet/model/client_platform
import libduvet/model/decoding
import libduvet/model/envelope

/// How long opening a socket to the gateway may take before the attempt is
/// dropped: 15 seconds.
pub const default_connect_timeout = 15_000

const heartbeat_interval_ms = 45_000

const heartbeat_ack_timeout_ms = 15_000

const first_reconnect_delay_ms = 1000

const max_reconnect_delay_ms = 30_000

/// How long the client waits before it opens another socket, after [failed]
/// attempts in a row failed to open one (none when an open socket dropped):
/// a second, doubling with each failure, up to 30, plus up to a second at
/// random, so that clients don't all come back at once.
pub fn reconnect_delay(failed: Int, jitter_ms: Int) -> Int {
  let doubled = doubled_delay(failed)
  let base = int.min(doubled, max_reconnect_delay_ms)
  base + int.min(jitter_ms, 999)
}

fn doubled_delay(failed: Int) -> Int {
  case failed {
    0 -> first_reconnect_delay_ms
    1 -> 2000
    2 -> 4000
    3 -> 8000
    4 -> 16_000
    _ -> 32_000
  }
}

fn random_jitter_ms() -> Int {
  float.truncate(float.random() *. 1000.0)
}

/// How a gateway client is set up.
pub type Config {
  Config(
    api: client.RestClient,
    router: api_router.ApiRouter,
    shard_id: Int,
    shard_count: Int,
    connect_timeout: Int,
    resume: Bool,
    platform: Option(client_platform.ClientPlatform),
    log: fn(String) -> Nil,
    feed: Feed,
  )
}

pub fn config(api: client.RestClient, feed: Feed) -> Config {
  Config(
    api: api,
    router: api_router.default_router(),
    shard_id: 0,
    shard_count: 1,
    connect_timeout: default_connect_timeout,
    resume: False,
    platform: None,
    log: fn(_message) { Nil },
    feed: feed,
  )
}

pub fn with_router(config: Config, router: api_router.ApiRouter) -> Config {
  Config(..config, router: router)
}

pub fn with_shard(config: Config, shard_id: Int, shard_count: Int) -> Config {
  Config(..config, shard_id: shard_id, shard_count: shard_count)
}

pub fn with_connect_timeout(config: Config, timeout_ms: Int) -> Config {
  Config(..config, connect_timeout: timeout_ms)
}

pub fn with_resume(config: Config, resume: Bool) -> Config {
  Config(..config, resume: resume)
}

pub fn with_platform(
  config: Config,
  platform: client_platform.ClientPlatform,
) -> Config {
  Config(..config, platform: Some(platform))
}

pub fn with_log(config: Config, log: fn(String) -> Nil) -> Config {
  Config(..config, log: log)
}

/// Why a connect call ended without a socket.
pub type ConnectFailure {
  /// Another attempt replaced this one, or the client was destroyed.
  Destroyed
  /// The attempt failed; see the failure.
  Failed(GatewayConnectFailure)
}

/// A single WebSocket connection to the gateway, kept by a process of its own.
/// It owns its heartbeat loop, reconnect logic and sequence tracking, and
/// tells its listeners through the feed it was given.
pub opaque type GatewayClient {
  GatewayClient(subject: Subject(Message))
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

type Message {
  Caller(command: Command)
  FromSocket(tagged: socket.Tagged)
}

type Command {
  Connect(reply: Subject(Result(Nil, ConnectFailure)))
  Tick(internal: Internal)
  Reconnect(reply: Subject(Bool))
  Destroy(reply: Subject(Nil))
  Send(type_: String, data: json.Json, reply: Subject(Bool))
  WantFreshSession
  RetryNow(reply: Subject(Bool))
  WaitForConnection(reply: Subject(Bool))
  GetState(reply: Subject(GatewayConnectionState))
  GetConnection(reply: Subject(Option(Int)))
  GetSilence(reply: Subject(Duration))
}

type Internal {
  HeartbeatTick(generation: Int)
  AckTimedOut(generation: Int)
  ConnectTimedOut(pid: process.Pid)
  RetryDue(generation: Int)
  ResumeSignal(pid: process.Pid)
}

// ---------------------------------------------------------------------------
// The client
// ---------------------------------------------------------------------------

type Engine {
  Engine(
    config: Config,
    command: Subject(Message),
    events: Subject(socket.Tagged),
    state: GatewayConnectionState,
    destroyed: Bool,
    socket: Option(socket.Socket),
    opening: Option(socket.Socket),
    connect_waiter: Option(Subject(Result(Nil, ConnectFailure))),
    reconnect_waiters: List(Subject(Bool)),
    wait_connection_waiters: List(Subject(Bool)),
    attempt: Int,
    await_ack: Bool,
    reconnect_attempts: Int,
    reconnecting: Bool,
    retry_pending: Bool,
    retry_generation: Int,
    last_seq: Int,
    session_token: Option(String),
    fresh_wanted: Bool,
    resuming: Bool,
    probing: Bool,
    resumed_from: Int,
    stopped: Bool,
    failures: Int,
    connections: Int,
    last_heard_at: Option(Timestamp),
    silence_before_ready: Duration,
    heartbeat_generation: Int,
    ack_generation: Int,
  )
}

pub fn start(config: Config) -> GatewayClient {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let command = process.new_subject()
      let events = process.new_subject()
      process.send(ready, command)
      let engine =
        Engine(
          config: config,
          command: command,
          events: events,
          state: Disconnected,
          destroyed: False,
          socket: None,
          opening: None,
          connect_waiter: None,
          reconnect_waiters: [],
          wait_connection_waiters: [],
          attempt: 0,
          await_ack: False,
          reconnect_attempts: 0,
          reconnecting: False,
          retry_pending: False,
          retry_generation: 0,
          last_seq: 0,
          session_token: None,
          fresh_wanted: False,
          resuming: False,
          probing: False,
          resumed_from: 0,
          stopped: False,
          failures: 0,
          connections: 0,
          last_heard_at: None,
          silence_before_ready: duration.seconds(0),
          heartbeat_generation: 0,
          ack_generation: 0,
        )
      loop(engine)
    })
  GatewayClient(process.receive_forever(ready))
}

fn loop(engine: Engine) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(engine.command)
    |> process.select_map(engine.events, FromSocket)
  loop2(engine, selector)
}

fn loop2(engine: Engine, selector: process.Selector(Message)) -> Nil {
  case process.selector_receive_forever(selector) {
    Caller(command) -> loop2(handle_command(engine, command), selector)
    FromSocket(tagged) -> loop2(handle_socket(engine, tagged), selector)
  }
}

fn handle_command(engine: Engine, command: Command) -> Engine {
  case command {
    Connect(reply) -> user_connect(engine, reply)
    Reconnect(reply) -> do_reconnect(engine, reply)
    Destroy(reply) -> {
      let engine = do_destroy(engine)
      process.send(reply, Nil)
      engine
    }
    Send(type_, data, reply) -> do_send_message(engine, type_, data, reply)
    Tick(internal) -> handle_internal(engine, internal)
    WantFreshSession -> Engine(..engine, fresh_wanted: True)
    RetryNow(reply) -> do_retry_now(engine, reply)
    WaitForConnection(reply) -> do_wait_for_connection(engine, reply)
    GetState(reply) -> {
      process.send(reply, engine.state)
      engine
    }
    GetConnection(reply) -> {
      process.send(reply, engine_connection(engine))
      engine
    }
    GetSilence(reply) -> {
      process.send(reply, engine.silence_before_ready)
      engine
    }
  }
}

// ---------------------------------------------------------------------------
// Public calls
// ---------------------------------------------------------------------------

/// Opens a socket and identifies on it, after closing the one open before.
pub fn connect(gateway: GatewayClient) -> Result(Nil, ConnectFailure) {
  let reply = process.new_subject()
  process.send(gateway.subject, Caller(Connect(reply)))
  process.receive_forever(reply)
}

/// Closes the socket, if one is open, and opens a new one: after a delay that
/// grows with each failed attempt, it tries until a socket opens or the client
/// is destroyed. Answers whether a socket opened.
pub fn reconnect(gateway: GatewayClient) -> Bool {
  call(gateway, fn(reply) { Reconnect(reply) })
}

pub fn destroy(gateway: GatewayClient) -> Nil {
  call(gateway, fn(reply) { Destroy(reply) })
}

/// Sends an event message, and answers whether it went out on an open socket.
pub fn send_message(
  gateway: GatewayClient,
  type_: String,
  data: json.Json,
) -> Bool {
  call(gateway, fn(reply) { Send(type_, data, reply) })
}

pub fn want_fresh_session(gateway: GatewayClient) -> Nil {
  process.send(gateway.subject, Caller(WantFreshSession))
}

pub fn retry_now(gateway: GatewayClient) -> Bool {
  call(gateway, fn(reply) { RetryNow(reply) })
}

pub fn wait_for_connection(gateway: GatewayClient) -> Bool {
  call(gateway, fn(reply) { WaitForConnection(reply) })
}

pub fn connection_state(gateway: GatewayClient) -> GatewayConnectionState {
  call(gateway, fn(reply) { GetState(reply) })
}

/// The number of the socket open now (they're counted from 1 as they open),
/// or None while none is.
pub fn connection(gateway: GatewayClient) -> Option(Int) {
  call(gateway, fn(reply) { GetConnection(reply) })
}

/// How long the gateway had been silent before the last READY.
pub fn silence_before_ready(gateway: GatewayClient) -> Duration {
  call(gateway, fn(reply) { GetSilence(reply) })
}

fn call(gateway: GatewayClient, message: fn(Subject(a)) -> Command) -> a {
  let reply = process.new_subject()
  process.send(gateway.subject, Caller(message(reply)))
  process.receive_forever(reply)
}

// ---------------------------------------------------------------------------
// Connecting
// ---------------------------------------------------------------------------

fn user_connect(
  engine: Engine,
  reply: Subject(Result(Nil, ConnectFailure)),
) -> Engine {
  case engine.destroyed {
    True -> {
      process.send(reply, Error(Destroyed))
      engine
    }
    False -> {
      let engine = Engine(..engine, stopped: False, retry_pending: False)
      start_attempt(engine, engine.reconnecting, Some(reply))
    }
  }
}

fn start_attempt(
  engine: Engine,
  reconnecting: Bool,
  reply: Option(Subject(Result(Nil, ConnectFailure))),
) -> Engine {
  let engine = close_socket(engine)
  let engine = case engine.opening {
    Some(opening) -> {
      socket.kill(opening)
      Engine(..engine, opening: None)
    }
    None -> engine
  }
  let engine = case reconnecting {
    True -> engine
    False -> set_state(engine, Connecting)
  }
  let token = client.token(engine.config.api)
  let url = stream_url(engine.config, token)
  log(engine, "connecting to " <> ws_authority(engine.config) <> "/gateway")
  let headers =
    core.auth_headers(
      token,
      client.session_token(engine.config.api),
      client.auth_mode(engine.config.api),
    )
  let opening =
    socket.start(url, headers, engine.config.connect_timeout, engine.events)
  let _ =
    process.send_after(
      engine.command,
      engine.config.connect_timeout,
      Caller(Tick(ConnectTimedOut(socket.pid(opening)))),
    )
  Engine(
    ..engine,
    attempt: engine.attempt + 1,
    opening: Some(opening),
    connect_waiter: reply,
    retry_pending: False,
  )
}

fn handle_socket(engine: Engine, tagged: socket.Tagged) -> Engine {
  let socket.Tagged(pid, event) = tagged
  let opening_matches = case engine.opening {
    Some(opening) -> socket.pid(opening) == pid
    None -> False
  }
  let socket_matches = case engine.socket {
    Some(socket) -> socket.pid(socket) == pid
    None -> False
  }
  case event {
    socket.Opened ->
      case opening_matches {
        True -> socket_opened(engine, pid)
        False -> engine
      }
    socket.OpenFailed(error) ->
      case opening_matches {
        True -> socket_failed(engine, error)
        False -> engine
      }
    socket.Frames(frames) ->
      case socket_matches {
        True -> list.fold(frames, engine, handle_frame)
        False -> engine
      }
    socket.SocketError(reason) ->
      case socket_matches {
        True -> dropped(engine, "socket error: " <> mask(engine, reason))
        False -> engine
      }
  }
}

fn socket_opened(engine: Engine, pid: process.Pid) -> Engine {
  let assert Some(opening) = engine.opening
  let _ = pid
  let engine =
    Engine(
      ..engine,
      opening: None,
      socket: Some(opening),
      connections: engine.connections + 1,
      reconnect_attempts: 0,
      failures: 0,
      reconnecting: False,
      retry_pending: False,
    )
  let engine = identify(engine)
  let engine = start_heartbeat(engine)
  let engine = set_state(engine, Connected)
  log(engine, "connected")
  resolve_connect(engine, Ok(Nil))
  resolve_reconnect(engine, True)
  resolve_wait_connection(engine, True)
}

fn socket_failed(engine: Engine, error: socket.ConnectError) -> Engine {
  match_socket_failure(engine, error)
}

fn match_socket_failure(engine: Engine, error: socket.ConnectError) -> Engine {
  let engine = Engine(..engine, opening: None, failures: engine.failures + 1)
  let http_status = case error {
    socket.HttpError(status) -> Some(status)
    _ -> None
  }
  let failure =
    feed.GatewayConnectFailure(
      shard_id: engine.config.shard_id,
      failures: engine.failures,
      http_status: http_status,
      error: connect_error_text(engine, error),
    )
  feed.publish(engine.config.feed, ConnectFailed(failure))
  log(engine, connect_error_text(engine, error))
  let engine = resolve_connect(engine, Error(Failed(failure)))
  case engine.reconnecting {
    True -> schedule_retry(engine)
    False -> set_state(engine, Disconnected)
  }
}

fn connect_error_text(engine: Engine, error: socket.ConnectError) -> String {
  case error {
    socket.Timeout -> "Timeout: the gateway did not take the socket"
    socket.HttpError(status) ->
      "the gateway refused the upgrade (HTTP status code: "
      <> int.to_string(status)
      <> ")"
    socket.Network(reason) -> "connect failed: " <> mask(engine, reason)
  }
}

fn resolve_connect(
  engine: Engine,
  result: Result(Nil, ConnectFailure),
) -> Engine {
  case engine.connect_waiter {
    Some(reply) -> process.send(reply, result)
    None -> Nil
  }
  Engine(..engine, connect_waiter: None)
}

fn resolve_reconnect(engine: Engine, opened: Bool) -> Engine {
  list.each(engine.reconnect_waiters, fn(reply) { process.send(reply, opened) })
  Engine(..engine, reconnect_waiters: [])
}

fn resolve_wait_connection(engine: Engine, connected: Bool) -> Engine {
  list.each(engine.wait_connection_waiters, fn(reply) {
    process.send(reply, connected)
  })
  Engine(..engine, wait_connection_waiters: [])
}

fn do_reconnect(engine: Engine, reply: Subject(Bool)) -> Engine {
  case engine.destroyed {
    True -> {
      process.send(reply, False)
      engine
    }
    False ->
      case engine.socket {
        Some(_) -> {
          process.send(reply, True)
          engine
        }
        None -> {
          let engine =
            Engine(..engine, reconnect_waiters: [
              reply,
              ..engine.reconnect_waiters
            ])
          case engine.retry_pending || engine.reconnecting {
            True -> engine
            False -> schedule_retry(engine)
          }
        }
      }
  }
}

fn schedule_retry(engine: Engine) -> Engine {
  let engine = set_state(engine, Reconnecting)
  let generation = engine.retry_generation + 1
  let delay = reconnect_delay(engine.reconnect_attempts, random_jitter_ms())
  log(
    engine,
    "reconnecting in "
      <> int.to_string(delay)
      <> "ms (attempt "
      <> int.to_string(engine.reconnect_attempts + 1)
      <> ")",
  )
  let _ =
    process.send_after(
      engine.command,
      delay,
      Caller(Tick(RetryDue(generation))),
    )
  Engine(
    ..engine,
    retry_generation: generation,
    retry_pending: True,
    reconnecting: True,
  )
}

fn do_retry_now(engine: Engine, reply: Subject(Bool)) -> Engine {
  case engine.destroyed || !engine.retry_pending {
    True -> {
      process.send(reply, False)
      engine
    }
    False -> {
      process.send(reply, True)
      let generation = engine.retry_generation + 1
      let _ = process.send(engine.command, Caller(Tick(RetryDue(generation))))
      Engine(..engine, retry_generation: generation, retry_pending: False)
    }
  }
}

fn do_wait_for_connection(engine: Engine, reply: Subject(Bool)) -> Engine {
  case engine.state {
    Connected -> {
      process.send(reply, True)
      engine
    }
    Disconnected ->
      case engine.destroyed {
        True -> {
          process.send(reply, False)
          engine
        }
        False ->
          Engine(..engine, wait_connection_waiters: [
            reply,
            ..engine.wait_connection_waiters
          ])
      }
    _ ->
      Engine(..engine, wait_connection_waiters: [
        reply,
        ..engine.wait_connection_waiters
      ])
  }
}

fn handle_internal(engine: Engine, internal: Internal) -> Engine {
  case internal {
    HeartbeatTick(generation) -> heartbeat_tick(engine, generation)
    AckTimedOut(generation) ->
      case generation == engine.ack_generation && engine.await_ack {
        True -> dropped(engine, "heartbeat ack timeout – closing")
        False -> engine
      }
    ConnectTimedOut(pid) ->
      case engine.opening {
        Some(opening) ->
          case socket.pid(opening) == pid {
            True -> {
              socket.kill(opening)
              match_socket_failure(engine, socket.Timeout)
            }
            False -> engine
          }
        None -> engine
      }
    RetryDue(generation) ->
      case engine.destroyed {
        True -> engine
        False ->
          case generation == engine.retry_generation {
            False -> engine
            True ->
              case engine.socket != None || engine.opening != None {
                True -> engine
                False -> {
                  let engine =
                    Engine(
                      ..engine,
                      retry_pending: False,
                      reconnect_attempts: engine.reconnect_attempts + 1,
                    )
                  start_attempt(engine, True, None)
                }
              }
          }
      }
    ResumeSignal(pid) ->
      case engine.socket {
        Some(socket) ->
          case socket.pid(socket) == pid {
            True -> {
              feed.publish(engine.config.feed, Resumed(engine.config.shard_id))
              engine
            }
            False -> engine
          }
        None -> engine
      }
  }
}

// ---------------------------------------------------------------------------
// Dropping and closing
// ---------------------------------------------------------------------------

fn dropped(engine: Engine, why: String) -> Engine {
  log(engine, why)
  let engine = close_socket(engine)
  case engine.destroyed {
    True -> engine
    False ->
      case engine.stopped {
        True -> {
          log(engine, "not reconnecting: the gateway refused the shard")
          set_state(engine, Disconnected)
        }
        False -> schedule_retry(engine)
      }
  }
}

fn close_socket(engine: Engine) -> Engine {
  let engine = stop_heartbeat(engine)
  let engine = Engine(..engine, probing: False)
  let engine = case engine.resuming {
    True -> {
      let keep = engine.last_seq == engine.resumed_from
      Engine(..engine, resuming: False, session_token: case keep {
        True -> engine.session_token
        False -> None
      })
    }
    False -> engine
  }
  case engine.socket {
    Some(socket) -> {
      socket.close(socket)
      Engine(..engine, socket: None)
    }
    None -> engine
  }
}

fn do_destroy(engine: Engine) -> Engine {
  case engine.destroyed {
    True -> engine
    False -> {
      let engine =
        Engine(..engine, destroyed: True, attempt: engine.attempt + 1)
      let engine = case engine.opening {
        Some(opening) -> {
          socket.kill(opening)
          Engine(..engine, opening: None)
        }
        None -> engine
      }
      let engine = close_socket(engine)
      let engine = set_state(engine, Disconnected)
      let engine = resolve_connect(engine, Error(Destroyed))
      let engine = resolve_reconnect(engine, False)
      let engine = resolve_wait_connection(engine, False)
      feed.close(engine.config.feed)
      log(engine, "destroyed")
      engine
    }
  }
}

// ---------------------------------------------------------------------------
// Heartbeats
// ---------------------------------------------------------------------------

fn start_heartbeat(engine: Engine) -> Engine {
  let engine = stop_heartbeat(engine)
  let generation = engine.heartbeat_generation
  let _ =
    process.send_after(
      engine.command,
      heartbeat_interval_ms,
      Caller(Tick(HeartbeatTick(generation))),
    )
  engine
}

fn stop_heartbeat(engine: Engine) -> Engine {
  Engine(
    ..engine,
    heartbeat_generation: engine.heartbeat_generation + 1,
    ack_generation: engine.ack_generation + 1,
    await_ack: False,
  )
}

fn heartbeat_tick(engine: Engine, generation: Int) -> Engine {
  case generation == engine.heartbeat_generation && engine.socket != None {
    False -> engine
    True ->
      case engine.await_ack {
        True -> dropped(engine, "missed heartbeat ack – closing")
        False -> {
          log(engine, "♥ heartbeat")
          let sent =
            send_on_socket(
              engine,
              json.object([
                #("type", json.string("heartbeat")),
                #("data", json.object([])),
              ]),
            )
          let engine = case sent {
            True -> Engine(..engine, await_ack: True)
            False -> engine
          }
          let ack_generation = engine.ack_generation + 1
          let _ =
            process.send_after(
              engine.command,
              heartbeat_ack_timeout_ms,
              Caller(Tick(AckTimedOut(ack_generation))),
            )
          let _ =
            process.send_after(
              engine.command,
              heartbeat_interval_ms,
              Caller(Tick(HeartbeatTick(engine.heartbeat_generation))),
            )
          Engine(..engine, ack_generation: ack_generation)
        }
      }
  }
}

fn on_ack(engine: Engine) -> Engine {
  let engine = case engine.resuming {
    True -> {
      log(
        engine,
        "session resumed (seq=" <> int.to_string(engine.last_seq) <> ")",
      )
      case engine.socket {
        Some(socket) ->
          process.send(
            engine.command,
            Caller(Tick(ResumeSignal(socket.pid(socket)))),
          )
        None -> Nil
      }
      Engine(..engine, resuming: False)
    }
    False -> engine
  }
  case engine.probing {
    True -> Engine(..engine, probing: False)
    False -> {
      let engine = Engine(..engine, await_ack: False)
      log(engine, "♥ ack")
      Engine(..engine, ack_generation: engine.ack_generation + 1)
    }
  }
}

// ---------------------------------------------------------------------------
// Identifying and sending
// ---------------------------------------------------------------------------

fn identify(engine: Engine) -> Engine {
  let token = client.token(engine.config.api)
  let resuming =
    engine.config.resume
    && engine.session_token != None
    && engine.last_seq > 0
    && !engine.fresh_wanted
  let data =
    json.object(
      list.flatten([
        [#("token", json.string(token))],
        case engine.last_seq > 0 {
          True -> [#("last_seq", json.int(engine.last_seq))]
          False -> []
        },
        case resuming, engine.session_token {
          True, Some(session_token) -> [
            #("session_token", json.string(session_token)),
          ]
          _, _ -> []
        },
        case engine.config.shard_count > 1 {
          True -> [
            #("shard_id", json.int(engine.config.shard_id)),
            #("num_shards", json.int(engine.config.shard_count)),
          ]
          False -> []
        },
        case engine.config.platform {
          Some(platform) -> [
            #("platform", json.string(client_platform.name(platform))),
          ]
          None -> []
        },
      ]),
    )
  let sent =
    send_on_socket(
      engine,
      json.object([#("type", json.string("identify")), #("data", data)]),
    )
  log(
    engine,
    "identify sent (shard="
      <> int.to_string(engine.config.shard_id)
      <> "/"
      <> int.to_string(engine.config.shard_count)
      <> ", seq="
      <> int.to_string(engine.last_seq)
      <> case resuming {
      True -> ", resuming"
      False -> ""
    }
      <> ")",
  )
  case resuming && sent {
    True -> {
      let probing =
        send_on_socket(
          engine,
          json.object([
            #("type", json.string("heartbeat")),
            #("data", json.object([])),
          ]),
        )
      Engine(
        ..engine,
        resuming: True,
        resumed_from: engine.last_seq,
        probing: probing,
      )
    }
    False -> engine
  }
}

fn do_send_message(
  engine: Engine,
  type_: String,
  data: json.Json,
  reply: Subject(Bool),
) -> Engine {
  let sent =
    send_on_socket(
      engine,
      json.object([#("type", json.string(type_)), #("data", data)]),
    )
  case sent {
    True -> Nil
    False ->
      log(
        engine,
        "cannot send \""
          <> type_
          <> "\" – socket not open (state: "
          <> state_name(engine.state)
          <> ")",
      )
  }
  process.send(reply, sent)
  engine
}

fn send_on_socket(engine: Engine, message: json.Json) -> Bool {
  case engine.socket {
    Some(socket) -> socket.send(socket, json.to_string(message))
    None -> False
  }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

fn handle_frame(engine: Engine, frame: socket.Frame) -> Engine {
  case frame {
    socket.TextFrame(text) -> handle_text(engine, text)
    socket.CloseFrame(code, reason) ->
      dropped(
        engine,
        "socket closed (" <> int.to_string(code) <> " " <> reason <> ")",
      )
    socket.SocketClosed -> dropped(engine, "socket closed")
    socket.Ping -> engine
    socket.Pong -> engine
    socket.BinaryFrame(_) -> engine
  }
}

fn handle_text(engine: Engine, text: String) -> Engine {
  case
    json.parse(from: text, using: decode.dict(decode.string, decode.dynamic))
  {
    Error(_) -> {
      log(engine, "malformed message")
      feed.publish(engine.config.feed, Malformed("a gateway frame isn't JSON"))
      engine
    }
    Ok(object) -> {
      // The frame as it came, for a listener that reads it itself. It parsed,
      // so a line built around it stays JSON.
      feed.publish(engine.config.feed, RawFrame(text))
      let type_ = decoding.string_or(object, "event", "")
      case string.lowercase(type_) {
        "close-with-reason" -> {
          let close =
            envelope.close_reason_from_json(object, engine.config.shard_id)
          log(
            engine,
            "the gateway closes the socket: "
              <> int.to_string(close.code)
              <> " "
              <> close.reason,
          )
          let engine = case close.code == 4000 {
            True -> Engine(..engine, stopped: True)
            False -> engine
          }
          feed.publish(engine.config.feed, Closed(close))
          engine
        }
        _ -> {
          let now = timestamp.system_time()
          let silence = case engine.last_heard_at {
            None -> duration.seconds(0)
            Some(heard) -> timestamp.difference(heard, now)
          }
          let engine = Engine(..engine, last_heard_at: Some(now))
          case string.uppercase(type_) {
            "HEARTBEAT_ACK" -> on_ack(engine)
            _ -> {
              let envelope = envelope.from_json(object)
              let engine = case envelope.s > 0 {
                True -> Engine(..engine, last_seq: envelope.s)
                False -> engine
              }
              case envelope.d {
                None -> {
                  log(
                    engine,
                    "warning: received event with null payload (type="
                      <> type_
                      <> ")",
                  )
                  engine
                }
                Some(payload) -> {
                  let engine = case payload {
                    envelope.ReadyEvent(data) ->
                      Engine(
                        ..engine,
                        silence_before_ready: silence,
                        session_token: Some(data.session_token),
                        fresh_wanted: False,
                        resuming: False,
                      )
                    _ -> engine
                  }
                  feed.publish(engine.config.feed, Payload(payload))
                  engine
                }
              }
            }
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn set_state(engine: Engine, state: GatewayConnectionState) -> Engine {
  case state == engine.state {
    True -> engine
    False -> {
      log(engine, "state: " <> state_name(state))
      feed.publish(engine.config.feed, StateChanged(state))
      Engine(..engine, state: state)
    }
  }
}

fn state_name(state: GatewayConnectionState) -> String {
  case state {
    Connecting -> "connecting"
    Connected -> "connected"
    Reconnecting -> "reconnecting"
    Disconnected -> "disconnected"
  }
}

fn engine_connection(engine: Engine) -> Option(Int) {
  case engine.socket {
    Some(_) -> Some(engine.connections)
    None -> None
  }
}

fn stream_url(config: Config, token: String) -> String {
  let scheme = case config.router.secure {
    True -> "wss"
    False -> "ws"
  }
  scheme
  <> "://"
  <> api_router.custom_api_url(config.router, "ws")
  <> "/gateway?token="
  <> api_router.encode_query_component(token)
}

fn ws_authority(config: Config) -> String {
  let scheme = case config.router.secure {
    True -> "wss"
    False -> "ws"
  }
  scheme <> "://" <> api_router.custom_api_url(config.router, "ws")
}

fn log(engine: Engine, message: String) -> Nil {
  engine.config.log(mask(engine, message))
}

fn mask(engine: Engine, text: String) -> String {
  let token = client.token(engine.config.api)
  case token == "" {
    True -> text
    False ->
      text
      |> string.replace(api_router.encode_query_component(token), "***")
      |> string.replace(token, "***")
  }
}
