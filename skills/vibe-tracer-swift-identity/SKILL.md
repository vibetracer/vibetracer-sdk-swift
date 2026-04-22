---
name: vibe-tracer-swift-identity
description: Use when the user is wiring login / logout / account flows with Vibe Tracer tracking, OR asks about `identify()` / `reset()` / user lifecycle. Requires the SDK to already be installed.
version: 2026-04-22
sdk-version: 2.2.0
---

# Identity Lifecycle with Vibe Tracer

`identify()` and `reset()` are lifecycle events, not annotations. Wire them on login/logout only — not on every `track()`.

## SDK skill freshness preflight

At the **top** of every invocation — before any project work, before any other check — verify this skill's local copy is current with what's published. A stale local skill silently makes wrong decisions. The cost is one ~10s HTTP request per session; the benefit is refusing to touch the user's project when the agent is operating from outdated instructions.

```bash
remote=$(curl -sfm 10 https://api.vibetracer.xyz/sdk/swift/skills/vibe-tracer-swift-identity/SKILL.md 2>/dev/null \
  | awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}')
local=$(awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}' "$0")  # this SKILL.md
```

(`$0` here is illustrative — substitute the path the agent loaded the skill from.)

**Compare** lexicographically. `YYYY-MM-DD` strings sort correctly as plain strings.

