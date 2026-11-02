# libduvet: port of duvet-client (Dart) to Gleam

Status: planned, not started
Source of truth: `../duvet-client` @ v2.3.0 (7,971 lines of Dart, 4,783 lines of tests)
Target: `libduvet` (this repository, currently a fresh `gleam new` scaffold)

## 1. Goal

Port the whole `duvet_client` Dart package to Gleam, with the same wire behaviour and
the same test coverage, including the loopback fake-gateway tests. The public API is
idiomatic Gleam: opaque actor handles, ordered event feeds, and `Result` for every
fallible operation. No feature of the Dart client is dropped.

## 2. Decisions

| Decision | Choice |
|---|---|
| Scope | Full port: models, 145 REST endpoints, gateway client/manager, voice signalling |
| Compile target | BEAM/Erlang now; JavaScript kept possible via a transport seam |
| HTTP and WebSocket | `hackney` 4.9.x for both, wrapped in one Erlang FFI module |
| Public API | OTP actors + `Subject` feeds + `Result(a, DuvetError)` |
| Timestamps | `gleam/time/timestamp.Timestamp` |
| Test harness | Ported Dart suites, run against a raw WebSocket fake gateway on loopback |

### Why hackney

Validated in a throwaway spike before planning:

- custom upgrade headers (`Authorization`, `X-Session-Token`) reach the gateway;
- a non-101 upgrade surfaces as `{error, {http_error, 401}}`, which is exactly what
  `GatewayConnectFailure.httpStatus` needs;
- a close-with-reason surfaces as `{error, {closed, 4004, "session ended"}}`;
- text frames, ping/pong and fragmentation are handled by the library;
- streaming request bodies (`send_body` in chunks) support upload progress and the
  idle-timeout-on-progress rule;
- active mode delivers frames and close/error messages to the socket owner, and
  `ws_setopts` re-arms it.

Fallback if hackney's WebSocket layer proves flaky in Phase 4: Gun (one lightweight
dependency) through the same seam.

### Consequence of "BEAM now, JS later"

Pure data and wire logic stay target-neutral: models, JSON decoders, URL/query
building, multipart encoding, request construction, envelope dispatch and
`VoiceStates`. Only two areas are BEAM-specific:

- `http/transport.gleam` (hackney) and `gateway/socket.gleam` (hackney + processes);
- the OTP actors and timers that expose handles and feeds.

A future JS build supplies a fetch/WebSocket transport and a callback-based facade
over the same core. `Subject` cannot be reused on the JS target because Gleam's JS
runtime has no processes; that adapter is explicitly out of scope for now.

## 3. Architecture

```
src/libduvet.gleam                  public entry point and module docs
src/libduvet/errors.gleam           DuvetError and helpers
src/libduvet/router.gleam           ApiRouter, url_from_path, query encoding
src/libduvet/date.gleam             RFC3339 parse/format helpers
src/libduvet/json.gleam             decode helpers (required/optional/list/map/number)
src/libduvet/models/enums.gleam     UserStatus, ClientPlatform, RoomType, MessageType, ...
src/libduvet/models/embed.gleam     embeds, attachments, allowed mentions
src/libduvet/models/user.gleam      GatewayUser, ConversationUser, ClientStatus, ...
src/libduvet/models/message.gleam   GatewayMessage, DirectMessage, Message, CallNotice
src/libduvet/models/space.gleam     space, room, role, overwrite, member, emoji, sticker
src/libduvet/models/conversation.gleam
src/libduvet/models/friend.gleam
src/libduvet/models/voice.gleam     voice states, ICE servers, SDP/candidate types
src/libduvet/models/activity.gleam
src/libduvet/models/storage.gleam
src/libduvet/models/team.gleam      team, invite, member, application, bot, webhook,
                                    commands, interactions
src/libduvet/models/events.gleam    every GatewayEventPayload + dispatch
src/libduvet/models/envelope.gleam  GatewayEnvelope, close codes and reasons
src/libduvet/http/rest.gleam        token state, login/logout, refresh, 401 re-send
src/libduvet/http/transport.gleam   Transport record: real (hackney) or fake (tests)
src/libduvet/http/send.gleam        idle timeout, abort, 64 KiB progress
src/libduvet/http/multipart.gleam   multipart encoding and media types
src/libduvet/http/request.gleam     request building, assert-ok, decoding helpers
src/libduvet/http/methods.gleam     145 public endpoints
src/libduvet/http/ack.gleam         AckThrottle actor (3 s interval)
src/libduvet/gateway/client.gleam   GatewayClient actor and state machine
src/libduvet/gateway/socket.gleam   hackney socket owner, batch-per-read forwarding
src/libduvet/gateway/manager.gleam  GatewayManager: shards and fan-out
src/libduvet/gateway/events.gleam   typed subscription helpers
src/libduvet/gateway/webrtc.gleam   VoiceStates + WebRTCController signalling
src/duvet_hackney_ffi.erl           hackney options/atoms, typed wrappers
```

