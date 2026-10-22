# ADR-0003: Package layout

Status: Accepted · 2026-10-22

## Context
Protocol parsing, the parameter model and cue logic must be testable on any
Mac and in hosted CI, which has no GPU guarantees. HAP needs C code, Syphon
is Objective-C. The owner wants SwiftPM, not Xcode projects.

## Decision
- One package at the repo root. `LanthornCore` imports only Foundation (CI
  greps for other imports). `LanthornEngine` holds every Apple media/GPU
  framework. Executables: `lanthornd`, `LanthornShell`, `lanthorn-bench`.
- Vendored C/ObjC as SPM targets: `CHap` (Vidvox hap.c), `CSnappy`
  (google/snappy, C++), `Syphon` (Syphon-Framework sources), each pinned to
  a commit in `docs/licensing/DEPENDENCIES.md` and carrying its license.
- The `.app` bundle is assembled by `scripts/bundle.sh` from SPM products;
  `web/dist` is an SPM resource of `lanthornd`.
- `swift-tools-version: 6.2` (buildable with Xcode 26.x and 27.x).
- Tests use Swift Testing; XCTest only where it is the only option. On a
  machine with Command Line Tools only (no Xcode) the Swift Testing macro
  plugin is not on the compiler's default search path; `scripts/test.sh`
  adds it. Xcode toolchains and CI need nothing extra.

## Consequences
+ Core tests run everywhere; GPU tests are a separate workflow.
+ No Xcode project to maintain; one build command.
− Bundle assembly and signing are our script, not Xcode's.
