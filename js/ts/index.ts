// A client for the Duvet chat platform. Everything takes and returns plain values
// (`string | null`, arrays, `Date`), and every failed call throws a `DuvetError`.
import * as rest from "../build/dev/javascript/libduvet_js/libduvet_js/rest.mjs";
import * as apiRouter from "../build/dev/javascript/libduvet/libduvet/api_router.mjs";
import { unwrap } from "./convert.js";
import { GatewayClient, GatewayManager, type GatewayOptions } from "./gateway.js";
import { BotMethods, RestMethods, type SignIn, decodeSignIn } from "./generated.js";

export { DuvetError } from "./convert.js";
export * from "./gateway.js";
export type * from "./generated.js";

const r: any = rest;

export interface ClientOptions {
  /** The access token of a session a login started before. */
  token?: string;
  /** The session (refresh) token that goes with it. */
  sessionToken?: string;
  /** The API's host, without a scheme. `api.duvet.chat` by default. */
  api?: string;
  /** The gateway's host, without a scheme. `ws.duvet.chat` by default. */
  ws?: string;
  /** Whether to use https and wss; a local server may not. True by default. */
  secure?: boolean;
  /** A request fails once this long passes without progress. 20 seconds by default. */
  timeoutMs?: number;
}

function routerFrom(options: ClientOptions): unknown {
  const router = (apiRouter as any).default_router();
  return new router.constructor(
    options.api ?? router.api,
    options.ws ?? router.ws,
    router.base,
    router.cdn,
    options.secure ?? router.secure,
  );
}

/** Read acks go out at most once per key every 3 seconds, with the newest ID. */
const ackInterval = 3000;

class AckThrottle {
  private readonly keys = new Map<string, { sentId: string; sentAt: number; pendingId?: string; timer?: ReturnType<typeof setTimeout> }>();

  constructor(private readonly send: (key: string, messageId: string) => void) {}

  ack(key: string, messageId: string): void {
    const state = this.keys.get(key);
    const now = Date.now();
    if (!state) {
      this.keys.set(key, { sentId: messageId, sentAt: now });
      this.send(key, messageId);
      return;
    }
    // IDs are UUIDv7, so they compare by time as strings; never ack backwards.
    if (messageId <= state.sentId || (state.pendingId && messageId <= state.pendingId)) return;
    if (now - state.sentAt >= ackInterval && !state.timer) {
      state.sentId = messageId;
      state.sentAt = now;
      this.send(key, messageId);
      return;
    }
    state.pendingId = messageId;
    state.timer ??= setTimeout(() => {
      const pending = state.pendingId!;
      state.sentId = pending;
      state.sentAt = Date.now();
      state.pendingId = undefined;
      state.timer = undefined;
      this.send(key, pending);
    }, ackInterval - (now - state.sentAt));
  }

  dispose(): void {
    for (const state of this.keys.values()) clearTimeout(state.timer);
    this.keys.clear();
  }
}

/** A client for the API. For a bot, use `DuvetClient.bot(token)`. */
export class DuvetClient extends RestMethods {
  /** The endpoints a bot calls with its own token: interactions, commands, room messages. */
  readonly bot: BotMethods;
  private readonly roomAcks: AckThrottle;
  private readonly conversationAcks: AckThrottle;

  constructor(options: ClientOptions = {}, handle?: unknown) {
    const made =
      handle ?? r.new$(routerFrom(options), options.token ?? "", options.sessionToken ?? "", options.timeoutMs ?? 20_000);
    super(made);
    this.bot = new BotMethods(made);
    const acks = (path: (key: string) => string, action: string) =>
      new AckThrottle((key, messageId) => void r.send_ack(made, path(key), action, messageId));
    this.roomAcks = acks((key) => `/api/rooms/${key}/ack`, "ack room");
    this.conversationAcks = acks((key) => `/api/users/@me/conversations/${key}/ack`, "ack conversation");
  }

  /** A client for a bot: its token goes as `Authorization: Bot <token>`, and a 401 ends the request. */
  static bot(token: string, options: Omit<ClientOptions, "token" | "sessionToken"> = {}): DuvetClient {
    return new DuvetClient(options, r.new_bot(routerFrom(options), token, options.timeoutMs ?? 20_000));
  }

  get token(): string {
    return r.token(this.$handle);
  }

  get sessionToken(): string {
    return r.session_token(this.$handle);
  }

  get isAuthenticated(): boolean {
    return this.token !== "";
  }

  get isBot(): boolean {
    return r.is_bot(this.$handle);
  }

  /** Logs in, and keeps the tokens for the calls after it. */
  async logIn(email: string, password: string): Promise<SignIn> {
    return unwrap(await r.log_in(this.$handle, email, password), decodeSignIn);
  }

  /** Ends the session. Best effort: the tokens are forgotten either way. */
  async logOut(): Promise<void> {
    await r.log_out(this.$handle);
  }

  /** Rotates the session's tokens. */
  async refreshSession(): Promise<SignIn> {
    return unwrap(await r.refresh_session(this.$handle), decodeSignIn);
  }

  /** Marks the room read up to `messageId`. Throttled, and failures are ignored. */
  ackRoom(roomId: string, messageId: string): void {
    this.roomAcks.ack(roomId, messageId);
  }

  /** Marks the conversation read up to `messageId`, as `ackRoom` does. */
  ackConversation(conversationId: string, messageId: string): void {
    this.conversationAcks.ack(conversationId, messageId);
  }

  /** Cancels the read acks still waiting. */
  dispose(): void {
    this.roomAcks.dispose();
    this.conversationAcks.dispose();
  }

  /** One gateway socket, not connected yet. */
  gateway(options: GatewayOptions = {}): GatewayClient {
    return new GatewayClient(this.$handle, options);
  }

  /** A manager that runs a gateway socket per shard. */
  gatewayManager(options: GatewayOptions = {}): GatewayManager {
    return new GatewayManager(this.$handle, options);
  }
}
