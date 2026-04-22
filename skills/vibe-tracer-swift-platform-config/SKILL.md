---
name: vibe-tracer-swift-platform-config
description: Use when the user is building the Vibe Tracer-integrated app for macOS, Mac Catalyst, or "Designed for iPad" on Mac; OR when events work on iOS but not on macOS/Catalyst; OR user asks about App Transport Security, entitlements, sandboxing, or Local Network permission.
version: 2026-04-22
sdk-version: 2.2.0
---

# Platform Configuration — ATS, Entitlements, Sandbox

The SDK talks to `https://api.vibetracer.xyz` (TLS 1.3, HTTP/2). On most iOS apps there's nothing to configure. The exceptions are macOS sandboxing, Mac Catalyst, and "Designed for iPad" on Apple Silicon — which all require an entitlement the iOS build doesn't need. This skill covers those cases.

## SDK skill freshness preflight

At the **top** of every invocation — before any project work, before any other check — verify this skill's local copy is current with what's published. A stale local skill silently makes wrong decisions. The cost is one ~10s HTTP request per session; the benefit is refusing to touch the user's project when the agent is operating from outdated instructions.

```bash
remote=$(curl -sfm 10 https://api.vibetracer.xyz/sdk/swift/skills/vibe-tracer-swift-platform-config/SKILL.md 2>/dev/null \
  | awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}')
local=$(awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}' "$0")  # this SKILL.md
```

(`$0` here is illustrative — substitute the path the agent loaded the skill from.)

**Compare** lexicographically. `YYYY-MM-DD` strings sort correctly as plain strings.

