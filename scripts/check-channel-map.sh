#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# docs/channel-map.md must equal what the engine generates. `--write` regenerates it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product fanousd >/dev/null
generated=$("$(swift build --show-bin-path)/fanousd" channel-map)
if [[ "${1:-}" == "--write" ]]; then
  printf '%s\n' "$generated" > docs/channel-map.md
  echo "docs/channel-map.md written"
  exit 0
fi
if ! diff -u docs/channel-map.md <(printf '%s\n' "$generated"); then
  echo "docs/channel-map.md is stale: run scripts/check-channel-map.sh --write"
  exit 1
fi
echo "docs/channel-map.md is current"
