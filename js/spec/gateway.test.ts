// The gateway client against a fake gateway on loopback, with the rules the
// BEAM's gateway and resume suites check.
import { afterAll, afterEach, expect, test } from "bun:test";
import { join } from "node:path";
import { type GatewayClient, DuvetClient, GatewayConnectError, type GatewayEvents, reconnectDelay } from "../ts/index";

const fixtures = join(import.meta.dir, "../../test/fixtures");

type Data = { headers: Headers; url: URL };
type Socket = Bun.ServerWebSocket<Data>;
const sockets: Socket[] = [];
const received: any[][] = [];
let onFrame: (socket: Socket, frame: any, index: number) => void = () => {};
let refuse = false;

const server = Bun.serve<Data>({
  port: 0,
  fetch(request, srv) {
    if (refuse) return new Response("no", { status: 401 });
    const url = new URL(request.url);
    if (srv.upgrade(request, { data: { headers: request.headers, url } })) return undefined;
    return new Response("not a socket", { status: 400 });
  },
  websocket: {
    open(socket: Socket) {
      sockets.push(socket);
      received.push([]);
    },
    message(socket: Socket, text) {
      const index = sockets.indexOf(socket);
      const frame = JSON.parse(String(text));
      // A socket from an earlier test may still be talking.
      if (index < 0) return;
      received[index]!.push(frame);
      onFrame(socket, frame, index);
    },
  },
});
afterAll(() => server.stop(true));

const clients: GatewayClient[] = [];
afterEach(() => {
  for (const client of clients.splice(0)) client.destroy();
  sockets.length = 0;
  received.length = 0;
  onFrame = () => {};
  refuse = false;
});

const rest = (token = "tok") =>
  new DuvetClient({ ws: `localhost:${server.port}`, api: `localhost:${server.port}`, secure: false, token, sessionToken: "ses" });

function gateway(options: Parameters<DuvetClient["gateway"]>[0] = {}, client = rest()) {
  const made = client.gateway({ heartbeatIntervalMs: 60_000, ...options });
  clients.push(made);
  return made;
}

function next<K extends keyof GatewayEvents>(
  source: { on: GatewayClient["on"] },
  kind: K,
  matches: (value: GatewayEvents[K]) => boolean = () => true,
): Promise<GatewayEvents[K]> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`no ${kind} in time`)), 4000);
    const stop = source.on(kind, (value) => {
      if (!matches(value)) return;
      clearTimeout(timer);
      stop();
      resolve(value);
    });
  });
}

const until = async (condition: () => boolean, ms = 4000) => {
  const deadline = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("the condition never held");
    await Bun.sleep(5);
  }
};

const readyFrame = async (s = 1) =>
  JSON.stringify({
    event: "READY",
    s,
    d: { type: "READY", data: await Bun.file(join(fixtures, "ready_event.full.json")).json() },
  });

test("connecting authenticates and identifies", async () => {
  const client = gateway({ platform: "desktop" });
  const states: string[] = [];
  client.on("state", (state) => states.push(state));

  await client.connect();
  await until(() => received[0]?.length === 1);

  expect(states).toEqual(["connecting", "connected"]);
  expect(client.connection).toBe(1);
  const { headers, url } = sockets[0]!.data;
  expect(headers.get("authorization")).toBe("Bearer tok");
  expect(headers.get("x-session-token")).toBe("ses");
  expect(url.searchParams.get("token")).toBe("tok");
  expect(received[0]![0]).toEqual({ type: "identify", data: { token: "tok", platform: "desktop" } });
});

test("a bot's upgrade carries its token as a bot's", async () => {
  const bot = DuvetClient.bot("bot-token", { ws: `localhost:${server.port}`, secure: false });
  const client = bot.gateway();
  clients.push(client);
  await client.connect();
  expect(sockets[0]!.data.headers.get("authorization")).toBe("Bot bot-token");
});

