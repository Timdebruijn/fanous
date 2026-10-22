#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# LanthornCore may import Foundation only (DESIGN.md §3, ADR-0003).
set -euo pipefail
cd "$(dirname "$0")/.."
bad=$(grep -rhoE '^\s*(@testable\s+)?import\s+[A-Za-z_]+' Sources/LanthornCore | awk '{print $NF}' | sort -u | grep -vx Foundation || true)
if [[ -n "$bad" ]]; then
  echo "LanthornCore imports non-Foundation modules:"
  echo "$bad"
  exit 1
fi
echo "LanthornCore is pure (Foundation only)"
