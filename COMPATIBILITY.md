# Compatibility with the Dart package

`libduvet` follows `duvet-client`'s wire behaviour: the same paths, query
parameters, JSON documents, multipart forms, WebSocket frames and state
machines, checked by the same fixtures and the same fake gateway. The API shape
differs where Gleam does, deliberately. This is the list.

## Errors

Dart throws; Gleam answers `Result(a, DuvetError)` ([`libduvet/error`](src/libduvet/error.gleam)).

- `DuvetApiException` → `DuvetError.ApiError`, `DuvetAuthException` →
  `DuvetError.AuthError` (401 and 403).
- `TimeoutException` → `DuvetError.RequestTimeout` (the request's method, path
  and idle timeout).
- `http.RequestAbortedException` → `DuvetError.RequestAborted`.
- `DuvetMalformedMessageException` → `DuvetError.MalformedMessage`.
- Network failures below HTTP → `DuvetError.NetworkError`.
- `ArgumentError`, thrown by `setStatus` for offline and by `sendVoiceNote` for
  an unsupported format, → `DuvetError.InvalidArgument`; nothing is sent, as in
  Dart.
- `DuvetApiException.reasonPhrase` has no counterpart: the transport reports a
  status, not a status line.

## Bots

`duvet-client` is a person's client: it has no bot-token mode and no bot-side
endpoints. `libduvet` adds them, and a person's calls are unchanged.

- `client.new_bot` sends `Authorization: Bot <token>`, no session token, and
  never tries to renew a session (a bot has none). `client.is_bot` and
  `client.auth_mode` say which mode a client is in.
- [`libduvet/http/bot`](src/libduvet/http/bot.gleam) has the bot-side routes:
  the application (`get_application`), interactions (`next_interaction`,
  `respond`, `follow_up`, `get_message`, `edit_message`, `delete_message`), room
  messages (`send_message`, `edit_message_in_room`, `delete_message_in_room`)
  and commands (`list_commands`, `overwrite_commands`, `create_command`,
  `get_command`, `update_command`, `delete_command`).
- Bodies and answers are `json.Json`, not modelled: a bot's components and an
  interaction's data are passed through as the API sends them.
- `FeedMessage.RawFrame(text)` publishes each gateway frame as it came, before
  decoding. A bot reads events this package doesn't model (`INTERACTION_CREATE`
  and the rest of the interaction payloads) there without losing fields.

## Streams and events

Dart's broadcast streams become a `Feed` of ordered messages
([`libduvet/gateway/feed`](src/libduvet/gateway/feed.gleam)): a client or a
manager publishes onto it, and each listener subscribes with its own subject
before the events it needs.

- `onEvent` → `FeedMessage.Payload`.
- `errors` → `FeedMessage.Malformed`.
- `onConnectionState` → `FeedMessage.StateChanged`.
- `onResume` → `FeedMessage.Resumed`.
- `onCloseReason` → `FeedMessage.Closed`.
- `onConnectFailure` → `FeedMessage.ConnectFailed`.
- Destroying a client or manager publishes `FeedMessage.FeedClosed` and no
  other message.
- The typed `GatewayEvents` getters (`onMessageCreate`, `onReady`, …) become
  typed awaits in [`libduvet/gateway/events`](src/libduvet/gateway/events.gleam)
  (`await_ready`, `await_message_delete`, `await_state`, `await_resumed`,
  `await_close`, `await_failure`, `await_call_*`, `await_voice_*`), or a
  listener plus `feed.subscribe` for anything else. An await drops the messages
  it isn't waiting for, so use one listener per kind (the gateway and voice
  tests do).

## Files and multipart

The Dart package reads files (`dart:io` `File`) and sends them. Gleam has no
file API in its standard library, and the app already has the bytes: every
endpoint that took a `File` takes a
[`multipart.FilePart`](src/libduvet/http/multipart.gleam) with the field name,
the bytes and the filename. The media type is still chosen from the filename
exactly as Dart chooses it (including `voice-note.webm` being audio), and the
multipart encoding is byte-for-byte the format Dart's `http` package writes.

## Optional arguments

Gleam has no optional arguments (as of 1.19). Every named parameter that has a
default in Dart is a required labelled argument here, with `None`, `False`, `0`
or `[]` standing in for the default. Call sites spell them out.

## Models

- `DateTime` → `gleam/time/timestamp.Timestamp`. Parsing keeps microseconds and
  drops finer precision, as Dart does; formatting matches
  `DateTime.toUtc().toIso8601String()` (three fractional digits when the
  microseconds are zero, six otherwise).
- `Map<String, dynamic>` for opaque documents (`components`, a modal data, a
  command choice's value) → `model/decoding.Object` (a
  `Dict(String, dynamic.Dynamic)`), or `json_value.JsonValue` where the value
  goes back out (an interaction's answers, a command option's value).
- `Envelope` and the event union are one Gleam custom type,
  `GatewayEventPayload`, with a variant per Dart class.

## The client and its caches

- `RestClient` is a value holding the API's session actor, the two ack
  throttles and the command cache. Its tokens are kept in a process of its own
  so that concurrent 401s share one refresh, as Dart's single-flight
  `_refreshing` does.
- The command list cache has the same 5-minute lifetime; a failed list isn't
  kept and a failed command use forgets all of them, as in Dart. Concurrent
  fetches aren't shared, because calls here are synchronous.
- `GatewayManager.withDefaultApi` isn't ported: pass the `RestClient` you have.
  (Dart's version also owns and closes an `http.Client`; the transport here
  owns its connections.)
- The default log is silent. Pass `with_log` to see what Dart prints by
  default.

## Transports

- REST: hackney. A request runs in a process of its own; the caller's idle
  timeout and abort kill it, which closes the connection. Uploads go in 64 KiB
  pieces with progress, and the body's length is sent explicitly.
- WebSocket: Gun, in [`src/duvet_network_ffi.erl`](src/duvet_network_ffi.erl).
  Hackney's active mode drops the frames that precede a close frame in the same
  read, which the gateway's bursts (a replay, a heartbeat ack and a close) can
  contain, so its WebSocket support isn't used. Frames are forwarded in order,
  one at a time. The connection is linked to the socket owner, so killing the
  owner (a connect timeout, a superseded attempt, `destroy`) closes it.

## Timers

Reconnect delays, the connect timeout, heartbeats and ack timeouts keep the
Dart constants (1, 2, 4, 8, 16, 30 seconds plus up to one at random; 15 s to
connect; 45 s between heartbeats; 15 s for an ack; 3 s between acks). Tests use
real time, as the Dart suite does, so a full run takes about a minute.

## JavaScript

`js/` compiles this package to JavaScript with TypeScript types. Its deliberate
differences from the BEAM's API are listed in [`js/README.md`](js/README.md).
