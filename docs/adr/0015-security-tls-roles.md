# ADR-0015: TLS everywhere with a self-generated certificate; role passwords, no accounts

Status: Accepted · 2026-10-22

## Context
The brief requires TLS and roles. WebCodecs needs a secure context, and
WebKit's treatment of `http://localhost` as secure is inconsistent (verified
2026-10-22), so even the local shell must use HTTPS. macOS has no public API
to generate an X.509 certificate. The owner does not want user accounts;
the server runs on trusted networks; a password on the web UI is welcome.

## Decision
- One HTTPS/WSS listener. The engine generates a self-signed ECDSA P-256
  certificate on first run with an own minimal DER/X.509 writer over
  `SecKey` (no dependency), stores the identity in the login keychain, shows
  the fingerprint in the UI; users may import their own PEM/PKCS#12.
- The shell pins the fingerprint; browsers accept the warning once. A CA
  profile for iPads is a later convenience.
- Roles monitor/operator/programmer with **optional** per-role passwords
  (PBKDF2-HMAC-SHA256 via CommonCrypto); no passwords after install, with a
  visible "web UI open" warning until the programmer password is set. The
  local shell authenticates with a per-install token file (0600).
- Session cookie (HttpOnly, SameSite=Strict) reused for the WebSocket
  upgrade; login rate limiting.

## Consequences
+ Uniform transport, preview works locally and remotely, no account
  management.
− First-run keychain interaction from a LaunchAgent is a Phase 0 spike (R6);
  fallback is a PKCS#12 file in Application Support loaded into an in-memory
  keychain.
