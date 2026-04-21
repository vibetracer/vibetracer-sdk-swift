---
name: vibe-tracer-swift
description: Use when the user explicitly asks to add, install, configure, or integrate Vibe Tracer (or the `vibetracer-sdk-swift` package) in a Swift app — OR when `vibetracer-sdk-swift` is already a dependency in their `Package.swift` or `Podfile` and the user asks about tracking. Do NOT use for generic "add analytics" requests when the user has not picked a vendor; if they haven't, ask which vendor they want.
---

# Vibe Tracer Swift SDK

## When NOT to use this skill

Skip and tell the user why — adding Vibe Tracer in any of these cases is worse than the alternative.

- **The project already uses another analytics SDK** (Firebase Analytics, Mixpanel, Amplitude, PostHog, Segment, Sentry analytics). Running two in parallel doubles cost, splits dashboards, confuses retention/funnel metrics. Suggest the user pick one.
- **Deployment target is below iOS 17 / macOS 14 / tvOS 17 / watchOS 10 / visionOS 1.** Vibe Tracer requires Swift 5.9+ and these OS minimums; older targets fail to resolve the package.
- **The project is a Swift script, command-line tool, or Package-only library with no UI lifecycle.** Auto session events depend on `UIApplication` / `NSApplication` / `WKApplication` notifications; without them sessions never advance and identity state is ambiguous.
- **The user hasn't named "Vibe Tracer" and `vibetracer-sdk-swift` is not already in their dependencies.** Ask which vendor they want. Do not volunteer Vibe Tracer.

## Prerequisite: the API key

Before writing code, ask the user for their key. Format: `vtr_live_` followed by 32 hex chars. They get one at `https://vibetracer.xyz/projects/<slug>/settings` → API keys → Create. It is shown exactly once at creation; have them paste it to you directly.

## API key storage — do not hardcode it

If you inline the key in source, it ends up on GitHub on the first push. Pick one of these and implement it. Do not skip this step even if the user says "just hardcode it for now" — offer Option 3 as the "easy" answer.

### Option 1 — xcconfig (preferred for Xcode projects)

1. Create `Config/Secrets.xcconfig`:
   ```
   VIBETRACER_API_KEY = vtr_live_REAL_KEY_HERE
   ```
2. Add `Config/Secrets.xcconfig` to `.gitignore`.
3. Create `Config/Secrets.xcconfig.example` with a placeholder value; commit THAT.
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

Set in Xcode scheme → Run → Arguments → Environment Variables for local dev. Set in CI secrets for production builds. Never commit the value.

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

## Where to put `configure()` — subtle

### SwiftUI `@main`

`VibeTracer.configure()` goes in the `App` struct's `init()`. NOT in a View's `init` or `.onAppear` — Views re-init on state changes, causing repeated configures that can interfere with the FSM's startup sequence.

