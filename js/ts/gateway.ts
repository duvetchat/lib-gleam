// The gateway client, the counterpart of `libduvet/gateway/client` and `manager`:
// the same frames, heartbeat, reconnect and resume rules. The BEAM's is an actor
// because it blocks; here the event loop already is one, so this is written for
// it rather than compiled. The frames' models are still Gleam's decoders.
import * as rest from "../build/dev/javascript/libduvet_js/libduvet_js/rest.mjs";
import * as apiRouter from "../build/dev/javascript/libduvet/libduvet/api_router.mjs";
import * as decoding from "../build/dev/javascript/libduvet/libduvet/model/decoding.mjs";
import * as envelope from "../build/dev/javascript/libduvet/libduvet/model/envelope.mjs";
import * as prelude from "../build/dev/javascript/libduvet_js/gleam.mjs";
import * as option from "../build/dev/javascript/gleam_stdlib/gleam/option.mjs";
import {
  type GatewayCloseReason,
  type GatewayConnectFailure,
  type GatewayEventPayload,
  decodeGatewayCloseReason,
  decodeGatewayEventPayload,
} from "./generated.js";

const Some: any = (option as any).Some;
const Ok: any = (prelude as any).Ok;
const envelopes: any = envelope;
const decoders: any = decoding;

export type GatewayConnectionState = "connecting" | "connected" | "reconnecting" | "disconnected";

/** What a gateway client or manager tells its listeners. */
export interface GatewayEvents {
  /** A decoded event from the gateway, including READY. */
  event: GatewayEventPayload;
  /** A frame as the gateway sent it, for what the models don't cover (a bot's INTERACTION_CREATE, say). */
  raw: string;
  /** Something the client couldn't read. */
  malformed: string;
  state: GatewayConnectionState;
  /** The gateway resumed a shard's session on a new socket. */
  resumed: number;
  /** The reason the gateway gave before it closed the socket. */
  close: GatewayCloseReason;
  /** An attempt to open a socket failed. */
  connectFailed: GatewayConnectFailure;
  /** The client was destroyed; nothing else comes. */
  destroyed: void;
}

type Listener<K extends keyof GatewayEvents> = (value: GatewayEvents[K]) => void;

class Feed {
  private readonly listeners = new Map<keyof GatewayEvents, Set<Listener<any>>>();

  on<K extends keyof GatewayEvents>(kind: K, listener: Listener<K>): () => void {
    let set = this.listeners.get(kind);
    if (!set) this.listeners.set(kind, (set = new Set()));
    set.add(listener);
    return () => set!.delete(listener);
  }

  emit<K extends keyof GatewayEvents>(kind: K, value: GatewayEvents[K]): void {
    for (const listener of this.listeners.get(kind) ?? []) {
      // One listener's failure mustn't stop the others, or the socket's handler.
      try {
        listener(value);
      } catch (cause) {
        console.error("[libduvet] a gateway listener threw:", cause);
      }
    }
  }
}

export interface GatewayOptions {
  /** Resume the session after a drop, instead of starting a new one with READY. */
  resume?: boolean;
  /** How long opening a socket may take: 15 seconds by default. */
  connectTimeoutMs?: number;
  /** Sent in identify: "desktop", "web" or "mobile". */
  platform?: string;
  log?: (message: string) => void;
  /** @internal The gateway's 45s and 15s, shortened by tests. */
  heartbeatIntervalMs?: number;
  /** @internal */
  heartbeatAckTimeoutMs?: number;
}

/** Why `connect` ended without a socket. */
export class GatewayConnectError extends Error {
  /** The failed attempt; null when the client was destroyed or another attempt replaced this one. */
  readonly failure: GatewayConnectFailure | null;

  constructor(failure: GatewayConnectFailure | null) {
    super(failure?.error ?? "the gateway client was destroyed");
    this.name = "GatewayConnectError";
    this.failure = failure;
  }
}

/** How long to wait before another socket, as `reconnect_delay` on the BEAM. */
export function reconnectDelay(failed: number, jitterMs: number): number {
  return Math.min(1000 * 2 ** Math.min(failed, 5), 30_000) + Math.min(jitterMs, 999);
}

