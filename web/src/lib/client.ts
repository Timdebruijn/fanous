// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { applyPatch } from './patch';
import type { ClientMessage, CommandArgs, CommandName, JSONValue, PatchOp, Role, ServerMessage } from './protocol';

export type ConnectionState = 'connecting' | 'open' | 'closed';
export type Doc = Record<string, JSONValue>;

export interface Welcome {
  role: Role;
  rev: number;
  project: Doc;
  live: Doc;
  caps: Doc;
}

export interface AckError {
  code: string;
  message: string;
}

export interface PreviewInfo {
  id: number;
  codec: 'avc' | 'jpeg';
  w: number;
  h: number;
  fps: number;
}

export interface StreamDescription {
  codec: string;
  description: Uint8Array;
  w: number;
  h: number;
  fps: number;
}

export interface ClientCallbacks {
  /** welcome and snapshot: the documents are replaced */
  onDocs(welcome: Welcome): void;
  /** one patch to apply; the client already checked the revision chain */
  onPatch(doc: 'project' | 'live', ops: PatchOp[], rev: number): void;
  onState(state: ConnectionState, detail?: string): void;
  /** binary stream frames: kind 1 H.264, 2 JPEG, 3 DMX universe, 4 metrics */
  onBinary?(kind: number, stream: number, payload: Uint8Array): void;
  /** an H.264 preview stream (re)announced its decoder configuration */
  onStream?(description: StreamDescription & { id: number }): void;
}

export interface ClientOptions {
  url: string;
  clientId: string;
  /** the role to ask for; the engine grants the highest one this client is entitled to */
  role: Role;
  /** the shell's per-install token (never shown to people) */
  token?: string;
  /** a WebSocket factory for tests */
  socket?: (url: string) => WebSocket;
}

/**
 * The engine's state-sync client (DESIGN.md §11.2): hello → welcome, commands with acks, patches on a
 * revision chain (a gap triggers a snapshot), reconnect with backoff, binary stream dispatch.
 */
export class FanousClient {
  private socket: WebSocket | null = null;
  private rev = -1;
  private resync = false;
  private pending = new Map<string, { resolve: (value: JSONValue) => void; reject: (error: AckError) => void }>();
  private subs = new Map<string, { resolve: (id: number) => void }>();
  /** preview `sub` requests in the order sent: the engine answers each with `sub` or a refusal (`error` with `stream`) in that order */
  private previewSubs: { resolve: (info: PreviewInfo) => void; reject: (error: AckError) => void }[] = [];
  /** per stream id: the latest `stream` description (avcC) for H.264 previews */
  readonly descriptions = new Map<number, StreamDescription>();
  private nextId = 1;
  private attempts = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private closedByUser = false;

  constructor(
    private readonly options: ClientOptions,
    private readonly callbacks: ClientCallbacks,
  ) {}

  connect(): void {
    this.closedByUser = false;
    this.open();
  }

  close(): void {
    this.closedByUser = true;
    if (this.timer) clearTimeout(this.timer);
    this.socket?.close(1000, 'client closed');
    this.socket = null;
  }

  get currentRev(): number {
    return this.rev;
  }

  /** Runs a command; rejects with the engine's {code, message} when it is refused. */
  cmd<N extends CommandName>(name: N, args?: CommandArgs[N]): Promise<JSONValue> {
    const id = `c${this.nextId++}`;
    return new Promise((resolve, reject) => {
      if (!this.send({ t: 'cmd', id, name, args: args as JSONValue })) {
        reject({ code: 'offline', message: 'not connected' });
        return;
      }
      this.pending.set(id, { resolve, reject });
    });
  }

  /** Subscribes to the DMX monitor stream of one universe; resolves to the stream id used in binary frames. */
  subscribeDMX(universe: string): Promise<number> {
    return new Promise((resolve, reject) => {
      if (!this.send({ t: 'sub', stream: 'dmx', universe })) {
        reject({ code: 'offline', message: 'not connected' });
        return;
      }
      this.subs.set(universe, { resolve });
    });
  }

  /** Subscribes to the canvas preview; resolves with the stream id and the codec the engine chose. */
  subscribePreview(codec: 'avc' | 'jpeg', target = 'canvas'): Promise<PreviewInfo> {
    return new Promise((resolve, reject) => {
      if (!this.send({ t: 'sub', stream: 'preview', codec, target })) {
        reject({ code: 'offline', message: 'not connected' });
        return;
      }
      this.previewSubs.push({ resolve, reject });
    });
  }

  unsubscribe(id: number): void {
    this.descriptions.delete(id);
    this.send({ t: 'unsub', id });
  }

