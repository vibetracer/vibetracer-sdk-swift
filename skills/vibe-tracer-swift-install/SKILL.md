---
name: vibe-tracer-swift-install
description: Use when the user explicitly asks to integrate, install, or configure Vibe Tracer in a Swift app, OR when `vibetracer-sdk-swift` is being added to their Package.swift or Podfile for the first time. Do NOT use for generic "add analytics" requests when the user has not picked a vendor.
version: 2026-04-21
sdk-version: 2.1.0
---

# Installing Vibe Tracer in a Swift App

First-time integration. Adds the package, wires `configure()` into the app's entry point, and protects the API key from ending up in git history.

## Iron Law

```
THE API KEY IS THE ONLY QUESTION YOU ASK THE USER.
KEY STORAGE IS ALWAYS xcconfig. THERE IS NO OTHER OPTION.
THE KEY IS NEVER HARDCODED — NOT EVEN IN #if DEBUG, NOT EVEN "JUST FOR NOW".
```

Violating the letter is violating the spirit. "Just hardcode it in debug for now" is still hardcoding — the literal lands in git history on the first push and stays there forever, in every clone and fork. `#if DEBUG` does not prevent the string from being committed to the repo.

If the user asks to hardcode: refuse, explain the git-history risk (next section), and implement xcconfig anyway. This is the one place the skill does not defer to the user.

The audience for this SDK is solo creators building iOS apps in Xcode. Assume `.xcodeproj` exists. If you genuinely cannot find one — see the short note at the bottom.

## Workflow

1. **Ask for the API key** — the only question. See "Getting the API key" below.
2. **Create the xcconfig files** + update `.gitignore` — see "Key storage — xcconfig" below.
3. **Run `wire-xcode.rb`** — the script adds the SPM dependency, wires the xcconfig into the project, and sets the `INFOPLIST_KEY`. See "Wire the Xcode project" below. The agent runs the script; the user never clicks through Xcode's Configurations UI.
4. **Wire `configure()`** into the app's entry point — see "Where to put `configure()`".

Do not announce a "plan" and wait for confirmation. Do not list alternatives. Ask for the key, then proceed.

## Getting the API key

Format: `vtr_live_` followed by 32 hex chars. Send the user to this URL:

```
https://www.vibetracer.xyz/projects/<slug>/agent-needs-api-key
```

The dashboard reads the slug, checks whether the project has received any events yet, and redirects automatically:

- **Empty project (first-time setup)** → `/projects/<slug>` (Overview page, which surfaces the install one-liner + a Copy-Prompt card for the next step).
- **Existing project** → `/projects/<slug>/settings?tab=keys` (Keys & access tab, with Create-key UI).

**Where the slug comes from:** the dashboard's install one-liner is `curl … | bash -s -- --project <slug>`, and `install.sh` embeds the slug into the post-install prompt (`"…help me figure out what to track. My project slug is X."`). That sentence is in the user's first message to you — extract the slug from it and substitute into the URL above.

