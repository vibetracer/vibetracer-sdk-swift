# Changelog

> **Heading convention.** Semver releases (Swift package source changes) use
> `## [X.Y.Z] - YYYY-MM-DD`. Skill-pack-only releases (no SDK source change —
> just SKILL.md / scripts / docs) use `## [skill-pack-YYYY-MM-DD]`. The
> `install-or-upgrade.sh` migration parser only matches the semver shape, so
> skill-pack entries are correctly ignored when computing API migration deltas.

## [skill-pack-2026-04-22] - 2026-04-22

Skill-pack-only release. Swift package source unchanged; SPM pin stays `2.2.0`.
This release fixes a high-severity install bug and adds layered verification so
the same class of failure cannot recur silently.

### Fixed

- **`wire-xcode.rb` was silently dropping the API key.** The previous script
  set `INFOPLIST_KEY_VibeTracerApiKey = $(VIBETRACER_API_KEY)` on the target's
  build settings, expecting Xcode's auto-Info.plist generator to promote it.
  Xcode only promotes `INFOPLIST_KEY_*` for keys on Apple's recognized-keys
  allowlist (`CFBundle*`, `NSCamera*`, `UILaunchScreen_*`, etc.) — custom keys
  like `VibeTracerApiKey` are silently dropped. Result at runtime:
  `Bundle.main.object(forInfoDictionaryKey: "VibeTracerApiKey")` returned
  `nil`, `??` coalesced to `""`, `configure(apiKey: "")` had nothing to
  authenticate with, every event was dropped client-side before the network.
  Headless build succeeded; dashboard showed zero events. Hard to diagnose.

  Fix: `wire-xcode.rb` now provisions a file-based `<Target>/Info.plist`
  containing the key as the primary (only) path, sets `INFOPLIST_FILE` on
  Debug + Release, leaves `GENERATE_INFOPLIST_FILE = YES` in place so Xcode
  merges its auto-generated Apple keys on top. The stale `INFOPLIST_KEY_*`
  setting is stripped during the same run.

### Added

- **`install-or-upgrade.sh`** — single entry point for first-time install,
  in-place upgrade, broken-state remediation, and already-current short-
  circuit. Replaces the previous direct `wire-xcode.rb` invocation in the
  install skill's workflow. (Renamed from `upgrade.sh`; routes through the
  same code paths internally.)
- **Broken-state detection.** `install-or-upgrade.sh` detects projects bitten
  by the silent-key-drop bug above (pbxproj has `INFOPLIST_KEY_VibeTracerApiKey`
  but no `INFOPLIST_FILE`) and remediates automatically. Existing broken
  installs heal on the next skill invocation.
- **Agent-driven build verification** — every skill that mutates code or
  config now invokes a `## Verifying the build` discipline (canonical stanza
  duplicated across all five skills, kept in sync by
  `scripts/check-skill-sync.sh`). Verification is agent-prose, not a script,
  because xcodebuild availability and simulator preference vary per user. On
  failure: agent diagnoses, attempts a fix in place, and escalates to the
  user with specifics. **Never** runs destructive git operations
  (`git checkout / stash / reset / clean`) to "undo" agent changes.
- **SDK skill freshness preflight** — at the top of every skill invocation,
  before any project work, the agent compares the local `version:` frontmatter
  to the published one and aborts loud if local is older. Catches the class
  of failure where a stale skill makes wrong decisions silently. Replaces the
  previous end-of-turn notice as the authoritative gate; the end-of-turn
  notice stays as an informational backstop.
- **Skill-specific build callouts** in events / identity / debug / platform-
  config. Each calls out where in its workflow a build verification fires
  (events: per-screen batch; identity: post-login/logout edits; debug:
  pre-symptom-tree; platform-config: post-entitlement / post-Info.plist).

### Changed

- `INFOPLIST_FILE` patching — when a user already has `INFOPLIST_FILE` set
  (older project template, multi-target setups), `wire-xcode.rb` now patches
  THAT existing file in place — preserving every other key — instead of
  redirecting to a new path.
- `scripts/check-skill-sync.sh` reworked to iterate every `.md` file under
  `scripts/.skill-templates/`, enforcing each as a canonical stanza across
  all five SKILL.md files. Drop a new template file, get sync enforcement on
  the next pre-commit. The previous single-template implementation
  (`scripts/.skill-version-check.template.md`) moves to
  `scripts/.skill-templates/keeping-current.md`.

### Breaking — API

None. Swift package source is unchanged.

### Notes

- Existing successfully-installed projects (those whose key actually landed in
  the built Info.plist via some other mechanism — older project templates with
  pre-existing file-based plists, manual edits) are unaffected. The bug bit
  modern Xcode templates (`GENERATE_INFOPLIST_FILE = YES`, no pre-existing
  `<Target>/Info.plist`) — the audience for this SDK is solo creators using
  exactly that template, so it bit ~all real users.
- `version:` frontmatter on all five SKILL.md files bumped to `2026-04-22`.

## [2.2.0] - 2026-04-21

### Added

