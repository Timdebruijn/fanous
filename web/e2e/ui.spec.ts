// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Browser end-to-end tests against a real engine (fixtures.ts). Few and robust: each covers a flow whose bugs unit
// tests cannot see (wrong JSON pointers, overlapping handles, subscription races).
import type { Page } from '@playwright/test';
import { expect, openScreen, test } from './fixtures';

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

test('canvases: add a canvas, put a layer on it, remove it', async ({ page }) => {
  await openScreen(page, 'Outputs');
  await page.getByRole('button', { name: 'Canvases' }).click();
  await page.getByRole('button', { name: 'Add canvas' }).click();
  const canvases = page.getByRole('group', { name: 'Canvas', exact: true });
  await expect(canvases.getByRole('button', { name: 'Canvas 2' })).toBeVisible();
  // its preview really starts once the canvas renders (B62): one left on "starting…" or "connecting…" fails here
  await expect(page.getByRole('figure').locator('figcaption')).toContainText(/H\.264|JPEG/);

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
  await page.goto(`${engine.url}/?token=${engine.token}`);  // again, with the listener above in place

  const shows = page.getByRole('group', { name: 'Preview shows' });
  const caption = page.getByRole('figure').locator('figcaption');
  await expect(caption).toContainText(/H\.264|JPEG/);

  await shows.getByRole('button', { name: 'This layer' }).click();
  // faster than a subscription round trip: each new layer is picked while the previous stream is still on its way
  await page.evaluate(async () => {
    for (const row of document.querySelectorAll<HTMLElement>('.row.layer')) {
      row.click();
      await new Promise((r) => setTimeout(r, 5));
    }
  });
  await expect(caption).toContainText(/(H\.264|JPEG).* · Layer 8/);
  await expect.poll(() => streams.size).toBe(1);

  await shows.getByRole('button', { name: 'Canvas' }).click();
  await expect(caption).toContainText(/(H\.264|JPEG).* · Canvas/);
  await expect.poll(() => streams.size).toBe(1);
});
