#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# web/src/lib/protocol.d.ts must equal what the engine's command registry generates (DESIGN.md §11.4). `--write` regenerates it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product lanthornd >/dev/null
generated=$("$(swift build --show-bin-path)/lanthornd" protocol-dts)
if [[ "${1:-}" == "--write" ]]; then
  printf '%s\n' "$generated" > web/src/lib/protocol.d.ts
  echo "web/src/lib/protocol.d.ts written"
  exit 0
fi
if ! diff -u web/src/lib/protocol.d.ts <(printf '%s\n' "$generated"); then
  echo "web/src/lib/protocol.d.ts is stale: run scripts/check-protocol-dts.sh --write"
  exit 1
fi
echo "web/src/lib/protocol.d.ts is current"
