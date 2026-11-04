# libduvet for JavaScript

A client for the [Duvet](https://duvet.chat) chat platform, for Bun (and Node 24):
the REST API and the WebSocket gateway, with TypeScript types. It needs no Erlang.
The models and requests are `libduvet`'s Gleam, compiled to JavaScript; the types
are generated from the same source.

## Install

From a GitHub release, not npm:

```sh
bun add https://github.com/duvetchat/libduvet/releases/download/v1.1.0/libduvet-1.1.0.tgz
```

## Call the API

Everything takes and returns plain values: `string | null`, arrays, `Date`,
`Uint8Array`. A failed call throws a `DuvetError`.

```ts
import { DuvetClient, DuvetError } from "libduvet";

const client = new DuvetClient();
await client.logIn("me@example.com", "password");

const page = await client.getMessages("some-room-id", null, 50);
console.log(page[0]?.content);

try {
  await client.sendMessage("some-room-id", "hello", {
    files: [{ field: "files", bytes: await Bun.file("cat.png").bytes(), filename: "cat.png" }],
  });
} catch (failure) {
  if (failure instanceof DuvetError) console.error(failure.status, failure.detail);
  else throw failure;
}
```

A session's tokens are `client.token` and `client.sessionToken`; pass them to
`new DuvetClient({ token, sessionToken })` to resume it. A 401 renews the session and
resends the request once. For a local server, say
`new DuvetClient({ api: "localhost:8080", ws: "localhost:8081", secure: false })`.

The methods are the Gleam package's in camelCase, 139 of them, documented in the types.

## The gateway

```ts
const gateway = client.gateway({ resume: true });

gateway.on("event", (event) => {
  // A union on `tag`: `event.data` narrows with it.
  if (event.tag === "MessageCreateEvent") console.log(event.data.content);
});
gateway.on("state", (state) => console.log(state));

await gateway.connect();
```

It keeps one socket, heartbeats it and reconnects by itself. Besides `event` it
reports `raw` (a frame as it came), `malformed`, `state`, `resumed`, `close`,
`connectFailed` and `destroyed`. `client.gatewayManager().connectAll(shards)` runs one
socket per shard with one set of listeners.

## Bots

A bot authenticates with its token alone. Its endpoints are on `.bot`, and their bodies
and answers stay JSON. Events the models don't cover, like `INTERACTION_CREATE`, arrive
through `raw`.

```ts
const bot = DuvetClient.bot(token);
const application = await bot.bot.getApplication();

const gateway = bot.gateway({ resume: true });
gateway.on("raw", (text) => {
  const frame = JSON.parse(text);
  if (frame.event === "INTERACTION_CREATE") console.log(frame.d);
});
await gateway.connect();
```

## What differs from the Gleam package

- Voice and call signalling (`gateway/webrtc`, `VoiceStates`) isn't here yet. The events
  arrive, and `gateway.send(type, data)` can send the messages by hand.
- Requests can't be aborted, only time out. `onProgress` reports only that the whole body
  went, because `fetch` doesn't report uploads.
- A refused gateway upgrade has no HTTP status (`httpStatus` is null): `WebSocket` hides it.
- A bad frame is reported as `malformed` and the socket goes on, where the BEAM's actor
  would crash.

## Development

The Gleam in `src/` holds what's hand-written for JavaScript (`rest.gleam`); everything
generated comes from the sources in `../src`, so a new endpoint or model needs no change
here.

```sh
bun install
bun run build        # tool/gen.ts, then gleam build, then tsc into dist/
bun run check
bun test spec
sh tool/smoke.sh     # packs it, and uses it as a consumer under Bun, Node and tsc
```
