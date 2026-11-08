// The REST client against a fake API, down to the requests it sends: the parts
// that are new on JavaScript (fetch, promises, conversions) and the rules the
// BEAM's suite checks (renewal, bots, errors).
import { afterAll, beforeEach, expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { DuvetClient, DuvetError } from "../ts/index";

const fixtures = join(import.meta.dir, "../../test/fixtures");
const fixture = (name: string) => Bun.file(join(fixtures, `${name}.json`)).json();

type Seen = { method: string; path: string; search: string; headers: Headers; body: Uint8Array };
const seen: Seen[] = [];
let answer: (seen: Seen) => Response | Promise<Response> = () => Response.json({});

const server = Bun.serve({
  port: 0,
  async fetch(request) {
    const url = new URL(request.url);
    const entry = {
      method: request.method,
      path: url.pathname,
      search: url.search,
      headers: request.headers,
      body: new Uint8Array(await request.arrayBuffer()),
    };
    seen.push(entry);
    return answer(entry);
  },
});
afterAll(() => server.stop(true));
beforeEach(() => {
  seen.length = 0;
  answer = () => Response.json({});
});

const options = { api: `localhost:${server.port}`, secure: false, timeoutMs: 2000 };
const textOf = (entry: Seen) => new TextDecoder().decode(entry.body);

test("a model comes back as plain values", async () => {
  const message = await fixture("message_response.full");
  answer = () => Response.json(message);
  const client = new DuvetClient({ ...options, token: "tok", sessionToken: "ses" });

  const sent = await client.sendMessage("room-1", "hello");

  expect(seen[0]!.method).toBe("POST");
  expect(seen[0]!.path).toBe("/api/rooms/room-1/messages");
  expect(seen[0]!.headers.get("authorization")).toBe("Bearer tok");
  expect(seen[0]!.headers.get("x-session-token")).toBe("ses");
  expect(JSON.parse(textOf(seen[0]!))).toEqual({ content: "hello" });
  expect(sent.id).toBe(message.id);
  expect(sent.createdAt).toBeInstanceOf(Date);
  expect(Array.isArray(sent.attachments)).toBe(true);
});

test("absent and null fields read as null", async () => {
  answer = async () => Response.json({ ...(await fixture("message_response.nulls")), room_id: "r" });
  const sent = await new DuvetClient({ ...options, token: "t" }).sendMessage("r", "x");
  expect(sent.webhookId).toBeNull();
  expect(sent.deletedAt).toBeNull();
});

test("a list and its query, with an option left out and given", async () => {
  const message = await fixture("message_model.full");
  answer = () => Response.json([message, message]);
  const client = new DuvetClient({ ...options, token: "t" });

  const page = await client.getMessages("room", null, 50);
  expect(page).toHaveLength(2);
  expect(seen[0]!.search).toBe("?count=50");

  await client.getMessages("room", "before id", 10);
  expect(new URLSearchParams(seen[1]!.search).get("before")).toBe("before id");
});

test("a file goes as a multipart form with its bytes intact", async () => {
  answer = async () => Response.json(await fixture("message_model.full"));
  const client = new DuvetClient({ ...options, token: "t" });
  const bytes = Uint8Array.from({ length: 300_000 }, (_, i) => i % 251);
  const progress: Array<[number, number]> = [];

  await client.sendMessage("room", "with a file", {
    nonce: "n1",
    files: [{ field: "files", bytes, filename: "data.bin" }],
    onProgress: (sent, total) => progress.push([sent, total]),
  });

  const contentType = seen[0]!.headers.get("content-type")!;
  expect(contentType).toStartWith("multipart/form-data");
  const form = await new Response(seen[0]!.body as BodyInit, { headers: { "content-type": contentType } }).formData();
  expect(form.get("content")).toBe("with a file");
  expect(form.get("nonce")).toBe("n1");
  const file = form.get("files") as unknown as File;
  expect(file.name).toBe("data.bin");
  expect(new Uint8Array(await file.arrayBuffer())).toEqual(bytes);
  expect(progress.at(-1)![0]).toBe(progress.at(-1)![1]);
});

test("a failure throws a DuvetError with its status and detail", async () => {
  answer = () => new Response("nope", { status: 404 });
  const client = new DuvetClient({ ...options, token: "t" });

  const failure = await client.getMessages("room", null, 1).catch((e) => e);

  expect(failure).toBeInstanceOf(DuvetError);
  expect(failure.status).toBe(404);
  expect(failure.message).toContain("404");
  expect(failure.detail.tag).toBe("ApiError");
  expect(failure.detail.failure.body).toBe("nope");
});

test("a request with no progress times out", async () => {
  answer = async () => {
    await Bun.sleep(400);
    return Response.json({});
  };
  const client = new DuvetClient({ ...options, token: "t", timeoutMs: 50 });
  const failure = await client.getMessages("room", null, 1).catch((e) => e);
  expect(failure.detail).toEqual({
    tag: "RequestTimeout",
    method: "GET",
    path: "/api/rooms/room/messages",
    timeoutMs: 50,
  });
});

test("an unreachable server is a network error", async () => {
  const client = new DuvetClient({ api: "localhost:1", secure: false, token: "t" });
  const failure = await client.getMessages("room", null, 1).catch((e) => e);
  expect(failure.detail.tag).toBe("NetworkError");
});

test("logging in keeps the tokens; logging out forgets them", async () => {
  answer = () => Response.json({ token: "access", session_token: "refresh" });
  const client = new DuvetClient(options);
  expect(client.isAuthenticated).toBe(false);

  const signIn = await client.logIn("me@example.com", "pw");

  expect(signIn).toEqual({ token: "access", sessionToken: "refresh" });
  expect(client.token).toBe("access");
  expect(JSON.parse(textOf(seen[0]!))).toEqual({ email: "me@example.com", password: "pw" });

  await client.logOut();
  expect(client.isAuthenticated).toBe(false);
});

test("a 401 renews the session once and resends, even for many requests at once", async () => {
  let refreshes = 0;
  answer = async (entry) => {
    if (entry.path === "/api/auth/refresh") {
      refreshes++;
      await Bun.sleep(20);
      expect(entry.headers.get("x-session-token")).toBe("old-session");
      return Response.json({ token: "new", session_token: "new-session" });
    }
    if (entry.headers.get("authorization") !== "Bearer new") return new Response("expired", { status: 401 });
    return Response.json([]);
  };
  const client = new DuvetClient({ ...options, token: "old", sessionToken: "old-session" });

  const pages = await Promise.all([client.getMessages("a", null, 1), client.getMessages("b", null, 1)]);

  expect(pages).toEqual([[], []]);
  expect(refreshes).toBe(1);
  expect(client.sessionToken).toBe("new-session");
});

test("a failed renewal gives the first answer's error, and forgets the tokens", async () => {
  answer = () => new Response("no", { status: 401 });
  const client = new DuvetClient({ ...options, token: "old", sessionToken: "s" });
  const failure: any = await client.getMessages("a", null, 1).catch((e) => e);
  expect(failure.status).toBe(401);
  expect(failure.detail.tag).toBe("AuthError");
  expect(client.token).toBe("");
});

test("a bot sends its token as such and never renews", async () => {
  answer = () => new Response("no", { status: 401 });
  const bot = DuvetClient.bot("bot-token", options);
  expect(bot.isBot).toBe(true);

  const failure: any = await bot.bot.getApplication().catch((e) => e);

  expect(failure.status).toBe(401);
  expect(seen).toHaveLength(1);
  expect(seen[0]!.headers.get("authorization")).toBe("Bot bot-token");
  expect(seen[0]!.headers.get("x-session-token")).toBeNull();
});

test("a bot's JSON stays JSON both ways", async () => {
  const application = await fixture("application.full");
  answer = () => Response.json(application);
  const bot = DuvetClient.bot("b", options);

  expect(((await bot.bot.getApplication()) as any).id).toBe(application.id);

  answer = () => Response.json({ id: "m1", components: [{ type: 1, nested: [1, 2.5, null, "x"] }] });
  const sent = await bot.bot.sendMessage("room", { content: "hi", components: [{ type: 1 }] });
  expect(sent).toEqual({ id: "m1", components: [{ type: 1, nested: [1, 2.5, null, "x"] }] });
  expect(JSON.parse(textOf(seen[1]!))).toEqual({ content: "hi", components: [{ type: 1 }] });

  answer = () => new Response("");
  expect(await bot.bot.nextInteraction("app", true)).toBeNull();
  expect(seen[2]!.search).toBe("?wait=short");
});

test("space commands are cached until forgotten", async () => {
  answer = async () => Response.json(await fixture("space_commands.full"));
  const client = new DuvetClient({ ...options, token: "t" });
  await client.getSpaceCommands("s");
  await client.getSpaceCommands("s");
  expect(seen).toHaveLength(1);
  client.forgetSpaceCommands("s");
  await client.getSpaceCommands("s");
  expect(seen).toHaveLength(2);
});

test("read acks are throttled, and the newest ID wins", async () => {
  const client = new DuvetClient({ ...options, token: "t" });
  client.ackRoom("room", "01");
  client.ackRoom("room", "02");
  client.ackRoom("room", "03");
  await Bun.sleep(50);
  expect(seen.map((entry) => JSON.parse(textOf(entry)).message_id)).toEqual(["01"]);
  client.dispose();
});

test("a voice note in an unknown format is refused before anything is sent", async () => {
  const client = new DuvetClient({ ...options, token: "t" });
  const failure = await client.sendVoiceNote("r", new Uint8Array(1), null, "wav").catch((e) => e);
  expect(failure.detail.tag).toBe("InvalidArgument");
  expect(seen).toHaveLength(0);
});

test("the fixtures of what methods decode read, in every variant", async () => {
  const cases: Array<[string, (client: DuvetClient) => Promise<unknown>]> = [
    ["message_model", (c) => c.sendMessage("r", "x")],
    ["space_commands", (c) => c.getSpaceCommands(crypto.randomUUID())],
    ["room", (c) => c.createRoom("s", "n", 0)],
    ["invite_info", (c) => c.getInvite("x")],
  ];
  const present = new Set(readdirSync(fixtures));
  let decoded = 0;
  for (const [name, call] of cases) {
    for (const variant of ["full", "nulls", "partial"]) {
      if (!present.has(`${name}.${variant}.json`)) continue;
      // As the BEAM's suite does: the server always sets a message's room.
      answer = async () => Response.json({ room_id: "r", ...(await fixture(`${name}.${variant}`)), ...(name === "message_model" ? { room_id: "r" } : {}) });
      await call(new DuvetClient({ ...options, token: "t" }));
      decoded++;
    }
  }
  expect(decoded).toBeGreaterThanOrEqual(8);
});

test("every REST method is on the client", () => {
  const methods = Object.getOwnPropertyNames(Object.getPrototypeOf(DuvetClient.prototype));
  expect(methods.filter((name) => name !== "constructor")).toHaveLength(145);
});
