---
name: vibe-tracer-swift
description: Use when the user asks to add event tracking, analytics, or user metrics to an iOS/macOS/tvOS/watchOS/visionOS Swift app. Integrates the Vibe Tracer SDK via Swift Package Manager, configures it with the API key, wires auto-tracking, and adds per-feature track() calls as requested.
---

# Vibe Tracer Swift SDK

A lightweight, privacy-respecting analytics SDK for Apple platforms. Drop it into any Swift app with one package dependency, call `VibeTracer.configure(apiKey:)` once at launch, and start tracking events from anywhere in the codebase. Built for vibe coders shipping apps and for AI agents wiring analytics into them — the public surface is intentionally tiny (six symbols) so there's nothing to misuse.

Supports iOS 17+, macOS 14+, tvOS 17+, watchOS 10+, and visionOS 1+. Single SwiftPM package, one XCFramework at runtime, no Objective-C bridging headers, no CocoaPods required (but available).

## Prerequisite

Ask the user for their **API key**. It looks like `vtr_live_…` followed by a long random string.

To get one:
1. Sign in at `https://vibetracer.xyz`.
2. Open the project: `https://vibetracer.xyz/projects/<slug>/settings`.
3. Go to **API keys** → **Create new key**.
4. **Copy the secret immediately** — it's only shown once. If lost, rotate and create a new one.

Do not hardcode the key in a public repository. For production apps, inject it via an xcconfig, environment variable, or a build-time secret manager.

## 1. Add the package

### Xcode (recommended)

1. **File → Add Package Dependencies…**
2. Paste the repo URL: `https://github.com/vibetracer/vibetracer-sdk-swift`
3. Dependency rule: **Up to Next Major Version** starting from `1.1.0`.
4. Add the `VibeTracer` library product to your app target.

### Package.swift manifest

```swift
dependencies: [
    .package(url: "https://github.com/vibetracer/vibetracer-sdk-swift", from: "1.1.0"),
]
```

Then add `"VibeTracer"` to the appropriate target's `dependencies:`:

```swift
.target(
    name: "MyApp",
    dependencies: ["VibeTracer"]
)
```

### China (Gitee mirror)

If GitHub is unreachable, swap the URL to the Gitee mirror — identical content, same tags, SPM resolves either:

```
https://gitee.com/vibetracer/vibetracer-sdk-swift
```

### CocoaPods (legacy projects)

For Podfile-managed projects, add to your `Podfile`:

```ruby
pod 'VibeTracer', '~> 1.1'
```

The CocoaPods trunk CDN is reachable globally, including China.

## 2. Configure once in @main

Find the app's `@main` entry point (usually `<AppName>App.swift` for SwiftUI, or `AppDelegate` for UIKit/AppKit). Add one `import` and one `configure` call — that's it.

### SwiftUI

```swift
import VibeTracer
import SwiftUI

@main
struct MyApp: App {
    init() {
        VibeTracer.configure(apiKey: "vtr_live_REPLACE_WITH_USER_KEY")
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

### UIKit / AppKit

Call `VibeTracer.configure(apiKey:)` at the top of `application(_:didFinishLaunchingWithOptions:)`, **before returning `true`**:

```swift
import VibeTracer
import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        VibeTracer.configure(apiKey: "vtr_live_REPLACE_WITH_USER_KEY")
        return true
    }
}
```

`configure` is idempotent — if called twice, the second call is a no-op and logs a warning.

## 3. Track events

Call `VibeTracer.track(_:properties:)` from anywhere in the app — view models, services, networking layers, button handlers. No view context, no environment object, no prop drilling.

```swift
VibeTracer.track("checkout_started", properties: [
    "plan": "pro",
    "price": 9.99,
])
```

### Conventions

- **Event name**: `snake_case`, 1–120 characters. Good examples: `signup_completed`, `video_played`, `payment_failed`, `settings_toggled`.
- **Properties**: `[String: Any]` where values are JSON-serializable — `String`, `Int`, `Double`, `Bool`, `Date`, `URL`, or arrays/dictionaries of those types. `Date` values are ISO-8601-encoded automatically; `URL` values are converted to their absolute string form.

`track()` is synchronous and returns immediately. The SDK enqueues the event on a background actor, writes it to disk, and flushes to the API with exponential backoff — the caller never waits on network.

## 4. Identify on login, reset on logout

When a user signs in, associate their events with a stable user id (could be a numeric id, email, or any stable key your backend uses):

```swift
// After successful login:
VibeTracer.identify(userId: "user_42")
```

When the user signs out, clear the association:

```swift
VibeTracer.reset()
```

`userId` persists across app restarts. Subsequent `track()` calls are linked to it until `reset()` is called or a new `identify()` overrides it.

## 5. Auto-tracked events

The SDK automatically emits session events on app lifecycle:

- **`$session_start`** — on first activation, or on activation after 30 minutes of inactivity.
- **`$session_end`** — emitted on the next launch if the previous session expired (since iOS apps can't reliably fire on background).

These appear in the dashboard prefixed with `$` so you can distinguish SDK-generated events from your own custom ones. No code required — they're wired up as soon as `configure()` is called.

## 6. Debug mode

During simulator development, route events to the console instead of the network. Useful for exercising the tracking flow without polluting real analytics data.

```swift
VibeTracer.configure(
    apiKey: "vtr_live_...",
    debug: true   // logs locally, does NOT send over the network
)
```

In debug mode, each `track()` call prints a one-line summary via `os.Logger` and drops the event — nothing is written to disk or sent to the API.

## 7. Disable / enable for consent flows (GDPR / CCPA)

For jurisdictions that require explicit consent before analytics collection:

```swift
VibeTracer.disable()   // no-ops future track() calls, persists across launches
VibeTracer.enable()    // resumes tracking
```

Typical pattern: call `disable()` at launch before showing a consent prompt, then call `enable()` only if the user accepts. The disable flag is stored in `UserDefaults`, so it survives app restarts.

## 8. Privacy

The SDK is designed to clear Apple's App Store review bar for analytics SDKs:

- Mints a random UUID stored in `UserDefaults` as the device identifier — **never uses IDFA**, so App Tracking Transparency (ATT) is **not required**.
- Ships a `PrivacyInfo.xcprivacy` manifest declaring `NSPrivacyAccessedAPICategoryUserDefaults` access with reason `CA92.1` ("access info from the same app"), and an `Analytics` purpose on collected data.
- Declares `NSPrivacyTracking: false` — events are not linked to data from other apps or websites.
- Does not capture IP on the device. The server logs inbound IP for debugging, but IP is not exposed in the dashboard.

## 9. Troubleshooting

- **Events not appearing in the dashboard**: verify the API key matches the current project at `vibetracer.xyz`. Enable `debug: true` temporarily to confirm events are being generated locally.
- **Build errors on `import VibeTracer`**: confirm the target lists `VibeTracer` under **Frameworks, Libraries, and Embedded Content** (Xcode → target → **General** tab).
- **SPM resolution fails from China**: swap the package URL to the Gitee mirror `https://gitee.com/vibetracer/vibetracer-sdk-swift`. Identical content, same tags.
- **First events slow to appear in dashboard**: the dashboard polls every 3 seconds. New events surface within ~5 seconds of a successful POST. On patchy connectivity, events queue on disk and flush when the network returns — no data loss up to 10,000 queued events per device.

## Source and license

Full SDK source: `https://github.com/vibetracer/vibetracer-sdk-swift`

Released under the MIT license.
