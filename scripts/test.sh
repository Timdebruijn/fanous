#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# `swift test` wrapper: Command Line Tools keep the Swift Testing macro plugin
# in a directory the compiler does not search by default; Xcode toolchains do.
set -euo pipefail
cd "$(dirname "$0")/.."
# Tests run serially: Swift Testing executes every test as a task on the cooperative pool, and
# AVAssetWriter (used by the media-writing tests) needs that pool too; a dozen tests blocking in
# finishWriting at once deadlocks the process (seen 2026-10-23). Serial takes ~10 s longer.
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$plugins" ]]; then
  exec swift test --no-parallel -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test --no-parallel "$@"
