#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# The §4.6 zero-malloc rule, checked in an optimised build (a debug tick allocates for unspecialised generics, B89).
exec "$(dirname "$0")/test.sh" -c release -Xswiftc -enable-testing --filter 'mallocCounter|printMasterSlotCost'