- **Mandatory device/build context on every event.** Six `$`-prefixed keys are
  now merged into the `properties` dict of every tracked event (including the
  auto-emitted `$session_start` / `$session_end`):
  - `$app_version` — `CFBundleShortVersionString` (e.g. `"1.4.2"`)
  - `$app_build` — `CFBundleVersion` (e.g. `"842"`)
  - `$build_type` — one of `debug`, `testflight`, `appstore`, `development`
  - `$device_type` — one of `simulator`, `mac_catalyst`, `ios_on_mac`, `mac`, `device`
  - `$os_name` — `iOS`, `macOS`, `tvOS`, `watchOS`, `visionOS`
  - `$os_version` — dotted `major.minor.patch` from `ProcessInfo`
- **Build-type detection** combines `#if DEBUG` (catches Xcode-run builds)
  with Apple's `appStoreReceiptURL` filename check (`sandboxReceipt` →
  TestFlight; other receipt on disk → App Store; missing → `development`
  for enterprise / ad-hoc / direct-distributed macOS builds).
- **Public `DeviceContext` type** (`Sources/VibeTracer/Platform/DeviceContext.swift`)
  with a `.current()` factory and a six-field initializer for tests. Apps
  shouldn't need to touch this — `VibeTracer.configure()` builds it
  automatically — but it's public so tests and hosted diagnostics can inject
  fixed values.

### Why

Every Vibe Tracer app previously had to add build/OS/app-version properties
by hand, which (a) almost nobody did, (b) produced inconsistent key names
across apps (`appVersion` vs `app_version` vs `version`), and (c) made
cross-app funnels impossible to filter by build type. Making these mandatory
defaults at the SDK level eliminates the bespoke boilerplate and guarantees
every event in the warehouse can be split by `$build_type` / `$device_type`
out of the box.

### Contract

- System keys always win over user-supplied properties with the same name.
  A caller passing `properties: ["$app_version": "fake"]` has that key
  dropped (logged at warn level) and the real value emitted. Mandatory =
  mandatory.
- Values are computed once at `configure()` — they're immutable for the
  process lifetime — so per-event cost is a dictionary merge, not a
  `Bundle` / `ProcessInfo` read.

### Breaking — API

None.

### Notes

- `sdk-version` frontmatter in all 5 skills bumped to `2.2.0`.
- Podspec bumped to match.

## [2.1.0] - 2026-04-22

### Added

- **`VibeTracer.trackDebounced(event, key:, debounce:, properties:)`** for
  settled-state events — calculator outputs, search refinement, slider drags,
  map pan/zoom, date-picker wheels, drag-to-reorder, multi-field form progress.
  Rapid-fire calls for the same `(event, key)` coalesce to a single event
  emitted after the debounce window elapses; the `properties` closure is
  evaluated at fire time so it captures the latest state. Default window: 1s.
- **`VibeTracer.cancelDebounced(event, key:)`** for `.onDisappear` — cancels a
  pending fire so screen dismiss doesn't race a deferred event.
- **Events-skill "Call shape" section** — decision guide for `track()` vs
  `trackDebounced()` with ~15 concrete UI-pattern examples. Replaces the terse
  "debounced, never per keystroke" note that left the tool choice implicit.
- **Install-skill Public API list** bumped from 8 → 10 symbols.

### Why

Every agent previously shipped a bespoke `DebouncedTracker` class per app
because the events skill mandated debounced tracking but the SDK didn't
provide it. That produced variation in timer strategy, memory lifecycle, key
scoping, thread safety, and cancellation — all of which should be the SDK's
job to do correctly once.

### Breaking — API

None.

### Notes

- `sdk-version` frontmatter in all 5 skills bumped to `2.1.0`.
- Podspec bumped to match; `release.sh` auto-commits future podspec bumps so
  this stays in sync.

## [2.0.1] - 2026-04-21

### Added

- **Per-skill version field** (`version: YYYY-MM-DD` in each SKILL.md frontmatter)
  so agents can detect out-of-date installs.
- **End-of-run version check** in all 5 skills. If a newer version is available,
  the agent prints a single italic notice pointing to
  `https://vibetracer.xyz/skills/update`. On any failure (network, empty body,
  HTML response, missing version line) the check stays silent — false positives
  are strictly worse than missing notices.
- **`/skills/update` page** with a copy-paste prompt that atomically upgrades all
  installed `vibe-tracer-swift-*` skills. Validates frontmatter (`^---$`, exact
  `^name: <expected>$`, `^version: YYYY-MM-DD$`) before any write; failed fetches
  leave local files untouched.
- **Cross-link** from the dashboard Install page to `/skills/update` as a backstop
  for users whose in-agent notice never fires.

### Notes

- Existing v2.0.0 installs do NOT have the version-check section — they must be
  updated once (via the prompt at `/skills/update`) to start receiving notices.
  After that, updates are detected automatically at the end of the next relevant
  session.

### Breaking — API

None. The Swift package itself is unchanged from v2.0.0 / v1.1.3 — skills-pack
and docs-distribution only.

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

### Breaking — API

None. The Swift package itself is identical to v1.1.3 — only documentation
distribution changed. The "Breaking — docs distribution" above refers to the
SKILL.md download URL, not the Swift API. App builds against `from: "1.1.0"`
resolve to 2.0.0 automatically.

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
