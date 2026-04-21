# VibeTracer

Agent-native analytics SDK for Apple platforms. Install the [skill pack](skills/) — vibe coders tell their AI "add vibe tracer to my app" and the SDK wires itself in.

- **Five platforms**, one package: iOS 17+ · macOS 14+ · tvOS 17+ · watchOS 10+ · visionOS 1+
- **Agent-first**: five focused skills teach the AI how to install, identify users, choose events, debug, and configure platforms. Humans just paste the install one-liner.
- **Offline-capable**: events persist to disk in an FSM-driven queue. Exponential backoff. No kill switch on auth errors (your events wait for backend recovery, not drop).
- **Privacy-first**: UUID-minted deviceId (not IDFA) — no App Tracking Transparency required. Ships the Apple `PrivacyInfo.xcprivacy` manifest.

## Install the skill pack

### For humans (one-liner, works in China via our proxy)

```bash
curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | bash
```

Installs all five Vibe Tracer Swift skills into `~/.claude/skills/`. Then in Claude Code: `"add vibe tracer event tracking to my app"`. The AI does the rest.

### Other agent tools

Pick Cursor or Windsurf with `--tool`:

```bash
curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | bash -s -- --tool cursor
curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | bash -s -- --tool windsurf
curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | bash -s -- --tool all    # auto-detect
```

Custom path (tools we don't know about): `--target ~/custom/path`. Pin a version: `--version v2.0.0`. Remove with `--uninstall`. Inspect the script before piping to bash via `curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | less`.

### Manual (for power users)

**Swift Package Manager** — `Package.swift`:
```swift
dependencies: [
    .package(url: "https://github.com/vibetracer/vibetracer-sdk-swift", from: "2.0.0"),
]
```

Or in Xcode: File → Add Package Dependencies → `https://github.com/vibetracer/vibetracer-sdk-swift`.

**China mirror (Gitee):** `https://gitee.com/vibetracer/vibetracer-sdk-swift` (same content, same tags).

**CocoaPods:** `pod 'VibeTracer', '~> 2.0'` (CocoaPods trunk is CDN-backed and reachable globally).

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

See [skills/](skills/) for the full reference pack the AI uses.

## Dashboard

Sign up at [vibetracer.xyz](https://vibetracer.xyz) to create a project and get your API key. Events appear within seconds.

## License

MIT. Copyright (c) 2026 Vibe Tracer.
