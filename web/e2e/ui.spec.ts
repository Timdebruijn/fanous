// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Browser end-to-end tests against a real engine (fixtures.ts). Few and robust: each covers a flow whose bugs unit
// tests cannot see (wrong JSON pointers, overlapping handles, subscription races).
import type { Page } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { previewClass } from '../src/lib/preview';
import { binary, expect, expectPreviewStreaming, openScreen, previewTimeout, repo, test } from './fixtures';

type Param = { key: string; raw: number; source: string };

/** Adds an unassigned output on the Outputs screen and returns its row. */
async function addUnassignedOutput(page: Page) {
  await openScreen(page, 'Outputs');
  await page.getByLabel('Add output on').selectOption('none');
  const row = page.getByRole('button', { name: /^Output 1\b/ });
  await expect(row).toBeVisible();
  return row;
}

/** x, y of a mapper handle in viewBox units (0–1000 wide), as the project has it. */
async function handleAt(page: Page, path: string): Promise<{ x: number; y: number }> {
  const dot = page.getByRole('button', { name: path, exact: true }).locator('circle').nth(1);
  return { x: Number(await dot.getAttribute('cx')), y: Number(await dot.getAttribute('cy')) };
}

/** Counts the page's WebCodecs decoders from its next load on: `openDecoders` says how many are not closed (B85). */
async function trackDecoders(page: Page): Promise<void> {
  await page.addInitScript(() => {
    if (!('VideoDecoder' in window)) return;
    const all: VideoDecoder[] = ((window as unknown as { decoders: VideoDecoder[] }).decoders = []);
    window.VideoDecoder = class extends VideoDecoder {
      constructor(init: VideoDecoderInit) {
        super(init);
        all.push(this);
      }
    };
  });
}
const openDecoders = (page: Page) =>
  page.evaluate(() => ((window as unknown as { decoders?: VideoDecoder[] }).decoders ?? []).filter((d) => d.state !== 'closed').length);
/** One open decoder while the preview shows H.264, none on JPEG (a leaked one makes 2). Caption and count are read
 * together on every poll: on a slow runner the decoder can fail after the caption said H.264 and fall back to JPEG. */
async function expectDecoders(page: Page): Promise<void> {
  const caption = page.getByRole('figure').locator('figcaption');
  const seen = async () => `${await openDecoders(page)} open on ${/H\.264/.test(await caption.innerText()) ? 'H.264' : 'JPEG'}`;
  await expect.poll(seen, { timeout: previewTimeout }).toMatch(/^(1 open on H\.264|0 open on JPEG)$/);
}

test('layers: Control puts content on a layer, and the engine resolves folder, file and intensity', async ({ page, engine }) => {
  const resolved = async () => {
    const live = (await (await engine.api.get('/api/live')).json()) as { fixtures: Record<string, Param[]> };
    const params = live.fixtures['Layer 2']!.filter((p) => ['folder', 'file', 'intensity'].includes(p.key));
    return Object.fromEntries(params.map((p) => [p.key, `${p.raw} ${p.source}`]));
  };
  const row = page.locator('.row.layer').nth(1);
  await row.click();
  await expect(page.getByRole('heading', { name: 'Layer 2' })).toBeVisible();
  await page.getByRole('switch', { name: 'Control' }).check({ force: true }); // the drawn track covers the input
  // a new project is "Console only": UI values would be kept but not shown
  await page.getByRole('button', { name: /^Use / }).click();

  // the controls appear with the engine's first resolved values (live document, 10 Hz)
  const intensity = page.getByRole('slider', { name: 'Intensity', exact: true });
  await expect(intensity).toBeVisible();
  const max = Number(await intensity.getAttribute('max'));

  // built-in content: folder 0, the generator's file, full intensity
  await page.getByLabel('Built-in content and Syphon (folder 0)').selectOption({ label: '101 · Grid' });
  await expect.poll(resolved).toEqual({ folder: '0 ui', file: '101 ui', intensity: `${max} ui` });
  await expect(row).toContainText('Grid');
  await expect(row.locator('.c-int')).toContainText('100 %');

  // then the File field and the Intensity slider one by one
  const file = page.getByRole('spinbutton', { name: 'File', exact: true });
  await file.fill('102');
  await file.press('Tab');
  await intensity.fill(String(Math.round(max / 2)));
  await expect.poll(resolved).toEqual({ folder: '0 ui', file: '102 ui', intensity: `${Math.round(max / 2)} ui` });
  await expect(row).toContainText('Colour bars');
});

