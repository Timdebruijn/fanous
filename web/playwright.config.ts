// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// `npm run e2e`: needs `.build/debug/fanousd` (swift build) and `web/dist` (npm run build); see docs/DEVELOPMENT.md.
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: 'e2e',
  // one engine per test; one at a time keeps the GPU and the machine quiet
  workers: 1,
  timeout: 60_000,
  // the same 52 tests take 2.6–3.5 min on a fast CI runner and 7–10 min on a slow one (a constant 8 s more per test,
  // the engine start; the slowest test stays 24 s on both), so 10 min cut the slow runs short 4 times on 2026-11-01 (B135)
  globalTimeout: 20 * 60_000,
  forbidOnly: !!process.env.CI,
  reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : 'list',
  use: {
    browserName: 'chromium',
    ignoreHTTPSErrors: true,
    viewport: { width: 1440, height: 900 },
    trace: 'retain-on-failure',
  },
});
