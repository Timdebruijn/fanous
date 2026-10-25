# ADR-0016: Plugin boundary: C ABI, dynamically loaded (design only in v1)

Status: Accepted · 2026-10-22

## Context
NDI and DeckLink SDKs are proprietary and must never be vendored or linked
into the GPL server. The plugin exception (`docs/licensing/PLUGIN-EXCEPTION.md`)
needs a precisely defined interface to refer to.

## Decision
- `FanousPluginAPI` is a C header (`fanous_plugin.h`) plus a Swift shim.
  A plugin is a `.dylib` in `~/Library/Application Support/Fanous/Plugins/`
  exporting `fanous_plugin_entry(const FanousHostAPI*) -> const FanousPluginAPI*`.
- Capabilities: **source** (delivers IOSurface-backed frames with pts into a
  ring the host owns), **sink** (receives completed canvas IOSurfaces),
  **control** (later: serial/other protocols). Versioned structs with size
  fields; the host refuses mismatched ABI versions.
- Plugins run in-process in v1's design (out-of-process isolation is a
  later option via XPC if a plugin proves unstable).
- v1 ships the header, the loader stub and the exception text; no plugin.

## Consequences
+ The GPL boundary is a documented, stable C interface.
− In-process plugins can crash the engine; accepted for v1 design, revisit
  before the first plugin ships.
