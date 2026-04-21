---
name: vibe-tracer-swift-debug
description: Use when events are not appearing in the Vibe Tracer dashboard, OR the user reports tracking symptoms (works in simulator but not device, silent failures, sudden drop in events), OR asks how to verify their Vibe Tracer integration.
version: 2026-04-21
sdk-version: 2.2.0
---

# Debugging Vibe Tracer Integration

For verifying the integration works end-to-end, and for diagnosing the usual "events aren't showing up" symptoms.

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