Test layout:

```
test/fixtures/*.json                copied from ../duvet-client/test/fixtures (261 files)
test/support/fake_gateway.erl       raw HTTP+WS server on loopback
test/support/fake_gateway.gleam     typed helper around the Erlang server
test/support/fake_transport.gleam   request-recording transport for REST tests
test/support/silent_server.erl      TCP server for timeout tests
test/models_test.gleam
test/requests_test.gleam
test/timeouts_test.gleam
test/gateway_test.gleam
test/resume_test.gleam
test/resume_order_test.gleam
test/voice_test.gleam
```

## 4. Behaviour parity rules

These are the rules that make the port faithful. They are checked by the ported
tests, not just by review.

### JSON and models

- Copy every field's optionality and default exactly:
  - required vs nullable vs omitted (`Option(T)` vs `T` + default);
  - `List?` vs `List` where an empty list and null differ;
  - default values such as `flags = 0`, `status_id = 0`, `version = 0`.
- Unknown enum values are preserved:
  - `UserStatus`/`RoomType`/`MessageType`/... are wrappers over `Int`;
  - `ClientPlatform` wraps `String`;
  - equality is structural.
- `UnknownEvent(type, data)` is kept for event types the client doesn't know.
- `GatewayEnvelope` keeps: missing `op`/`s`/`event` defaults, null payload
  warning, sequence tracking only when `s > 0`.
- Timestamps parse with `gleam/time/timestamp.parse_rfc3339` and format with
  `to_rfc3339(t, duration.seconds(0))`, which matches Dart for the fixture formats.
- `num` fields (e.g. `percentage_used`) decode from either JSON int or float.
- Decoders return `Result(model, DecodeError)` instead of throwing.

### REST

- Same method, path, query, header, JSON body and multipart field names.
- Auth headers: `Authorization: Bearer <token>` and `X-Session-Token: <session>`
  only when non-empty.
- A JSON body sets `Content-Type: application/json`; a bodiless request doesn't.
- Multipart:
  - fields first, then files;
  - media type from the filename extension, with the voice-note special case
    (`voice-note.webm` is `audio/webm`, any other `.webm` is `video/webm`);
  - the same fallback `application/octet-stream`.
- `sendWithin`:
  - 64 KiB pieces;
  - each piece sent and each response chunk received resets the idle timer;
  - default 20 s request timeout;
  - abort trigger cancels the request and fails with an aborted error.
- 401 handling:
  - refresh once, then re-send once;
  - a 401 to a request sent before a completed refresh also re-sends once;
  - concurrent refresh calls share one request;
  - refresh 429s retry up to 3 times, waiting `Retry-After` or
    `X-RateLimit-Reset-After`, capped at 20 s per attempt;
  - 401/403 on refresh forgets the tokens; other failures don't.