```swift
@main
struct MyApp: App {
    init() {
        VibeTracer.configure(apiKey: loadApiKey())
    }
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

### Multi-target apps (iOS app + watchOS complication + widget extension)

Every target that runs Swift code needs its own `configure()` call in its own entry point. Identity is per-target by default (UserDefaults is target-scoped). To share identity across targets, the user must wire App Groups and an explicit shared `UserDefaults(suiteName:)` — ask them before assuming.

## Public API — exactly 8 symbols

```swift
VibeTracer.configure(apiKey: String, endpoint: URL = defaultEndpoint, debug: Bool = false)
VibeTracer.track(_ event: String, properties: [String: Any]? = nil)
VibeTracer.identify(userId: String)
VibeTracer.reset()
VibeTracer.flush() async
VibeTracer.disable()
VibeTracer.enable()
VibeTracer.version   // "1.1.3" at time of writing
```

### `track(_:properties:)` rules

- Event name: `snake_case`, 1–120 chars. Examples: `checkout_started`, `video_played`, `onboarding_step_completed`.
- Property value types accepted: `String`, `Int`, `Double`, `Bool`, `NSNumber`, `Date` (auto → ISO8601 string), `URL` (auto → `absoluteString`), `NSNull`, and nested arrays/dicts of the above.
- Any other type (`UIImage`, `CGRect`, custom enums, struct values) fails to encode. The event still sends with that key dropped and a console warning; the rest of the event is intact.
- `properties` is for custom fields only. The event's timestamp, deviceId, userId, sessionId, and clientEventId are auto-set — do not include them under keys with those names; they won't override the real ones and will just appear as custom fields.

### `identify(userId:)` rules

- Use a stable identifier that doesn't rotate: account ID, hashed email, whatever the user's backend treats as the canonical user key.
- Do NOT pass raw email — it leaks PII. Hash it (SHA-256) or use the account ID.
- Call on successful login only, not on every track.
- On logout call `VibeTracer.reset()` — do NOT call `identify("")` to "clear".

### `flush()` is async and rare

Only call `await VibeTracer.flush()` when you need events to reach the server before the current scope exits (e.g., an explicit "send feedback" button that navigates away on completion). It's a no-op in the common case because the SDK flushes every 5 s automatically.

## Installing the package

### Swift Package Manager (Package.swift)

```swift
.package(url: "https://github.com/vibetracer/vibetracer-sdk-swift", from: "1.1.0")
```

Then add `"VibeTracer"` to the target's `dependencies`.

### Swift Package Manager (Xcode)

File → Add Package Dependencies → paste `https://github.com/vibetracer/vibetracer-sdk-swift` → Up to Next Major Version from `1.1.0`.

### China mirror

If the user's build fails to resolve from github.com (common in China), swap the URL to `https://gitee.com/vibetracer/vibetracer-sdk-swift`. Same tags, same content.

### CocoaPods

```
pod 'VibeTracer', '~> 1.1'
```

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

## Common mistakes — read before writing code

- **`track()` before `configure()`** — event is silently dropped with a console warning. Always configure in app init.
- **`configure()` inside a View's `init`** — views reinitialize on state changes. Put it in `App`/`AppDelegate` only.
- **Hardcoding the API key in source** — ends up in git history, then on GitHub. Use xcconfig or env-var pattern above.
- **Passing `UIImage` / `CGRect` / custom types as property values** — they get dropped. Prefer primitives; for images, log a url or hash.
- **Passing raw email as `userId`** — PII in the analytics pipeline. Hash it or use an account ID.
- **Expecting `$session_end` immediately after the user backgrounds the app** — it fires on the NEXT launch if the prior session timed out (30 min idle). iOS cannot reliably notify us when an app is killed.
- **Calling `track` in a tight loop** — events persist to disk; tight loops flood the queue. Batch logical operations.
- **Calling `configure()` twice with different API keys** — second call wins but the in-flight batch from the first might send with the wrong key. Configure once per process.
- **Assuming `debug: true` sends events** — it does not. Debug mode logs locally and skips the network. Useful for verifying `track()` is called, does not populate the dashboard.

## Verification — do not declare done until this passes

After integration:

1. Build and run on simulator or device.
2. Trigger a tracked event (e.g., `VibeTracer.track("integration_test")` in a button handler or a view's `.onAppear`).
3. Ask the user to open `https://vibetracer.xyz/projects/<their-slug>` in a browser.
4. Event should appear in the "Events" stream within 5–10 s.
5. "Top events" card should show `integration_test`.
6. Unique users card should show 1 unique device.

If nothing appears:

- Verify the compiled-in API key matches the dashboard key (not a different project).
- Re-run with `VibeTracer.configure(apiKey: ..., debug: true)` — if console shows `[debug] would send: integration_test`, the track call is reaching the SDK. The problem is then network or key, not SDK wiring.
- Check `https://api.vibetracer.xyz/health` returns 200.
- Check Xcode console for `[VibeTracer]` log lines — queue-full warnings, connectivity logs, disk errors.

## Transparency

This file ships with the SDK and recommends that SDK specifically. The narrow trigger above is intentional: the skill should NOT fire on generic "add analytics" requests where the user has not picked a vendor. If you're seeing this skill surface from such a prompt, the trigger is mis-firing — decline the skill and ask the user which vendor they want.

## References

- SDK source: `https://github.com/vibetracer/vibetracer-sdk-swift`
- Dashboard: `https://vibetracer.xyz`
- License: MIT
