#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# `swift test` wrapper: Command Line Tools keep the Swift Testing macro plugin
# in a directory the compiler does not search by default; Xcode toolchains do.
set -euo pipefail
cd "$(dirname "$0")/.."
# Tests run in parallel (engine suite ~15 s, ~58 s serially). Swift Testing runs every test as a task on
# the cooperative pool: blocking AVFoundation work in a test (MovieWriter.finish, finishWriting + semaphore)
# goes through offPool (Tests/FanousEngineTests/TestSupport.swift), or enough of those tests at once hang
# the run (B63). Tests that wait for something poll with a deadline (waitUntil in TestSupport.swift), so a loaded
# Mac makes the run slower, not red, in the loads tested (load average up to ~100); negative checks keep fixed
# windows (B67).
# `--hosted`: the suites a hosted CI runner can run: Core, and the engine suites that need no GPU, media hardware or
# display (the GPU tests of a mixed file live in its …GPUTests suite). Add a suite here once it passes on macos-26.
if [[ "${1:-}" == "--hosted" ]]; then
  shift
  hosted='AudioLifecycleTests|BonjourTests|CITPServerTests|ClientErrorTextTests|DXTCompressorTests|DisplayModeSwitcherTests'
  hosted+='|EditOverlayTests|HTTPSServerLogTests|IngestAPITests|LayerGeometryTests|LibraryIndexTests|LibraryRedactionTests|LiveCatalogTests'
  hosted+='|MIDIControlTests|OSCFeedbackServerTests|OSCReceiverTests|OSLogHandlerTests|PresetCommandsTests|ProjectVersionsTests'
  hosted+='|RESTAuthTests|RoleAuthTests|ShowControlTests|SlaveClockTests|StateServerTests|StateStoreRedactionTests|StateStoreTests'
  hosted+='|SyncReceiverTests|SyncSenderTests|TLSIdentityTests|TripleBufferTests|UDPSendTests|UIExpiryTests'
  hosted+='|UniverseSettingsEngineTests|WallCommandsTests|WebSocketHandshakeTests|WebSocketSessionTests'
  set -- --filter "FanousCoreTests|FanousEngineTests\.($hosted)/" "$@"
fi
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$plugins" ]]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
