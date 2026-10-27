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
# the run (B63). A few tests are wall-clock bound: on a loaded machine use `scripts/test.sh --no-parallel`.
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$plugins" ]]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
