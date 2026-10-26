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
  forbidOnly: !!process.env.CI,
  reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : 'list',
  use: {
    browserName: 'chromium',
    ignoreHTTPSErrors: true,
    viewport: { width: 1440, height: 900 },
    trace: 'retain-on-failure',
  },
});