test('layers: a layer showing built-in content gets a live thumbnail, an empty layer none (B29)', async ({ page }) => {
  const row = page.locator('.row.layer').nth(1);
  await row.click();
  await page.getByRole('switch', { name: 'Control' }).check({ force: true }); // the drawn track covers the input
  await page.getByRole('button', { name: /^Use / }).click();
  await page.getByLabel('Built-in content and Syphon (folder 0)').selectOption({ label: '101 · Grid' });
  await expect(row).toContainText('Grid');
  // 4 atlas passes a second: the row's picture turns live (default timeout: CI's paravirtual Metal is slow)
  await expect(row.locator('img[data-live="true"]')).toBeVisible();
  await expect(page.locator('.row.layer').nth(0).locator('img[data-live="true"]')).toHaveCount(0);
});

test('sync: a slave layer locks to a master layer of its group, and loses it when the master goes off (B60)', async ({ page, engine }) => {
  // a 2 s movie as folder 1 file 1 of a new library (generators and stills have no clock to share), switched to on
  // the System screen
  const frames = mkdtempSync(join(engine.home, 'frames-'));
  for (let i = 1; i <= 50; i++) copyFileSync(join(repo, 'Tests/Fixtures/golden/baseline.png'), join(frames, `${String(i).padStart(3, '0')}.png`));
  const library = join(engine.home, 'library');
  mkdirSync(join(library, '001_Sync'), { recursive: true });
  execFileSync(binary, ['ingest', frames, join(library, '001_Sync/001_clip.mov'), '--codec', 'hap']);
  await openScreen(page, 'System');
  await page.getByLabel('Library root path').fill(library);
  await page.getByRole('region', { name: 'Machine' }).getByRole('button', { name: 'Apply' }).click();
  await openScreen(page, 'Layers');

  const rows = page.locator('.row.layer');
  const sync = page.getByRole('combobox', { name: 'Sync', exact: true });
  async function setUp(n: number, band: string) {
    await rows.nth(n - 1).click();
    await expect(page.getByRole('heading', { name: `Layer ${n}` })).toBeVisible();
    await page.getByLabel('Media from the library').selectOption('1/1');
    await sync.selectOption({ label: band });
  }
  await rows.first().click();
  await page.getByRole('switch', { name: 'Control' }).check({ force: true }); // the drawn track covers the input
  await page.getByRole('button', { name: /^Use / }).click();
  await expect(page.getByLabel('Media from the library').locator('option[value="1/1"]')).toHaveCount(1);
  await setUp(1, 'Master 1');
  await setUp(2, 'Slave 1');

  const master = rows.nth(0).locator('.sync');
  const slave = rows.nth(1).locator('.sync');
  await expect(master).toHaveText('M1');
  await expect(master).toHaveAttribute('title', 'Sync: master of group 1, sending');
  await expect(slave).toHaveText('S1');
  await expect(slave).toHaveAttribute('title', /^Sync: locked to Layer 1 on /);
  await expect(slave).toHaveClass(/sync-green/);
  await expect(page.locator('.syncline')).toHaveText(/^locked to Layer 1 on .+, −?\d+\.\d ms$/);

  // master off: the slave freewheels, then is lost 2 s after the last clock
  await rows.nth(0).click();
  await sync.selectOption('0');
  await expect(master).toHaveCount(0);
  await expect(slave).toHaveAttribute('title', /^Sync: (lost|no master)/);
  await expect(slave).toHaveClass(/sync-(red|grey)/);
});

