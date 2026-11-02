# libduvet

A Gleam client for the [Duvet](https://duvet.chat) chat platform: the REST API,
the WebSocket gateway and its voice and call signalling. It is a port of the
Dart package in [`duvet-client`](../duvet-client), with the same wire behaviour
and the same tests.

It runs on the BEAM (Erlang/OTP) today, over hackney for HTTP and Gun for
WebSocket.

## Install

```sh
gleam add libduvet
```

## Log in and call the API

Every call answers a `Result`, whose failure says what happened.

```gleam
import gleam/io
import gleam/option.{None}
import libduvet/api_router
import libduvet/http/client as api
import libduvet/http/methods
import libduvet/http/transport

pub fn main() {
  let rest =
    api.new(
      transport.hackney(20_000),
      api_router.default_router(),
      "",
      "",
      20_000,
    )

  let assert Ok(sign_in) = api.log_in(rest, "me@example.com", "password")
  io.println("logged in with " <> sign_in.token)

  let assert Ok(page) =
    methods.get_messages(rest, "some-room-id", before: None, count: 50)
  io.println("the newest message is " <> message_id(page))

  let assert Ok(_) =
    methods.send_message(
      rest,
      "some-room-id",
      "hello",
      methods.send_message_options(),
    )
  Nil
}
```

## The gateway

The gateway keeps one WebSocket at a time, heartbeats it, and reconnects by
itself. What it hears goes onto a `Feed`, which any number of listeners can
subscribe to; it is also where its state, resumes, close reasons and failed
attempts are published.

```gleam
import gleam/io
import gleam/option.{None}
import libduvet/api_router
import libduvet/gateway/events
import libduvet/gateway/feed
import libduvet/gateway/manager
import libduvet/http/client.{type RestClient}
import libduvet/model/envelope

pub fn watch(rest: RestClient) {
  let events_feed = feed.start()

  let config =
    manager.config(rest)
    |> manager.with_router(api_router.default_router())
    |> manager.with_resume(True)
    |> manager.with_log(fn(_shard, message) { io.println(message) })

  let gateway = manager.start(config)
  let listener = feed.subscribe(events_feed)

  let assert Ok(_) = manager.connect_all(gateway, 1)
  let assert Ok(ready) = events.await_ready(listener, 15_000)
  io.println("connected as " <> ready.user.username)

  // Later events, in the order they came.
  case events.await_payload(listener, 30_000) {
    Ok(envelope.MessageCreateEvent(message)) ->
      io.println("a message: " <> message.id)
    _ -> Nil
  }

  manager.destroy(gateway)
}
```

## Voice and calls

`libduvet/gateway/webrtc` carries the signalling: join a voice room or a
call with a peer connection's offer, sync its whole state, pass ICE candidates
and answers, and place or answer calls. It also keeps `VoiceStates`, who is in
voice where, in version order.

```gleam
import libduvet/gateway/webrtc
import libduvet/model/event

pub fn join_voice(manager: libduvet/gateway/manager.GatewayManager) {
  let rtc = webrtc.start(manager)

  let offer =
    event.SessionDescription(type_: "offer", sdp: peer_connection_offer)

  let _ = webrtc.join_voice(rtc, "room-id", offer, [], False)
  let _ =
    webrtc.sync_voice(rtc, "room-id", False, False, False, False, False)
}

fn message_id(message: libduvet/model/message.GatewayMessage) -> String {
  message.id
}

const peer_connection_offer = "v=0"
```

The peer connection itself is the app's (Flutter WebRTC, WebRTC in a browser,
an Erlang WebRTC stack…), as it is with the Dart package.

## Development

```sh
gleam build
gleam test
gleam format --check src test
```

The tests copy their fixtures from `duvet-client/test/fixtures`
(`tool/sync-fixtures.sh`) and run against a fake gateway on `127.0.0.1`
(`test/support/duvet_fake_gateway.erl`), as the Dart suite does.

- `PLAN.md`: how the port was planned, phase by phase.
- `PARITY.md`: every public symbol of the Dart package and where it went.
  `tool/parity.sh --strict` fails while anything is unported.
- `COMPATIBILITY.md`: the deliberate differences from the Dart package.
