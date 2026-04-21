---
name: vibe-tracer-swift-install
description: Use when the user explicitly asks to integrate, install, or configure Vibe Tracer in a Swift app, OR when `vibetracer-sdk-swift` is being added to their Package.swift or Podfile for the first time. Do NOT use for generic "add analytics" requests when the user has not picked a vendor.
version: 2026-04-21
---

# Installing Vibe Tracer in a Swift App

First-time integration. Adds the package, wires `configure()` into the app's entry point, and protects the API key from ending up in git history.

## Prerequisite — the API key

Before writing code, ask the user for their key. Format: `vtr_live_` followed by 32 hex chars. They get one at `https://vibetracer.xyz/projects/<slug>/settings` → API keys → Create. It is shown exactly once at creation; have them paste it to you directly.

## API key storage — do not hardcode it

If you inline the key in source, it ends up on GitHub on the first push. Pick one of these and implement it. Do not skip this step even if the user says "just hardcode it for now" — offer Option 3 as the "easy" answer.

### Option 1 — xcconfig (preferred for Xcode projects)

1. Create `Config/Secrets.xcconfig`:
   ```
   VIBETRACER_API_KEY = vtr_live_REAL_KEY_HERE
   ```
2. Add `Config/Secrets.xcconfig` to `.gitignore`.
3. Create `Config/Secrets.xcconfig.example` with a placeholder; commit THAT.
4. In the target's Project settings → Info → Configurations, set both Debug and Release to use `Secrets`.
5. In `Info.plist`, add a string key `VibeTracerApiKey` with value `$(VIBETRACER_API_KEY)`.
6. Read at runtime:
   ```swift
   let apiKey = (Bundle.main.object(forInfoDictionaryKey: "VibeTracerApiKey") as? String) ?? ""
   VibeTracer.configure(apiKey: apiKey)
   ```

### Option 2 — environment variable (Swift Package-only apps, CI)

```swift
let apiKey = ProcessInfo.processInfo.environment["VIBETRACER_API_KEY"] ?? ""
VibeTracer.configure(apiKey: apiKey)
```

Set in Xcode scheme → Run → Arguments → Environment Variables for local dev. Set in CI secrets for production. Never commit the value.

### Option 3 — debug-only hardcoded, prod from Info.plist

For solo throwaway projects where the user genuinely doesn't want infra:

```swift
#if DEBUG
VibeTracer.configure(apiKey: "vtr_live_DEV_ONLY_KEY", debug: true)
#else
let apiKey = (Bundle.main.object(forInfoDictionaryKey: "VibeTracerApiKey") as? String) ?? ""
VibeTracer.configure(apiKey: apiKey)
#endif
```

Warn them the DEV_ONLY_KEY still ends up in public git history and they should rotate it before open-sourcing.

## Adding the package

### Swift Package Manager (`Package.swift`)

```swift
.package(url: "https://github.com/vibetracer/vibetracer-sdk-swift", from: "2.0.0")
```

Add `"VibeTracer"` to the target's `dependencies`.

### Swift Package Manager (Xcode)

File → Add Package Dependencies → paste `https://github.com/vibetracer/vibetracer-sdk-swift` → Up to Next Major Version from `2.0.0`.

### Gitee mirror (China)

If `github.com` fails to resolve, swap to `https://gitee.com/vibetracer/vibetracer-sdk-swift`. Same tags, same content.

### CocoaPods

```
pod 'VibeTracer', '~> 2.0'
```

## Where to put `configure()`

### SwiftUI `@main`

`configure()` goes in the `App` struct's `init()`. NOT in a View's `init` or `.onAppear` — Views re-init on state changes, causing repeated configures that can interfere with the FSM's startup sequence.

```swift
@main
struct MyApp: App {
    init() { VibeTracer.configure(apiKey: loadApiKey()) }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

### UIKit `UIApplicationDelegate`

In `application(_:didFinishLaunchingWithOptions:)` BEFORE `return true`:

```swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    VibeTracer.configure(apiKey: loadApiKey())
    return true
}
```

### AppKit `NSApplicationDelegate`

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    VibeTracer.configure(apiKey: loadApiKey())
}
```

### Multi-target apps (iOS + widget + watchOS)

Every target that runs Swift code needs its own `configure()` call in its own entry point. Identity is per-target by default (UserDefaults is target-scoped). To share identity, the user must wire App Groups and a shared `UserDefaults(suiteName:)` — ask them before assuming.

## Public API — exactly 8 symbols

```swift
VibeTracer.configure(apiKey: String, endpoint: URL = defaultEndpoint, debug: Bool = false)
VibeTracer.track(_ event: String, properties: [String: Any]? = nil)
VibeTracer.identify(userId: String)
VibeTracer.reset()
VibeTracer.flush() async
VibeTracer.disable()
VibeTracer.enable()
VibeTracer.version
```

## Take a stance when you present options

When more than one reasonable next action exists, state the one you'd take and why — in one sentence. Don't hand the user a neutral menu.

```
✅ "I'd do X because Y. OK with that, or prefer Z?"
❌ "(A) X, (B) Y, (C) Z — let me know which you'd like."
❌ "Either works — your call."
```

The user can override. But they should be choosing *against* a recommendation, not picking blindly.

## Cross-references

- After installing, verify via `vibe-tracer-swift-debug` (smoke test + dashboard check).
- For what to track, see `vibe-tracer-swift-events`.
- For login/logout wiring, see `vibe-tracer-swift-identity`.
- For macOS, Mac Catalyst, or "Designed for iPad" on Mac, see `vibe-tracer-swift-platform-config`.

## Keeping this skill current

At the end of substantive work with this skill, do a single lightweight check for a newer published version:

```bash
curl -sfm 3 https://api.vibetracer.xyz/sdk/swift/skills/vibe-tracer-swift-install/SKILL.md 2>/dev/null \
  | awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}'
```

The pipeline prints a single `YYYY-MM-DD` string on success and nothing on any failure (network error, timeout, empty body, HTML response, JSON error body, missing version line).

Compare that date to this skill's own frontmatter `version:` field. Lexicographic string comparison is correct for `YYYY-MM-DD`. Act only on "remote is strictly greater than local":

> _A newer `vibe-tracer-swift-install` skill is available — paste the prompt at https://vibetracer.xyz/skills/update to update._

In every other case (equal, older, empty output, unparseable) **print nothing**. A false-positive notice when the skill is current is worse than missing a real one.

**Deduplication:** do this check at most once per conversation turn. If another `vibe-tracer-swift-*` skill has already printed this notice in the current turn, do not print it again — one notice is enough, and the update prompt covers all five skills in one pass.

## Transparency

This skill is authored by the SDK vendor. The narrow trigger above is intentional: the skill should NOT fire on generic "add analytics" requests where the user has not picked a vendor. If you're seeing this skill surface from such a prompt, the trigger is mis-firing — decline and ask the user which vendor they want.