test('media: folder 0 lists the generators and the Syphon servers, and puts one on a layer', async ({ page }) => {
  await openScreen(page, 'Media');
  await page.getByRole('button', { name: /^0 Built-in and Syphon/ }).click();
  await expect(page.getByRole('heading', { name: '0 · Built-in and Syphon' })).toBeVisible();
  // no other app publishes Syphon on CI; on a workstation other engines may (this engine's own canvas is never listed)
  const servers = page.getByRole('list', { name: 'Syphon servers (150–169)' });
  await expect(page.getByText(/^No Syphon servers running\./).or(servers)).toBeVisible();
  await page.getByRole('list', { name: 'Built-in content' }).getByRole('button', { name: /^110 Test card/ }).click();
  await page.getByLabel('Play on layer').selectOption({ label: 'Layer 1' });
  await expect(page.getByText('Layer 1 now shows 0 / 110 · Test card (timecode, frame flags).')).toBeVisible();
});

test('outputs: add an unassigned output and a second slice', async ({ page }) => {
  await addUnassignedOutput(page);
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  await page.getByRole('button', { name: 'Slices', exact: true }).click();
  await page.getByRole('button', { name: 'Add slice' }).click();
  const slice = page.getByRole('combobox', { name: 'Slice', exact: true });
  await expect(slice.locator('option')).toHaveText(['Slice 1', 'Slice 2']);
  await expect(slice).toHaveValue('1');
});

test('outputs: with two slices on the same corners, a drag moves the selected slice only; Reset slice puts it back', async ({ page }) => {
  await addUnassignedOutput(page);
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  await page.getByRole('button', { name: 'Slices', exact: true }).click();
  await page.getByRole('button', { name: 'Add slice' }).click();
  const slice = page.getByRole('combobox', { name: 'Slice', exact: true });
  await expect(slice).toHaveValue('1');

  // slice 2 lies on top of slice 1: select slice 1, grab the shared top-left corner and drop it in the middle
  await slice.selectOption('0');
  const box = (await page.getByRole('application', { name: /Mapping editor/ }).boundingBox())!;
  await page.mouse.move(box.x + 4, box.y + 4);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 8 });
  await page.mouse.up();
  await expect.poll(async () => Math.round((await handleAt(page, '/slices/0/dest/0')).x / 100)).toBe(5);

  await slice.selectOption('1');
  expect(await handleAt(page, '/slices/1/dest/0')).toEqual({ x: 0, y: 0 });

  await slice.selectOption('0');
  await page.getByRole('button', { name: 'Reset slice' }).click();
  await expect.poll(() => handleAt(page, '/slices/0/dest/0')).toEqual({ x: 0, y: 0 });
});

test('outputs: Spread canvas gives each slice its strip of the canvas', async ({ page }) => {
  await addUnassignedOutput(page);
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  await page.getByRole('button', { name: 'Slices', exact: true }).click();
  await page.getByRole('button', { name: 'Add slice' }).click();
  await page.getByRole('button', { name: 'Spread canvas' }).click();
  // two slices of equal width: slice 2 takes the right half
  const x = page.getByLabel('Source x in pixels');
  const w = page.getByLabel('Source w in pixels');
  await expect(x).not.toHaveValue('0');
  await expect(x).toHaveValue(await w.inputValue());
});

test('outputs: remove an output, then Undo brings it back', async ({ page }) => {
  await addUnassignedOutput(page);
  await page.getByRole('button', { name: 'Outputs', exact: true }).click();
  await page.getByRole('button', { name: 'Remove output' }).click();
  await expect(page.getByText('No outputs yet.')).toBeVisible();
  await page.getByRole('status').getByRole('button', { name: /Undo$/ }).click();
  await expect(page.getByRole('button', { name: /^Output 1\b/ })).toBeVisible();
});

