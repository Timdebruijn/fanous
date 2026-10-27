// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Every test gets its own real engine: `fanousd --no-network` on a free port with FANOUS_HOME in a fresh temporary
// directory, so it never touches the user's data, logs or library and runs next to an engine on 8443.
import { test as base, expect, type APIRequestContext, type Page } from '@playwright/test';
import { execFileSync, spawn, type ChildProcess } from 'node:child_process';
import { copyFileSync, existsSync, mkdtempSync, openSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer, type AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const repo = resolve(import.meta.dirname, '../..');
const binary = process.env.FANOUSD ?? join(repo, '.build/debug/fanousd');
const webRoot = join(repo, 'web/dist');

// A known engine race, not fixed yet (B62 a): StateStore.commit broadcasts a project patch before onProjectChanged
// applies it, so the preview of a just added (or undone) output can be asked for before the engine knows the output.
// A refused output preview within RACE_MS of the patch that added the output is allowed; any other refusal fails
// (a canvas preview waits until the canvas renders). Drop this once it is fixed.
const RACE_MS = 1500;
const REFUSED_TARGET = /^preview target (output:\d+) is not /;
const LIST_OR_ITEM = /^\/outputs(?:\/\d+)?$/;

export type Engine = { url: string; home: string; token: string; api: APIRequestContext };

function freePort(): Promise<number> {
  return new Promise((done, fail) => {
    const server = createServer().once('error', fail);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address() as AddressInfo;
      server.close(() => done(port));
    });
  });
}

function stopped(child: ChildProcess, ms: number): Promise<boolean> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
  return new Promise((done) => {
    const timer = setTimeout(() => done(false), ms);
    child.once('exit', () => {
      clearTimeout(timer);
      done(true);
    });
  });
}

/** Engines left by an aborted run (their test runner gone, so launchd adopted them): killed, their homes removed. */
function reapOrphans(): void {
  for (const name of readdirSync(tmpdir()).filter((n) => n.startsWith('fanous-e2e-'))) {
    const home = join(tmpdir(), name);
    const pid = Number(existsSync(join(home, 'fanousd.pid')) ? readFileSync(join(home, 'fanousd.pid'), 'utf8') : NaN);
    if (!pid) continue;  // being set up right now, or not ours
    let ps = '';
    try {
      ps = execFileSync('ps', ['-o', 'ppid=,comm=', '-p', String(pid)], { encoding: 'utf8' }).trim();
    } catch {
      // no such process: only the directory is left
    }
    const [ppid, command = ''] = ps.split(/\s+/, 2);
    if (ps && !(ppid === '1' && command.endsWith('fanousd'))) continue;  // a live engine of a running test
    if (ps) process.kill(pid, 'SIGKILL');
    rmSync(home, { recursive: true, force: true });
  }
}

export const test = base.extend<{ engine: Engine }>({
  engine: async ({ playwright }, use, testInfo) => {
    if (!existsSync(binary)) throw new Error(`${binary} is missing: run \`swift build\` in the repository first`);
    if (!existsSync(join(webRoot, 'index.html'))) throw new Error('web/dist is missing: run `npm run build` first');
    reapOrphans();
    const home = mkdtempSync(join(tmpdir(), 'fanous-e2e-'));
    const port = await freePort();
    const url = `https://127.0.0.1:${port}`;
    const out = join(home, 'fanousd.out');
    const fd = openSync(out, 'w');
    const child = spawn(binary, ['--foreground', '--no-network', '--port', String(port), '--web-root', webRoot], {
      env: { ...process.env, FANOUS_HOME: home },
      stdio: ['ignore', fd, fd],
    });
    writeFileSync(join(home, 'fanousd.pid'), String(child.pid));
    const api = await playwright.request.newContext({ baseURL: url, ignoreHTTPSErrors: true });
    try {
      const deadline = Date.now() + 20_000;
      for (;;) {
        if (child.exitCode !== null) throw new Error(`fanousd exited with ${child.exitCode}:\n${readFileSync(out, 'utf8')}`);
        if (Date.now() > deadline) throw new Error(`fanousd did not answer on ${url} within 20 s:\n${readFileSync(out, 'utf8')}`);
        if (await api.get('/healthz').then((r) => r.ok(), () => false)) break;
        await new Promise((r) => setTimeout(r, 100));
      }
      const token = readFileSync(join(home, 'Library/Application Support/Fanous/shell-token'), 'utf8').trim();
      await use({ url, home, token, api });
    } finally {
      await api.dispose();
      child.kill('SIGTERM');
      if (!(await stopped(child, 5_000))) child.kill('SIGKILL');
      if (testInfo.status !== testInfo.expectedStatus) {
        const log = join(home, 'Library/Logs/Fanous/fanousd.log');
        if (existsSync(log)) {
          copyFileSync(log, testInfo.outputPath('fanousd.log'));
          await testInfo.attach('fanousd.log', { path: testInfo.outputPath('fanousd.log'), contentType: 'text/plain' });
        }
      }
      rmSync(home, { recursive: true, force: true });
    }
  },

  // The UI opened as the shell does (`?token=`), so it is programmer. Any page error, console error, refused command
  // or protocol error fails the test.
  page: async ({ page, engine }, use) => {
    const errors: string[] = [];
    page.on('pageerror', (error) => errors.push(`page error: ${error.message}`));
    page.on('console', (message) => {
      if (message.type() === 'error') errors.push(`console error: ${message.text()}`);
    });
    const appeared = new Map<string, number>();  // "output:1" → when a project patch added it
    page.on('websocket', (socket) =>
      socket.on('framereceived', ({ payload }) => {
        if (typeof payload !== 'string') return;
        const message = JSON.parse(payload) as {
          t: string; ok?: boolean; error?: unknown; code?: string; message?: string; id?: number;
          doc?: string; ops?: { path: string; value?: unknown }[];
        };
        if (message.t === 'patch' && message.doc === 'project') {
          for (const op of message.ops ?? []) {
            if (!LIST_OR_ITEM.test(op.path)) continue;
            for (const item of [op.value].flat() as { id?: unknown }[]) {
              if (typeof item?.id === 'number') appeared.set(`output:${item.id}`, Date.now());
            }
          }
        }
        if (message.t === 'ack' && !message.ok) errors.push(`command refused: ${JSON.stringify(message.error)}`);
        // an error with a stream id ends a stream that went away (a removed canvas); without one a request was refused
        if (message.t === 'error' && message.id === undefined) {
          const target = REFUSED_TARGET.exec(message.message ?? '')?.[1];
          const race = target !== undefined && Date.now() - (appeared.get(target) ?? -Infinity) < RACE_MS;
          if (!race) errors.push(`protocol error: ${message.code}: ${message.message}`);
        }
      }),
    );
    page.on('dialog', (dialog) => void dialog.accept());
    await page.goto(`${engine.url}/?token=${engine.token}`);
    await expect(page.getByRole('button', { name: 'PROGRAMMER' })).toBeVisible();
    // and the first live document (the status bar counts this page): until it arrives the preview block is missing
    // and the layout shifts under a click
    await expect(page.getByRole('banner')).toContainText(/\b[1-9]\d* clients/);
    await use(page);
    expect(errors, 'errors in the browser').toEqual([]);
  },
});

export { expect };

export async function openScreen(page: Page, name: 'Layers' | 'Media' | 'Outputs' | 'Patch' | 'Show' | 'System'): Promise<void> {
  await page.getByRole('navigation', { name: 'Screens' }).getByRole('link', { name }).click();
}