- `logout` is best effort and always forgets local tokens.
- `refreshSession` only replaces the session token when the new one is non-empty.
- Voice notes validate the format (`webm`, `ogg`, `m4a`) before sending.
- `setStatus` refuses anything except online (1) and do-not-disturb (2).
- `sendTypingIndicator` / `sendRecordingIndicator` swallow failures.
- `getMentionCounts` answers an empty map on failure.
- Ack throttle:
  - first ack immediately;
  - later ones within 3 s merge into one trailing ack with the newest ID;
  - never send an ID older than the last sent;
  - failures are swallowed;
  - `dispose` cancels trailing acks.

### Gateway

- Reconnect delay: 1 s doubling per failure, capped at 30 s, plus up to 1 s jitter.
- Connect timeout bounds the whole upgrade, not just TCP connect.
- Only one socket at a time; a superseded attempt closes its socket when it opens.
- Heartbeat every 45 s, ack timeout 15 s, a missed ack drops the socket.
- Identify fields:
  - `token`;
  - `last_seq` when > 0;
  - `session_token` only when resuming;
  - `shard_id`/`num_shards` only when `shard_count > 1`;
  - `platform` when set.
- Resume:
  - enabled only with `resume = true`, a session token, `last_seq > 0` and no
    fresh-session request;
  - a heartbeat goes right after a resuming identify;
  - an ack with no READY before it means the gateway resumed;
  - the resume notification comes after the replayed events, and is suppressed if
    the socket closes in the same read;
  - `_sessionToken` is dropped if the socket closes mid-resume and the sequence
    number moved.
- Close reasons:
  - `4000` stops reconnecting until `connect`;
  - `close-with-reason` doesn't count as hearing from the gateway;
  - the last sequence number is untouched by close frames.
- `silenceBeforeReady` measures silence up to READY.
- `wantFreshSession` lasts until the next READY.
- `retryNow` ends the reconnect wait early and answers whether it was waiting.
- Token masking in logs: URL-encoded token and raw token replaced with `***`.
- Destroy closes the socket, cancels waits, and closes all feeds exactly once.

### Voice

- `VoiceStates` keeps the newest version per room and user, including after leave.
- `reset` drops everything and takes READY's calls.
- `space` replaces its rooms' snapshots, keeping newer versions.
- `ongoing` replaces a call's snapshot.
- `forget` removes a room/call.
- `apply` drops older updates, keeps equal versions, handles leave and empty rooms.
- `WebRTCController` sends the same JSON payloads as the Dart controller.

## 5. Phases

Each phase ends with: `gleam format --check src test` clean, `gleam build` clean,
the phase's ported tests green. The next phase doesn't start until it is green.

### Phase 0: Foundation and smoke test

Deliverables:

- `gleam.toml`: description, licences, repository, dependencies:
  - `gleam_stdlib`, `gleam_json`, `gleam_time`, `gleam_erlang`, `gleam_otp`,
    `hackney` (Erlang package);
  - dev: `gleeunit`.
- `src/duvet_hackney_ffi.erl` with typed wrappers:
  - `ws_connect(url, headers, connect_timeout, recv_timeout)`;
  - `ws_setopts(conn, active_once)`;
  - `ws_send_text`, `ws_close`;
  - `request_*` for streaming uploads and response chunks;
  - atoms confined to this module.
- `tool/sync-fixtures.sh`: copy the 261 fixtures from
  `../duvet-client/test/fixtures`, with a note that the canonical generator lives
  in duvet-client.
- `tool/parity.sh`: extract public Dart symbols and compare with `PARITY.md`.
- CI: `gleam deps download`, `gleam build`, `gleam test`,
  `gleam format --check src test`.
- Smoke test: an actor skeleton connects to the fake gateway, receives READY, and
  shuts down cleanly. This proves FFI + actor wiring before bulk porting.

### Phase 1: Models and envelope

Port `lib/models/types.dart` (3,158 lines), `lib/models/rest_types.dart` (828
lines) and `lib/models/gateway_envelope.dart` (230 lines).

Deliverables:

- Every enum, model, `from_json`, `to_json`, event payload, envelope, close code
  and close reason.