interface Shard {
  id: number;
  count: number;
}

/**
 * A single WebSocket connection to the gateway. It keeps its heartbeat, reconnects
 * by itself and tracks the sequence, and tells its listeners through `on`.
 */
export class GatewayClient {
  private readonly feed: Feed;
  private readonly heartbeatMs: number;
  private readonly ackTimeoutMs: number;
  private socket: WebSocket | null = null;
  private opening: WebSocket | null = null;
  private openTimer: ReturnType<typeof setTimeout> | undefined;
  private connectWaiter: { resolve: () => void; reject: (cause: Error) => void } | null = null;
  private reconnectWaiters: Array<(opened: boolean) => void> = [];
  private connectionWaiters: Array<(connected: boolean) => void> = [];
  private currentState: GatewayConnectionState = "disconnected";
  private destroyed = false;
  private stopped = false;
  private reconnecting = false;
  private retryTimer: ReturnType<typeof setTimeout> | undefined;
  private retryPending = false;
  private reconnectAttempts = 0;
  private failures = 0;
  private lastSeq = 0;
  private sessionToken: string | null = null;
  private freshWanted = false;
  private resuming = false;
  private probing = false;
  private resumedFrom = 0;
  private awaitAck = false;
  private heartbeatTimer: ReturnType<typeof setInterval> | undefined;
  private ackTimer: ReturnType<typeof setTimeout> | undefined;
  private connections = 0;

  /** @internal */
  constructor(
    private readonly handle: unknown,
    private readonly options: GatewayOptions,
    private readonly shard: Shard = { id: 0, count: 1 },
    feed?: Feed,
  ) {
    this.feed = feed ?? new Feed();
    this.heartbeatMs = options.heartbeatIntervalMs ?? 45_000;
    this.ackTimeoutMs = options.heartbeatAckTimeoutMs ?? 15_000;
  }

  /** Listens for one kind of message, and answers how to stop. */
  on<K extends keyof GatewayEvents>(kind: K, listener: Listener<K>): () => void {
    return this.feed.on(kind, listener);
  }

  get state(): GatewayConnectionState {
    return this.currentState;
  }

  /** The number of the socket open now (counted from 1), or null while none is. */
  get connection(): number | null {
    return this.socket ? this.connections : null;
  }

  /** Opens a socket and identifies on it, after closing the one open before. */
  connect(): Promise<void> {
    if (this.destroyed) return Promise.reject(new GatewayConnectError(null));
    this.stopped = false;
    this.cancelRetry();
    return new Promise((resolve, reject) => {
      this.connectWaiter?.reject(new GatewayConnectError(null));
      this.connectWaiter = { resolve, reject };
      this.startAttempt(this.reconnecting);
    });
  }

  /** Opens a socket if none is, trying until one opens; answers whether one did. */
  reconnect(): Promise<boolean> {
    if (this.destroyed) return Promise.resolve(false);
    if (this.socket) return Promise.resolve(true);
    return new Promise((resolve) => {
      this.reconnectWaiters.push(resolve);
      if (!this.retryPending && !this.reconnecting) this.scheduleRetry();
    });
  }

  /** Answers whether a socket opened, waiting for one while any attempt may still make it. */
  waitForConnection(): Promise<boolean> {
    if (this.currentState === "connected") return Promise.resolve(true);
    if (this.destroyed) return Promise.resolve(false);
    return new Promise((resolve) => this.connectionWaiters.push(resolve));
  }

  /** Sends an event message, and answers whether it went out on an open socket. */
  send(type: string, data: unknown): boolean {
    const sent = this.sendJson({ type, data });
    if (!sent) this.log(`cannot send "${type}" – socket not open (state: ${this.currentState})`);
    return sent;
  }

  /** Makes the next identify start a new session, with READY. */
  wantFreshSession(): void {
    this.freshWanted = true;
  }

  /** Ends the wait before the next attempt, and answers whether there was one. */
  retryNow(): boolean {
    if (this.destroyed || !this.retryPending) return false;
    this.cancelRetry();
    this.reconnectAttempts++;
    this.startAttempt(true);
    return true;
  }

