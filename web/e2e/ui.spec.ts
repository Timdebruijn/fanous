// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Browser end-to-end tests against a real engine (fixtures.ts). Few and robust: each covers a flow whose bugs unit
// tests cannot see (wrong JSON pointers, overlapping handles, subscription races).
import type { Locator, Page } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { previewClass } from '../src/lib/preview';
import { binary, expect, expectPreviewStreaming, openScreen, previewTimeout, repo, test, type Engine } from './fixtures';

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
 * together on every poll: on a slow runner the decoder can fail after the caption said H.264 and fall back to JPEG.
 * The mode is the caption's start: a JPEG caption can name H.264 further on ("JPEG 5 fps · no H.264 stream …", B98). */
async function expectDecoders(page: Page): Promise<void> {
  const caption = page.getByRole('figure').locator('figcaption');
  const seen = async () => `${await openDecoders(page)} open: ${(await caption.innerText()).trim()}`;
  await expect.poll(seen, { timeout: previewTimeout }).toMatch(/^(1 open: H\.264 · |0 open: JPEG 5 fps · )/);
}

test('patch API: /api/patch serves the live patch, an added output included', async ({ page, engine }) => {
  const outputPatched = async () => {
    const patch = (await (await engine.api.get('/api/patch')).json()) as { entries: { fixture: Record<string, unknown> }[] };
    return patch.entries.some((e) => 'output' in e.fixture);
  };
  expect(await outputPatched()).toBe(false); // a new project starts without outputs
  await addUnassignedOutput(page);
  await expect.poll(outputPatched).toBe(true);
});

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
  await page.getByLabel('Built-in content and live inputs (folder 0)').selectOption({ label: '101 · Grid' });
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
  await page.getByLabel('Built-in content and live inputs (folder 0)').selectOption({ label: '101 · Grid' });
  await expect(row).toContainText('Grid');
  // 4 atlas passes a second: the row's picture turns live (default timeout: CI's paravirtual Metal is slow)
  await expect(row.locator('img[data-live="true"]')).toBeVisible();
  await expect(page.locator('.row.layer').nth(0).locator('img[data-live="true"]')).toHaveCount(0);
});

