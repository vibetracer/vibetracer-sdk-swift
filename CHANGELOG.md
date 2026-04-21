# Changelog

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
