// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { svelte } from '@sveltejs/vite-plugin-svelte';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [svelte()],
  build: { target: 'es2022', sourcemap: true },
  server: {
    // `vite dev` against a running engine; the built UI is served by fanousd itself.
    proxy: {
      '/healthz': { target: 'https://127.0.0.1:8443', secure: false },
      '/metrics': { target: 'https://127.0.0.1:8443', secure: false },
      '/api': { target: 'https://127.0.0.1:8443', secure: false },
      '/ws': { target: 'wss://127.0.0.1:8443', ws: true, secure: false },
    },
  },
  test: { include: ['src/**/*.test.ts'] },
});