test('layers: a layer added at runtime plays at once, and goes dark when it is removed again (B121)', async ({ page }) => {
  // the live document each welcome carries, and per layer number the width of the last live thumbnail (0: dark)
  let welcome: { layers: unknown[] } | undefined;
  let thumbsStream = -1;
  const thumbs = new Map<number, number>();
  page.on('websocket', (socket) =>
    socket.on('framereceived', ({ payload }) => {
      if (typeof payload === 'string') {
        const message = JSON.parse(payload) as { t: string; id?: number; stream?: string; live?: typeof welcome };
        if (message.t === 'welcome') welcome = message.live;
        if (message.t === 'sub' && message.stream === 'thumbs') thumbsStream = message.id!;
        return;
      }
      // [u8 kind 2 JPEG][u32 stream][u8 layer][u16 w][u16 h][JPEG] (client.ts, parseThumbFrame)
      if (payload.length >= 10 && payload[0] === 2 && payload.readUInt32BE(1) === thumbsStream) thumbs.set(payload[5]!, payload.readUInt16BE(6));
    }),
  );
  /** The layers the live document lists, from a fresh welcome. */
  const liveLayers = async () => {
    welcome = undefined;
    await page.reload();
    await expect.poll(() => welcome).toBeDefined();
    return welcome!.layers.length;
  };
  expect(await liveLayers(), "the project's layers, not the engine's 32 render layers").toBe(8);

  await openScreen(page, 'Patch');
  await page.getByRole('button', { name: 'Add layer' }).click();
  await expect(page.getByRole('button', { name: 'Remove layer 9' })).toBeVisible();
  await openScreen(page, 'Layers');
  const row = page.locator('.row.layer').nth(8);
  await row.click();
  await expect(page.getByRole('heading', { name: 'Layer 9' })).toBeVisible();
  await page.getByRole('switch', { name: 'Control' }).check({ force: true }); // the drawn track covers the input
  await page.getByRole('button', { name: /^Use / }).click();
  // the controls appear with the layer's first live document; before it the picker does not know the intensity is 0,
  // leaves it there, and the layer draws nothing
  await expect(page.getByRole('slider', { name: 'Intensity', exact: true })).toBeVisible();
  await page.getByLabel('Built-in content and live inputs (folder 0)').selectOption({ label: '101 · Grid' });
  // the engine opened it and draws it: without a restart, not after one
  await expect(row).toContainText('Grid');
  await expect(row.locator('img[data-live="true"]')).toBeVisible();
  expect(await liveLayers()).toBe(9);

  // removed: layer 9 has no fixture, so it lets its media go. A new thumbs subscription gets every render layer's
  // frame, layer 9's empty
  await openScreen(page, 'Patch');
  await page.getByRole('button', { name: 'Remove layer 9' }).click();
  await expect(page.getByRole('button', { name: 'Remove layer 8' })).toBeVisible();
  thumbs.clear();
  await openScreen(page, 'Layers');
  await expect.poll(() => thumbs.get(9)).toBe(0);
  // a welcome carries the live document as last published (every 100 ms): it can still list layer 9 for a moment
  await expect.poll(liveLayers).toBe(8);
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

test('patch: Hold on signal loss is set on the universe in the Universes panel, kept over a reload, and undone', async ({ page }) => {
  await openScreen(page, 'Patch');
  const universes = page.getByRole('region', { name: 'Universes' });
  const row = universes.getByRole('button', { name: /^A 0\.0\.0,/ });
  await expect(row).toContainText('Layers 1–8');
  await expect(row).toContainText('Hold last values');
  await row.click();
  await expect(row).toHaveAttribute('aria-expanded', 'true');
  // the monitor shows the universe that was opened
  await expect(page.getByRole('region', { name: 'DMX monitor' }).getByRole('button', { name: 'A 0.0.0' })).toHaveAttribute('aria-pressed', 'true');
  await universes.getByLabel('Hold on signal loss').selectOption('zero');
  await expect(row).toContainText('Go to zero');
  await page.reload();
  await openScreen(page, 'Patch');
  await expect(row).toContainText('Go to zero');
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(row).toContainText('Hold last values');
});

test('patch: the Layers block is laid from A 0.0.2 in one step, and one Undo puts the patch back', async ({ page }) => {
  await openScreen(page, 'Patch');
  const layers = page.getByRole('region', { name: 'Layers' });
  const universes = page.getByRole('region', { name: 'Universes' });
  const start = layers.getByLabel('Layers block universe');
  await expect(start).toHaveValue('artnet:0.0.0');
  await start.selectOption('artnet:0.0.2');
  await expect(universes.getByRole('button', { name: /^A 0\.0\.2, Layers 1–8,/ })).toBeVisible();
  await expect(layers.getByRole('button', { name: 'Layer 8, A 0.0.2 449–512, ok' })).toBeVisible();
  // no layer is left on A 0.0.0 (the row itself may stay for stored settings or a console)
  await expect(universes.getByRole('button', { name: /^A 0\.0\.0, Layers/ })).toHaveCount(0);
  await page.getByRole('status').getByRole('button', { name: /Undo$/ }).click();
  await expect(universes.getByRole('button', { name: /^A 0\.0\.0, Layers 1–8,/ })).toBeVisible();
  await expect(layers.getByRole('button', { name: 'Layer 1, A 0.0.0 1–64, ok' })).toBeVisible();
  await expect(start).toHaveValue('artnet:0.0.0');
});

test('patch: a group with nothing patched says what it does, and Patch as block puts it at the standard position', async ({ page }) => {
  await openScreen(page, 'Patch');
  const master = page.getByRole('region', { name: 'Master' });
  await master.getByRole('button', { name: 'Master, A 0.0.1 1–8, ok' }).click();
  await expect(page.getByRole('group', { name: 'Patch of Master' })).toBeFocused();
  await master.getByRole('button', { name: 'Unpatch' }).click();
  await expect(master.getByRole('button', { name: 'Master, no address · at defaults' })).toBeVisible();
  await master.getByRole('button', { name: 'Patch as block' }).click();
  await expect(master.getByRole('button', { name: 'Master, A 0.0.1 1–8, ok' })).toBeVisible();
  await expect(master.getByRole('group', { name: 'Master block' })).toBeFocused();
  await expect(master.getByLabel('Master block universe')).toHaveValue('artnet:0.0.1');
});

test('patch: the Patch sheet lists the layer block, prints alone, and counts Art-Net universes from 1 after a reload', async ({ page }) => {
  const openSheet = async () => {
    await openScreen(page, 'Patch');
    await page.getByRole('button', { name: 'Patch sheet' }).click();
  };
  await openSheet();
  const sheet = page.getByRole('dialog', { name: 'Patch sheet' });
  const layers = sheet.getByRole('row', { name: /^Layers 1–8 Fanous Layer \(64ch\) 8/ });
  await expect(layers).toContainText('A 0.0.0 = universe 0');
  await expect(layers).toContainText('1, 65, 129, 193, 257, 321, 385, 449');
  await page.emulateMedia({ media: 'print' });
  await expect(page.getByRole('navigation', { name: 'Screens' })).toBeHidden();
  await expect(sheet.getByRole('button', { name: 'Print' })).toBeHidden();
  await expect(layers).toBeVisible();
  await expect(page.locator('body')).toHaveCSS('background-color', 'rgb(255, 255, 255)');
  await page.emulateMedia({ media: 'screen' });
  await sheet.getByRole('switch', { name: 'Count Art-Net universes from 1' }).check({ force: true }); // the drawn track covers the input
  await expect(layers).toContainText('A 0.0.0 = universe 1');
  await expect(sheet).toContainText('Art-Net universes counted from 1');
  await page.reload();
  await openSheet();
  await expect(sheet.getByRole('switch', { name: 'Count Art-Net universes from 1' })).toBeChecked();
  await expect(layers).toContainText('A 0.0.0 = universe 1');
  await sheet.getByRole('button', { name: 'Close' }).click();
  await expect(sheet).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Patch sheet' })).toBeFocused();
});

test('status bar: the universe pills wrap on a phone instead of widening the page', async ({ page }) => {
  await openScreen(page, 'Outputs');
  await page.getByLabel('Add output on').selectOption('none');
  await openScreen(page, 'Patch');
  await page.getByRole('region', { name: 'Outputs' }).getByLabel('Outputs block universe').selectOption('artnet:0.0.2');
  const banner = page.getByRole('banner');
  for (const u of ['A 0.0.0', 'A 0.0.1', 'A 0.0.2']) await expect(banner.getByText(new RegExp(`^${u.replaceAll('.', '\\.')} ·`))).toBeVisible();
  await page.setViewportSize({ width: 375, height: 812 });
  await expect.poll(() => banner.evaluate((el) => el.scrollWidth - el.clientWidth)).toBe(0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(375);
});

test('keys: the global shortcuts do nothing while a modal dialog is open, and ? still closes the shortcut list', async ({ page }) => {
  await openScreen(page, 'Patch');
  await page.getByRole('button', { name: 'Patch sheet' }).click();
  const sheet = page.getByRole('dialog', { name: 'Patch sheet' });
  await sheet.getByRole('button', { name: 'Copy' }).focus();
  for (const key of ['1', 'l', '?', 'ControlOrMeta+z']) await page.keyboard.press(key);
  await expect(sheet).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(sheet).toHaveCount(0);
  const hash = () => page.evaluate(() => location.hash);
  expect(await hash()).toBe('#/patch');
  const help = page.getByRole('dialog', { name: 'Keyboard shortcuts' });
  await page.keyboard.press('?');
  await expect(help).toBeVisible();
  await page.keyboard.press('1');
  expect(await hash()).toBe('#/patch');
  await page.keyboard.press('?');
  await expect(help).toBeHidden();
  await page.keyboard.press('1');
  await expect.poll(hash).toBe('#/layers');
  // L and undo had their round trips by now: the lock is still off and no "history is empty" alert came back
  await expect(page.getByRole('button', { name: 'UNLOCKED' })).toBeVisible();
  await expect(page.getByRole('alert')).toHaveCount(0);
});

test('keys: Space on the Show screen fires no cue while the shortcut list is open', async ({ page }) => {
  const sent: string[] = [];
  page.on('websocket', (socket) => socket.on('framesent', ({ payload }) => typeof payload === 'string' && sent.push(payload)));
  await page.reload();
  await expect(page.getByRole('banner')).toContainText(/\b[1-9]\d* clients/);
  await openScreen(page, 'Show');
  await page.keyboard.press('?');
  // a click on the list's text leaves the focus on the page's body, which Space does not skip
  await page.getByRole('heading', { name: 'Keyboard shortcuts' }).click();
  await page.keyboard.press('Space');
  await page.keyboard.press('?');
  await expect(page.getByRole('dialog', { name: 'Keyboard shortcuts' })).toBeHidden();
  expect(sent.filter((p) => p.includes('cue.go'))).toEqual([]);
});

test('media: folder 0 lists the generators and the Syphon servers, and puts one on a layer', async ({ page }) => {
  await openScreen(page, 'Media');
  await page.getByRole('button', { name: /^0 Built-in and live inputs/ }).click();
  await expect(page.getByRole('heading', { name: '0 · Built-in and live inputs' })).toBeVisible();
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
  // the controls scrolled the page (the Presets strip makes it taller): the editor's corner back in view first
  const editor = page.getByRole('application', { name: /Mapping editor/ });
  await editor.scrollIntoViewIfNeeded();
  const box = (await editor.boundingBox())!;
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

/** A pointer drag on the mapping editor from one place to another, given as fractions of the picture, through `via`. */
async function dragOnEditor(page: Page, points: [number, number][]) {
  const editor = page.getByRole('application', { name: /Mapping editor/ });
  await editor.scrollIntoViewIfNeeded();
  const box = (await editor.boundingBox())!;
  const at = ([x, y]: [number, number]) => [box.x + x * box.width, box.y + y * box.height] as const;
  await page.mouse.move(...at(points[0]!));
  await page.mouse.down();
  for (const p of points.slice(1)) await page.mouse.move(...at(p), { steps: 4 });
  await page.mouse.up();
}

/** The points of a circle around (0.5, 0.5) of the picture, `n` of them, back to the start: a freehand stroke. */
const loop = (n: number, r = 0.25): [number, number][] => Array.from({ length: n + 1 }, (_, i) => [0.5 + r * Math.cos((2 * Math.PI * i) / n), 0.5 + r * Math.sin((2 * Math.PI * i) / n)]);

/** Where a mapper handle is on the page (CSS px). */
async function onPage(page: Page, path: string): Promise<{ x: number; y: number }> {
  const editor = page.getByRole('application', { name: /Mapping editor/ });
  const [box, at, view] = [(await editor.boundingBox())!, await handleAt(page, path), (await editor.getAttribute('viewBox'))!.split(' ').map(Number)];
  return { x: box.x + (at.x / view[2]!) * box.width, y: box.y + (at.y / view[3]!) * box.height };
}

/** The dashed previews of a shape being drawn. */
const previews = (page: Page) => page.locator('.mapper polyline[stroke="#FFC532"]');

/** The number of points a mask row of the list names. */
async function pointCount(row: Locator): Promise<number> {
  return Number(/(\d+) points/.exec((await row.textContent()) ?? '')?.[1] ?? NaN);
}

test('outputs: each mask tool adds a mask on a real engine, and one Undo takes one tool back', async ({ page }) => {
  await addUnassignedOutput(page);
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  await page.getByRole('button', { name: 'Mask', exact: true }).click();
  const masks = page.getByRole('list', { name: 'Masks of slice 1' }).getByRole('listitem');
  await expect(masks).toHaveText([/^No masks/]);
  const point = (m: number, i: number) => page.getByRole('button', { name: `/slices/0/masks/${m}/path/${i}`, exact: true });

  // Rectangle: a box dragged from bottom right to top left gives its 4 corners clockwise from the top left; its preview
  // is closed while the drag lasts
  await page.getByRole('button', { name: 'Rectangle', exact: true }).click();
  const editor = (await page.getByRole('application', { name: /Mapping editor/ }).boundingBox())!;
  await page.mouse.move(editor.x + editor.width * 0.5, editor.y + editor.height * 0.5);
  await page.mouse.down();
  await page.mouse.move(editor.x + editor.width * 0.6, editor.y + editor.height * 0.6, { steps: 3 });
  const outline = (await previews(page).getAttribute('points'))!.split(' ');
  expect(outline.length).toBeGreaterThan(4);
  expect(outline.at(-1), 'closed').toBe(outline[0]);
  await page.mouse.up();
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(masks).toHaveText([/^No masks/]);
  await page.getByRole('button', { name: 'Rectangle', exact: true }).click();
  await dragOnEditor(page, [[0.75, 0.8], [0.5, 0.5], [0.25, 0.2]]);
  await expect(masks).toHaveCount(1);
  const x = async (path: string) => Math.round((await handleAt(page, path)).x);
  expect(await x('/slices/0/masks/0/path/0')).toBe(250);
  expect(await x('/slices/0/masks/0/path/2')).toBe(750);
  await expect(page.getByRole('button', { name: 'Rectangle', exact: true }), 'one shape, then the tool is off').toHaveAttribute('aria-pressed', 'false');

  // Ellipse: 4 points with Bézier handles, shown for the selected point
  await page.getByRole('button', { name: 'Ellipse', exact: true }).click();
  await dragOnEditor(page, [[0.1, 0.1], [0.4, 0.5]]);
  await expect(masks).toHaveCount(2);
  expect(await x('/slices/0/masks/1/path/0')).toBe(250);
  await expect(page.getByRole('button', { name: '/slices/0/masks/1/path/0/out', exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: 'Mask 2', exact: true }).click();
  expect(await x('/slices/0/masks/1/path/0/out')).toBe(Math.round(250 + 0.5523 * 150));

  // Polygon: tap the corners, then Done; Polygon pressed again meanwhile keeps the corners tapped
  await page.getByRole('button', { name: 'Polygon', exact: true }).click();
  for (const p of [[0.6, 0.1], [0.9, 0.1]] as [number, number][]) await dragOnEditor(page, [p]);
  await page.getByRole('button', { name: 'Polygon', exact: true }).click();
  await dragOnEditor(page, [[0.75, 0.4]]);
  await page.getByRole('button', { name: 'Done', exact: true }).click();
  await expect(masks).toHaveCount(3);
  await expect(point(2, 2)).toHaveCount(1);

  // Freehand with a pointer drag around a circle: a smooth path of several points, each with handles. The engine keeps
  // edits of the same path less than 1 s apart as one undo step, so this one waits that long
  await page.waitForTimeout(1100);
  await page.getByRole('button', { name: 'Freehand', exact: true }).click();
  await dragOnEditor(page, loop(24));
  await expect(masks).toHaveCount(4);
  // the 24 corners of the stroke, and a few more where a screen pixel is more than the 2 output px RDP keeps; far fewer
  // than the ~100 pointer moves
  expect(await pointCount(masks.nth(3))).toBeGreaterThanOrEqual(12);
  expect(await pointCount(masks.nth(3))).toBeLessThan(50);
  await page.getByRole('button', { name: 'Mask 4', exact: true }).click();
  await expect(page.getByRole('button', { name: '/slices/0/masks/3/path/0/in', exact: true })).toHaveCount(1);

  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(masks).toHaveCount(3);
  await expect(point(2, 2)).toHaveCount(1);

  // Cancel while the button is still down: no preview is left, also not when the tool is chosen again
  await page.getByRole('button', { name: 'Freehand', exact: true }).click();
  await page.mouse.move(editor.x + editor.width * 0.3, editor.y + editor.height * 0.3);
  await page.mouse.down();
  await page.mouse.move(editor.x + editor.width * 0.5, editor.y + editor.height * 0.4, { steps: 5 });
  await page.getByRole('button', { name: 'Cancel', exact: true }).dispatchEvent('click');
  await expect(previews(page), 'gone at once, the button still down').toHaveCount(0);
  await page.mouse.up();
  await expect(previews(page)).toHaveCount(0);
  await page.getByRole('button', { name: 'Freehand', exact: true }).click();
  await page.mouse.move(editor.x + editor.width * 0.8, editor.y + editor.height * 0.8, { steps: 5 });
  await expect(previews(page)).toHaveCount(0);
  await expect(masks).toHaveCount(3);
});

test('outputs: Bézier handles: a press takes the nearest, a handle drags alone and goes with its point, Backspace removes it', async ({ page }) => {
  await addUnassignedOutput(page);
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  await page.getByRole('button', { name: 'Mask', exact: true }).click();
  await page.getByRole('button', { name: 'Freehand', exact: true }).click();
  await dragOnEditor(page, loop(24));
  await page.getByRole('button', { name: 'Mask 1', exact: true }).click();
  const [point, out, inn] = ['', '/out', '/in'].map((side) => `/slices/0/masks/0/path/0${side}`);
  const selected = () => page.locator('.mapper g.handle.sel').getAttribute('aria-label');

  // a smooth loop's handle is short: inside the hit circle of its point (37 px), drawn on top of it; a press on the
  // handle takes the handle, and it drags alone
  const [p, h] = [await onPage(page, point), await onPage(page, out)];
  expect(Math.hypot(h.x - p.x, h.y - p.y)).toBeLessThan(30);
  const before = await handleAt(page, point);
  await page.mouse.move(h.x, h.y);
  await page.mouse.down();
  await expect.poll(selected).toBe(out);
  await page.mouse.move(h.x, h.y + 20, { steps: 4 });
  await page.mouse.up();
  await expect.poll(async () => Math.round((await onPage(page, out)).y - h.y)).toBe(20);
  expect(await handleAt(page, point)).toEqual(before);

  // a double-tap on a handle leaves it, and its point smooth
  await page.mouse.dblclick(h.x, h.y + 20);
  await page.waitForTimeout(500);
  await expect(page.getByRole('button', { name: out, exact: true })).toHaveCount(1);

  // the point dragged: its handles go with it before the engine answers
  await page.mouse.move(p.x, p.y);
  await page.mouse.down();
  await page.mouse.move(p.x + 30, p.y, { steps: 4 });
  expect(Math.round((await onPage(page, out)).x - h.x)).toBe(30);
  await page.mouse.up();

  // Backspace with a handle selected removes that handle only (Remove point says Remove handle then); one Undo. The
  // engine joins edits of the same path less than 1 s apart, and the drag above wrote this point
  await page.waitForTimeout(1100);
  await page.getByRole('application', { name: /Mapping editor/ }).focus();
  await page.keyboard.press('Tab');
  await expect.poll(selected).toBe(inn);
  await expect(page.getByRole('button', { name: 'Remove handle' })).toBeVisible();
  await page.keyboard.press('Backspace');
  await expect(page.getByRole('button', { name: inn, exact: true })).toHaveCount(0);
  await expect(page.getByRole('button', { name: out, exact: true })).toHaveCount(1);
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(page.getByRole('button', { name: inn, exact: true })).toHaveCount(1);
});

test('outputs: the mask list: an image mask from the library, Invert, feather, a point drag, a double-tap, Remove', async ({ page, engine }) => {
  const sets: unknown[] = [];
  page.on('websocket', (socket) =>
    socket.on('framesent', ({ payload }) => typeof payload === 'string' && payload.includes('"output.set"') && sets.push(JSON.parse(payload))),
  );
  await page.goto(`${engine.url}/?token=${engine.token}`);
  // a still as folder 1 file 1 of a new library
  const library = join(engine.home, 'library');
  mkdirSync(join(library, '001_Masks'), { recursive: true });
  copyFileSync(join(repo, 'Tests/Fixtures/golden/baseline.png'), join(library, '001_Masks/001_door.png'));
  await openScreen(page, 'System');
  await page.getByLabel('Library root path').fill(library);
  await page.getByRole('region', { name: 'Machine' }).getByRole('button', { name: 'Apply' }).click();
  await addUnassignedOutput(page);
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  await page.getByRole('button', { name: 'Mask', exact: true }).click();
  const masks = page.getByRole('list', { name: 'Masks of slice 1' }).getByRole('listitem');

  // an image mask: no points and no feather
  await page.getByLabel('Image mask').selectOption('1/1');
  await expect(masks).toHaveCount(1);
  await expect(masks.first()).toContainText('door.png');
  await expect(page.getByLabel('Mask 1 feather px')).toHaveCount(0);

  // a rectangle 10 % inside, the way that needs no drag
  await page.getByRole('button', { name: 'Rectangle', exact: true }).click();
  await page.getByRole('button', { name: '10 % inside' }).click();
  await expect(masks).toHaveCount(2);
  await expect.poll(async () => Math.round((await handleAt(page, '/slices/0/masks/1/path/2')).x)).toBe(900);

  // Invert: a subtract mask, its outline dashed; Undo makes it an add mask again
  const invert = page.getByRole('button', { name: 'Invert Mask 2' });
  await invert.click();
  await expect(invert).toHaveAttribute('aria-pressed', 'true');
  await expect(masks.nth(1)).toContainText('Subtract');
  await expect(page.locator('.mapper polyline[stroke-dasharray="8 6"]')).toHaveCount(1);
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(invert).toHaveAttribute('aria-pressed', 'false');
  await expect(page.locator('.mapper polyline[stroke-dasharray="8 6"]')).toHaveCount(0);
  await invert.click();
  await expect(invert).toHaveAttribute('aria-pressed', 'true');
  await invert.click();
  await expect(invert, 'and back').toHaveAttribute('aria-pressed', 'false');

  // the bottom-right point to the middle of the picture
  const handle = (await page.getByRole('button', { name: '/slices/0/masks/1/path/2', exact: true }).boundingBox())!;
  const editor = (await page.getByRole('application', { name: /Mapping editor/ }).boundingBox())!;
  await page.mouse.move(handle.x + handle.width / 2, handle.y + handle.height / 2);
  await page.mouse.down();
  await page.mouse.move(editor.x + editor.width / 2, editor.y + editor.height / 2, { steps: 8 });
  await page.mouse.up();
  await expect.poll(async () => Math.round((await handleAt(page, '/slices/0/masks/1/path/2')).x / 10)).toBe(50);

  // Redraw names its mask; once the mask changes meanwhile, Done would add a new one, and the caption says so
  await page.getByRole('button', { name: 'Redraw Mask 2' }).click();
  await expect(page.getByText('Redrawing mask 2:')).toBeVisible();
  await page.getByRole('button', { name: 'Invert Mask 2' }).click();
  await expect(page.getByText(/^Drawing a new mask \(the mask to redraw has changed since\):/)).toBeVisible();
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(invert).toHaveAttribute('aria-pressed', 'false');

  const feather = page.getByLabel('Mask 2 feather px');
  await feather.fill('6');
  await feather.press('Enter');
  // the field as the project has it: away to another mode and back
  await page.getByRole('button', { name: 'Slices', exact: true }).click();
  await page.getByRole('button', { name: 'Mask', exact: true }).click();
  await expect(feather).toHaveValue('6');

  // a double-tap on a corner makes it smooth (handles from its neighbours), one Undo makes it a corner again
  await page.waitForTimeout(1100); // the drag above wrote this point less than 1 s ago: the engine would join the steps
  const corner = page.getByRole('button', { name: '/slices/0/masks/1/path/1', exact: true });
  const smooth = page.getByRole('button', { name: 'Smooth point' });
  const before = sets.length;
  await corner.dblclick({ position: { x: (await corner.boundingBox())!.width / 2, y: (await corner.boundingBox())!.height / 2 } });
  await expect(page.getByRole('button', { name: '/slices/0/masks/1/path/1/in', exact: true })).toHaveCount(1);
  expect(sets.length - before, 'the toggle only: a tap without a move sends nothing').toBe(1);
  await expect(smooth).toHaveAttribute('aria-pressed', 'true');
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(page.getByRole('button', { name: '/slices/0/masks/1/path/1/in', exact: true })).toHaveCount(0);
  await expect(smooth).toHaveAttribute('aria-pressed', 'false');
  expect(Math.round((await handleAt(page, '/slices/0/masks/1/path/1')).x), 'the taps did not move it').toBe(900);

  await page.getByRole('button', { name: 'Remove Mask 1' }).click();
  await expect(masks).toHaveCount(1);
  await expect(masks.first()).toContainText('4 points');
  await expect(page.getByLabel('Mask 1 feather px')).toHaveValue('6');
});

test('outputs: the slice shapes Triangle and Circle, one Undo each', async ({ page }) => {
  await addUnassignedOutput(page);
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  await page.getByRole('button', { name: 'Slices', exact: true }).click();
  await page.getByRole('button', { name: 'Triangle', exact: true }).click();
  await expect.poll(() => handleAt(page, '/slices/0/dest/0')).toEqual({ x: 500, y: 0 });
  expect(await handleAt(page, '/slices/0/dest/1')).toEqual({ x: 500, y: 0 });
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect.poll(() => handleAt(page, '/slices/0/dest/1')).toEqual({ x: 1000, y: 0 });
  expect(await handleAt(page, '/slices/0/dest/0')).toEqual({ x: 0, y: 0 });

  // Circle on a slice whose corners span 0…1: the ellipse touching the middle of each edge
  await page.getByRole('button', { name: 'Circle', exact: true }).click();
  await page.getByRole('button', { name: 'Mask', exact: true }).click();
  await expect.poll(() => handleAt(page, '/slices/0/masks/0/path/0')).toEqual({ x: 500, y: 0 });
  expect((await handleAt(page, '/slices/0/masks/0/path/1')).x).toBe(1000);
  // the top point's handle lies on the output's edge: dragged up, it goes past it (a point would stop there)
  await page.getByRole('button', { name: 'Mask 1', exact: true }).click();
  await page.evaluate(() => window.scrollTo(0, 0)); // the editor's top edge in the window, with room above it
  const knob = await onPage(page, '/slices/0/masks/0/path/0/out');
  await page.mouse.move(knob.x, knob.y + 2);
  await page.mouse.down();
  await page.mouse.move(knob.x, knob.y - 40, { steps: 4 });
  await page.mouse.up();
  await expect.poll(async () => (await handleAt(page, '/slices/0/masks/0/path/0/out')).y).toBeLessThan(-20);
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect.poll(async () => (await handleAt(page, '/slices/0/masks/0/path/0/out')).y).toBe(0);
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(page.getByRole('list', { name: 'Masks of slice 1' }).getByRole('listitem')).toHaveText([/^No masks/]);
});

test.describe('on a phone', () => {
  // the narrowest phone: every mode and tool button still reachable (the groups wrap)
  test.use({ viewport: { width: 320, height: 700 }, hasTouch: true });

  test('outputs: Freehand by touch: a finger dragged around on the picture draws a smooth mask', async ({ page }) => {
    await addUnassignedOutput(page);
    await page.getByRole('button', { name: 'Warp & Slices' }).click();
    await page.getByRole('button', { name: 'Mask', exact: true }).click();
    // nothing cut off at 320 px (Playwright would scroll a clipped group to click in it; a finger cannot)
    for (const name of ['Edit', 'Mask tools']) {
      const cut = await page.getByRole('group', { name, exact: true }).evaluate((group) => group.scrollWidth - group.clientWidth);
      expect(cut, name).toBe(0);
    }
    await page.getByRole('button', { name: 'Freehand', exact: true }).click();
    const editor = page.getByRole('application', { name: /Mapping editor/ });
    await editor.scrollIntoViewIfNeeded();
    const box = (await editor.boundingBox())!;
    // Playwright's touchscreen only taps: a drag goes through the DevTools protocol, as touch events with their pointers
    const cdp = await page.context().newCDPSession(page);
    const touch = (type: string, [x, y]: [number, number]) =>
      cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x: box.x + x * box.width, y: box.y + y * box.height, id: 0 }] });
    const stroke = loop(24, 0.3);
    await touch('touchStart', stroke[0]!);
    for (const p of stroke.slice(1, 12)) await touch('touchMove', p);
    // a second finger (or the palm) lands and lifts halfway: the stroke goes on (touchEnd names the finger that lifts)
    const at = (p: [number, number], id: number) => ({ x: box.x + p[0] * box.width, y: box.y + p[1] * box.height, id });
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [at(stroke[11]!, 0), at([0.05, 0.05], 1)] });
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [at([0.05, 0.05], 1)] });
    for (const p of stroke.slice(12)) await touch('touchMove', p);
    await touch('touchEnd', stroke.at(-1)!);
    const masks = page.getByRole('list', { name: 'Masks of slice 1' }).getByRole('listitem');
    await expect(masks).toHaveText([/^Mask 1/]);
    // the whole loop: its 24 corners (half of it would be 12 or 13)
    expect(await pointCount(masks.first())).toBeGreaterThanOrEqual(22);
    expect(await pointCount(masks.first())).toBeLessThan(30);
    const first = await handleAt(page, '/slices/0/masks/0/path/0');
    expect(Math.round(first.x / 10)).toBe(80);
  });
});