  /** Closes the socket for good. */
  destroy(): void {
    if (this.destroyed) return;
    this.destroyed = true;
    this.cancelRetry();
    this.dropOpening();
    this.closeSocket();
    this.setState("disconnected");
    this.settleConnect(new GatewayConnectError(null));
    this.settle(false);
    this.feed.emit("destroyed", undefined);
    this.log("destroyed");
  }

  // -------------------------------------------------------------------------
  // Opening
  // -------------------------------------------------------------------------

  private startAttempt(reconnecting: boolean): void {
    this.closeSocket();
    this.dropOpening();
    if (!reconnecting) this.setState("connecting");

    const token: string = (rest as any).token(this.handle);
    const router: any = (rest as any).router(this.handle);
    const authority = `${router.secure ? "wss" : "ws"}://${(apiRouter as any).custom_api_url(router, "ws")}`;
    this.log(`connecting to ${authority}/gateway`);
    const url = `${authority}/gateway?token=${(apiRouter as any).encode_query_component(token)}`;
    const headers = Object.fromEntries([...(rest as any).auth_headers(this.handle)].map(([k, v]: any) => [k, v]));

    let socket: WebSocket;
    try {
      // Bun and Node take headers here; browsers can't, and the token in the URL stands in.
      socket = new (WebSocket as any)(url, { headers });
    } catch (cause) {
      this.openFailed(`connect failed: ${this.mask(String(cause))}`);
      return;
    }
    this.opening = socket;
    this.openTimer = setTimeout(() => {
      if (this.opening !== socket) return;
      this.dropOpening();
      this.openFailed("Timeout: the gateway did not take the socket");
    }, this.options.connectTimeoutMs ?? 15_000);

    socket.onopen = () => {
      if (this.opening !== socket) return;
      clearTimeout(this.openTimer);
      this.opening = null;
      this.socket = socket;
      this.connections++;
      this.reconnectAttempts = 0;
      this.failures = 0;
      this.reconnecting = false;
      this.retryPending = false;
      this.identify();
      this.startHeartbeat();
      this.setState("connected");
      this.log("connected");
      this.settleConnect(null);
      this.settle(true);
    };
    socket.onmessage = (message) => {
      if (this.socket === socket && typeof message.data === "string") this.handleText(message.data);
    };
    socket.onerror = (event) => {
      if (this.socket === socket) this.dropped(`socket error: ${this.mask(String((event as any).message ?? "unknown"))}`);
    };
    socket.onclose = (event) => {
      if (this.opening === socket) {
        clearTimeout(this.openTimer);
        this.opening = null;
        this.openFailed(`connect failed: closed (${event.code})`);
      } else if (this.socket === socket) {
        this.dropped(`socket closed (${event.code} ${event.reason})`);
      }
    };
  }

  private openFailed(error: string): void {
    this.failures++;
    const failure: GatewayConnectFailure = {
      shardId: this.shard.id,
      failures: this.failures,
      // shortcut: WebSocket hides the refused upgrade's status, so this stays null; upgrade if runtimes expose it.
      httpStatus: null,
      error,
    };
    this.feed.emit("connectFailed", failure);
    this.log(error);
    this.settleConnect(new GatewayConnectError(failure));
    if (this.reconnecting) this.scheduleRetry();
    else this.setState("disconnected");
  }

  private settleConnect(failure: Error | null): void {
    const waiter = this.connectWaiter;
    this.connectWaiter = null;
    if (failure) waiter?.reject(failure);
    else waiter?.resolve();
  }

  private settle(opened: boolean): void {
    for (const waiter of this.reconnectWaiters.splice(0)) waiter(opened);
    for (const waiter of this.connectionWaiters.splice(0)) waiter(opened);
  }

