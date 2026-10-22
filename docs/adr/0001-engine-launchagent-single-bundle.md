# ADR-0001: Engine as a LaunchAgent inside one app bundle

Status: Proposed · 2026-10-22

## Context
The render engine must be headless, survive UI crashes, restart after its own
crash, and drive displays. A LaunchDaemon runs outside the GUI session and
cannot talk to the WindowServer, so it cannot own displays. The owner wants
to start the application like any app, without mandatory auto-login, and
wants one bundle, not an installer package.

## Decision
- `lanthornd` ships inside `Lanthorn.app` and is registered as a
  **LaunchAgent** with `SMAppService.agent(plistName:)` (macOS 13+). The plist
  lives in `Contents/Library/LaunchAgents/` and uses `BundleProgram`;
  `KeepAlive` and `RunAtLoad` are set.
- The shell app registers/starts the agent on launch, shows the Login Items
  approval step when macOS requires it, and otherwise only hosts the UI.
- The engine runs an `NSApplication` with `.accessory` activation policy to
  create output windows without ever being the frontmost app.
- The same binary runs in the foreground for development.
- Auto-login is documented as optional for unattended machines, not required.

## Consequences
+ UI and engine lifecycles are independent; crash restart is launchd's job.
+ No installer, no root, no daemon privileges; Developer ID + notarization
  is enough.
− The one-time "Allow in the Background" approval is a UX step we must
  explain in the UI.
− Microphone (LTC) and other TCC prompts are attributed to the agent; the
  bundle must carry the usage descriptions and be properly signed.
