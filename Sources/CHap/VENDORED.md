Vendored from https://github.com/Vidvox/hap at commit d847f6bbd3be88575dd4ef33a877243780e3be76 (2024-07-25): source/hap.c, source/hap.h. License: BSD-2-Clause, see LICENSE.

## Local changes

Upstream has no fix for these (checked 2026-11-18: no commit to `source/hap.c` after `c7abb0c` of 2022-05-06, no
open pull request); each change is marked `local, B265` in a comment in `hap.c`.

- B265 (2026-11-18): bounds checks for frames from a file. `hap_read_section_header` compares by subtraction, so a
  section length of 0xFFFFFFF8 or more no longer wraps the header sum; `hap_decode_header_complex_instructions`
  refuses an empty chunk table; `hap_decode_single_texture` refuses a chunk whose offset or size reaches outside the
  frame data. Each returns `HapResult_Bad_Frame`. Valid frames decode byte for byte as before
  (`HAPFrameBoundsTests`).
