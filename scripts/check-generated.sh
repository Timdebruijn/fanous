#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# docs/channel-map.md and web/src/lib/protocol.d.ts (DESIGN.md §11.4) must equal what the engine generates.
# `--write` regenerates them.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product fanousd >/dev/null
fanousd="$(swift build --show-bin-path)/fanousd"
stale=0
for command file in channel-map docs/channel-map.md protocol-dts web/src/lib/protocol.d.ts; do
  generated=$("$fanousd" "$command")
  if [[ "${1:-}" == "--write" ]]; then
    printf '%s\n' "$generated" > "$file"
    echo "$file written"
  elif diff -u "$file" <(printf '%s\n' "$generated"); then
    echo "$file is current"
  else
    echo "$file is stale: run scripts/check-generated.sh --write"
    stale=1
  fi
done
exit $stale