If the slug isn't in the user's prompt (they ran the installer without `--project`, or they're invoking this skill manually), ask for it in one line: *"What's your project slug? It's the last path segment of your dashboard URL — `vibetracer.xyz/projects/<this-part>`."*

The API key itself is shown exactly once at creation. Have the user paste it to you directly; don't store or log it yourself.

## Red flags — STOP if you're about to write any of these

Menu-presenting red flags (none of these should appear for key storage):

- "Which storage approach would you prefer?"
- "Confirm the storage approach…"
- "Before I touch code, I need [more than the API key] from you"
- "I'd use xcconfig because… OK with that, or prefer something simpler?"
- Any `(A) / (B) / (C)` or bulleted list of storage options
- "Option 1 / Option 2 / Option 3" anywhere — there's only one option

Hardcoding red flags:

- `apiKey: "vtr_live_..."` as a literal in any `.swift` file
- `#if DEBUG` wrapping a hardcoded key — still hits git history
- "for now we can just hardcode", "temporary", "placeholder key" — same file, same commit
- Suggesting the user paste the key "just to get started and we'll move it later"
- Adding a `.env`-style file with the real key alongside a `.gitignore` line — if you forget to stage `.gitignore` first, you lose

All of these are failure modes this skill exists to prevent.

## Rationalization table

| Thought                                                   | Reality                                                              |
|-----------------------------------------------------------|----------------------------------------------------------------------|
| "The user should decide their own infra"                  | The skill already decided. You're stalling with fake choice.         |
| "Being thorough means listing the options"                | There are no options to list. Implement xcconfig.                    |
| "It's polite to confirm the plan first"                   | Politeness ≠ competence. Ask for the key and proceed.                |
| "This is a judgement call, I should present my reasoning" | Not a judgement call. This section is the reasoning.                 |
| "User insists on hardcoding, I should defer"              | Not here. Decline, explain git-history risk, implement xcconfig.     |
| "It's only a debug key, `#if DEBUG` makes it safe"        | Git doesn't care about `#if`. The literal is in the commit forever.  |
| "I'll add a TODO to rotate it later"                      | Rotation doesn't un-leak. The key stays in every clone and fork.     |
| "The repo is private / a throwaway"                       | Private repos get forked, leaked, or made public. Don't bet on it.   |
| "xcconfig feels like overkill for a 5-minute prototype"   | Five minutes of xcconfig beats five years of a leaked key.           |

## Key storage — xcconfig

Agent creates these files. Do this before running the Ruby script (next section); the script adds the references but doesn't create the files themselves.

1. **`.gitignore` first.** Add `Config/Secrets.xcconfig` to `.gitignore` and commit `.gitignore` BEFORE the real key ever touches disk. If the order is reversed, a slip-up leaks the key into the first commit that includes the xcconfig.
2. **Create `Config/Secrets.xcconfig.example`** with a placeholder — this is committed so collaborators know the shape:
   ```
   VIBETRACER_API_KEY = vtr_live_REPLACE_ME
   ```
3. **Create `Config/Secrets.xcconfig`** with the real key (gitignored, never committed):
   ```
   VIBETRACER_API_KEY = vtr_live_<the key the user gave you>
   ```

Runtime read code (goes in the app entry point — see "Where to put `configure()`"):
```swift
let apiKey = (Bundle.main.object(forInfoDictionaryKey: "VibeTracerApiKey") as? String) ?? ""
VibeTracer.configure(apiKey: apiKey)
```

## Wire the Xcode project (run the script)

The pbxproj edits that used to be "click through Project → Info → Configurations, then File → Add Package Dependencies" are automated. The agent runs one Ruby script; the user sees "✓ wired."

### Preflight (agent does these, in order)

1. **Ruby check.** `command -v ruby` — if missing, tell the user to run `xcode-select --install` and stop. Apple's Command Line Tools ship with Ruby; if they're missing, the user has bigger iOS-dev problems than this skill. Do not try to install Ruby yourself.

2. **xcodeproj gem check.** `ruby -r xcodeproj -e 'exit' 2>/dev/null` — if it fails, install it user-locally (no sudo):
   ```bash
   gem install --user-install xcodeproj
   ```
   Report outcome in one sentence. If the install itself fails (rare — locked-down managed Mac), surface the error verbatim to the user; do not silently retry.

3. **Git safety.** Run `git -C <project-root> status --porcelain`. If non-empty, pause and ask the user — pbxproj edits are cleanest to review against a clean tree. If they confirm to proceed anyway, proceed. No `--force` flag; the agent is the judgement.

### Running the script

```bash
ruby ~/.claude/skills/vibe-tracer-swift-install/scripts/wire-xcode.rb \
  <path-to-project.xcodeproj> \
  <target-name> \
  <sdk-version>
```

- **`<path-to-project.xcodeproj>`** — detect from the project root (there's exactly one `.xcodeproj` directory in our audience's projects).
- **`<target-name>`** — run `xcodebuild -list -project <path>` to enumerate, pick the app target (not tests or extensions unless the user specifies otherwise).
- **`<sdk-version>`** — read the `sdk-version:` line from this skill's YAML frontmatter. Do not hardcode a version.

### What the script does

Idempotent. Touches only `project.pbxproj`. In one pass:

- Adds `XCRemoteSwiftPackageReference` for `https://github.com/vibetracer/vibetracer-sdk-swift` with `upToNextMajorVersion = <sdk-version>`.
- Adds the `VibeTracer` product dependency to the target, including the Frameworks build phase entry the linker needs.
- Adds file references for `Config/Secrets.xcconfig` and `Config/Secrets.xcconfig.example` under a `Config` group.
- Sets `baseConfigurationReference` on the project's Debug + Release configurations to `Secrets.xcconfig`.
- Sets `INFOPLIST_KEY_VibeTracerApiKey = $(VIBETRACER_API_KEY)` on the target's Debug + Release build settings.

Success prints `✓ Wired Vibe Tracer into <target>:` with a per-line summary of every mutation, or `✓ No changes needed` on re-run. Any failure exits non-zero with a clear error — show it to the user verbatim and debug the specific cause; don't improvise a manual fallback just because the script errored.

### If the project uses a file-based Info.plist (older template)

The script prints a warning when `GENERATE_INFOPLIST_FILE ≠ YES`, because `INFOPLIST_KEY_VibeTracerApiKey` is only honored when the Info.plist is generated. In that case, additionally edit the target's `Info.plist` file to add:
```xml
<key>VibeTracerApiKey</key>
<string>$(VIBETRACER_API_KEY)</string>
```
The rest of the script's work still applies — only this one step needs a manual follow-up. This is rare for our audience (new Xcode templates default to `GENERATE_INFOPLIST_FILE = YES`).

## If the user pushes back and asks to hardcode

Don't. The request typically sounds like:

- "just hardcode it for now"
- "I'll replace it before shipping"
- "it's only a debug key"
- "wrap it in `#if DEBUG`, that's fine"

Respond, in one short paragraph: the literal will be in git history from the first commit, public mirrors and forks cache it, rotating later does not retroactively remove it from published refs, and `#if DEBUG` does not prevent the string from being committed. Then implement xcconfig anyway. The user can refuse to merge your change — that's fine — but the skill does not produce hardcoded keys.

## Adding the package manually (fallback paths)

The Xcode SPM case is handled by `wire-xcode.rb` above — you should not be in this section for a normal iOS app install. Use this section only if:

- The user has a pure `Package.swift` project (no `.xcodeproj`) — in which case the script doesn't apply.
- The user insists on CocoaPods for an existing Podfile-based project.

**Version pinning in all cases:** use the `sdk-version` value from this skill's frontmatter (currently `2.1.0` — but read the frontmatter, don't trust this sentence which may be stale). Never hardcode a different version.

