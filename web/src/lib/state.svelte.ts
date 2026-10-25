// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { FanousClient, patchDoc, type ConnectionState, type Doc, type PreviewInfo, type StreamDescription } from './client';
import { emptyLive, emptyProject, type LiveDoc, type ProjectDoc } from './docs';
import type { CommandArgs, CommandName, JSONValue, Role } from './protocol';

/** One deep `$state` tree: patches mutate it in place, so only the touched paths re-render. */
export const app = $state({
  connection: 'connecting' as ConnectionState,
  detail: '' as string,
  role: 'monitor' as Role,
  rev: 0,
  project: structuredClone(emptyProject) as ProjectDoc,
  live: structuredClone(emptyLive) as LiveDoc,
  caps: {} as Doc,
  /** last refused command, for a toast */
  lastError: null as { code: string; message: string } | null,
});

export const roleRank: Record<Role, number> = { monitor: 0, operator: 1, programmer: 2 };
export function can(role: Role): boolean {
  return roleRank[app.role] >= roleRank[role];
}

function clientId(): string {
  try {
    const existing = localStorage.getItem('fanous.clientId');
    if (existing) return existing;
    const id = crypto.randomUUID();
    localStorage.setItem('fanous.clientId', id);
    return id;
  } catch {
    return crypto.randomUUID();
  }
}

/** The shell opens the UI with `?token=` from its 0600 file; the token leaves the URL at once. */
function shellToken(): string | undefined {
  const params = new URLSearchParams(location.search);
  const token = params.get('token') ?? undefined;
  if (token) {
    params.delete('token');
    const query = params.toString();
    history.replaceState(null, '', location.pathname + (query ? `?${query}` : '') + location.hash);
  }
  return token;
}

const binaryListeners = new Map<number, (kind: number, payload: Uint8Array) => void>();
const streamListeners = new Map<number, (description: StreamDescription) => void>();
const token = shellToken();

/** Headers for REST calls that change state (ingest, upload): the shell's token when we have it; browsers rely on the session cookie. */
export function authHeaders(): Record<string, string> {
  return token ? { Authorization: `Bearer ${token}` } : {};
}

export const client = new FanousClient(
  {
    url: `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`,
    clientId: clientId(),
    role: 'programmer',
    token,
  },
  {
    onDocs(welcome) {
      app.role = welcome.role;
      app.rev = welcome.rev;
      app.caps = welcome.caps;
      app.project = { ...structuredClone(emptyProject), ...(welcome.project as unknown as ProjectDoc) };
      app.live = { ...structuredClone(emptyLive), ...(welcome.live as unknown as LiveDoc) };
    },
    onPatch(doc, ops, rev) {
      try {
        patchDoc((doc === 'project' ? app.project : app.live) as unknown as Doc, ops);
        app.rev = rev;
      } catch {
        client.requestSnapshot();
      }
    },
    onState(state, detail) {
      app.connection = state;
      app.detail = detail ?? '';
    },
    onBinary(kind, stream, payload) {
      binaryListeners.get(stream)?.(kind, payload);
    },
    onStream(description) {
      streamListeners.get(description.id)?.(description);
    },
  },
);

/** Runs a command and records a refusal for the UI. */
export async function cmd<N extends CommandName>(name: N, args?: CommandArgs[N]): Promise<JSONValue | undefined> {
  try {
    const result = await client.cmd(name, args);
    app.lastError = null;
    return result;
  } catch (error) {
    app.lastError = error as { code: string; message: string };
    return undefined;
  }
}

export async function subscribeDMX(universe: string, listener: (payload: Uint8Array) => void): Promise<() => void> {
  const id = await client.subscribeDMX(universe);
  binaryListeners.set(id, (_kind, payload) => listener(payload));
  return () => {
    binaryListeners.delete(id);
    client.unsubscribe(id);
  };
}

/** Canvas preview: H.264 access units (kind 1) or JPEGs (kind 2) plus the decoder description for H.264. */
export async function subscribePreview(
  codec: 'avc' | 'jpeg',
  onFrame: (kind: number, payload: Uint8Array) => void,
  onDescription: (description: StreamDescription) => void,
  target = 'canvas',
): Promise<PreviewInfo & { stop: () => void }> {
  const info = await client.subscribePreview(codec, target);
  binaryListeners.set(info.id, onFrame);
  streamListeners.set(info.id, onDescription);
  const existing = client.descriptions.get(info.id);
  if (existing) onDescription(existing);
  return {
    ...info,
    stop: () => {
      binaryListeners.delete(info.id);
      streamListeners.delete(info.id);
      client.unsubscribe(info.id);
    },
  };
}

export function connect(): void {
  client.connect();
}
