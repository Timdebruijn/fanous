#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# Kept for the docs and benchmark records that name it; the matrix is `scripts/bench.sh sweep`.
exec "$(dirname "$0")/bench.sh" sweep