- `PARITY.md` entries for all model types.
- `test/models_test.gleam` ported case-for-case from `models_test.dart`
  (1,405 lines):
  - `_parses` table over all fixture variants;
  - all special cases: null embeds/components, webhook messages, zero times,
    omitempty fields, mention_author, pin updates, call notices, voice/video,
    client status, close reasons, ICE servers, etc.

Acceptance:

- all 261 fixture files decode as the Dart tests expect;
- every `case` in the Dart envelope dispatch has a Gleam counterpart and a fixture;
- `UnknownEvent` and `GatewayCloseReason` behaviour match.

### Phase 2: REST core

Port `http/router.dart`, `errors.dart`, `http/rest.dart`, `http/send.dart`,
`http/ack.dart`, plus the request/multipart helpers from `http/methods.dart`.

Deliverables:

- `ApiRouter` with the same defaults and custom URL behaviour.
- `DuvetError` taxonomy.
- `RestClient` actor:
  - token/session state;
  - login/logout;
  - single-flight refresh;
  - 429 retry policy;
  - 401 re-send policy with a token generation counter.
- `Transport` seam:
  - real implementation on hackney, with streaming uploads, response chunks,
    idle timeout and abort;
  - fake implementation for tests.
- Multipart encoder and media-type table.
- `AckThrottle` actor.

Acceptance:

- `headers` and `auth` groups of `requests_test.dart`;
- `timeouts_test.dart` ported against the real loopback transport;
- ack throttle tests from `requests_test.dart`.

### Phase 3: REST endpoints

Port the remaining 145 public methods from `http/methods.dart` in groups:

1. spaces, attachments, buckets;
2. rooms, overwrites, invites;
3. messages, search, pins, threads, reactions, ack, mentions;
4. roles, emojis, stickers;
5. webhooks;
6. interactions and commands;
7. friends;
8. conversations and DMs;
9. users, profile images, status, personal storage;
10. teams, invites, applications, bots, bot-to-space.

Acceptance:

- every group's tests from `requests_test.dart` ported and green;
- `PARITY.md` shows no unported endpoint;
- multipart bodies assert the same field names, filenames and content types.

### Phase 4: Gateway client

Port `gateway/client.dart` (757 lines) and `gateway/events.dart` helpers.

Deliverables:

- `GatewayClient` actor: connect, reconnect, heartbeat, identify, resume,
  close-with-reason, shard rules, platform, fresh session, retry now, destroy.
- `gateway/socket.gleam`:
  - socket process owns the hackney connection;
  - active-once mode;
  - drains all frames available in one read into one batch;
  - forwards batches, close frames and errors to the client actor.
- Ordered feed carrying `Payload`, `Malformed`, `StateChanged`, `Resumed`,
  `Closed`, `ConnectFailed`.
- Typed subscription helpers (equivalent of the `GatewayEvents` mixin).

Acceptance:

- `gateway_test.dart` (486 lines) ported:
  - connect/identify/READY;
  - drop/reconnect, one socket at a time;
  - retries until accepted;
  - exact delay growth and jitter bounds;
  - platform in identify;
  - bot shards and per-shard failures;
  - connect during wait keeps the new socket;
  - `retryNow`;
  - hanging attempt dropped after connect timeout;
  - connect failure statuses and token masking;
  - destroy races;
  - destroyed client cannot connect or send.
- `resume_test.dart` (495 lines) ported:
  - no resume without the flag;
  - resume replays missed events then `Resumed`;
  - failed resume gets READY and no `Resumed`;
  - platform on resuming identifies;
  - `wantFreshSession`;
  - close mid-resume with and without movement;
  - bare events don't move `last_seq`;
  - 4000 stops until connect;
  - close-with-reason then resume;
  - silence-before-READY measurement.
- `resume_order_test.dart` (325 lines) ported:
  - ack in the same read as replay: replay then resumed;
  - ack + close in the same read: no resumed until the next socket;
  - both for `GatewayClient` and `GatewayManager`.

### Phase 5: Gateway manager

Port `gateway/manager.dart` (236 lines).

Deliverables:

- shard spawning and connection;
- fan-out of events, errors, states, resumes, close reasons and failures;
- `wantFreshSession`, `retryNow`, `sendMessage`, `connection`,
  `silenceBeforeReady`;