test("READY arrives decoded, with the raw frame beside it", async () => {
  const client = gateway();
  const raw = next(client, "raw");
  const event = next(client, "event");
  await client.connect();
  const frame = await readyFrame();
  sockets[0]!.send(frame);

  expect(await raw).toBe(frame);
  const payload = await event;
  expect(payload.tag).toBe("ReadyEvent");
  if (payload.tag === "ReadyEvent") {
    expect(typeof payload.data.sessionToken).toBe("string");
    expect(typeof payload.data.user.username).toBe("string");
    expect(Array.isArray(payload.data.iceServers)).toBe(true);
  }
});

test("an event the models can't read is reported, and the socket goes on", async () => {
  const client = gateway();
  await client.connect();
  const malformed = next(client, "malformed");
  sockets[0]!.send("not json");
  expect(await malformed).toContain("isn't JSON");
  const bad = next(client, "malformed");
  sockets[0]!.send(JSON.stringify({ event: "READY", s: 1, d: { type: "READY", data: { user: 3 } } }));
  expect(await bad).toContain("READY");
  expect(client.state).toBe("connected");
});

test("heartbeats go out and an ack keeps the socket", async () => {
  onFrame = (socket, frame) => {
    if (frame.type === "heartbeat") socket.send(JSON.stringify({ event: "HEARTBEAT_ACK" }));
  };
  const client = gateway({ heartbeatIntervalMs: 20 });
  await client.connect();
  await until(() => (received[0] ?? []).filter((f) => f.type === "heartbeat").length >= 3);
  expect(client.connection).toBe(1);
});

test("a missed ack drops the socket and another opens", async () => {
  const client = gateway({ heartbeatIntervalMs: 20, heartbeatAckTimeoutMs: 1000 });
  await client.connect();
  await next(client, "state", (state) => state === "reconnecting");
  await next(client, "state", (state) => state === "connected");
  expect(client.connection).toBe(2);
});

test("after a drop it resumes with its session and sequence", async () => {
  const client = gateway({ resume: true });
  const ready = next(client, "event");
  await client.connect();
  sockets[0]!.send(await readyFrame(7));
  await ready;

  onFrame = (socket, f) => {
    if (f.type === "heartbeat") socket.send(JSON.stringify({ event: "HEARTBEAT_ACK" }));
  };
  const resumed = next(client, "resumed");
  sockets[0]!.close();

  expect(await resumed).toBe(0);
  const identify = received[1]![0];
  expect(identify.data.last_seq).toBe(7);
  expect(typeof identify.data.session_token).toBe("string");
  // The heartbeat that probes the resume doesn't count as one awaiting its ack.
  expect(received[1]![1].type).toBe("heartbeat");
});

test("without resume it still tells the sequence, but no session", async () => {
  const client = gateway();
  const ready = next(client, "event");
  await client.connect();
  sockets[0]!.send(await readyFrame(3));
  await ready;
  const connected = next(client, "state", (state) => state === "connected");
  sockets[0]!.close();
  await connected;
  await until(() => received[1]?.length === 1);
  expect(received[1]![0].data.last_seq).toBe(3);
  expect(received[1]![0].data.session_token).toBeUndefined();
});

test("a fresh session is asked for when wanted", async () => {
  const client = gateway({ resume: true });
  const ready = next(client, "event");
  await client.connect();
  sockets[0]!.send(await readyFrame(3));
  await ready;
  client.wantFreshSession();
  const connected = next(client, "state", (state) => state === "connected");
  sockets[0]!.close();
  await connected;
  await until(() => received[1]?.length === 1);
  expect(received[1]![0].data.session_token).toBeUndefined();
});

test("close code 4000 stops it reconnecting", async () => {
  const client = gateway();
  await client.connect();
  const close = next(client, "close");
  sockets[0]!.send(JSON.stringify({ event: "close-with-reason", code: 4000, reason: "refused" }));
  expect(await close).toEqual({ code: 4000, reason: "refused", shardId: 0 });
  const down = next(client, "state", (state) => state === "disconnected");
  sockets[0]!.close();
  await down;
  await Bun.sleep(1100);
  expect(sockets).toHaveLength(1);
});

