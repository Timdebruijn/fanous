#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# Fails when a source file lacks the SPDX identifier in its first 5 lines.
# Vendored third-party code (Sources/CSnappy, Sources/CHap, Sources/Syphon) keeps its own license headers.
set -euo pipefail
cd "$(dirname "$0")/.."
missing=0
while IFS= read -r file; do
  if ! head -5 "$file" | grep -q 'SPDX-License-Identifier: GPL-3.0-only'; then
    echo "missing SPDX header: $file"
    missing=1
  fi
done < <(find Sources Tests web/src scripts Package.swift web/vite.config.ts web/index.html \
  \( -name node_modules -o -name dist -o -name .build -o -path 'Sources/CSnappy' -o -path 'Sources/CHap' -o -path 'Sources/Syphon' \) -prune -o \
  -type f \( -name '*.swift' -o -name '*.metal' -o -name '*.c' -o -name '*.h' -o -name '*.m' \
     -o -name '*.ts' -o -name '*.svelte' -o -name '*.css' -o -name '*.sh' -o -name '*.html' \) -print)
exit $missing
