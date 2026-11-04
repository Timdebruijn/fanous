#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# Kept for the docs and benchmark records that name it: no argument runs `scripts/bench.sh phase3`, `drift` the soak.
exec "$(dirname "$0")/bench.sh" "${1:-phase3}"
