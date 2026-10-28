// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it, vi } from 'vitest';
import { FanousClient } from './client';

/** A connected client on a fake socket; `deliver` plays a server message. */
function connected() {
  const socket = { readyState: WebSocket.OPEN, send() {}, close() {} } as unknown as WebSocket;
  const onState = vi.fn();
  const client = new FanousClient({ url: 'wss://test/ws', clientId: 't', role: 'programmer', socket: () => socket }, { onDocs() {}, onPatch() {}, onState });
  client.connect();
  const deliver = (message: object) => socket.onmessage?.({ data: JSON.stringify(message) } as MessageEvent);
  return { client, socket, onState, deliver };
}

describe('FanousClient preview subscriptions (B62)', () => {
  it('rejects a refused request and gives the next reply to the next request', async () => {
    const { client, onState, deliver } = connected();
    const refused = client.subscribePreview('avc', 'canvas:2');
    const accepted = client.subscribePreview('avc', 'canvas');
    deliver({ t: 'error', id: 7, stream: 'preview', code: 'badTarget', message: 'preview target canvas:2 is not …' });
    deliver({ t: 'sub', id: 8, stream: 'preview', codec: 'avc', w: 640, h: 360, fps: 30, target: 'canvas' });
    await expect(refused).rejects.toEqual({ code: 'badTarget', message: 'preview target canvas:2 is not …' });
    await expect(accepted).resolves.toMatchObject({ id: 8, codec: 'avc' });
    expect(onState).toHaveBeenCalledTimes(1);  // 'connecting' only: a refusal is the request's, not the connection's
  });

  it('leaves waiting requests alone when a running stream ends (an error with an id and no stream)', async () => {
    const { client, onState, deliver } = connected();
    const waiting = client.subscribePreview('jpeg', 'canvas');
    deliver({ t: 'error', id: 3, code: 'badTarget', message: 'preview target canvas:2 no longer exists' });
    expect(onState).toHaveBeenLastCalledWith('open', 'badTarget: preview target canvas:2 no longer exists');
    deliver({ t: 'sub', id: 9, stream: 'preview', codec: 'jpeg', w: 640, h: 360, fps: 5, target: 'canvas' });
    await expect(waiting).resolves.toMatchObject({ id: 9 });
  });

  it('rejects waiting requests when the connection closes', async () => {
    const { client, socket } = connected();
    const waiting = client.subscribePreview('avc');
    socket.onclose?.({ code: 1006, reason: '' } as CloseEvent);
    await expect(waiting).rejects.toMatchObject({ code: 'offline' });
    client.close();
  });
});

describe('FanousClient thumbnail subscriptions (B29)', () => {
  it('resolves with the stream id, rejects a refusal and does not mix with preview replies', async () => {
    const { client, onState, deliver } = connected();
    const refused = client.subscribeThumbs();
    const preview = client.subscribePreview('avc');
    const thumbs = client.subscribeThumbs();
    deliver({ t: 'error', id: 4, stream: 'thumbs', code: 'noPreview', message: 'the engine is not rendering' });
    deliver({ t: 'sub', id: 5, stream: 'preview', codec: 'avc', w: 640, h: 360, fps: 30, target: 'canvas' });
    deliver({ t: 'sub', id: 6, stream: 'thumbs', w: 160, fps: 4 });
    await expect(refused).rejects.toEqual({ code: 'noPreview', message: 'the engine is not rendering' });
    await expect(preview).resolves.toMatchObject({ id: 5 });
    await expect(thumbs).resolves.toBe(6);
    expect(onState).toHaveBeenCalledTimes(1);
  });
});