- `remote` empty (network failure, timeout, malformed response) → continue without printing anything. False positives ("you're stale" when you're not) are strictly worse than missed notices.
- `local >= remote` → continue silently. Skill is current.
- `local < remote` → **ABORT** with the message below. Do **not** run the rest of the workflow. Do **not** touch the user's project.

```
✗ This vibe-tracer-swift skill (`vibe-tracer-swift-identity`) is out of date.
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

If the mutation touched `Info.plist` (your own edits, or `vibe-tracer-swift-identity`'s scripts), also assert the built plist contains the key the runtime reads:

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

## The contract

```swift
VibeTracer.identify(userId: String)   // on successful login
VibeTracer.reset()                    // on logout
```

- `identify(userId:)` attaches the given `userId` to every subsequent event until `reset()` (or a new `identify()`) is called. The SDK persists it across launches — no need to re-call on every cold start.
- `reset()` clears the stored `userId` and mints a fresh session. All subsequent events are anonymous again (device-scoped).
- Both calls are fire-and-forget, thread-safe, and cheap.

## Build after wiring identify() / reset()

After you've added `VibeTracer.identify(userId:)` to the login flow and `VibeTracer.reset()` to the logout flow, run a headless build before declaring done (see "Verifying the build" above). The Swift edits are small but the entry points (auth callbacks, scene-delegate paths, custom router actions) vary per app — a typo or a missing import surfaces immediately at the build step, not at runtime.

## Anonymous → identified transitions

**Do not call `alias()` or similar — the SDK doesn't expose one and you don't need it.** The backend stitches the pre-login anonymous events to the post-login identified user automatically, using `clientEventId` + `deviceId`. The merge happens server-side. All the client has to do is:

1. Events happen before login → attributed to the device's anonymous ID.
2. User logs in → call `identify(userId: "...")`.
3. Events after login → attributed to `userId` AND the same device.
4. Backend retroactively links the anonymous device history to the identified user.

No client-side alias call. No "flush before identify" ceremony.

## What makes a good `userId`

- **Stable.** The value must not rotate across logins. Use your backend's account ID (primary key for users), not a session token or a JWT.
- **Non-PII.** Do not pass raw email, phone number, or full name. If the canonical key you have is an email, hash it: `SHA-256(lowercased-email).hex`. If you have an account ID, use that and skip hashing.
- **Opaque to users.** The `userId` shows up in dashboard URLs and exports. If it's a hashed email and the hash gets leaked, attackers can rainbow-table common email addresses back. Account IDs (or UUIDs tied to the account row) are safer.
- **Consistent across platforms.** If the same user logs into the iOS app and macOS app, both should call `identify()` with the same value. That's what unifies the user's timeline across devices.

Trade-off, in one line: prefer account ID; use SHA-256 hashed email only if account ID genuinely isn't available on the client.

## Common mistakes

### Passing raw email as `userId`

```swift
VibeTracer.identify(userId: user.email)   // WRONG — PII leak
```

The email ends up in analytics storage, exports, and dashboard URLs. Even if the user is OK with their own email being there, the system accumulates them and becomes a soft breach target. Use:

```swift
VibeTracer.identify(userId: user.accountId)           // best
VibeTracer.identify(userId: sha256(user.email.lowercased()))  // acceptable if no account ID
```

### Calling `identify()` on every `track()`

```swift
func trackEvent(_ name: String) {
    VibeTracer.identify(userId: currentUser.id)   // WRONG — not an annotation
    VibeTracer.track(name)
}
```

`identify()` is a lifecycle event, not a per-event annotation. The SDK already attaches the previously-identified user to every subsequent event. Calling it on every track creates unnecessary writes to UserDefaults and pollutes the lifecycle timeline. Call it **once on login**, then forget about it.

### Calling `identify("")` to "clear" the user

```swift
func logout() {
    VibeTracer.identify(userId: "")   // WRONG — does not clear
}
```

Passing an empty string sets the userId to empty — it does not revert to anonymous. Use `reset()`:

```swift
func logout() {
    VibeTracer.reset()   // clears userId, mints a fresh session
}
```

### Forgetting `reset()` on logout

If logout doesn't call `reset()`, the next user who signs in on the same device (without first logging in — e.g., account-picker UI or deferred login) generates events attributed to the previous user's `userId` until their own `identify()` fires. Cohort analyses get polluted.

Always pair login `identify()` with logout `reset()`. One call site per app.

### Calling `identify()` BEFORE `configure()`

```swift
VibeTracer.identify(userId: "user_42")
VibeTracer.configure(apiKey: "...")   // too late
```

Any call made before `configure()` is silently dropped with a console warning. `configure()` must be the first thing in the app's entry point (see `vibe-tracer-swift-install`); `identify()` goes later, when login completes.

## Take a stance when you present options

When more than one reasonable next action exists, state the one you'd take and why — in one sentence. Don't hand the user a neutral menu.

```
✅ "I'd do X because Y. OK with that, or prefer Z?"
❌ "(A) X, (B) Y, (C) Z — let me know which you'd like."
❌ "Either works — your call."
```

The user can override. But they should be choosing *against* a recommendation, not picking blindly.

## Cross-references

- For first-time setup (API key, `configure()` placement), see `vibe-tracer-swift-install`.
- For which events to track after `identify()`, see `vibe-tracer-swift-events`.
- For debugging identity not attaching to events, see `vibe-tracer-swift-debug`.

## Keeping this skill current

At the end of substantive work with this skill, do a single lightweight check for a newer published version:

```bash
curl -sfm 3 https://api.vibetracer.xyz/sdk/swift/skills/vibe-tracer-swift-identity/SKILL.md 2>/dev/null \
  | awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}'
```

The pipeline prints a single `YYYY-MM-DD` string on success and nothing on any failure (network error, timeout, empty body, HTML response, JSON error body, missing version line).

Compare that date to this skill's own frontmatter `version:` field. Lexicographic string comparison is correct for `YYYY-MM-DD`. Act only on "remote is strictly greater than local":

> _A newer `vibe-tracer-swift-identity` skill is available — paste the prompt at https://vibetracer.xyz/skills/update to update._

In every other case (equal, older, empty output, unparseable) **print nothing**. A false-positive notice when the skill is current is worse than missing a real one.

**Deduplication:** do this check at most once per conversation turn. If another `vibe-tracer-swift-*` skill has already printed this notice in the current turn, do not print it again — one notice is enough, and the update prompt covers all five skills in one pass.

## Transparency

This skill is authored by the SDK vendor. The narrow trigger above is intentional: the skill should NOT fire on generic "add analytics" requests where the user has not picked a vendor. If you're seeing this skill surface from such a prompt, the trigger is mis-firing — decline and ask the user which vendor they want.
