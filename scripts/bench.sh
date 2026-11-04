#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# Benchmark matrices, written to docs/benchmarks/:
#   sweep   the Phase 2 matrix (codec × resolution), layers ramped up to MAX_LAYERS
#   phase3  the Phase 3 variants at the Phase 2 tier maxima: two effect slots on every layer, permanent dissolves
#   drift   a one-hour audio drift soak on one layer
#   WINDOW=20 MAX_LAYERS=16 MODE=--headless scripts/bench.sh sweep
#   WINDOW=20 MODE=--headless scripts/bench.sh phase3
#   AUDIO_MEDIA=/path/to/dir-with-audio-file DRIFT_SECONDS=3600 scripts/bench.sh drift
set -euo pipefail
cd "$(dirname "$0")/.."
case ${1:-} in
  sweep) FILTER='^layers|^soak|wrote|error' ;;
  phase3|drift) FILTER='^layers|^  audio|wrote|error' ;;
  *) echo "usage: scripts/bench.sh sweep|phase3|drift" >&2; exit 64 ;;
esac
MEDIA=${MEDIA:-"$HOME/Movies/Fanous Bench"}
WINDOW=${WINDOW:-20}
MAX_LAYERS=${MAX_LAYERS:-16}
MODE=${MODE:---headless}
BIN=$(swift build -c release --show-bin-path)
run() { "$BIN/fanous-bench" run --media "$MEDIA" --out docs/benchmarks $MODE --window "$WINDOW" "$@" 2>&1 | grep -E "$FILTER"; }
case $1 in
  sweep)
    for codec in prores422hq hapq; do
      for res in 1920x1080p60 3840x2160p30 3840x2160p60; do
        echo "=== $codec $res $MODE (window ${WINDOW}s)"
        run --codec "$codec" --res "$res" --max-layers "$MAX_LAYERS"
      done
    done ;;
  phase3)
    for codec in prores422hq hapq; do
      echo "=== $codec 1080p60 × 16 layers, blur + edge on every layer"
      run --codec "$codec" --res 1920x1080p60 --layers 16 --effects blur,edge
      echo "=== $codec 4K30 × 16 layers, blur + edge on every layer"
      run --codec "$codec" --res 3840x2160p30 --layers 16 --effects blur,edge
      echo "=== $codec 1080p60 × 8 layers, permanent 2 s dissolves"
      run --codec "$codec" --res 1920x1080p60 --layers 8 --dissolve 2
    done ;;
  drift)
    WINDOW=${DRIFT_SECONDS:-3600}
    echo "=== audio drift soak: 1 layer, $WINDOW s"
    MEDIA=${AUDIO_MEDIA:?set AUDIO_MEDIA to a directory with hapq_1920x1080p60.mov generated with --audio}
    run --codec hapq --res 1920x1080p60 --layers 1 ;;
esac