  private scheduleRetry(): void {
    this.setState("reconnecting");
    const delay = reconnectDelay(this.reconnectAttempts, Math.floor(Math.random() * 1000));
    this.log(`reconnecting in ${delay}ms (attempt ${this.reconnectAttempts + 1})`);
    clearTimeout(this.retryTimer);
    this.retryTimer = setTimeout(() => {
      this.retryPending = false;
      if (this.destroyed || this.socket || this.opening) return;
      this.reconnectAttempts++;
      this.startAttempt(true);
    }, delay);
    this.retryPending = true;
    this.reconnecting = true;
  }

  private cancelRetry(): void {
    clearTimeout(this.retryTimer);
    this.retryPending = false;
  }

  // -------------------------------------------------------------------------
  // Dropping
  // -------------------------------------------------------------------------

  private dropped(why: string): void {
    this.log(why);
    this.closeSocket();
    if (this.destroyed) return;
    if (this.stopped) {
      this.log("not reconnecting: the gateway refused the shard");
      this.setState("disconnected");
    } else {
      this.scheduleRetry();
    }
  }

  private dropOpening(): void {
    clearTimeout(this.openTimer);
    const opening = this.opening;
    this.opening = null;
    if (opening) closeQuietly(opening);
  }

  private closeSocket(): void {
    this.stopHeartbeat();
    this.probing = false;
    if (this.resuming) {
      this.resuming = false;
      // A resume that delivered something moved the sequence past what the old token can replay.
      if (this.lastSeq !== this.resumedFrom) this.sessionToken = null;
    }
    const socket = this.socket;
    this.socket = null;
    if (socket) closeQuietly(socket);
  }

  // -------------------------------------------------------------------------
  // Heartbeats
  // -------------------------------------------------------------------------

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => this.heartbeatTick(), this.heartbeatMs);
  }

  private stopHeartbeat(): void {
    clearInterval(this.heartbeatTimer);
    clearTimeout(this.ackTimer);
    this.awaitAck = false;
  }

  private heartbeatTick(): void {
    if (!this.socket) return;
    if (this.awaitAck) {
      this.dropped("missed heartbeat ack – closing");
      return;
    }
    this.log("♥ heartbeat");
    if (this.sendJson({ type: "heartbeat", data: {} })) this.awaitAck = true;
    clearTimeout(this.ackTimer);
    this.ackTimer = setTimeout(() => {
      if (this.awaitAck) this.dropped("heartbeat ack timeout – closing");
    }, this.ackTimeoutMs);
  }

  private onAck(): void {
    if (this.resuming) {
      this.log(`session resumed (seq=${this.lastSeq})`);
      this.resuming = false;
      this.feed.emit("resumed", this.shard.id);
    }
    if (this.probing) {
      this.probing = false;
      return;
    }
    this.awaitAck = false;
    clearTimeout(this.ackTimer);
    this.log("♥ ack");
  }

  // -------------------------------------------------------------------------
  // Identifying
  // -------------------------------------------------------------------------

  private identify(): void {
    const resuming =
      (this.options.resume ?? false) && this.sessionToken !== null && this.lastSeq > 0 && !this.freshWanted;
    const data: Record<string, unknown> = { token: (rest as any).token(this.handle) };
    if (this.lastSeq > 0) data.last_seq = this.lastSeq;
    if (resuming) data.session_token = this.sessionToken;
    if (this.shard.count > 1) {
      data.shard_id = this.shard.id;
      data.num_shards = this.shard.count;
    }
    if (this.options.platform) data.platform = this.options.platform;
    const sent = this.sendJson({ type: "identify", data });
    this.log(`identify sent (shard=${this.shard.id}/${this.shard.count}, seq=${this.lastSeq}${resuming ? ", resuming" : ""})`);
    if (resuming && sent) {
      this.probing = this.sendJson({ type: "heartbeat", data: {} });
      this.resuming = true;
      this.resumedFrom = this.lastSeq;
    }
  }

  private sendJson(message: unknown): boolean {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return false;
    this.socket.send(JSON.stringify(message));
    return true;
  }

  // -------------------------------------------------------------------------
  // Frames
  // -------------------------------------------------------------------------

  private handleText(text: string): void {
    const parsed = (rest as any).parse_frame(text);
    if (!(parsed instanceof Ok)) {
      this.log("malformed message");
      this.feed.emit("malformed", "a gateway frame isn't JSON");
      return;
    }
    const object = parsed[0];
    this.feed.emit("raw", text);
    const type: string = decoders.string_or(object, "event", "");
    if (type.toLowerCase() === "close-with-reason") {
      const close = decodeGatewayCloseReason(envelopes.close_reason_from_json(object, this.shard.id));
      this.log(`the gateway closes the socket: ${close.code} ${close.reason}`);
      if (close.code === 4000) this.stopped = true;
      this.feed.emit("close", close);
      return;
    }
    if (type.toUpperCase() === "HEARTBEAT_ACK") {
      this.onAck();
      return;
    }
    // The models panic on a frame they can't read; on the BEAM that ends the actor, here it's one bad frame.
    let frame: any;
    let payload: GatewayEventPayload | null = null;
    try {
      frame = envelopes.from_json(object);
      if (frame.d instanceof Some) payload = decodeGatewayEventPayload(frame.d[0]);
    } catch (cause) {
      this.log(`malformed ${type}: ${String(cause)}`);
      this.feed.emit("malformed", `a ${type} frame couldn't be read`);
      return;
    }
    if (frame.s > 0) this.lastSeq = frame.s;
    if (!payload) {
      this.log(`warning: received event with null payload (type=${type})`);
      return;
    }
    if (payload.tag === "ReadyEvent") {
      this.sessionToken = payload.data.sessionToken;
      this.freshWanted = false;
      this.resuming = false;
    }
    this.feed.emit("event", payload);
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  private setState(state: GatewayConnectionState): void {
    if (state === this.currentState) return;
    this.currentState = state;
    this.log(`state: ${state}`);
    this.feed.emit("state", state);
  }

  private log(message: string): void {
    this.options.log?.(this.mask(message));
  }

  private mask(text: string): string {
    const token: string = (rest as any).token(this.handle);
    if (token === "") return text;
    return text.replaceAll((apiRouter as any).encode_query_component(token), "***").replaceAll(token, "***");
  }
}

