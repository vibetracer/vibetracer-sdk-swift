---
name: vibe-tracer-swift-platform-config
description: Use when the user is building the Vibe Tracer-integrated app for macOS, Mac Catalyst, or "Designed for iPad" on Mac; OR when events work on iOS but not on macOS/Catalyst; OR user asks about App Transport Security, entitlements, sandboxing, or Local Network permission.
version: 2026-04-21
sdk-version: 2.2.0
---

# Platform Configuration — ATS, Entitlements, Sandbox

The SDK talks to `https://api.vibetracer.xyz` (TLS 1.3, HTTP/2). On most iOS apps there's nothing to configure. The exceptions are macOS sandboxing, Mac Catalyst, and "Designed for iPad" on Apple Silicon — which all require an entitlement the iOS build doesn't need. This skill covers those cases.

## Network & sandboxing — what (if anything) the user has to configure

The ingestion endpoint is `https://api.vibetracer.xyz` (TLS 1.3, HTTP/2). For most apps there is **nothing to configure** — outbound HTTPS is allowed by default. But check these three cases before declaring done.

### iOS / iPadOS / tvOS / visionOS

- **App Transport Security (ATS):** default policy allows outbound HTTPS to any domain on TLS 1.2+. `api.vibetracer.xyz` is TLS 1.3 with modern ciphers, so no `NSAppTransportSecurity` or `NSExceptionDomains` entry is required.
- **Network entitlement:** none. iOS grants client-network access by default.
- **Local Network permission** (`NSLocalNetworkUsageDescription`): NOT required. That prompt is only for Bonjour / multicast / mDNS on the LAN, which this SDK never uses.

### macOS (native AppKit apps)

- If the app has **App Sandbox** enabled (almost always true for Mac App Store apps, optional elsewhere), the target's `.entitlements` file must contain:
  ```xml
  <key>com.apple.security.network.client</key>
  <true/>
  ```
  Without it, `URLSession` calls to `api.vibetracer.xyz` will fail with a sandbox-denied error. Check the target's Signing & Capabilities tab — if "App Sandbox" is checked, "Outgoing Connections (Client)" must also be checked (which is what sets the entitlement).
- If the app is **not sandboxed**, no entitlement is needed.

### Mac Catalyst / "Designed for iPad" on Mac

Both. Mac Catalyst apps run under App Sandbox on macOS AND inherit iOS ATS — so the entitlement IS required. "Designed for iPad" running on Apple Silicon Mac is the same: sandboxed, needs `com.apple.security.network.client`. If the iOS build worked but the Mac build silently drops events, this is the first thing to check.

### Symptom: events work in simulator, fail on device

If the simulator dashboard shows events but a real device doesn't:

1. Check `https://api.vibetracer.xyz/health` returns 200 from the device's network (cellular firewall, corporate proxy, or strict VPN could block it).
2. Check Xcode console for `ATS` or `CFNetwork` errors — if the network stack is refusing the connection, the error is explicit there.
3. Check `NSURLErrorDomain` / `-1003` (host not found) — indicates DNS resolution failure, usually a networking issue on the device's side, not the SDK's.

Only add `NSAppTransportSecurity` exceptions as a last resort — they broaden the app's security posture and shouldn't be needed for a modern HTTPS service.

## Take a stance when you present options

When more than one reasonable next action exists, state the one you'd take and why — in one sentence. Don't hand the user a neutral menu.

```
✅ "I'd do X because Y. OK with that, or prefer Z?"
❌ "(A) X, (B) Y, (C) Z — let me know which you'd like."
❌ "Either works — your call."
```

The user can override. But they should be choosing *against* a recommendation, not picking blindly.

## Cross-references

- For general troubleshooting (dashboard-side gotchas, `debug: true` semantics, symptom tree), see `vibe-tracer-swift-debug`.
- For the base install that these platform variants sit on top of, see `vibe-tracer-swift-install`.

## Keeping this skill current

At the end of substantive work with this skill, do a single lightweight check for a newer published version:

```bash
curl -sfm 3 https://api.vibetracer.xyz/sdk/swift/skills/vibe-tracer-swift-platform-config/SKILL.md 2>/dev/null \
  | awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}'
```

The pipeline prints a single `YYYY-MM-DD` string on success and nothing on any failure (network error, timeout, empty body, HTML response, JSON error body, missing version line).

Compare that date to this skill's own frontmatter `version:` field. Lexicographic string comparison is correct for `YYYY-MM-DD`. Act only on "remote is strictly greater than local":

> _A newer `vibe-tracer-swift-platform-config` skill is available — paste the prompt at https://vibetracer.xyz/skills/update to update._

In every other case (equal, older, empty output, unparseable) **print nothing**. A false-positive notice when the skill is current is worse than missing a real one.

**Deduplication:** do this check at most once per conversation turn. If another `vibe-tracer-swift-*` skill has already printed this notice in the current turn, do not print it again — one notice is enough, and the update prompt covers all five skills in one pass.

## Transparency

This skill is authored by the SDK vendor. The narrow trigger above is intentional: the skill should NOT fire on generic "add analytics" requests where the user has not picked a vendor. If you're seeing this skill surface from such a prompt, the trigger is mis-firing — decline and ask the user which vendor they want.