test('outputs: a change of mesh density keeps the shape; Reset mesh flattens it', async ({ page }) => {
  await addUnassignedOutput(page);
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  await page.getByRole('button', { name: /^Mesh/ }).click();
  await page.getByLabel('Density').selectOption('3');
  const rounded = async (path: string) => {
    const p = await handleAt(page, path);
    return { x: Math.round(p.x), y: Math.round(p.y) };
  };
  const flat = await rounded('/warp/mesh/points/4');

  // drag the middle point of the 3 × 3 grid away from the centre
  const handle = (await page.getByRole('button', { name: '/warp/mesh/points/4', exact: true }).boundingBox())!;
  await page.mouse.move(handle.x + handle.width / 2, handle.y + handle.height / 2);
  await page.mouse.down();
  await page.mouse.move(handle.x + handle.width / 2 + 60, handle.y + handle.height / 2 + 30, { steps: 8 });
  await page.mouse.up();
  // wait for the drop position itself, not an echo of a step in between
  const editor = (await page.getByRole('application', { name: /Mapping editor/ }).boundingBox())!;
  const targetX = Math.round(((handle.x + handle.width / 2 + 60 - editor.x) / editor.width) * 1000);
  await expect.poll(async () => Math.abs((await rounded('/warp/mesh/points/4')).x - targetX)).toBeLessThanOrEqual(1);
  const bent = await rounded('/warp/mesh/points/4');

  // 3 × 3 → 5 × 5: the old middle point is the new grid's middle (index 12) and stays where it was dragged
  await page.getByLabel('Density').selectOption('5');
  await expect.poll(() => rounded('/warp/mesh/points/12')).toEqual(bent);

  await page.getByRole('button', { name: 'Reset mesh' }).click();
  await expect.poll(() => rounded('/warp/mesh/points/12')).toEqual(flat);
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

test("walls: the wizard makes a 1 × 2 wall at 15 %, a seam gamma drag is one undo step, the tint hint opens a projector's colour, Remove wall", async ({ page, engine }) => {
  // the wall.seam commands this page sends (the socket of the page as loaded again with the listener in place)
  let seamCommands = 0;
  page.on('websocket', (socket) =>
    socket.on('framesent', ({ payload }) => {
      if (typeof payload === 'string' && (JSON.parse(payload) as { name?: string }).name === 'wall.seam') seamCommands++;
    }),
  );
  await page.goto(`${engine.url}/?token=${engine.token}`);

  // two outputs of 1920 × 1200: an unassigned output has no pixel size until it gets a region (or a display mode)
  await addUnassignedOutput(page);
  await page.getByLabel('Add output on').selectOption('none');
  const row = (n: number) => page.locator('.row.out', { hasText: `Output ${n}` });
  for (const n of [1, 2]) {
    await row(n).click();
    const h = page.getByLabel('Region h', { exact: true });
    await h.fill('1200');
    await h.press('Tab');
  }

  await page.getByRole('region', { name: 'Projector walls' }).getByRole('button', { name: 'New projector wall' }).click();
  const wizard = page.getByRole('region', { name: 'New projector wall' });
  await wizard.getByRole('button', { name: /^Output 1, / }).click();
  await wizard.getByRole('button', { name: /^Output 2, / }).click();
  // two projectors: 1 × 2 and 2 × 1 match, one row first
  const grid = wizard.getByRole('group', { name: 'Grid' }).getByRole('button');
  await expect(grid).toHaveText(['1 × 2', '2 × 1']);
  await expect(grid.first()).toHaveAttribute('aria-pressed', 'true');
  await wizard.getByRole('button', { name: 'Next' }).click();
  await expect(wizard.getByText('15 %', { exact: true })).toBeVisible();
  await expect(wizard.getByRole('radio', { name: /^Use Canvas 1/ })).toBeChecked();
  await wizard.getByRole('button', { name: 'Make wall' }).click();

  // the panel opens on the seam check, Blend check on both outputs
  const panel = page.getByRole('region', { name: 'Wall 1' });
  await expect(panel.getByRole('group', { name: 'Seam check pattern' }).getByRole('button', { name: 'Blend check' })).toHaveAttribute('aria-pressed', 'true');
  await expect(row(1)).toContainText('Wall 1 · r1 c1');
  await expect(row(2)).toContainText('Wall 1 · r1 c2');
  // the inner edges overlap 0.15 × 1920 = 288 px, the outer ones not at all
  const overlap = (edge: string) => page.getByRole('group', { name: `${edge} edge` }).getByLabel('Overlap (px)');
  await row(1).click();
  await expect(page.getByRole('region', { name: 'Output settings' }).getByRole('button', { name: 'Blend check' })).toHaveAttribute('aria-pressed', 'true');
  await expect(overlap('right')).toHaveValue('288');
  await expect(overlap('left')).toHaveValue('0');
  await row(2).click();
  await expect(overlap('left')).toHaveValue('288');
  await expect(overlap('right')).toHaveValue('0');

  // a drag on the seam's gamma sends several wall.seam commands (at most one per 50 ms); the engine keeps them as one
  // undo step
  await panel.getByRole('button', { name: 'Seam between Output 1 and Output 2' }).click();
  const gamma = panel.getByRole('slider', { name: 'Gamma', exact: true });
  await expect(gamma).toHaveValue('2.2');
  const box = (await gamma.boundingBox())!;
  const x = (v: number) => box.x + 8 + ((v - 0.5) / 4.5) * (box.width - 16);
  await page.mouse.move(x(2.2), box.y + box.height / 2);
  await page.mouse.down();
  for (let i = 1; i <= 10; i++) {
    await page.mouse.move(x(2.2 + i / 10), box.y + box.height / 2);
    await page.waitForTimeout(40);
  }
  await page.mouse.up();
  await expect.poll(async () => Number(await gamma.inputValue())).toBeGreaterThan(2.6);
  expect(seamCommands).toBeGreaterThan(1);
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(gamma).toHaveValue('2.2');
  // unlinked, R, G and B replace the single gamma (each starts at it)
  await panel.getByRole('switch', { name: 'Link R, G, B' }).uncheck({ force: true }); // the drawn track covers the input
  await expect(panel.getByRole('slider', { name: 'Gamma B' })).toHaveValue('2.2');
  await expect(gamma).toHaveCount(0);
  await expect(panel.getByRole('slider', { name: /^Gamma/ })).toHaveCount(3);
  await expect(panel.getByRole('button', { name: 'Seam between Output 1 and Output 2, gamma R 2.2 · G 2.2 · B 2.2' })).toHaveText('RGB');
  // Output 2's inner (left) edge shows the three values instead of a gamma field; One gamma for R, G, B links the seam again
  const left = page.getByRole('group', { name: 'left edge' });
  await expect(left.getByLabel('Gamma R · G · B')).toHaveValue('2.20 · 2.20 · 2.20');
  await expect(left.getByLabel('Gamma', { exact: true })).toHaveCount(0);
  await left.getByRole('button', { name: 'One gamma for R, G, B' }).click();
  await expect(gamma).toHaveValue('2.2');
  await expect(panel.getByRole('slider', { name: 'Gamma B' })).toHaveCount(0);
  await expect(left.getByLabel('Gamma', { exact: true })).toHaveValue('2.2');

  // on Grey 25 %, "one projector darker, or tinted" opens the colour gain of the projector tapped next
  await panel.getByRole('group', { name: 'Seam check pattern' }).getByRole('button', { name: 'Grey 25 %' }).click();
  await panel.getByRole('button', { name: /^One projector darker, or tinted/ }).click();
  await panel.getByRole('button', { name: 'Output 2 · r1 c2' }).click();
  const projector = panel.getByRole('region', { name: 'Projector' });
  await expect(projector.getByRole('heading')).toHaveText('Output 2 · r1 c2');
  const colour = projector.getByRole('group', { name: 'Colour' });
  await expect(colour).toHaveClass(/focus/);
  await expect(colour.getByRole('slider', { name: 'Gain R' })).toHaveValue('100');

  // Remove wall ends the seam check (each output gets its own pattern back) and keeps the outputs
  await panel.getByRole('button', { name: 'Geometry' }).click();
  await panel.getByRole('button', { name: 'Remove wall' }).click();
  await expect(panel).toHaveCount(0);
  await expect(row(2)).not.toContainText('Wall 1');
  await expect(page.getByRole('button', { name: 'Off', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(overlap('left')).toHaveValue('288');
});

test('walls: Cancel changes nothing; a reload, leaving the screen and End seam check give each output its own pattern back', async ({ page, engine }) => {
  let wallAdds = 0;
  page.on('websocket', (socket) =>
    socket.on('framesent', ({ payload }) => {
      if (typeof payload === 'string' && (JSON.parse(payload) as { name?: string }).name === 'wall.add') wallAdds++;
    }),
  );
  await page.goto(`${engine.url}/?token=${engine.token}`);
  await addUnassignedOutput(page);
  await page.getByLabel('Add output on').selectOption('none');
  const row = (n: number) => page.locator('.row.out', { hasText: `Output ${n}` });
  const settings = page.getByRole('region', { name: 'Output settings' });
  for (const n of [1, 2]) {
    await row(n).click();
    const h = page.getByLabel('Region h', { exact: true });
    await h.fill('1200');
    await h.press('Tab');
  }
  // Output 1's own pattern is Crosshair, Output 2's Off
  await row(1).click();
  await settings.getByRole('button', { name: 'Crosshair' }).click();
  const own = async () => {
    await row(2).click();
    await expect(settings.getByRole('button', { name: 'Off', exact: true })).toHaveAttribute('aria-pressed', 'true');
    await row(1).click();
    await expect(settings.getByRole('button', { name: 'Crosshair' })).toHaveAttribute('aria-pressed', 'true');
  };
  const walls = page.getByRole('region', { name: 'Projector walls' });
  async function makeWall(cancel: boolean) {
    await walls.getByRole('button', { name: 'New projector wall' }).click();
    const wizard = page.getByRole('region', { name: 'New projector wall' });
    await wizard.getByRole('button', { name: /^Output 1, / }).click();
    await wizard.getByRole('button', { name: /^Output 2, / }).click();
    await wizard.getByRole('button', { name: 'Next' }).click();
    await wizard.getByRole('button', { name: cancel ? 'Cancel' : 'Make wall' }).click();
    await expect(wizard).toHaveCount(0);
  }

  // Cancel at step 2: no wall, no wall.add, the patterns as they were
  await makeWall(true);
  await expect(page.getByRole('region', { name: 'Wall 1' })).toHaveCount(0);
  expect(wallAdds).toBe(0);
  await own();

  // a page reloaded during the seam check offers the outputs' own patterns back
  await makeWall(false);
  const panel = page.getByRole('region', { name: 'Wall 1' });
  await expect(panel.getByRole('button', { name: 'Seam check', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await row(1).click();
  await expect(settings.getByRole('button', { name: 'Blend check' })).toHaveAttribute('aria-pressed', 'true');
  await page.goto(`${engine.url}/?token=${engine.token}`);
  await openScreen(page, 'Outputs');
  await page.getByRole('button', { name: 'Give the test patterns back' }).click();
  await expect(page.getByRole('button', { name: 'Give the test patterns back' })).toHaveCount(0);
  await own();

  // leaving the Outputs screen ends a running seam check
  await panel.getByRole('button', { name: 'Seam check', exact: true }).click();
  await expect(settings.getByRole('button', { name: 'Grid' })).toHaveAttribute('aria-pressed', 'true');
  await openScreen(page, 'Layers');
  await openScreen(page, 'Outputs');
  await expect(panel.getByRole('button', { name: 'Seam check', exact: true })).toHaveAttribute('aria-pressed', 'false');
  await own();

  // and so does End seam check
  await panel.getByRole('button', { name: 'Seam check', exact: true }).click();
  await panel.getByRole('group', { name: 'Seam check pattern' }).getByRole('button', { name: 'White' }).click();
  await expect(settings.getByRole('button', { name: 'White' })).toHaveAttribute('aria-pressed', 'true');
  await panel.getByRole('button', { name: 'End seam check' }).click();
  await own();
});

test('outputs: a colour gain drag is one undo step; the black offset steps by 0.1 %', async ({ page, engine }) => {
  // the output.set commands for red gain this page sends (the socket of the page as loaded again with the listener in place)
  let redSets = 0;
  page.on('websocket', (socket) =>
    socket.on('framesent', ({ payload }) => {
      if (typeof payload !== 'string') return;
      const message = JSON.parse(payload) as { name?: string; args?: { path?: string } };
      if (message.name === 'output.set' && message.args?.path === '/color/gain/0') redSets++;
    }),
  );
  await page.goto(`${engine.url}/?token=${engine.token}`);
  await addUnassignedOutput(page);
  const colour = page.getByRole('region', { name: 'Output settings' }).getByRole('group', { name: 'Colour' });
  const red = colour.getByRole('slider', { name: 'Gain R' });
  await expect(red).toHaveValue('100');

  // a drag sends several output.set commands (at most one per 50 ms); the engine keeps them as one undo step
  await red.scrollIntoViewIfNeeded();
  const box = (await red.boundingBox())!;
  const x = (v: number) => box.x + 8 + (v / 200) * (box.width - 16);
  await page.mouse.move(x(100), box.y + box.height / 2);
  await page.mouse.down();
  for (let i = 1; i <= 10; i++) {
    await page.mouse.move(x(100 - i * 3), box.y + box.height / 2);
    await page.waitForTimeout(40);
  }
  const dragged = Number(await red.inputValue());
  expect(dragged).toBeLessThan(80);
  await page.mouse.up();
  // the last value of the drag reaches the engine: after the release the slider shows the engine's value
  await expect(colour.getByLabel('Gain R value')).toHaveText(`${dragged.toFixed(1)} %`);
  await expect.poll(async () => Number(await red.inputValue())).toBe(dragged);
  expect(redSets).toBeGreaterThan(1);
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(red).toHaveValue('100');

  await colour.getByRole('button', { name: 'Black offset up' }).click();
  await expect(colour.getByLabel('Black offset value')).toHaveText('0.1 %');
  await expect(colour.getByRole('slider', { name: 'Black offset' })).toHaveValue('0.1');
});

// B114: the −/range/+ sliders (RangeStepper) against a slow network, where the engine's echo of a value comes a round
// trip after it was sent

/** Loads the page again behind a slow network: every frame from the engine `net.ms` late (250 ms, as over a busy Wi-Fi;
 * a test may change it), the names of the commands the page sends in `net.sent`; a command named `drop` never reaches
 * the engine. */
async function slowEchoes(page: Page, engine: Engine, { ms = 250, drop = '' } = {}): Promise<{ ms: number; sent: string[] }> {
  const net = { ms, sent: [] as string[] };
  await page.routeWebSocket(/\/ws$/, (ws) => {
    const server = ws.connectToServer();
    ws.onMessage((message) => {
      const name = typeof message === 'string' ? (JSON.parse(message) as { name?: string }).name : undefined;
      if (name) net.sent.push(name);
      if (!drop || name !== drop) server.send(message);
    });
    server.onMessage((message) => void setTimeout(() => ws.send(message), net.ms));
  });
  await page.goto(`${engine.url}/?token=${engine.token}`);
  return net;
}

type Watched = HTMLElement & { seen?: number[]; times?: number[] };
/** Records every number a slider's value text shows from now on; the function returned reads them, repeats dropped.
 * `timesOf` reads when each appeared (performance.now() in the page). */
async function watchValue(value: Locator): Promise<() => Promise<number[]>> {
  await value.evaluate((el: Watched) => {
    const seen = (el.seen = [parseFloat(el.textContent ?? '')]);
    const times = (el.times = [performance.now()]);
    new MutationObserver(() => {
      const n = parseFloat(el.textContent ?? '');
      if (n === seen.at(-1)) return;
      seen.push(n);
      times.push(performance.now());
    }).observe(el, { subtree: true, characterData: true, childList: true });
  });
  return () => value.evaluate((el: Watched) => el.seen ?? []);
}
const timesOf = (value: Locator) => value.evaluate((el: Watched) => el.times ?? []);

/** How often a sequence of values turns between rising and falling: a slider that jumps back turns more than the hand did. */
const turns = (seen: number[]) => seen.filter((v, i) => i >= 2 && Math.sign(v - seen[i - 1]!) !== Math.sign(seen[i - 1]! - seen[i - 2]!)).length;

/** The x of value `v` on a 0–`max` range input (its thumb is 16 px wide). */
async function rangeX(slider: Locator, max: number): Promise<{ x: (v: number) => number; y: number }> {
  await slider.scrollIntoViewIfNeeded();
  const box = (await slider.boundingBox())!;
  return { x: (v) => box.x + 8 + (v / max) * (box.width - 16), y: box.y + box.height / 2 };
}

const colourOf = (page: Page) => page.getByRole('region', { name: 'Output settings' }).getByRole('group', { name: 'Colour' });

test('outputs: a released colour slider stays where it was let go until the engine catches up (B114 a)', async ({ page, engine }) => {
  await slowEchoes(page, engine);
  await addUnassignedOutput(page);
  const colour = colourOf(page);
  const red = colour.getByRole('slider', { name: 'Gain R' });
  await expect(red).toHaveValue('100');
  const shown = await watchValue(colour.getByLabel('Gain R value'));
  const { x, y } = await rangeX(red, 200);
  await page.mouse.move(x(100), y);
  await page.mouse.down();
  for (let i = 1; i <= 10; i++) {
    await page.mouse.move(x(100 - i * 3), y);
    await page.waitForTimeout(30);
  }
  const dragged = Number(await red.inputValue());
  expect(dragged).toBeLessThan(80);
  await page.mouse.up();
  // past the late echoes and the grace: the slider only ever went down, and the engine has the value let go at
  await page.waitForTimeout(1500);
  const seen = await shown();
  expect(turns(seen), seen.join(' ')).toBe(0);
  expect(seen.at(-1)).toBe(dragged);
  await expect(red).toHaveValue(String(dragged));
});

test('outputs: quick taps on a colour + all land, as one undo step (B114 b)', async ({ page, engine }) => {
  await slowEchoes(page, engine);
  await addUnassignedOutput(page);
  const colour = colourOf(page);
  const up = colour.getByRole('button', { name: 'Black offset up' });
  await up.scrollIntoViewIfNeeded();
  const plus = (await up.boundingBox())!;
  for (let i = 0; i < 5; i++) await page.mouse.click(plus.x + plus.width / 2, plus.y + plus.height / 2);
  const value = colour.getByLabel('Black offset value');
  await expect(value).toHaveText('0.5 %');
  await page.waitForTimeout(1500); // the engine's value after the grace
  await expect(value).toHaveText('0.5 %');
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(value).toHaveText('0.0 %');
});

test('outputs: a colour slider dragged down and back up faster than a round trip shows none of the late echoes after the release (B114)', async ({ page, engine }) => {
  await slowEchoes(page, engine);
  await addUnassignedOutput(page);
  const colour = colourOf(page);
  const red = colour.getByRole('slider', { name: 'Gain R' });
  await expect(red).toHaveValue('100');
  const shown = await watchValue(colour.getByLabel('Gain R value'));
  const { x, y } = await rangeX(red, 200);
  await page.mouse.move(x(100), y);
  await page.mouse.down();
  // about 150 ms: a few sends at 50 ms intervals, all echoed after the release
  for (const v of [97, 94, 91, 88, 91, 94, 97, 100]) {
    await page.mouse.move(x(v), y);
    await page.waitForTimeout(15);
  }
  await page.mouse.up();
  await page.waitForTimeout(1500);
  const seen = await shown();
  expect(turns(seen), seen.join(' ')).toBe(1); // down, then up
  expect(seen.at(-1)).toBe(100);
});

test('outputs: + and then − on a colour within a round trip, the late echo of the + does not show, nor after another gain echoes (B114)', async ({ page, engine }) => {
  await slowEchoes(page, engine);
  await addUnassignedOutput(page);
  const colour = colourOf(page);
  await colour.getByRole('button', { name: 'Black offset up' }).scrollIntoViewIfNeeded();
  const shown = await watchValue(colour.getByLabel('Gain R value'));
  // Gain G's echo arrives after the −, before Gain R's: it re-renders Gain R with its old value, the value sent
  await colour.getByRole('button', { name: 'Gain G up' }).click();
  await page.waitForTimeout(100);
  await colour.getByRole('button', { name: 'Gain R up' }).click();
  await page.waitForTimeout(60);
  await colour.getByRole('button', { name: 'Gain R down' }).click();
  await page.waitForTimeout(1500);
  expect(await shown()).toEqual([100, 100.5, 100]);
});

test("outputs: a colour + the engine never gets shows the engine's value again after the grace (B114)", async ({ page, engine }) => {
  const net = await slowEchoes(page, engine, { drop: 'output.set' });
  await addUnassignedOutput(page);
  const colour = colourOf(page);
  const value = colour.getByLabel('Black offset value');
  await colour.getByRole('button', { name: 'Black offset up' }).click();
  await expect(value).toHaveText('0.1 %');
  await expect(value).toHaveText('0.0 %', { timeout: 2_000 });
  expect(net.sent).toContain('output.set');
});

test('outputs: Undo right after a tap on a colour + shows at once, not at the end of the grace (B114)', async ({ page, engine }) => {
  // the engine's echo of the tap (the socket of the page as loaded again with the listener in place)
  let echoed = () => {};
  const echo = new Promise<void>((done) => (echoed = done));
  page.on('websocket', (socket) =>
    socket.on('framereceived', ({ payload }) => {
      if (typeof payload === 'string' && payload.includes('/color/black')) echoed();
    }),
  );
  await page.goto(`${engine.url}/?token=${engine.token}`);
  await addUnassignedOutput(page);
  const colour = colourOf(page);
  const value = colour.getByLabel('Black offset value');
  const shown = await watchValue(value);
  await colour.getByRole('button', { name: 'Black offset up' }).click();
  await echo;
  await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(value).toHaveText('0.0 %');
  expect(await shown()).toEqual([0, 0.1, 0]);
  // the grace alone would keep 0.1 until 1000 ms after the tap
  const [, tapped, undone] = await timesOf(value);
  expect(undone! - tapped!).toBeLessThan(900);
});

test.describe('with touch', () => {
  test.use({ hasTouch: true });

  test('outputs: two fingers on two colour sliders, each slider follows its own finger only (B114 c)', async ({ page, engine }) => {
    await slowEchoes(page, engine);
    await addUnassignedOutput(page);
    const colour = colourOf(page);
    const names = ['Gain R', 'Gain G'];
    const sliders = names.map((name) => colour.getByRole('slider', { name }));
    const shown = await Promise.all(names.map((name) => watchValue(colour.getByLabel(`${name} value`))));
    const ranges = [await rangeX(sliders[0]!, 200), await rangeX(sliders[1]!, 200)];
    const at = (finger: number, v: number) => ({ x: ranges[finger]!.x(v), y: ranges[finger]!.y, id: finger });
    // Playwright's touchscreen only taps: two fingers go through the DevTools protocol
    const cdp = await page.context().newCDPSession(page);
    const touch = (type: 'touchStart' | 'touchMove' | 'touchEnd', touchPoints: { x: number; y: number; id: number }[]) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints });
    await touch('touchStart', [at(0, 100)]);
    await touch('touchStart', [at(0, 100), at(1, 100)]);
    for (let i = 1; i <= 10; i++) {
      await touch('touchMove', [at(0, 100 - i * 3), at(1, 100 - i * 2)]);
      await page.waitForTimeout(30);
    }
    // the second finger lifts first, the first one goes on a little
    await touch('touchEnd', [at(1, 80)]);
    for (let i = 11; i <= 13; i++) {
      await touch('touchMove', [at(0, 100 - i * 3)]);
      await page.waitForTimeout(30);
    }
    await touch('touchEnd', []);
    await page.waitForTimeout(1500);
    for (const [i, name] of names.entries()) {
      const seen = await shown[i]!();
      expect(turns(seen), `${name}: ${seen.join(' ')}`).toBe(0);
      expect(seen.at(-1), name).toBeLessThan(i === 0 ? 70 : 85);
      expect(seen.at(-1), name).toBe(Number(await sliders[i]!.inputValue()));
    }
  });
});

test("outputs: a colour slider dragged away and back shows another client's change and Undo after the release (B114 d)", async ({ page, engine, browser }) => {
  await addUnassignedOutput(page);
  const colour = colourOf(page);
  const red = colour.getByRole('slider', { name: 'Gain R' });
  await expect(red).toHaveValue('100');
  const { x, y } = await rangeX(red, 200);
  await page.mouse.move(x(100), y);
  await page.mouse.down();
  for (const v of [97, 94, 91, 88, 91, 94, 97, 100]) {
    await page.mouse.move(x(v), y);
    await page.waitForTimeout(40);
  }
  await page.mouse.up(); // where it was pressed: Chromium fires no change
  await expect(red).toHaveValue('100');

  const other = await browser.newContext({ ignoreHTTPSErrors: true });
  try {
    const second = await other.newPage();
    await second.goto(`${engine.url}/?token=${engine.token}`);
    await openScreen(second, 'Outputs');
    await second.getByRole('button', { name: /^Output 1\b/ }).click();
    await colourOf(second).getByRole('button', { name: 'Gain R up' }).click();
    await expect(colour.getByLabel('Gain R value')).toHaveText('100.5 %');
    await expect(red).toHaveValue('100.5');
    await page.getByRole('banner').getByRole('button', { name: 'Undo', exact: true }).click();
    await expect(colour.getByLabel('Gain R value')).toHaveText('100.0 %');
  } finally {
    await other.close();
  }
});

test('walls: under late echoes an overlap drag sends one wall.set and stays, and quick taps on two axes or two gamma channels all land (B114)', async ({ page, engine }) => {
  const net = await slowEchoes(page, engine, { ms: 0 }); // the set-up at full speed
  // a 2 × 2 wall of four outputs of 1920 × 1200
  await addUnassignedOutput(page);
  for (let i = 0; i < 3; i++) await page.getByLabel('Add output on').selectOption('none');
  const row = (n: number) => page.locator('.row.out', { hasText: `Output ${n}` });
  for (const n of [1, 2, 3, 4]) {
    await row(n).click();
    const h = page.getByLabel('Region h', { exact: true });
    await h.fill('1200');
    await h.press('Tab');
  }
  await page.getByRole('region', { name: 'Projector walls' }).getByRole('button', { name: 'New projector wall' }).click();
  const wizard = page.getByRole('region', { name: 'New projector wall' });
  for (const n of [1, 2, 3, 4]) await wizard.getByRole('button', { name: new RegExp(`^Output ${n}, `) }).click();
  await wizard.getByRole('group', { name: 'Grid' }).getByRole('button', { name: '2 × 2' }).click();
  await wizard.getByRole('button', { name: 'Next' }).click();
  await wizard.getByRole('button', { name: 'Make wall' }).click();
  const panel = page.getByRole('region', { name: 'Wall 1' });
  await panel.getByRole('button', { name: 'Geometry' }).click();
  const across = panel.getByRole('slider', { name: 'Overlap across' });
  await expect(across).toHaveValue('15');
  net.ms = 250;

  // a drag on the overlap sends one wall.set, on release, and the thumb stays where it was let go
  const acrossValue = panel.getByLabel('Overlap across value');
  const shown = await watchValue(acrossValue);
  const sets = () => net.sent.filter((name) => name === 'wall.set').length;
  const before = sets();
  const { x, y } = await rangeX(across, 50);
  await page.mouse.move(x(15), y);
  await page.mouse.down();
  for (const v of [17, 19, 21, 23, 25]) {
    await page.mouse.move(x(v), y);
    await page.waitForTimeout(30);
  }
  const dragged = Number(await across.inputValue());
  expect(dragged).toBeGreaterThan(20);
  expect(sets()).toBe(before);
  await page.mouse.up();
  await page.waitForTimeout(1500);
  expect(sets() - before).toBe(1);
  const seen = await shown();
  expect(turns(seen), seen.join(' ')).toBe(0);
  expect(seen.at(-1)).toBe(dragged);

  // across + and then down + within a round trip: one wall.set carries both axes, and each keeps its tap
  await panel.getByRole('button', { name: 'Overlap across up' }).click();
  await panel.getByRole('button', { name: 'Overlap down up' }).click();
  await page.waitForTimeout(1500);
  await expect(acrossValue).toHaveText(`${dragged + 1} %`);
  await expect(panel.getByLabel('Overlap down value')).toHaveText('16 %');

  // four taps on gamma R up, then one on G up after the first send went out: one wall.seam carries all three channels,
  // and R keeps its taps
  await panel.getByRole('button', { name: 'Seam between Output 1 and Output 2' }).click();
  await panel.getByRole('switch', { name: 'Link R, G, B' }).uncheck({ force: true }); // the drawn track covers the input
  const up = (channel: string) => panel.getByRole('button', { name: `Gamma ${channel} up` });
  await up('G').scrollIntoViewIfNeeded();
  await expect(panel.getByLabel('Gamma G value')).toHaveText('2.20');
  const tap = async (channel: string, times: number) => {
    const box = (await up(channel).boundingBox())!;
    for (let i = 0; i < times; i++) await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  };
  await tap('R', 4);
  await page.waitForTimeout(100); // past the 50 ms throttle, within the round trip
  await tap('G', 1);
  await page.waitForTimeout(1500);
  await expect(panel.getByLabel('Gamma R value')).toHaveText('2.40');
  await expect(panel.getByLabel('Gamma G value')).toHaveText('2.25');
});

test('outputs: store a mapping preset, move a corner, recall the preset; Undo takes the recall back', async ({ page }) => {
  await addUnassignedOutput(page);
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  const presets = page.getByRole('region', { name: 'Mapping presets' });
  await presets.getByRole('button', { name: 'Store as 1' }).click();
  await expect(presets.getByRole('combobox', { name: 'Preset', exact: true })).toHaveValue('1');
  await expect(presets.getByRole('button', { name: 'Store as 2' })).toBeVisible();

  // the corner pin's top-left corner to the middle of the picture (the strip is below it: scroll back up first)
  const editor = page.getByRole('application', { name: /Mapping editor/ });
  await editor.scrollIntoViewIfNeeded();
  const box = (await editor.boundingBox())!;
  await page.mouse.move(box.x + 4, box.y + 4);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 8 });
  await page.mouse.up();
  await expect.poll(async () => Math.round((await handleAt(page, '/warp/cornerPin/0')).x / 100)).toBe(5);
  const moved = await handleAt(page, '/warp/cornerPin/0');

  await presets.getByRole('button', { name: 'Recall' }).click();
  await expect.poll(() => handleAt(page, '/warp/cornerPin/0')).toEqual({ x: 0, y: 0 });
  await page.getByRole('status').filter({ hasText: 'Preset 1 recalled.' }).getByRole('button', { name: /Undo$/ }).click();
  await expect.poll(() => handleAt(page, '/warp/cornerPin/0')).toEqual(moved);
});

test('outputs: holding Compare with the mouse keeps the preset on the output until the button is let go', async ({ page }) => {
  await addUnassignedOutput(page);
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  const presets = page.getByRole('region', { name: 'Mapping presets' });
  await presets.getByRole('button', { name: 'Store as 1' }).click();
  const hold = presets.getByRole('button', { name: 'Hold to compare' });
  await hold.hover();
  await page.mouse.down();
  // the badges under the preview appear while held: the button must not lose the hold when the page reflows
  await page.waitForTimeout(1000);
  await expect(hold).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('.kbadges').getByText('Preset 1 (compare)')).toBeVisible();
  await page.mouse.up();
  await expect(hold).toHaveAttribute('aria-pressed', 'false');
  await expect(page.getByText('Preset 1 (compare)')).toHaveCount(0);
});

/** The `output.overlay` arguments `page` sends from its next load on (any the engine refuses fails the test, fixtures). */
function overlaySent(page: Page): unknown[] {
  const sent: unknown[] = [];
  page.on('websocket', (socket) =>
    socket.on('framesent', ({ payload }) => {
      if (typeof payload !== 'string') return;
      const message = JSON.parse(payload) as { name?: string; args?: unknown };
      if (message.name === 'output.overlay') sent.push(message.args);
    }),
  );
  return sent;
}

test('outputs: opening Warp & Slices puts the edit overlay on the output with the selected point; Show on output takes it off', async ({ page, engine }) => {
  const sent = overlaySent(page);
  await page.goto(`${engine.url}/?token=${engine.token}`);
  await addUnassignedOutput(page);
  expect(sent, 'not before the tab opens').toEqual([]);
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  await expect.poll(() => sent).toEqual([{ id: 1, on: true, selected: null }]);
  // the corner's hit circle reaches past the picture's corner: tap the part over the picture
  const corner = page.getByRole('button', { name: '/warp/cornerPin/0', exact: true });
  const box = (await corner.boundingBox())!;
  await corner.click({ position: { x: box.width * 0.7, y: box.height * 0.7 } });
  await expect.poll(() => sent.at(-1)).toEqual({ id: 1, on: true, selected: { slice: 0, kind: 'corner', point: 0 } });
  const toggle = page.getByRole('switch', { name: 'Show on output' });
  await expect(toggle).toBeChecked();
  await toggle.uncheck({ force: true }); // the drawn track covers the input
  await expect.poll(() => sent.at(-1)).toEqual({ id: 1, on: false, selected: null });
  await toggle.check({ force: true });
  await expect.poll(() => sent.at(-1)).toEqual({ id: 1, on: true, selected: { slice: 0, kind: 'corner', point: 0 } });
  await page.getByRole('button', { name: 'Outputs', exact: true }).click();
  await expect.poll(() => sent.at(-1)).toEqual({ id: 1, on: false, selected: null });
  const on = { id: 1, on: true, selected: { slice: 0, kind: 'corner', point: 0 } }, off = { id: 1, on: false, selected: null };
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  await expect.poll(() => sent.at(-1)).toEqual(on);

  // the show locked: the switch shows off and why; nothing is sent (the engine ended the lease); unlocked, it is back
  const count = sent.length;
  await page.getByRole('button', { name: 'UNLOCKED' }).click();
  await expect(toggle).not.toBeChecked();
  await expect(toggle).toBeDisabled();
  await expect(toggle).toHaveAccessibleDescription(/the show is locked/);
  await page.getByRole('button', { name: 'LOCKED', exact: true }).click();
  await expect.poll(() => sent.length, 'only the one after unlocking').toBe(count + 1);
  expect(sent.at(-1)).toEqual(on);
  await expect(toggle).toBeChecked();

  // a hidden page ends the lease (its timers would be throttled), shown again it is back
  const visibility = (state: 'hidden' | 'visible') =>
    page.evaluate((state) => {
      Object.defineProperty(document, 'visibilityState', { value: state, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    }, state);
  await visibility('hidden');
  await expect.poll(() => sent.at(-1)).toEqual(off);
  await visibility('visible');
  await expect.poll(() => sent.at(-1)).toEqual(on);

  // leaving the screen ends it
  await openScreen(page, 'Layers');
  await expect.poll(() => sent.at(-1)).toEqual(off);
});

test('outputs: the edit overlay switches itself off after 10 minutes without an edit; one click brings it back', async ({ page, engine }) => {
  const sent = overlaySent(page);
  await page.clock.install();
  await page.goto(`${engine.url}/?token=${engine.token}`);
  await addUnassignedOutput(page);
  await page.getByRole('button', { name: 'Warp & Slices' }).click();
  await expect.poll(() => sent.at(-1)).toEqual({ id: 1, on: true, selected: null });
  const toggle = page.getByRole('switch', { name: 'Show on output' });
  await page.clock.fastForward('10:30');
  await expect.poll(() => sent.at(-1)).toEqual({ id: 1, on: false, selected: null });
  await expect(toggle).not.toBeChecked();
  await toggle.check({ force: true }); // the drawn track covers the input
  await expect.poll(() => sent.at(-1)).toEqual({ id: 1, on: true, selected: null });
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

test('preview: a viewer refused H.264 at the encoder limit shows JPEG at once and is upgraded when an encoder frees up (B86)', async ({ page, engine }) => {
  // the page's preview subscriptions of canvas 2; the first is the refused one: the JPEG frames (kind 2) the engine
  // sends on it, and its upgrade (not a JPEG subscription the page's B95 watchdog makes later)
  let subs = 0;
  let refusedId = 0;
  let jpegFrames = 0;
  let upgradedAt = 0;  // `subs` when the first `stream` description (H.264) came on the refused subscription; 0 = none yet
  page.on('websocket', (socket) => {
    socket.on('framesent', ({ payload }) => {
      const m = typeof payload === 'string' ? (JSON.parse(payload) as { t: string; stream?: string; target?: string }) : null;
      if (m?.t === 'sub' && m.stream === 'preview' && m.target === 'canvas:2') subs++;
    });
    socket.on('framereceived', ({ payload }) => {
      if (typeof payload === 'string') {
        const m = JSON.parse(payload) as { t: string; id: number; stream?: string; target?: string };
        if (m.t === 'sub' && m.stream === 'preview' && m.target === 'canvas:2') refusedId ||= m.id;
        if (m.t === 'stream' && m.id === refusedId) upgradedAt ||= subs;
      } else if (payload[0] === 2 && payload.readUInt32BE(1) === refusedId) jpegFrames++;
    });
  });
  await page.goto(`${engine.url}/?token=${engine.token}`);  // again, with the listener above in place

  // another client takes 3 H.264 encoders of canvas 1 (320, 960 and 1280 wide): with canvas 1's own (640) that is the
  // limit of 4, and canvas 2 has no stream of its own or of its canvas to fall back to, so it is refused to JPEG
  const load = await page.context().newPage();
  await load.goto(`${engine.url}/healthz`);
  await load.evaluate(async (token) => {
    const ws = new WebSocket(`wss://${location.host}/ws`);
    const ids: number[] = [];
    await new Promise<void>((done) => {
      ws.onopen = () => ws.send(JSON.stringify({ t: 'hello', clientId: 'e2e-encoders', schema: 1, role: 'programmer', token }));
      ws.onmessage = (event) => {
        if (typeof event.data !== 'string') return;
        const m = JSON.parse(event.data) as { t: string; id: number; stream?: string };
        if (m.t === 'welcome') for (const w of [320, 960, 1280]) ws.send(JSON.stringify({ t: 'sub', stream: 'preview', codec: 'avc', target: 'canvas', w }));
        if (m.t === 'sub' && m.stream === 'preview' && ids.push(m.id) === 3) done();
      };
    });
    Object.assign(window, { ws, ids });
  }, engine.token);

  await openScreen(page, 'Outputs');
  await page.getByRole('button', { name: 'Canvases' }).click();
  await page.getByRole('button', { name: 'Add canvas' }).click();
  await page.getByRole('group', { name: 'Canvas', exact: true }).getByRole('button', { name: 'Canvas 2' }).click();
  const figure = page.getByRole('figure');
  await expect.poll(() => subs, { timeout: previewTimeout }).toBe(1);
  // the engine's JPEG counters (live streamers only) while this viewer is the only one on JPEG: JPEGs made, encodes
  // that returned nil, sends a connection refused (B99); a failed read gives zeros, never a failed test
  type JPEGCounters = { jpegOut: number; jpegFailed: number; jpegDropped: number };
  const jpegCounters = async (): Promise<JPEGCounters> => {
    try {
      return ((await (await engine.api.get('/metrics')).json()) as { preview: JPEGCounters }).preview;
    } catch {
      return { jpegOut: 0, jpegFailed: 0, jpegDropped: 0 };
    }
  };
  const before = await jpegCounters();
  // the refusal says `codec: "jpeg"`: JPEG at once (not after 5 s without a description), and its frames are drawn
  await expect(figure.locator('figcaption')).toContainText(/^JPEG 5 fps · .* · H\.264 encoders busy/, { timeout: 3_000 });
  const drawn = () => figure.locator('canvas').evaluate((c: HTMLCanvasElement) => c.getContext('2d')!.getImageData(c.width / 2, c.height / 2, 1, 1).data[3]);
  // B98: on CI's VM the engine has sent this refused stream no JPEG frame for 30 s (cause open): on a workstation one
  // must come; drawing is checked once a frame came, and a CI run without one says so (Actions warning with the
  // engine's JPEG counters, engine log attached) and is skipped (B99)
  await expect.poll(() => jpegFrames, { timeout: previewTimeout }).toBeGreaterThan(0).catch(async (error: unknown) => {
    if (!process.env.CI || !/Timeout \d+ms exceeded/.test((error as Error).message ?? '')) throw error;
    const after = await jpegCounters();
    const made = (['jpegOut', 'jpegFailed', 'jpegDropped'] as const).map((k) => `${k} +${after[k] - before[k]} (now ${after[k]})`).join(', ');
    const note = `B98: ${jpegFrames} JPEG frames on the refused canvas:2 stream within ${previewTimeout} ms; ${made} (B99)`;
    console.log(`::warning::${note}`);
    test.info().annotations.push({ type: 'B98', description: note });
    await test.info().attach('fanousd.log (B98)', { path: join(engine.home, 'Library/Logs/Fanous/fanousd.log'), contentType: 'text/plain' });
    // the upgrade does not come on such a runner either: the rest would only run into the test timeout
    test.skip(true, 'no JPEG frame for the refused viewer on this runner (B99)');
  });
  if (jpegFrames > 0) await expect.poll(drawn, { timeout: previewTimeout }).toBe(255);

  // the other client lets go of one encoder: the engine moves the refused viewer to its own H.264 stream, on the same
  // subscription
  await load.evaluate(() => {
    const { ws, ids } = window as unknown as { ws: WebSocket; ids: number[] };
    ws.send(JSON.stringify({ t: 'unsub', id: ids[2] }));
  });
  // on CI the moved stream's VideoToolbox session, or the browser's decoder config after its description, can take
  // over 5 s without a frame: the page's B95 watchdog then re-subscribes as JPEG
  const fellBack = async () => /^JPEG 5 fps · no H\.264 stream/.test(await figure.locator('figcaption').innerText());
  await expect.poll(async () => upgradedAt > 0 || (!!process.env.CI && (await fellBack())), { timeout: previewTimeout }).toBe(true);
  // a fallback after the description came is not skipped here: the poll returns on `upgradedAt` first, and `decoded`
  // below accepts that JPEG on CI
  test.skip(upgradedAt === 0, 'no H.264 description within 5 s of the move on this runner (B66, B95); JPEG fallback');
  expect(upgradedAt).toBe(1);  // on the one subscription the page sent
  // the page decodes it; on CI a decoder that fails (B98) may fall back to JPEG with its reason, a new subscription
  const decoded = process.env.CI ? /^(H\.264 · |JPEG 5 fps · (?!.*encoders busy))/ : /^H\.264 · /;
  await expect(figure.locator('figcaption')).toContainText(decoded, { timeout: previewTimeout });
  await load.close();
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

/** Another client of the engine takes 3 H.264 encoders of canvas 1 (320, 960 and 1280 wide): with canvas 1's own (640)
 * that is the limit of 4 (B70). Resolves with `release(i)`, which ends its i-th of those subscriptions. */
async function holdEncoders(page: Page, engine: Engine): Promise<(i: number) => Promise<void>> {
  const other = await page.context().newPage();
  await other.goto(`${engine.url}/healthz`);
  await other.evaluate(async (token) => {
    const ws = new WebSocket(`wss://${location.host}/ws`);
    const ids: number[] = [];
    await new Promise<void>((done) => {
      ws.onopen = () => ws.send(JSON.stringify({ t: 'hello', clientId: 'e2e-encoders', schema: 1, role: 'programmer', token }));
      ws.onmessage = (event) => {
        if (typeof event.data !== 'string') return;
        const m = JSON.parse(event.data) as { t: string; id: number; stream?: string };
        if (m.t === 'welcome') for (const w of [320, 960, 1280]) ws.send(JSON.stringify({ t: 'sub', stream: 'preview', codec: 'avc', target: 'canvas', w }));
        if (m.t === 'sub' && m.stream === 'preview' && ids.push(m.id) === 3) done();
      };
    });
    Object.assign(window, { ws, ids });
  }, engine.token);
  return (i) =>
    other.evaluate((i) => {
      const { ws, ids } = window as unknown as { ws: WebSocket; ids: number[] };
      ws.send(JSON.stringify({ t: 'unsub', id: ids[i] }));
    }, i);
}

test('preview: an output region on the canvas stream at the encoder limit is letterboxed and says so (B87)', async ({ page, engine }) => {
  const release = await holdEncoders(page, engine);
  await addUnassignedOutput(page);  // its preview falls back to the canvas stream nearest its size
  const figure = page.getByRole('figure');
  const caption = figure.locator('figcaption');
  const fit = () => figure.locator('canvas').evaluate((c) => getComputedStyle(c).objectFit);
  await expectPreviewStreaming(figure);
  // the canvas fallback is an H.264 one: a browser that fell back to JPEG (no description within 5 s, B66) has its own
  // JPEG stream in the output's shape
  test.skip(!!process.env.CI && /^JPEG/.test(await caption.innerText()), 'H.264 not ready within 5 s on this runner (B66, B98); JPEG fallback');
  // a 16:9 output on the 16:9 canvas: the same shape, still the canvas stream and said so (B96); `contain` draws it as
  // `fill` would in a box of its shape
  await expect(caption).toContainText(/^H\.264 · \d+×\d+ · \d+ fps · canvas fallback/, { timeout: previewTimeout });
  expect(await fit()).toBe('contain');

  // a 4:3 region: the 16:9 canvas stream is shown whole, letterboxed, not stretched
  const region = page.getByLabel('Region w', { exact: true });
  await region.fill('1440');
  await region.press('Tab');
  await expect(caption).toContainText(/^H\.264 · \d+×\d+ · \d+ fps · canvas fallback/);
  expect(await fit()).toBe('contain');

  // an encoder frees up (not the 1280 one: the page's fallback keeps that one encoding): the engine moves the viewer
  // to the output's own 4:3 stream, and the letterbox goes
  await release(0);
  await expect(caption).not.toContainText('canvas fallback', { timeout: previewTimeout });
  expect(await fit()).toBe('fill');
});

test('preview: a layer on its canvas stream at the encoder limit says so, in the same shape (B96)', async ({ page, engine }) => {
  const release = await holdEncoders(page, engine);
  const figure = page.getByRole('figure');
  const caption = figure.locator('figcaption');
  await page.getByRole('group', { name: 'Preview shows' }).getByRole('button', { name: 'This layer' }).click();
  await expectPreviewStreaming(figure, 'Layer \\d+');  // at the limit: the stream of its canvas nearest its size
  test.skip(!!process.env.CI && /^JPEG/.test(await caption.innerText()), 'H.264 not ready within 5 s on this runner (B66, B98); JPEG fallback');
  // a layer has its canvas's 16:9 shape: before B96 the whole canvas showed as if it were the layer, unflagged
  await expect(caption).toContainText(/^H\.264 · \d+×\d+ · \d+ fps · canvas fallback · Layer \d+/, { timeout: previewTimeout });

  // encoders free up (all three: the page's fallback keeps the one it is on encoding): the engine moves the viewer to
  // the layer's own stream, whose description clears the flag
  for (const i of [0, 1, 2]) await release(i);
  await expect(caption).not.toContainText('canvas fallback', { timeout: previewTimeout });
  await expect(caption).toContainText(/^H\.264 · .* · Layer \d+/);
});

test('preview: a refused viewer the engine moves to a stream that never delivers falls back to JPEG after 5 s (B95)', async ({ page, engine }) => {
  // the page's socket runs through the test: once `frozen`, the engine's messages on the refused canvas:2 subscription
  // are dropped, as from a new streamer whose VideoToolbox session is stuck or failed
  let refused = 0;  // its id
  let subs = 0;  // the page's canvas:2 preview subscriptions
  let jpegFrames = 0;  // on the refused subscription
  let frozen = false;
  let moved = false;  // the engine's H.264 description or frame on it, dropped: it was moved to a new streamer
  await page.routeWebSocket(/\/ws$/, (ws) => {
    const server = ws.connectToServer();
    server.onMessage((message) => {
      if (typeof message === 'string') {
        const m = JSON.parse(message) as { t: string; id: number; stream?: string; target?: string };
        if (m.t === 'sub' && m.stream === 'preview' && m.target === 'canvas:2' && subs++ === 0) refused = m.id;
        if (frozen && m.t === 'stream' && m.id === refused) return void (moved = true);
      } else if (message.length >= 5 && message.readUInt32BE(1) === refused) {
        if (frozen) return void (moved ||= message[0] === 1);
        if (message[0] === 2) jpegFrames++;
      }
      ws.send(message);
    });
  });
  await page.goto(`${engine.url}/?token=${engine.token}`);  // again, through the route above
  const release = await holdEncoders(page, engine);
  await openScreen(page, 'Outputs');
  await page.getByRole('button', { name: 'Canvases' }).click();
  await page.getByRole('button', { name: 'Add canvas' }).click();
  await page.getByRole('group', { name: 'Canvas', exact: true }).getByRole('button', { name: 'Canvas 2' }).click();
  const figure = page.getByRole('figure');
  const caption = figure.locator('figcaption');
  await expect(caption).toContainText(/^JPEG 5 fps · .* · H\.264 encoders busy/, { timeout: previewTimeout });
  // the moved case needs the refused stream's JPEG first: without a frame on it (the B99 symptom) the watchdog fires
  // before any move. A CI run without one says so (Actions warning, engine log attached) and is skipped, as in B86
  await expect.poll(() => jpegFrames, { timeout: 4_000 }).toBeGreaterThan(0).catch(async (error: unknown) => {
    if (!process.env.CI || !/Timeout \d+ms exceeded/.test((error as Error).message ?? '')) throw error;
    const note = `B98: ${jpegFrames} JPEG frames on the refused canvas:2 stream within 4000 ms (B99)`;
    console.log(`::warning::${note}`);
    test.info().annotations.push({ type: 'B98', description: note });
    await test.info().attach('fanousd.log (B98)', { path: join(engine.home, 'Library/Logs/Fanous/fanousd.log'), contentType: 'text/plain' });
    test.skip(true, 'no JPEG frame for the refused viewer on this runner (B99)');
  });
  const drawn = () => figure.locator('canvas').evaluate((c: HTMLCanvasElement) => c.getContext('2d')!.getImageData(c.width / 2, c.height / 2, 1, 1).data[3]);
  await expect.poll(drawn).toBe(255);
  await expect(caption).toContainText('H.264 encoders busy');  // still the refused stream

  // an encoder frees up: the engine moves the viewer to its own H.264 stream, which never delivers a frame
  frozen = true;
  await release(2);
  // the watchdog would fire on the dropped JPEG alone: the move itself must be seen. A CI run whose new VideoToolbox
  // session gives nothing before the watchdog fires (B66) is skipped
  await expect.poll(() => moved, { timeout: previewTimeout }).toBe(true).catch((error: unknown) => {
    if (!process.env.CI || !/Timeout \d+ms exceeded/.test((error as Error).message ?? '')) throw error;
    test.skip(true, 'the moved stream sent no description within 5 s on this runner (B66); JPEG fallback first');
  });
  // before B95 the caption stayed "H.264 encoders busy" over a frozen picture; now it re-subscribes as JPEG, once
  await expect(caption).toContainText(/^JPEG 5 fps · no H\.264 stream from the engine/, { timeout: 10_000 });
  await page.waitForTimeout(1_000);  // the fallback stream has no watchdog: no further subscription
  expect(subs).toBe(2);
  await expect(caption.locator('.stalled')).toHaveCount(0, { timeout: 5_000 });  // the new stream's frames are drawn
});