function closeQuietly(socket: WebSocket): void {
  socket.onopen = socket.onmessage = socket.onerror = socket.onclose = null;
  try {
    socket.close();
  } catch {
    // It may have failed before it opened.
  }
}

/** Runs one client per shard, with one feed for them all. */
export class GatewayManager {
  private readonly feed = new Feed();
  private shards: GatewayClient[] = [];
  private destroyed = false;

  /** @internal */
  constructor(
    private readonly handle: unknown,
    private readonly options: GatewayOptions,
  ) {}

  on<K extends keyof GatewayEvents>(kind: K, listener: Listener<K>): () => void {
    return this.feed.on(kind, listener);
  }

  /** Connects `shardCount` shards one by one, trying until each has a socket. */
  async connectAll(shardCount = 1): Promise<void> {
    for (let id = 0; id < shardCount; id++) {
      if (this.destroyed) throw new GatewayConnectError(null);
      const shard = new GatewayClient(this.handle, this.options, { id, count: shardCount }, this.feed);
      this.shards.push(shard);
      try {
        await shard.connect();
      } catch {
        if (!(await shard.reconnect())) throw new GatewayConnectError(null);
      }
    }
  }

  /** Sends an event message through shard 0, and answers whether it went out. */
  send(type: string, data: unknown): boolean {
    return this.shards[0]?.send(type, data) ?? false;
  }

  /** Makes each shard's next identify start a new session. */
  wantFreshSession(): void {
    for (const shard of this.shards) shard.wantFreshSession();
  }

  /** Ends each shard's wait before its next attempt, and answers whether one was waiting. */
  retryNow(): boolean {
    return this.shards.map((shard) => shard.retryNow()).some(Boolean);
  }

  /** Shard 0's connection number, or null while it has no socket. */
  get connection(): number | null {
    return this.shards[0]?.connection ?? null;
  }

  /** Shuts down every shard for good. */
  destroy(): void {
    if (this.destroyed) return;
    this.destroyed = true;
    for (const shard of this.shards) shard.destroy();
    this.shards = [];
  }
}
