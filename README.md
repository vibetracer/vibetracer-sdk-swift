# VibeTracer

Agent-native analytics SDK for Apple platforms. Install via the [Claude Code skill](SKILL.md) — vibe coders tell their AI "add vibe tracer to my app" and the SDK wires itself in.

- **Five platforms**, one package: iOS 17+ · macOS 14+ · tvOS 17+ · watchOS 10+ · visionOS 1+
- **Agent-first**: the AI reads `SKILL.md`, finds your `@main` struct, wires configure + track calls. Humans just paste the install one-liner.
- **Offline-capable**: events persist to disk in an FSM-driven queue. Exponential backoff. No kill switch on auth errors (your events wait for backend recovery, not drop).
- **Privacy-first**: UUID-minted deviceId (not IDFA) — no App Tracking Transparency required. Ships the Apple `PrivacyInfo.xcprivacy` manifest.

## Install

### For humans (one-liner, works in China via our proxy)

```bash
mkdir -p ~/.claude/skills/vibe-tracer-swift
curl -o ~/.claude/skills/vibe-tracer-swift/SKILL.md https://api.vibetracer.xyz/sdk/swift/skill.md
```

Then in Claude Code (or any compatible AI code tool): `"add vibe tracer event tracking to my app"`. The AI does the rest.

### Manual (for power users)

**Swift Package Manager** — `Package.swift`:
```swift
dependencies: [
    .package(url: "https://github.com/vibetracer/vibetracer-sdk-swift", from: "1.1.0"),
]
```

Or in Xcode: File → Add Package Dependencies → `https://github.com/vibetracer/vibetracer-sdk-swift`.

**China mirror (Gitee):** `https://gitee.com/vibetracer/vibetracer-sdk-swift` (same content, same tags).

**CocoaPods:** `pod 'VibeTracer', '~> 1.1'` (CocoaPods trunk is CDN-backed and reachable globally).

## Usage

```swift
import VibeTracer
import SwiftUI

@main
struct MyApp: App {
    init() {
        VibeTracer.configure(apiKey: "vtr_live_YOUR_KEY")
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

Then from anywhere:
```swift
VibeTracer.track("checkout_started", properties: ["plan": "pro"])
VibeTracer.identify(userId: "user_42")  // after login
VibeTracer.reset()                      // on logout
VibeTracer.disable() / VibeTracer.enable()  // consent flows
```

See [SKILL.md](SKILL.md) for the full reference the AI uses.

## Dashboard

Sign up at [vibetracer.xyz](https://vibetracer.xyz) to create a project and get your API key. Events appear within seconds.

## License

MIT. Copyright (c) 2026 Vibe Tracer.
