#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# Phase 3 benchmark variants at the Phase 2 tier maxima: two effect slots on
# every layer, permanent dissolves, and (optionally) a one-hour audio drift soak.
#   WINDOW=20 MODE=--headless scripts/bench-phase3.sh
#   AUDIO_MEDIA=/path/to/dir-with-audio-file DRIFT_SECONDS=3600 scripts/bench-phase3.sh drift
set -euo pipefail
cd "$(dirname "$0")/.."
MEDIA=${MEDIA:-"$HOME/Movies/Lanthorn Bench"}
WINDOW=${WINDOW:-20}
MODE=${MODE:---headless}
BIN=$(swift build -c release --show-bin-path)
run() { "$BIN/lanthorn-bench" run --media "$MEDIA" --out docs/benchmarks $MODE "$@" 2>&1 | grep -E "^layers|^  audio|wrote|error"; }
if [[ "${1:-}" == "drift" ]]; then
  echo "=== audio drift soak: 1 layer, ${DRIFT_SECONDS:-3600} s"
  MEDIA=${AUDIO_MEDIA:?set AUDIO_MEDIA to a directory with hapq_1920x1080p60.mov generated with --audio}
  run --codec hapq --res 1920x1080p60 --layers 1 --window "${DRIFT_SECONDS:-3600}"
  exit 0
fi
run() { "$BIN/lanthorn-bench" run --media "$MEDIA" --out docs/benchmarks $MODE --window "$WINDOW" "$@" 2>&1 | grep -E "^layers|^  audio|wrote|error"; }
for codec in prores422hq hapq; do
  echo "=== $codec 1080p60 × 16 layers, blur + edge on every layer"
  run --codec "$codec" --res 1920x1080p60 --layers 16 --effects blur,edge
  echo "=== $codec 4K30 × 16 layers, blur + edge on every layer"
  run --codec "$codec" --res 3840x2160p30 --layers 16 --effects blur,edge
  echo "=== $codec 1080p60 × 8 layers, permanent 2 s dissolves"
  run --codec "$codec" --res 1920x1080p60 --layers 8 --dissolve 2
done