### Swift Package Manager (`Package.swift`)

```swift
.package(url: "https://github.com/vibetracer/vibetracer-sdk-swift", from: "<sdk-version>")
```
Substitute `<sdk-version>` with the frontmatter value — e.g. `from: "2.1.0"`. Add `"VibeTracer"` to the target's `dependencies`.

### CocoaPods

```
pod 'VibeTracer', '~> <major>.<minor>'
```
Substitute `<major>.<minor>` with the first two segments of `sdk-version` — e.g. with `sdk-version: 2.1.0`, write `'~> 2.0'` (up-to-next-major semantics, matching the SPM `from:` behavior).

### Gitee mirror (China)

If `github.com` fails to resolve, swap to `https://gitee.com/vibetracer/vibetracer-sdk-swift`. Same tags, same content.

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

## If there's genuinely no Xcode project

Almost never applies — this SDK targets iOS / macOS / Catalyst / tvOS / visionOS apps, which are Xcode projects by construction. If you're in an SPM-only executable (Swift Playgrounds, a CLI tool), read the key from `ProcessInfo.processInfo.environment["VIBETRACER_API_KEY"]` and set the env var in the scheme. Do not present this as an option the user picks — it's a structural fallback, used only when xcconfig is physically impossible.

## Public API — exactly 10 symbols

```swift
VibeTracer.configure(apiKey: String, endpoint: URL = defaultEndpoint, debug: Bool = false)
VibeTracer.track(_ event: String, properties: [String: Any]? = nil)
VibeTracer.trackDebounced(_ event: String, key: String = "", debounce: TimeInterval = 1.0, properties: @escaping () -> [String: Any]?)
VibeTracer.cancelDebounced(_ event: String, key: String = "")
VibeTracer.identify(userId: String)
VibeTracer.reset()
VibeTracer.flush() async
VibeTracer.disable()
VibeTracer.enable()
VibeTracer.version
```

`trackDebounced` / `cancelDebounced` are for settled-state events (calculator outputs, search refinement, slider drags). See the events skill's "Call shape" section for when to reach for them.

## Take a stance — but only when there's a genuine choice

This section applies to decisions the skill does NOT pre-determine (e.g. whether to also wire up `identify()` in the same pass, naming conventions, etc.). It does **NOT** apply to the key-storage decision — that one is fixed by the Iron Law; implement it, don't pitch it.

For genuine open choices, state your pick and why in one sentence. Don't hand the user a neutral menu.

```
✅ "I'd do X because Y. Say so if you'd rather not."
❌ "I'd do X because Y. OK with that, or prefer Z?"   ← still a menu
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
