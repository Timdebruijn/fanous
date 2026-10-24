#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# Soak test (DESIGN.md §18): drives the running engine with scripted Art-Net for HOURS, samples /metrics and the
# engine's RSS every second, kills the engine (-9) at the kill interval and measures the restart, and writes
# docs/benchmarks/soak-<date>.{csv,md} with a pass/fail verdict: no missed (dropped) frames outside the restart
# windows, memory growth under MEM_GROWTH_MB after a 5-minute warm-up, every restart under RESTART_S. Late presents
# (a frame shown one vsync late) are listed as warnings: DESIGN.md §18 counts dropped frames.
#   scripts/soak.sh [HOURS=8] [LAYERS=4]   env: LABEL=org.lanthorn.engine (launchd label), PORT=8443,
#   KILL_EVERY_S=7200 (0 = never), MEM_GROWTH_MB=100, RESTART_S=3, FILES=4, OUT=docs/benchmarks
set -euo pipefail
cd "$(dirname "$0")/.."
HOURS=${1:-8}; LAYERS=${2:-4}
LABEL=${LABEL:-org.lanthorn.engine}; PORT=${PORT:-8443}; KILL_EVERY_S=${KILL_EVERY_S:-7200}
MEM_GROWTH_MB=${MEM_GROWTH_MB:-100}; RESTART_S=${RESTART_S:-3}; FILES=${FILES:-4}; OUT=${OUT:-docs/benchmarks}
SECONDS_TOTAL=$(printf '%.0f' "$(echo "$HOURS * 3600" | bc)")
STAMP=$(date +%Y-%m-%d-%H%M)
CSV="$OUT/soak-$STAMP.csv"; MD="$OUT/soak-$STAMP.md"
BIN=$(swift build -c release --show-bin-path)
[[ -x "$BIN/lanthorn-bench" ]] || swift build -c release --product lanthorn-bench >/dev/null

metrics() { curl -sk --max-time 2 "https://127.0.0.1:$PORT/metrics" || true; }
# one python per sample: "pid totalFrames totalMissed totalLate frames gpuMsP99 cpuMsP99 dmxToPhotonMsP99 textureMisses clients uptimeSeconds"
fields() { python3 -c 'import json,sys
d=json.load(sys.stdin); print(" ".join(str(d.get(k, "")) for k in ("pid","totalFrames","totalMissed","totalLate","frames","gpuMsP99","cpuMsP99","dmxToPhotonMsP99","textureMisses","clients","uptimeSeconds")))' 2>/dev/null || true; }
engine_pid() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1; }

m=$(metrics); read -r pid _ <<< "$(echo "$m" | fields)"
[[ -n "$pid" ]] || { echo "no engine answers on https://127.0.0.1:$PORT (start the agent first)"; exit 1; }
echo "soak: ${HOURS} h, $LAYERS layers, engine pid $pid ($LABEL), kill every ${KILL_EVERY_S}s → $CSV"
"$BIN/lanthorn-bench" dmx --layers "$LAYERS" --files "$FILES" --seconds "$SECONDS_TOTAL" >/dev/null 2>&1 &
DMX_PID=$!
trap 'kill $DMX_PID 2>/dev/null || true' EXIT

