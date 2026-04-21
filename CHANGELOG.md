# Changelog

## [2.0.0] - 2026-04-21

### Breaking — docs distribution only (no SDK API changes)

- Root `SKILL.md` removed. Skills now live under `skills/vibe-tracer-swift-*/SKILL.md`
  and install as a pack. The old one-liner install (`curl ... skill.md > SKILL.md`)
  no longer works — no legacy URL is preserved.
- New install mechanism: a single shell script that installs all skills into the
  user's agent-tool directory (Claude Code, Cursor, Windsurf, or a custom target).
  See README for the new one-liner.

### Changed

- SKILL.md split into five focused skills, each with a narrow trigger and
  discipline-enforcing content (modeled on the superpowers pattern):
  - `vibe-tracer-swift-install` — first-time integration
  - `vibe-tracer-swift-events` — what to track (business advisory)
  - `vibe-tracer-swift-identity` — login/logout patterns
  - `vibe-tracer-swift-debug` — troubleshooting
  - `vibe-tracer-swift-platform-config` — ATS, macOS sandbox, Mac Catalyst

### No SDK code changes

The Swift package itself is identical to v1.1.3. Only documentation distribution
changed. App builds against `from: "1.1.0"` resolve to 2.0.0 automatically.

## [1.1.3] - 2026-04-21

### Docs

- `SKILL.md`: added "Network & sandboxing" section covering the three real
  cases for outbound HTTPS to `api.vibetracer.xyz`:
  - **iOS/iPadOS/tvOS/visionOS** — nothing to configure (ATS allows modern
    TLS HTTPS by default; no entitlement; Local Network permission is NOT
    relevant — that's for Bonjour/LAN discovery only).
  - **macOS AppKit** — if App Sandbox is enabled, target needs the
    `com.apple.security.network.client` entitlement (surfaced in Xcode as
    "Outgoing Connections (Client)" under Signing & Capabilities → App
    Sandbox).
  - **Mac Catalyst / "Designed for iPad" on Mac** — sandboxed by default;
    same entitlement requirement as native macOS. First thing to check if
    iOS works but Mac silently drops events.
- Plus a "symptom: works in simulator, fails on device" debugging tree
  distinguishing cellular/proxy blocks, ATS errors, and DNS failures.

## [1.1.2] - 2026-04-21

### Docs

- `SKILL.md` substantially rewritten after external review. Changes aimed at
  making the skill an actionable instruction for Claude rather than a README
  reshaped as a skill:
  - **Narrower trigger**: fires only when the user explicitly names Vibe
    Tracer / `vibetracer-sdk-swift`, or when the package is already in
    `Package.swift` / `Podfile` and the user asks about tracking. Does NOT
    fire on generic "add analytics" asks — the skill explicitly instructs
    Claude to decline and ask which vendor the user wants.
  - **Added "When NOT to use"**: project already uses another analytics SDK;
    deployment target below 2023 OS minimums; no UI lifecycle; user has not
    named Vibe Tracer.
  - **Added "Common mistakes"**: calling `track()` before `configure()`;
    `configure()` in a View's `init`; hardcoding the API key; passing
    unencodable property types; passing raw email as `userId`; etc.
  - **Concrete API key storage patterns** (xcconfig, env var, debug-only
    hardcoded) — replaces the previous "don't hardcode" warning that
    contradicted its own inline example.
  - **Verification checklist** — Claude is instructed not to declare done
    until the dashboard shows the test event.
  - **Transparency note** acknowledging the skill is authored by the SDK
    vendor, with instructions for Claude to decline if the skill surfaced
    from a generic prompt.
  - Trimmed ~40% of marketing copy and README-duplicating SPM boilerplate
    Claude can derive from any package.

## [1.1.1] - 2026-04-21

Post-v1.1.0 self-review patch. No API-breaking changes; all fixes are internal
behavior corrections, correctness tightening, and documentation fixes.

### Fixed
- `flush()` now forces an immediate retry when the queue is in `.backoff`
  (previously it would wait briefly and return without actually flushing).
  Introduced a dedicated `QueueSignal.flushRequested` distinct from
  `.appBackgrounded` — the OS-suspension signal keeps its original semantics
  (don't cut the backoff short).
- `$session_start` is no longer emitted on every foreground activation for
  reused sessions. `SessionTracker.rollover(now:)` now atomically reports
  whether a session was newly minted, reused, or rolled over due to idle
  timeout, and `VibeTracerCore` only emits `$session_start` on actual mints.
- `track()` hot path no longer does a redundant `UserDefaults` read for the
  session id — the current session id is cached on the actor and refreshed
  only on rollover. `noteActivity()` still bumps `lastActivity` on every
  track (needed for idle-timeout accuracy).
- Lifecycle callbacks (`onActivate`, `onBackground`, `onTerminate`,
  `onBecameReachable`) now coalesce into a single `lifecycleTask` handle
  rather than spawning unbounded Tasks under rapid foreground/background
  cycling.
- `DeviceIdStore` and `UserIdStore` now declare `@unchecked Sendable` with
  a doc comment explaining why. Resolves a Swift 6 strict-concurrency
  warning (and upcoming error) caused by `UserDefaults` not declaring
  `Sendable` itself.

### Changed
- `SessionTracker` gains a `rollover(now:)` entry point that returns a
  `SessionRolloverResult` (`expired`, `currentSessionId`, `wasMinted`) —
  the single source of truth for session-identity decisions. The legacy
  `takeExpiredPriorSession()` / `startSessionIfNeeded()` methods are still
  there for backward-compat but new call sites should prefer `rollover()`.
- Extracted session-event emission into a small `SessionEmitter` helper
  so the rollover→events mapping can be unit-tested without booting the
  actor.
- Mailbox now logs a diagnostic warning when its depth crosses 100, 1000,
  or 10 000 pending signals. Diagnostic only — no backpressure applied
  (intentional: `track()` stays sync fire-and-forget by design).

### Docs
- `_waitForIdle()` doc comment corrected: it uses 500µs `Task.sleep` ticks
  (not `Task.yield`), with a 4-tick stability check and 10 s worst-case
  ceiling. Tests have a ~2 ms floor per `flush()`.
- `SKILL.md`: corrected "six symbols" → "eight symbols" (enumerated),
  removed inaccurate XCFramework claim (SDK ships as source).

## [1.1.0] - 2026-04-21

Initial public release.

### Features
- Swift Package Manager distribution + CocoaPods (secondary, legacy projects)
- Supports iOS 17 · macOS 14 · tvOS 17 · watchOS 10 · visionOS 1
- Auto-tracked lifecycle events (`$session_start`, `$session_end`) with 30-min idle rollover
- Persistent on-disk event queue with pure-FSM driven state transitions
- Exponential backoff with ±20% jitter, 60s ceiling, no kill switch on auth errors
- `NWPathMonitor`-driven early wake from backoff when connectivity returns
- `disable()` / `enable()` API for GDPR/CCPA consent flows
- Apple `PrivacyInfo.xcprivacy` manifest included (declares UserDefaults access, analytics purpose)
- Client-side `clientEventId` for idempotent retries; backend dedups
- Claude Code invocable skill file (SKILL.md) for AI-driven install