  requestSnapshot(): void {
    this.resync = true;
    this.send({ t: 'snapshot' });
  }

  private send(message: ClientMessage): boolean {
    if (this.socket?.readyState !== WebSocket.OPEN) return false;
    this.socket.send(JSON.stringify(message));
    return true;
  }

  private open(): void {
    this.callbacks.onState('connecting');
    const socket = this.options.socket ? this.options.socket(this.options.url) : new WebSocket(this.options.url);
    socket.binaryType = 'arraybuffer';
    this.socket = socket;
    socket.onopen = () => {
      this.attempts = 0;
      this.send({ t: 'hello', clientId: this.options.clientId, schema: 1, role: this.options.role, token: this.options.token });
    };
    socket.onmessage = (event: MessageEvent) => {
      if (typeof event.data === 'string') this.handle(JSON.parse(event.data) as ServerMessage);
      else this.handleBinary(new Uint8Array(event.data as ArrayBuffer));
    };
    socket.onclose = (event: CloseEvent) => {
      if (this.socket !== socket) return;
      this.socket = null;
      for (const { reject } of [...this.pending.values(), ...this.previewSubs]) reject({ code: 'offline', message: 'connection closed' });
      this.pending.clear();
      this.subs.clear();
      this.previewSubs = [];
      this.descriptions.clear();
      this.callbacks.onState('closed', event.reason || `code ${event.code}`);
      if (this.closedByUser || event.code === 4401) return;
      const delay = Math.min(5000, 1000 * 2 ** Math.min(this.attempts++, 3));
      this.timer = setTimeout(() => this.open(), delay);
    };
    socket.onerror = () => {
      /* onclose follows with the reason */
    };
  }

  private handle(message: ServerMessage): void {
    switch (message.t) {
      case 'welcome':
      case 'snapshot': {
        this.rev = message.rev;
        this.resync = false;
        const role = message.t === 'welcome' ? message.role : (this.lastRole ?? 'monitor');
        const caps = message.t === 'welcome' ? (message.caps as Doc) : (this.lastCaps ?? {});
        this.lastRole = role;
        this.lastCaps = caps;
        this.callbacks.onDocs({ role, rev: message.rev, project: message.project as Doc, live: message.live as Doc, caps });
        if (message.t === 'welcome') this.callbacks.onState('open');
        break;
      }
      case 'patch': {
        if (this.resync) return;
        if (message.rev !== this.rev + 1) {
          this.requestSnapshot();
          return;
        }
        this.rev = message.rev;
        this.callbacks.onPatch(message.doc, message.ops, message.rev);
        break;
      }
      case 'ack': {
        const waiter = this.pending.get(message.id);
        this.pending.delete(message.id);
        if (!waiter) return;
        if (message.ok) waiter.resolve(message.result);
        else waiter.reject(message.error);
        break;
      }
      case 'sub': {
        if (message.stream === 'preview') {
          this.previewSubs.shift()?.resolve({ id: message.id, codec: message.codec, w: message.w, h: message.h, fps: message.fps });
          break;
        }
        const waiter = this.subs.get(message.universe);
        this.subs.delete(message.universe);
        waiter?.resolve(message.id);
        break;
      }
      case 'stream': {
        const bytes = Uint8Array.from(atob(message.description), (c) => c.charCodeAt(0));
        const description = { codec: message.codec, description: bytes, w: message.w, h: message.h, fps: message.fps };
        this.descriptions.set(message.id, description);
        this.callbacks.onStream?.({ id: message.id, ...description });
        break;
      }
      case 'error':
        // a refused preview request carries `stream`; without it the error is the connection's (or a stream that went away)
        if (message.stream === 'preview') this.previewSubs.shift()?.reject({ code: message.code, message: message.message });
        else this.callbacks.onState(this.socket ? 'open' : 'closed', `${message.code}: ${message.message}`);
        break;
    }
  }

  private lastRole: Role | null = null;
  private lastCaps: Doc | null = null;

  private handleBinary(bytes: Uint8Array): void {
    if (bytes.length < 5) return;
    const kind = bytes[0]!;
    const stream = ((bytes[1]! << 24) | (bytes[2]! << 16) | (bytes[3]! << 8) | bytes[4]!) >>> 0;
    this.callbacks.onBinary?.(kind, stream, bytes.subarray(5));
  }
}

/** Applies a patch onto a document that may be a Svelte `$state` proxy: in place, fine-grained. */
export function patchDoc(doc: Doc, ops: PatchOp[]): void {
  applyPatch(doc, ops);
}