- `remote` empty (network failure, timeout, malformed response) → continue without printing anything. False positives ("you're stale" when you're not) are strictly worse than missed notices.
- `local >= remote` → continue silently. Skill is current.
- `local < remote` → **ABORT** with the message below. Do **not** run the rest of the workflow. Do **not** touch the user's project.

```
✗ This vibe-tracer-swift skill (`vibe-tracer-swift-platform-config`) is out of date.
  Local:  $local
  Remote: $remote
  Refresh first, then re-run the same command:

    curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | bash

  This refresh updates ALL five vibe-tracer-swift-* skills in one shot, so any
  sibling skill the workflow needs will also be current after.
```

**Why this is a hard abort, not a notice:**

The skill writes to the user's `.xcodeproj`, provisions Info.plist files, edits Swift sources. If the local instructions are stale, those edits could be wrong in ways that surface only at runtime (e.g. silently dropped events). "Better fail loud at preflight than break the project" is the core invariant.

**Why this check does NOT dedup across sibling skills:**

Each `vibe-tracer-swift-*` skill checks its own freshness independently. If one skill is current and another is stale, only the stale one aborts. Cross-skill dedup would silence the abort that matters; "no notice from any skill" would look like "everything is fresh," which is exactly the failure mode this preflight exists to prevent.

(The end-of-turn `## Keeping this skill current` notice still runs, on its own dedup, as a backstop after a successful workflow. That notice is informational; this preflight is gating.)

## Before anything else — SDK version check

This skill shares a drift gate with every other `vibe-tracer-swift-*` skill. Run it at the top of every invocation — the gate is cheap (idempotent, ~100ms when not behind) and prevents you from advising on symbols the user's build does not have.

1. Locate the user's `.xcodeproj` (ask if none obvious, multiple, or ambiguous).
2. Run the script colocated with the install skill:
   ```bash
   <skills-root>/vibe-tracer-swift-install/scripts/install-or-upgrade.sh <project-root> <target>
   ```
   `<skills-root>` is the parent of this SKILL.md's containing directory — e.g. `~/.claude/skills`, `~/.cursor/rules`, `~/.codex/skills`, depending on the agent tool.
3. If it prints `✓ Already on …` (or any other no-op message), continue to this skill's workflow.
4. Otherwise it either bumped the pin or remediated a broken install. Read the script's output:
   - **Bump path** with CHANGELOG delta: if every breaking section is `None.`, tell the user "bumped VibeTracer to `<current>`, no migrations needed" and continue. If any is not `None.`, walk the user through the call-site edits **before** continuing.
   - **Broken-state remediation path**: the script printed `→ Detected the silent-key-drop install bug …`. Run the build verification (see "Verifying the build" below) to confirm the fix took. Then continue to this skill's workflow.

After any path that mutated the project, run a headless build (see "Verifying the build" below) before continuing.

This is a gate, not a notice. If the user's project is pinned to 2.0.1 and asks about `trackDebounced` (added in 2.1.0), there is no truthful answer without bumping first.

## Verifying the build

Run a headless `xcodebuild build` after every mutation that could affect compilation or the built bundle: any `project.pbxproj` change, any `Info.plist` change, any `.entitlements` change, any `.swift` source you wrote or rewrote. The cost (10–90s per build, incremental after the first) is the price of catching a class of failures that otherwise compounds across steps.

**Choose a destination once per session:**

- If the user has named a preferred simulator anywhere in the conversation, use it.
- Otherwise ask, once at the top of the workflow, in one line: *"Which simulator do you usually test on? (Or say 'any' and I'll pick the first available iOS sim.)"* — reuse the answer for the rest of the session.
- For headless verification only (i.e. you are not launching the app for the user to interact with), `-destination 'generic/platform=iOS Simulator'` is acceptable and avoids needing a specific UDID. Default to this when the user is not present to ask.

**Run the build:**

```bash
xcodebuild build \
  -project <project>.xcodeproj \
  -scheme <scheme> \
  -destination '<destination>' \
  -derivedDataPath "$(mktemp -d)/vtr-verify"
```

- Pick `<scheme>` via `xcodebuild -list -project <project>.xcodeproj` and take the first shared scheme. If no shared scheme exists, ask the user which one to use — don't guess.
- The `-derivedDataPath` argument MUST point outside the user's project tree. `mktemp -d` puts the scratch directory in the OS temp area, which is reaped automatically. Do NOT write to the project's own `build/`, `DerivedData/`, or any sibling directory the user might be tracking.

**On success — check the runtime, not just the compile:**

If the mutation touched `Info.plist` (your own edits, or `vibe-tracer-swift-platform-config`'s scripts), also assert the built plist contains the key the runtime reads:

```bash
app=$(ls -d "$DERIVED/Build/Products/Debug-iphonesimulator"/*.app | head -1)
key=$(/usr/libexec/PlistBuddy -c "Print :VibeTracerApiKey" "$app/Info.plist" 2>/dev/null)
```

- `$key` empty → the key isn't in the built plist. Most likely cause: `INFOPLIST_FILE` not wired into the configs, or `GENERATE_INFOPLIST_FILE = NO` without a complete file-based plist. Re-run `install-or-upgrade.sh` and re-build.
- `$key` literally `$(VIBETRACER_API_KEY)` → the xcconfig substitution didn't happen. The Secrets.xcconfig file isn't wired as the configs' `baseConfigurationReference`. Re-run `install-or-upgrade.sh`.
- `$key` starts with `vtr_live_` → ✓ pass.

**On failure — diagnose, then escalate (NEVER auto-rollback):**

1. **Read the error.** The first non-note line in the build log usually localizes the cause. Compile errors → check imports, type signatures, missing symbols (often an SDK-version mismatch — see this skill's "SDK skill freshness preflight" and Step 0). Linker errors → check the package product is linked. Plist errors → check the file shape and the `INFOPLIST_FILE` setting.
2. **Attempt a fix in place.** Re-edit the file you just wrote. Most failures are tractable in 1–2 attempts.
3. **DO NOT run any destructive git command** — no `git checkout`, no `git stash`, no `git reset`, no `git clean` — to "undo" your changes. Those can wipe co-located user work the agent didn't touch. The user's audience for this SDK includes non-engineers; a `git checkout` "to clean up" can vaporize hours of design work irreversibly.
4. **If the fix doesn't take in 1–2 attempts, escalate to the user with specifics.** Name the file you wrote, paste the exact error line, state your best theory of the cause, and ask one precise question. Vague asks ("could you check the project?") waste their time. Precise asks ("I added `import VibeTracer` to `DateAdjustScreen.swift:10`, but the compiler reports `No such module 'VibeTracer'`. Could you confirm the package shows up under Package Dependencies in the Xcode sidebar?") get a useful answer.

This is a hard rule for this skill. The agent diagnoses; the user inspects; nothing automatically rewrites or reverts working-tree state.

## Build after every entitlement / Info.plist / project setting change

The mutations in this skill (entitlement file edits, Info.plist platform keys, target capability flags) are easy to typo or to apply to the wrong configuration. Run a headless build after each one (see "Verifying the build" above). For an entitlement change specifically, also assert it landed in the built bundle via `codesign -d --entitlements :- <built>.app` — a broken entitlement file silently disables the capability rather than failing the build.

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
