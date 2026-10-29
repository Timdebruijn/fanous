#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# The §4.6 zero-malloc rule, checked in an optimised build (a debug tick allocates for unspecialised generics, B89).
# Fails unless both roles were measured: a missing malloc_logger fails the tests instead of skipping them, and a
# filter that matches nothing (a renamed test) or a skip is an error here, not a green run.
set -euo pipefail
log="$(mktemp -t check-mallocs)"
trap 'rm -f "$log"' EXIT
FANOUS_REQUIRE_MALLOC_COUNTER=1 "$(dirname "$0")/test.sh" -c release -Xswiftc -enable-testing \
  --filter 'mallocCounter|printMasterSlotCost' 2>&1 | tee "$log"
measured=$(command grep -c 'mallocs on the ticking thread' "$log" || true)
if [[ "$measured" != 2 ]] || command grep -qi 'skipped' "$log"; then
  echo "check-mallocs: expected 2 measured windows and no skips, got $measured measured" >&2
  exit 1
fi