test("another close code does not", async () => {
  const client = gateway();
  await client.connect();
  const close = next(client, "close");
  sockets[0]!.send(JSON.stringify({ event: "close-with-reason", code: 4004, reason: "session ended" }));
  await close;
  const back = next(client, "state", (state) => state === "connected");
  sockets[0]!.close();
  await back;
  expect(sockets).toHaveLength(2);
});

test("a refused upgrade fails connect with the failure", async () => {
  refuse = true;
  const client = gateway();
  const announced = next(client, "connectFailed");
  const failure = await client.connect().catch((e) => e);
  expect(failure).toBeInstanceOf(GatewayConnectError);
  expect((await announced).failures).toBe(1);
  expect(failure.failure.shardId).toBe(0);
  expect(client.state).toBe("disconnected");
});

test("reconnect keeps trying until a socket opens, and retryNow skips the wait", async () => {
  refuse = true;
  const client = gateway();
  await client.connect().catch(() => {});
  const opened = client.reconnect();
  await until(() => client.state === "reconnecting");
  refuse = false;
  expect(client.retryNow()).toBe(true);
  expect(await opened).toBe(true);
  expect(client.connection).toBe(1);
});

test("the token never reaches the log", async () => {
  const lines: string[] = [];
  refuse = true;
  const client = gateway({ log: (line) => lines.push(line) }, rest("sec ret/token"));
  await client.connect().catch(() => {});
  expect(lines.length).toBeGreaterThan(0);
  expect(lines.join("\n")).not.toContain("sec ret");
  expect(lines.join("\n")).not.toContain("sec%20ret");
});

test("destroying ends everything and is final", async () => {
  const client = gateway();
  const waiting = client.waitForConnection();
  await client.connect();
  expect(await waiting).toBe(true);
  const destroyed = next(client, "destroyed");
  client.destroy();
  await destroyed;
  expect(client.state).toBe("disconnected");
  expect(client.send("x", {})).toBe(false);
  await expect(client.connect()).rejects.toBeInstanceOf(GatewayConnectError);
  await Bun.sleep(1100);
  expect(sockets).toHaveLength(1);
});

test("destroying during a retry answers those waiting", async () => {
  refuse = true;
  const client = gateway();
  await client.connect().catch(() => {});
  const opened = client.reconnect();
  client.destroy();
  expect(await opened).toBe(false);
});

test("sending goes on the socket", async () => {
  const client = gateway();
  await client.connect();
  expect(client.send("typing", { room_id: "r" })).toBe(true);
  await until(() => received[0]?.length === 2);
  expect(received[0]![1]).toEqual({ type: "typing", data: { room_id: "r" } });
});

test("a manager runs its shards with one feed", async () => {
  const manager = rest().gatewayManager({ heartbeatIntervalMs: 60_000 });
  const events: string[] = [];
  manager.on("state", (state) => events.push(state));

  await manager.connectAll(2);
  await until(() => received[1]?.length === 1);

  expect(received[0]![0].data).toMatchObject({ shard_id: 0, num_shards: 2 });
  expect(received[1]![0].data).toMatchObject({ shard_id: 1, num_shards: 2 });
  expect(events.filter((state) => state === "connected")).toHaveLength(2);
  expect(manager.connection).toBe(1);
  expect(manager.send("x", {})).toBe(true);

  manager.destroy();
  await expect(manager.connectAll(1)).rejects.toBeInstanceOf(GatewayConnectError);
});

test("the wait grows, up to a limit, as on the BEAM", () => {
  expect(reconnectDelay(0, 0)).toBe(1000);
  expect(reconnectDelay(1, 0)).toBe(2000);
  expect(reconnectDelay(4, 0)).toBe(16_000);
  expect(reconnectDelay(5, 0)).toBe(30_000);
  expect(reconnectDelay(99, 5000)).toBe(30_999);
});
