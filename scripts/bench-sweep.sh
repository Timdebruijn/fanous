#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# Runs the Phase 2 benchmark matrix (codec × resolution) and writes docs/benchmarks/.
#   WINDOW=20 MAX_LAYERS=16 MODE=--headless scripts/bench-sweep.sh
set -euo pipefail
cd "$(dirname "$0")/.."
MEDIA=${MEDIA:-"$HOME/Movies/Lanthorn Bench"}
WINDOW=${WINDOW:-20}
MAX_LAYERS=${MAX_LAYERS:-16}
MODE=${MODE:---headless}
BIN=$(swift build -c release --show-bin-path)
for codec in prores422hq hapq; do
  for res in 1920x1080p60 3840x2160p30 3840x2160p60; do
    echo "=== $codec $res $MODE (window ${WINDOW}s)"
    "$BIN/lanthorn-bench" run --media "$MEDIA" --codec "$codec" --res "$res" --max-layers "$MAX_LAYERS" --window "$WINDOW" $MODE --out docs/benchmarks 2>&1 | grep -E "^layers|^soak|wrote|error"
  done
done
