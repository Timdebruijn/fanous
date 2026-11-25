#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# `swift test` wrapper: Command Line Tools keep the Swift Testing macro plugin
# in a directory the compiler does not search by default; Xcode toolchains do.
set -euo pipefail
cd "$(dirname "$0")/.."
# Tests run in parallel (engine suite ~24 s on an M1 Pro, 2026-11-04; serially far longer). Swift Testing runs every test as a task on
# the cooperative pool: blocking AVFoundation work in a test (MovieWriter.finish, finishWriting + semaphore)
# goes through offPool (Tests/FanousEngineTests/TestSupport.swift), or enough of those tests at once hang
# the run (B63). Tests that wait for something poll with a deadline (waitUntil in TestSupport.swift), so a loaded
# Mac makes the run slower, not red, in the loads tested (load average up to ~100); negative checks keep fixed
# windows (B67). A test that blocks (a `recv` with a timeout, a semaphore) or computes for more than a fraction of a
# second without suspending runs off the pool: `@Test(.offPool)`. On a 3-core runner three such tests held every pool
# thread and async tests elsewhere missed their 10 s deadlines (B353). A `waitUntil` that held only after more than half
# its deadline prints a "waitUntil margin" line. The run ends with its ten slowest tests (suite.test, from the xUnit
# file in .build). Every duration includes the time the test queued for a thread before and after its body; the run's
# median duration is printed as that queue wait. Locally (10 threads, wait well under a second) a test near the top
# that neither waits real time nor runs off the pool is a candidate; on a loaded CI runner the wait blurs the list.
# `--hosted`: the suites a hosted CI runner can run: Core, and the engine suites that need no GPU, media hardware or
# display (the GPU tests of a mixed file live in its …GPUTests suite). Add a suite here once it passes on macos-26.
# They run one at a time: on a 3-core runner the polls of a parallel run resumed only once the pool had worked through
# every test queued at the start, and a 10 s deadline held after 9.96 s (B353); serial, the queue wait is zero.
if [[ "${1:-}" == "--hosted" ]]; then
  shift
  hosted='AudioLifecycleTests|BonjourTests|CITPServerTests|ClientErrorTextTests|ConnectionLimitTests|DXTCompressorTests|DisplayModeSwitcherTests'
  hosted+='|ControlQueueTests|EditOverlayTests|HTTPSServerLogTests|IngestAPITests|LayerGeometryTests|LibraryIndexTests|LibraryRedactionTests|ListenerRecoveryTests|LiveCatalogTests'
  hosted+='|DMXStateBoundsTests|HAPFrameBoundsTests|HTTPSPipeliningTests|MetricsMicrosTests|MetricsStaleFramesTests|ProjectValueRangeTests'
  hosted+='|MIDIControlTests|OSCFeedbackServerTests|OSCReceiverTests|OSLogHandlerTests|PresetCommandsTests|ProjectVersionsTests'
  hosted+='|ReferenceSwapTests|RESTAuthTests|RoleAuthTests|ShowControlTests|SlaveClockTests|StateServerTests|StateStoreRedactionTests|StateStoreTests'
  hosted+='|SyncReceiverTests|SyncSenderTests|TLSIdentityTests|TripleBufferTests|UDPFlowTests|UDPSendTests|UIExpiryTests'
  hosted+='|UniverseSettingsEngineTests|WallCommandsTests|WebSocketHandshakeTests|WebSocketSessionTests'
  set -- --no-parallel --filter "FanousCoreTests|FanousEngineTests\.($hosted)/" "$@"
fi
# Test engines get a throwaway FANOUS_HOME, so an AppPaths write lands there and not in the real install (B240); a
# FANOUS_HOME already set is kept.
if [[ -z "${FANOUS_HOME:-}" ]]; then
  FANOUS_HOME="$(mktemp -d -t fanous-test-home)"  # its own line: `export X="$(…)"` hides a failed mktemp from set -e
  export FANOUS_HOME
  trap 'rm -rf "$FANOUS_HOME"' EXIT
fi
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$plugins" ]]; then
  set -- -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
results=.build/test-results-swift-testing.xml  # swift test adds `-swift-testing` to the name given
rm -f "$results"
code=0
swift test --xunit-output .build/test-results.xml "$@" || code=$?
if [[ -f "$results" ]]; then
  awk -F'"' '/<testcase / {
      for (i = 1; i < NF; i++) {
        if ($i ~ /classname=$/) c = $(i + 1); else if ($i ~ / name=$/) n = $(i + 1); else if ($i ~ /time=$/) t = $(i + 1)
      }
      sub(/^[^.]*\./, "", c); printf "%.3f %s.%s\n", t, c, n
    }' "$results" | sort -rn | awk '{ line[NR] = $0; t[NR] = $1 }
    END {
      if (NR == 0) exit
      printf "Ten slowest tests (s; each includes the queue wait, the median duration: %s s):\n", t[int((NR + 1) / 2)]
      for (i = 1; i <= 10 && i <= NR; i++) print "  " line[i]
    }'
fi
exit $code
