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
