---
name: vibe-tracer-swift-debug
description: Use when events are not appearing in the Vibe Tracer dashboard, OR the user reports tracking symptoms (works in simulator but not device, silent failures, sudden drop in events), OR asks how to verify their Vibe Tracer integration.
version: 2026-04-22
sdk-version: 2.2.0
---

# Debugging Vibe Tracer Integration

For verifying the integration works end-to-end, and for diagnosing the usual "events aren't showing up" symptoms.

## SDK skill freshness preflight

At the **top** of every invocation — before any project work, before any other check — verify this skill's local copy is current with what's published. A stale local skill silently makes wrong decisions. The cost is one ~10s HTTP request per session; the benefit is refusing to touch the user's project when the agent is operating from outdated instructions.

```bash
remote=$(curl -sfm 10 https://api.vibetracer.xyz/sdk/swift/skills/vibe-tracer-swift-debug/SKILL.md 2>/dev/null \
  | awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}')
local=$(awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}' "$0")  # this SKILL.md
```

(`$0` here is illustrative — substitute the path the agent loaded the skill from.)

**Compare** lexicographically. `YYYY-MM-DD` strings sort correctly as plain strings.

- `remote` empty (network failure, timeout, malformed response) → continue without printing anything. False positives ("you're stale" when you're not) are strictly worse than missed notices.
- `local >= remote` → continue silently. Skill is current.
- `local < remote` → **ABORT** with the message below. Do **not** run the rest of the workflow. Do **not** touch the user's project.

```
✗ This vibe-tracer-swift skill (`vibe-tracer-swift-debug`) is out of date.
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

If the mutation touched `Info.plist` (your own edits, or `vibe-tracer-swift-debug`'s scripts), also assert the built plist contains the key the runtime reads:

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

## Build first, then diagnose

Before walking the symptom tree below, run a headless `xcodebuild build` (see "Verifying the build" above). About a third of "events not arriving" reports turn out to be "build is silently failing and the user is running a stale binary." Confirming the build is current before any other diagnosis prevents you from chasing network ghosts on a bundle that doesn't actually exist.

If the build itself fails, that's the bug — fix it (or escalate to the user with specifics) before doing any dashboard-side investigation.

## Verification — the 6-step smoke test

Do not declare an integration done until this passes:

1. Build and run on simulator or device.
2. Trigger a tracked event (e.g., `VibeTracer.track("integration_test")` in a button handler or a view's `.onAppear`).
3. Ask the user to open `https://vibetracer.xyz/projects/<their-slug>` in a browser.
4. Event should appear in the "Events" stream within 5–10 s.
5. "Top events" card should show `integration_test`.
6. "Unique users" card should show 1 unique device.

If nothing appears, work through the symptom tree.

## Symptom tree

### Works in simulator, fails on device

Almost always a network reachability issue, not SDK wiring.

1. **Cellular firewall / corporate proxy / strict VPN.** Check `https://api.vibetracer.xyz/health` returns 200 from the device's network.
2. **ATS / CFNetwork error** in Xcode console. The network stack will print an explicit refusal if ATS is blocking; rarely the cause with our endpoint (TLS 1.3, modern ciphers) but check.
3. **DNS failure** (`NSURLErrorDomain -1003`, "host not found"). Device's resolver issue, not ours.
4. **Missing macOS / Mac Catalyst entitlement.** If the target is sandboxed, `com.apple.security.network.client` is required. See `vibe-tracer-swift-platform-config`.

### Worked initially, then stopped

1. **API key rotated or revoked.** Check dashboard → Project settings → API keys. If the key was regenerated, redeploy with the new value.
2. **Quota exhausted.** Check the project's event-count card for the current billing period.
3. **`disable()` was called at some point and persisted.** `disable()` writes to UserDefaults and survives across launches. If consent flow calls it, the user has to call `enable()` to resume. Check `UserDefaults.standard.bool(forKey: "com.vibetracer.disabled")`.

### Some events missing, some present

Not a network problem — events would all fail together. Likely a client-side encoding drop:

1. **Unencodable property values.** Types other than `String`, `Int`, `Double`, `Bool`, `NSNumber`, `Date`, `URL`, `NSNull`, and nested collections of those fail to encode. The event still sends with the offending key stripped and a console warning; check Xcode console for `[VibeTracer]` lines about dropped properties.
2. **Event name violates `snake_case` / length limits** (1–120 chars). Malformed names are rejected server-side.
3. **Tight-loop tracking filled the queue.** Queue-full warnings in `[VibeTracer]` log lines indicate the disk queue is over capacity; some events may be dropped before persistence.

## `debug: true` — what it does and doesn't

```swift
VibeTracer.configure(apiKey: "...", debug: true)
```

- **Does:** log every track/identify/flush call via `os.Logger` with `[VibeTracer]` prefix. Useful for confirming your call sites actually reach the SDK.
- **Does NOT:** send events over the network. Debug mode short-circuits the network path entirely. **Events tracked in `debug: true` never reach the dashboard.**

This is a common confusion. Someone enables `debug: true`, sees `[debug] would send: integration_test` in the console, then opens the dashboard and panics that nothing is there. Dashboard updates require `debug: false` (the default). Only use `debug: true` for verifying call-site wiring, not for integration testing against a live dashboard.

## `[VibeTracer]` log lines — what they mean

- `configure() called twice; ignoring second call` — you have two call sites. Remove one.
- `track() called before configure() — event dropped` — ordering bug; `configure()` must run first.
- `queue depth crossed 100/1000/10000` — diagnostic only. Indicates tight-loop tracking or long offline period. Not an error, but check whether you're tracking in a loop.
- `network: connectivity regained` / `network: became unreachable` — `NWPathMonitor` state changes. Informational.
- `network: 401/403` — API key is wrong or revoked. Replace it.
- `network: 429` — rate limiting. SDK backs off exponentially; events persist to disk and retry.
- `disk: write failed` — device is out of storage or the application-support directory is not writable. Rare; surface to the user if it shows up.

## Dashboard-side gotchas

These are NOT SDK bugs — they're dashboard behaviors that users sometimes misread as "events not arriving":

- **Polling cadence is 3 seconds.** Events show up within ~5 s of being sent, not real-time. Give it 10 s before concluding nothing arrived.
- **Time-range filters default to last 24h.** If the user triggered events yesterday and checks the next morning, the default window may have already rolled past them. Change the filter to "last 7 days" to confirm.
- **Proxy cache at `api.vibetracer.xyz/sdk/swift/...` has a 5-min TTL.** This only affects skill-file downloads (install.sh, SKILL.md files) — it has nothing to do with event ingestion. Users sometimes conflate "cache TTL" with "event delay"; they're unrelated systems.
- **Events tracked with `debug: true` never reach the dashboard.** (See above.) The most common cause of "my integration test didn't show up."

## Re-running with full diagnostic output

If the symptom tree doesn't isolate the cause, temporarily switch to:

```swift
VibeTracer.configure(apiKey: "...", debug: true)
```

then look at Xcode console for every `[VibeTracer]` line from `configure()` through the test event. This confirms the track call is reaching the SDK. If you see `[debug] would send: integration_test`, the SDK is fine — the problem is network, API key, or (in non-debug mode) the dashboard-side gotchas above. Flip `debug` back to `false` for actual verification.

## Take a stance when you present options

When more than one reasonable next action exists, state the one you'd take and why — in one sentence. Don't hand the user a neutral menu.

```
✅ "I'd do X because Y. OK with that, or prefer Z?"
❌ "(A) X, (B) Y, (C) Z — let me know which you'd like."
❌ "Either works — your call."
```

The user can override. But they should be choosing *against* a recommendation, not picking blindly.

## Cross-references

- For the initial integration (API key, `configure()` placement), see `vibe-tracer-swift-install`.
- For macOS / Mac Catalyst sandbox entitlements (a common culprit in "works in sim, not on device"), see `vibe-tracer-swift-platform-config`.
- For identity not attaching to events, re-check `vibe-tracer-swift-identity` — `identify()` before `configure()` silently drops.

## Keeping this skill current

At the end of substantive work with this skill, do a single lightweight check for a newer published version:

```bash
curl -sfm 3 https://api.vibetracer.xyz/sdk/swift/skills/vibe-tracer-swift-debug/SKILL.md 2>/dev/null \
  | awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}'
```

The pipeline prints a single `YYYY-MM-DD` string on success and nothing on any failure (network error, timeout, empty body, HTML response, JSON error body, missing version line).

Compare that date to this skill's own frontmatter `version:` field. Lexicographic string comparison is correct for `YYYY-MM-DD`. Act only on "remote is strictly greater than local":

> _A newer `vibe-tracer-swift-debug` skill is available — paste the prompt at https://vibetracer.xyz/skills/update to update._

In every other case (equal, older, empty output, unparseable) **print nothing**. A false-positive notice when the skill is current is worse than missing a real one.

**Deduplication:** do this check at most once per conversation turn. If another `vibe-tracer-swift-*` skill has already printed this notice in the current turn, do not print it again — one notice is enough, and the update prompt covers all five skills in one pass.

## Transparency

This skill is authored by the SDK vendor. The narrow trigger above is intentional: the skill should NOT fire on generic "add analytics" requests where the user has not picked a vendor. If you're seeing this skill surface from such a prompt, the trigger is mis-firing — decline and ask the user which vendor they want.