- destroy semantics.

Acceptance: manager variants of the gateway/resume tests, including the
`mostOpen == 1` guarantee and shard failure attribution.

### Phase 6: Voice and call signalling

Port `gateway/webrtc_controller.dart` (395 lines).

Deliverables:

- `VoiceStates` with version handling;
- `WebRTCController`:
  - subscribes to manager events;
  - resets/updates voice state on READY, SPACE_CREATE, VOICE_STATE_UPDATE,
    CALL_ONGOING, CALL_ENDED, ROOM_DELETE;
  - emits only applied `VOICE_STATE_UPDATE`s;
  - sends `VOICE_JOIN`, `VOICE_LEAVE`, `VOICE_SYNC`,
    `WEBRTC_ICE_CANDIDATE`, `WEBRTC_ANSWER`, `WEBRTC_RENEGOTIATE_OFFER`,
    `CALL_INITIATE`, `CALL_ACCEPT`, `CALL_DECLINE`, `CALL_CANCEL`, `CALL_LEAVE`;
  - returns false when no socket is open;
  - dispose semantics.

Acceptance: `voice_test.dart` (467 lines) ported case-for-case, including the
exact JSON the gateway receives.

### Phase 7: Polish and parity proof

- `README.md` with a working example: login, fetch messages, connect the gateway,
  subscribe to events, voice signalling.
- Hex docs metadata and module docs.
- `PARITY.md` final audit: every exported Dart class, enum, method and constant has
  a Gleam counterpart.
- `COMPATIBILITY.md`: intentional differences.
- Optional `test/live_test.gleam` behind `DUVET_LIVE`, matching `live_test.dart`.
- Full `gleam test` run, format check, CI green.
- Initial commit(s). No `build/` artifacts.

## 6. Test harness details

### Fake gateway

An Erlang module under `test/support/` because Gleam compiles `.erl` files in
`test/`. It provides:

- `start/0` on `127.0.0.1:0`, returning the port;
- raw HTTP upgrade handling with `Sec-WebSocket-Accept`;
- a per-request plan: upgrade, refuse with a status (401/503), or hold forever;
- identify capture, token capture, timing capture;
- `push(type, data)` with incrementing sequence numbers;
- `send_bare(type, data)` with no sequence number;
- `drop()` closes without a close frame;
- `close_with_reason(code, reason)`;
- `write_burst(frames)` writes several frames in one TCP write;
- `open_count` and `most_open` for the one-socket guarantee;
- clean shutdown.

Gleam tests call it through `test/support/fake_gateway.gleam`.

### Fake transport

A `Transport` whose `send` records each request and answers from a function, the
equivalent of Dart's `MockClient`. It exposes the recorded method, path, query,
headers and body so `requests_test` can assert exactly what went out.

### Time-based tests

The Dart suites use real time (reconnect 1–2.5 s, ack 3.2 s). The port keeps the
same constants and real waits. The full suite is expected to take about a minute.
No test-only time acceleration in the public code.

## 7. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Gateway resume ordering | Batch-per-read socket design; port `resume_order_test` before other gateway work |
| Hackney WebSocket maturity | Spike-validated; fallback to Gun behind the same seam |
| Custom connect timeout | Timer in the client actor + killing the socket process; tested with a 200–300 ms timeout |
| Time-based flakiness | Port the Dart tolerances exactly; keep waits generous in assertions |
| Model drift | Fixtures copied verbatim; one test per fixture variant, like Dart |
| Missing endpoints | `PARITY.md` + `tool/parity.sh` |
| Large change set | One phase per change/PR; suite must be green before the next |

## 8. Definition of done (whole port)

- `gleam format --check src test` clean.
- `gleam build` clean.
- `gleam test` green, including every ported Dart test file.
- `PARITY.md` has no unported public symbol.
- `COMPATIBILITY.md` lists every intentional difference.
- README example compiles (`gleam run` or a documented snippet).
- CI workflow runs format, build and tests on push/PR.