/** Outputs › Warp & Slices with Remote on and the first corner of a new output selected; returns the remote panel. */
async function remoteOnFirstCorner(page: Page) {
  await addUnassignedOutput(page);
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  await page.getByRole('button', { name: 'Remote', exact: true }).click();
  const remote = page.getByRole('region', { name: 'Remote' });
  await remote.getByRole('button', { name: /^Next point/ }).click();
  await expect(remote.getByText('corner top-left')).toBeVisible();
  return remote;
}

test('outputs: remote mode on a phone steps to the next corner and nudges it; one Undo takes the burst back', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const remote = await remoteOnFirstCorner(page);
  await remote.getByRole('button', { name: /^Next point/ }).click();
  await expect(remote.getByText('corner top-right')).toBeVisible();

  // two quick taps: the first goes out at once, the second ~100 ms later as its own output.set, and the engine keeps
  // them as one undo step
  const y = page.getByLabel('Point y in pixels');
  const down = remote.getByRole('button', { name: 'Down 1 px' });
  await down.click();
  await down.click();
  await expect(y).toHaveValue('2');
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(y).toHaveValue('0');
});

test('outputs: remote mode, holding an arrow moves 0.25 px and a slow trackpad drag 1 px per 4 CSS px', async ({ page }) => {
  const remote = await remoteOnFirstCorner(page);
  const box = (await remote.getByRole('button', { name: 'Down 1 px' }).boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.waitForTimeout(600);
  await page.mouse.up();
  await expect(remote.getByText('x 0 · y 0.25 px')).toBeVisible();

  // 4 CSS px per move is below 600 px/s however fast the moves come (an interval counts as 8 ms at least)
  const pad = (await remote.getByText(/^Trackpad:/).boundingBox())!;
  await page.mouse.move(pad.x + 10, pad.y);
  await page.mouse.down();
  for (let i = 1; i <= 20; i++) await page.mouse.move(pad.x + 10 + 4 * i, pad.y);
  await page.mouse.up();
  await expect(remote.getByText('x 20 · y 0.25 px')).toBeVisible();
});

test('canvases: add a canvas, put a layer on it, remove it', async ({ page }) => {
  await openScreen(page, 'Outputs');
  await page.getByRole('button', { name: 'Canvases' }).click();
  await page.getByRole('button', { name: 'Add canvas' }).click();
  const canvases = page.getByRole('group', { name: 'Canvas', exact: true });
  await expect(canvases.getByRole('button', { name: 'Canvas 2' })).toBeVisible();
  // its preview really starts once the canvas renders (B62): one left on "starting…" or "connecting…" fails here
  await expectPreviewStreaming(page.getByRole('figure'));

  await openScreen(page, 'Layers');
  await page.getByLabel('Canvas of layer 2').selectOption({ label: 'Canvas 2' });

  await openScreen(page, 'Outputs');
  await page.getByRole('button', { name: 'Canvases' }).click();
  await canvases.getByRole('button', { name: 'Canvas 2' }).click();
  await expect(page.getByText('Layers on this canvas: 2.')).toBeVisible();
  await page.getByRole('button', { name: 'Remove canvas' }).click();
  await expect(canvases.getByRole('button', { name: 'Canvas 2' })).toHaveCount(0);
  await expect(page.getByText(/Layers on this canvas: 1–8\./)).toBeVisible();
});

test('preview: Canvas / This layer and fast layer switching leave one stream running', async ({ page, engine }) => {
  // preview streams this page holds: granted by the engine (`sub`) and not stopped (`unsub`)
  const streams = new Set<number>();
  page.on('websocket', (socket) => {
    socket.on('framereceived', ({ payload }) => {
      const m = typeof payload === 'string' ? (JSON.parse(payload) as { t: string; stream?: string; id: number }) : null;
      if (m?.t === 'sub' && m.stream === 'preview') streams.add(m.id);
    });
    socket.on('framesent', ({ payload }) => {
      const m = typeof payload === 'string' ? (JSON.parse(payload) as { t: string; id: number }) : null;
      if (m?.t === 'unsub') streams.delete(m.id);
    });
  });
  await trackDecoders(page);
  await page.goto(`${engine.url}/?token=${engine.token}`);  // again, with the listener above in place

  const shows = page.getByRole('group', { name: 'Preview shows' });
  const figure = page.getByRole('figure');
  await expectPreviewStreaming(figure);

  await shows.getByRole('button', { name: 'This layer' }).click();
  // faster than a subscription round trip: each new layer is picked while the previous stream is still on its way
  await page.evaluate(async () => {
    for (const row of document.querySelectorAll<HTMLElement>('.row.layer')) {
      row.click();
      await new Promise((r) => setTimeout(r, 5));
    }
  });
  await expectPreviewStreaming(figure, 'Layer 8');
  await expect.poll(() => streams.size).toBe(1);
  await expectDecoders(page);  // each target change closed its stream's decoder (B85)

  await shows.getByRole('button', { name: 'Canvas' }).click();
  await expectPreviewStreaming(figure, 'Canvas');
  await expect.poll(() => streams.size).toBe(1);
});

test('preview: a streaming preview subscribes again, once, after its socket closed (B68)', async ({ page, engine }) => {
  // the page's sockets run through the test, which closes one under the page while the engine keeps running (an engine
  // restart would not do: the new engine's first live document has no `engine.rendering`, so the preview remounts)
  type Message = { t: string; stream?: string; id: number };
  const parse = (message: string | Buffer) => (typeof message === 'string' ? (JSON.parse(message) as Message) : null);
  let sockets = 0;  // connection attempts
  let drop = async () => {};  // closes the newest connected socket, on both sides
  let streams = new Set<number>();  // preview streams held on the newest socket: granted (`sub`), not stopped (`unsub`)
  let subs = 0;  // preview subscriptions asked for on the newest socket
  await page.routeWebSocket(/\/ws$/, (ws) => {
    if (++sockets === 2) return void ws.close({ code: 4000, reason: 'test' });  // the first reconnect attempt fails
    const server = ws.connectToServer();
    drop = async () => (await ws.close({ code: 4000, reason: 'test' }), await server.close());
    const mine = (streams = new Set());
    subs = 0;
    ws.onMessage((message) => {
      const m = parse(message);
      if (m?.t === 'unsub') mine.delete(m.id);
      if (m?.t === 'sub' && m.stream === 'preview') subs++;
      server.send(message);
    });
    server.onMessage((message) => {
      const m = parse(message);
      if (m?.t === 'sub' && m.stream === 'preview') mine.add(m.id);
      ws.send(message);
    });
  });
  await trackDecoders(page);
  await page.goto(`${engine.url}/?token=${engine.token}`);  // again, through the route above
  const figure = page.getByRole('figure');
  await expectPreviewStreaming(figure);
  await expect.poll(() => streams.size).toBe(1);

  // every caption from here on: after "no preview · not connected" it says "connecting…" until the stream is back
  await figure.locator('figcaption').evaluate((caption) => {
    const seen: string[] = ((window as unknown as { captions: string[] }).captions = []);
    new MutationObserver(() => seen.push(caption.textContent!.trim())).observe(caption, { subtree: true, childList: true, characterData: true });
  });
  await drop();
  await expect.poll(() => sockets, { timeout: 10_000 }).toBe(3);  // one refused attempt, then connected again
  // the caption alone cannot tell: before B68 it kept the old stream's "H.264 · …" over a frozen picture
  await expect.poll(() => streams.size, { timeout: previewTimeout }).toBe(1);
  await expectPreviewStreaming(figure);
  await expect(figure.locator('.stalled')).toHaveCount(0);
  const captions = await page.evaluate(() => (window as unknown as { captions: string[] }).captions);
  const closed = captions.findLastIndex((c) => c.startsWith('no preview · not connected'));
  expect(closed, captions.join(' | ')).toBeGreaterThanOrEqual(0);
  expect(captions[closed + 1], captions.join(' | ')).toMatch(/^connecting…/);
  expect(captions.slice(closed + 1).filter((c) => c.startsWith('no preview')), captions.join(' | ')).toEqual([]);
  // one subscription on the new socket (a second when H.264 fell back to JPEG): no storm from the reconnect attempts
  expect(subs).toBeLessThanOrEqual(/JPEG/.test(await figure.locator('figcaption').innerText()) ? 2 : 1);
  expect(streams.size).toBe(1);
  await expectDecoders(page);  // the stream the closed socket took had its decoder closed too (B85)
});

test("preview: an output stream has the output's shape and the size of its box (B32)", async ({ page, engine }) => {
  // what the engine told this page about its output:1 streams: the `sub` replies, then each `stream` description (a
  // rebuilt stream announces its new size there, without a new subscription)
  const ids = new Set<number>();
  const told: { w: number; h: number }[] = [];
  let subs = 0;
  const codecs = new Set<string>();  // H.264: JPEG streams have no descriptions
  page.on('websocket', (socket) =>
    socket.on('framereceived', ({ payload }) => {
      type Message = { t: string; id: number; stream?: string; target?: string; codec?: string; w: number; h: number };
      const m = typeof payload === 'string' ? (JSON.parse(payload) as Message) : null;
      if (m?.t === 'sub' && m.stream === 'preview' && m.target === 'output:1') {
        codecs.add(m.codec ?? '');
        ids.add(m.id);
        subs++;
        told.push({ w: m.w, h: m.h });
      }
      if (m?.t === 'stream' && ids.has(m.id)) told.push({ w: m.w, h: m.h });
    }),
  );
  await page.goto(`${engine.url}/?token=${engine.token}`);  // again, with the listener above in place
  await addUnassignedOutput(page);
  // the class the engine picks for the preview's rendered width in device pixels
  const wanted = async () =>
    previewClass(await page.locator('figure canvas').evaluate((c) => Math.ceil(c.getBoundingClientRect().width * window.devicePixelRatio)));
  // a 1440×1080 region in class c: the pixels of c's 16:9 frame at 4:3, even (engine PreviewSize.size)
  const fourThree = (c: number) => {
    const w = Math.floor(c * 0.75 * Math.sqrt(4 / 3)) & ~1;
    return { w, h: Math.floor((w * 3) / 4) & ~1 };
  };
  const w = await wanted();
  await expect.poll(() => told.at(-1)).toEqual({ w, h: (w * 9) / 16 });
  // the `sub` reply alone has that size: wait for the stream itself, or the browser's JPEG fallback (5 s without a
  // description, B66) adds a subscription below; this test needs H.264, JPEG streams have no descriptions
  const figure = page.getByRole('figure');
  await expectPreviewStreaming(figure);
  const jpeg = /JPEG/.test(await figure.locator('figcaption').innerText());
  test.skip(!!process.env.CI && jpeg, 'H.264 encoder not ready within 5 s on this runner (B66); JPEG fallback');
  expect([...codecs], 'H.264, not the JPEG fallback').toEqual(['avc']);

  // a 4:3 region: the engine rebuilds the stream and says so in a new description; no new subscription is needed
  const before = subs;
  const region = page.getByLabel('Region w', { exact: true });
  await region.fill('1440');
  await region.press('Tab');
  await expect.poll(() => told.at(-1), { timeout: previewTimeout }).toEqual(fourThree(w));  // a new encoder session
  expect(subs).toBe(before);

  // a narrower window: the preview asks for the smaller class it now needs
  await page.setViewportSize({ width: 800, height: 900 });
  await expect.poll(wanted).toBeLessThan(w);
  const narrow = await wanted();
  await expect.poll(() => told.at(-1)).toEqual(fourThree(narrow));
  expect(subs).toBe(before + 1);
});
