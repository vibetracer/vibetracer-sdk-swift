# Changelog

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
