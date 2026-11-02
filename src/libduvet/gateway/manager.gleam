import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/duration.{type Duration}
import libduvet/api_router
import libduvet/gateway/client
import libduvet/gateway/feed.{type Feed}
import libduvet/http/client as rest
import libduvet/model/client_platform

/// What a manager can fail with.
pub type ManagerError {
  /// The manager was destroyed before its shards were online.
  Destroyed
}

/// A manager's setup: its API client, where the gateway is, how long an
/// attempt may take, and whether sessions resume.
pub type Config {
  Config(
    api: rest.RestClient,
    router: api_router.ApiRouter,
    connect_timeout: Int,
    resume: Bool,
    platform: Option(client_platform.ClientPlatform),
    log: fn(Int, String) -> Nil,
    feed: Feed,
  )
}

pub fn config(api: rest.RestClient) -> Config {
  Config(
    api: api,
    router: api_router.default_router(),
    connect_timeout: client.default_connect_timeout,
    resume: False,
    platform: None,
    log: fn(_shard_id, _message) { Nil },
    feed: feed.start(),
  )
}

pub fn with_router(config: Config, router: api_router.ApiRouter) -> Config {
  Config(..config, router: router)
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

pub fn with_log(config: Config, log: fn(Int, String) -> Nil) -> Config {
  Config(..config, log: log)
}

/// The manager's feed: every shard's events, states, resumes, closes and
/// failures, in the order the shard published them.
pub fn feed(config: Config) -> Feed {
  config.feed
}

pub opaque type GatewayManager {
  GatewayManager(subject: Subject(Message))
}

type Message {
  Spawn(
    shard_id: Int,
    shard_count: Int,
    reply: Subject(Result(client.GatewayClient, Nil)),
  )
  Destroy
  WantFreshSession
  RetryNow(reply: Subject(Bool))
  Send(type_: String, data: json.Json, reply: Subject(Result(Bool, Nil)))
  GetConnection(reply: Subject(Option(Int)))
  GetSilence(reply: Subject(Duration))
}

type State {
  State(config: Config, shards: List(client.GatewayClient), destroyed: Bool)
}

pub fn start(config: Config) -> GatewayManager {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(State(config: config, shards: [], destroyed: False), subject)
    })
  GatewayManager(process.receive_forever(ready))
}

/// Spawns [shard_count] shards and connects each one: it returns once each has
/// a socket open, trying again while one can't open, and fails with
/// [Destroyed] if the manager is destroyed first.
pub fn connect_all(
  manager: GatewayManager,
  shard_count: Int,
) -> Result(Nil, ManagerError) {
  connect_shards(manager, 0, shard_count)
}

fn connect_shards(
  manager: GatewayManager,
  shard_id: Int,
  shard_count: Int,
) -> Result(Nil, ManagerError) {
  case shard_id >= shard_count {
    True -> Ok(Nil)
    False ->
      case spawn_shard(manager, shard_id, shard_count) {
        Error(Nil) -> Error(Destroyed)
        Ok(gateway) ->
          case client.connect(gateway) {
            Ok(_) -> connect_shards(manager, shard_id + 1, shard_count)
            Error(_) -> {
              case client.reconnect(gateway) {
                True -> connect_shards(manager, shard_id + 1, shard_count)
                False -> Error(Destroyed)
              }
            }
          }
      }
  }
}

fn spawn_shard(
  manager: GatewayManager,
  shard_id: Int,
  shard_count: Int,
) -> Result(client.GatewayClient, Nil) {
  let reply = process.new_subject()
  process.send(manager.subject, Spawn(shard_id, shard_count, reply))
  process.receive_forever(reply)
}

/// Permanently shuts down all shards and closes the feed.
pub fn destroy(manager: GatewayManager) -> Nil {
  process.send(manager.subject, Destroy)
}

/// Makes each shard's next identify start a new session, with READY, rather
/// than resume its own.
pub fn want_fresh_session(manager: GatewayManager) -> Nil {
  process.send(manager.subject, WantFreshSession)
}

/// Ends each shard's wait before its next attempt, and answers whether one was
/// waiting.
pub fn retry_now(manager: GatewayManager) -> Bool {
  call(manager, RetryNow)
}

/// Sends an event message through shard 0, when one is connected.
pub fn send_message(
  manager: GatewayManager,
  type_: String,
  data: json.Json,
) -> Result(Bool, Nil) {
  call(manager, fn(reply) { Send(type_, data, reply) })
}

/// Shard 0's connection number, or None while it has no socket.
pub fn connection(manager: GatewayManager) -> Option(Int) {
  call(manager, GetConnection)
}

/// Shard 0's silence before its last READY.
pub fn silence_before_ready(manager: GatewayManager) -> Duration {
  call(manager, GetSilence)
}

fn call(manager: GatewayManager, message: fn(Subject(a)) -> Message) -> a {
  let reply = process.new_subject()
  process.send(manager.subject, message(reply))
  process.receive_forever(reply)
}

fn loop(state: State, subject: Subject(Message)) -> Nil {
  case process.receive_forever(subject) {
    Spawn(shard_id, shard_count, reply) ->
      case state.destroyed {
        True -> {
          process.send(reply, Error(Nil))
          loop(state, subject)
        }
        False -> {
          let gateway = spawn_client(state.config, shard_id, shard_count)
          process.send(reply, Ok(gateway))
          loop(
            State(..state, shards: list.append(state.shards, [gateway])),
            subject,
          )
        }
      }
    Destroy -> {
      case state.destroyed {
        True -> loop(state, subject)
        False -> {
          list.each(state.shards, client.destroy)
          state.config.log(-1, "[GatewayManager] destroyed")
          feed.close(state.config.feed)
          loop(State(..state, shards: [], destroyed: True), subject)
        }
      }
    }
    WantFreshSession -> {
      list.each(state.shards, client.want_fresh_session)
      loop(state, subject)
    }
    RetryNow(reply) -> {
      let waiting =
        list.fold(state.shards, False, fn(waiting, gateway) {
          client.retry_now(gateway) || waiting
        })
      process.send(reply, waiting)
      loop(state, subject)
    }
    Send(type_, data, reply) -> {
      case state.shards {
        [] -> {
          process.send(reply, Error(Nil))
          loop(state, subject)
        }
        [first, ..] -> {
          process.send(reply, Ok(client.send_message(first, type_, data)))
          loop(state, subject)
        }
      }
    }
    GetConnection(reply) -> {
      process.send(reply, case state.shards {
        [] -> None
        [first, ..] -> client.connection(first)
      })
      loop(state, subject)
    }
    GetSilence(reply) -> {
      process.send(reply, case state.shards {
        [] -> duration.seconds(0)
        [first, ..] -> client.silence_before_ready(first)
      })
      loop(state, subject)
    }
  }
}

fn spawn_client(
  config: Config,
  shard_id: Int,
  shard_count: Int,
) -> client.GatewayClient {
  let client_config =
    client.config(config.api, config.feed)
    |> client.with_router(config.router)
    |> client.with_shard(shard_id, shard_count)
    |> client.with_connect_timeout(config.connect_timeout)
    |> client.with_resume(config.resume)
    |> client.with_log(fn(message) { config.log(shard_id, message) })
  let client_config = case config.platform {
    Some(platform) -> client.with_platform(client_config, platform)
    None -> client_config
  }
  client.start(client_config)
}