echo "t,pid,rss_mb,total_frames,total_missed,total_late,fps,gpu_p99_ms,cpu_p99_ms,dmx_p99_ms,texture_misses,clients,event" > "$CSV"
start=$(date +%s); next_kill=$(( KILL_EVERY_S > 0 ? KILL_EVERY_S : 0 )); restarts=(); fails=(); warns=()
warm_rss=""; last_pid=$pid; prev_missed=0; prev_late=0; in_restart=0
while :; do
  now=$(date +%s); t=$(( now - start )); [[ $t -ge $SECONDS_TOTAL ]] && break
  event=""
  if [[ $KILL_EVERY_S -gt 0 && $t -ge $next_kill ]]; then
    next_kill=$(( next_kill + KILL_EVERY_S )); event="kill"
    kill -9 "$last_pid" 2>/dev/null || true
    k0=$(python3 -c 'import time; print(time.time())')
    until curl -sk --max-time 1 -o /dev/null "https://127.0.0.1:$PORT/healthz"; do sleep 0.05; done
    k1=$(python3 -c 'import time; print(time.time())')
    restart=$(python3 -c "print(round($k1 - $k0, 2))"); restarts+=("$restart"); event="kill→healthz ${restart}s"
    python3 -c "exit(0 if $restart <= $RESTART_S else 1)" || fails+=("restart took ${restart}s at t=${t}s")
    in_restart=1; prev_missed=0; prev_late=0
  fi
  m=$(metrics)
  if [[ -z "$m" ]]; then echo "$t,,,,,,,,,,,,engine unreachable" >> "$CSV"; [[ $in_restart -eq 1 ]] || fails+=("engine unreachable at t=${t}s"); sleep 1; continue; fi
  read -r pid tf tm tl fps gpu cpu dmx tex clients up <<< "$(echo "$m" | fields)"
  rss_mb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.0f", $1/1024}')
  if [[ "$pid" != "$last_pid" ]]; then [[ -n "$event" ]] || { event="restarted (pid $last_pid → $pid)"; fails+=("unexpected restart at t=${t}s"); }; last_pid=$pid; in_restart=1; prev_missed=0; prev_late=0; fi
  # the first 5 s after a (re)start are the restart window: frames missed while the pipeline fills do not count
  if [[ $in_restart -eq 1 ]]; then [[ "${up:-0}" -ge 5 ]] && { in_restart=0; prev_missed=$tm; prev_late=$tl; }; fi
  if [[ $in_restart -eq 0 ]]; then
    [[ "$tm" -gt "$prev_missed" ]] && fails+=("missed $(( tm - prev_missed )) frame(s) at t=${t}s")
    [[ "$tl" -gt "$prev_late" ]] && warns+=("late $(( tl - prev_late )) present(s) at t=${t}s")
    prev_missed=$tm; prev_late=$tl
    [[ -z "$warm_rss" && $t -ge 300 ]] && warm_rss=$rss_mb
  fi
  echo "$t,$pid,$rss_mb,$tf,$tm,$tl,$fps,$gpu,$cpu,$dmx,$tex,$clients,$event" >> "$CSV"
  sleep 1
done
kill $DMX_PID 2>/dev/null || true
end_rss=${rss_mb:-0}; growth=$(( end_rss - ${warm_rss:-$end_rss} ))
[[ $growth -le $MEM_GROWTH_MB ]] || fails+=("RSS grew ${growth} MB after warm-up (${warm_rss} → ${end_rss} MB)")
verdict=PASS; [[ ${#fails[@]} -eq 0 ]] || verdict=FAIL; [[ $verdict == PASS && ${#warns[@]} -gt 0 ]] && verdict="PASS (with warnings)"
{
  echo "# Soak $STAMP: $verdict"
  echo
  echo "$(sw_vers -productName) $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string), $LABEL, $LAYERS layers, ${HOURS} h, Art-Net at 40 Hz (random file/play mode/dissolve/intensity every 3–8 s), kill -9 every ${KILL_EVERY_S} s."
  echo
  echo "| Metric | Value |"; echo "|---|---|"
  echo "| Frames presented | $tf (last engine instance) |"; echo "| Missed (dropped) outside restart windows | $(printf '%s\n' "${fails[@]}" | grep -c missed || true) event(s) |"
  echo "| Late presents (one vsync late) | ${#warns[@]} event(s) |"; echo "| Restarts (kill → healthz) | ${restarts[*]:-none} s |"
  echo "| RSS after warm-up → end | ${warm_rss:-?} → ${end_rss} MB (${growth} MB) |"
  echo "| GPU p99 (last sample) | ${gpu} ms |"; echo "| DMX→photon p99 (last sample) | ${dmx} ms |"
  echo
  if [[ ${#fails[@]} -gt 0 ]]; then echo "Failures:"; printf -- '- %s\n' "${fails[@]}"; else echo "No failures."; fi
  if [[ ${#warns[@]} -gt 0 ]]; then echo; echo "Warnings:"; printf -- '- %s\n' "${warns[@]}"; fi
  echo; echo "Samples: \`$(basename "$CSV")\` (1 s)."
} > "$MD"
cat "$MD"
[[ $verdict == PASS* ]]
