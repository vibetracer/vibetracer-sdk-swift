---
name: vibe-tracer-swift-install
description: Use when the user explicitly asks to integrate, install, configure, upgrade, or update Vibe Tracer in a Swift app, OR when `vibetracer-sdk-swift` is being added to their Package.swift or Podfile for the first time. Do NOT use for generic "add analytics" requests when the user has not picked a vendor.
version: 2026-04-22
sdk-version: 2.2.0
---

# Installing Vibe Tracer in a Swift App

First-time integration OR upgrade of an already-integrated project. First-time integration adds the package, wires `configure()` into the app's entry point, and protects the API key from ending up in git history. Upgrade bumps the SPM pin and surfaces any API migration notes — no key prompt, no xcconfig churn, no re-wire.

## SDK skill freshness preflight

At the **top** of every invocation — before any project work, before any other check — verify this skill's local copy is current with what's published. A stale local skill silently makes wrong decisions. The cost is one ~10s HTTP request per session; the benefit is refusing to touch the user's project when the agent is operating from outdated instructions.

```bash
remote=$(curl -sfm 10 https://api.vibetracer.xyz/sdk/swift/skills/vibe-tracer-swift-install/SKILL.md 2>/dev/null \
  | awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}')
local=$(awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}' "$0")  # this SKILL.md
```

(`$0` here is illustrative — substitute the path the agent loaded the skill from.)

**Compare** lexicographically. `YYYY-MM-DD` strings sort correctly as plain strings.

- `remote` empty (network failure, timeout, malformed response) → continue without printing anything. False positives ("you're stale" when you're not) are strictly worse than missed notices.
- `local >= remote` → continue silently. Skill is current.
- `local < remote` → **ABORT** with the message below. Do **not** run the rest of the workflow. Do **not** touch the user's project.

```
✗ This vibe-tracer-swift skill (`vibe-tracer-swift-install`) is out of date.
  Local:  $local
  Remote: $remote
  Refresh first, then re-run the same command:

    curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | bash

  This refresh updates ALL five vibe-tracer-swift-* skills in one shot, so any
  sibling skill the workflow needs will also be current after.
```

**Why this is a hard abort, not a notice:**

The skill writes to the user's `.xcodeproj`, provisions Info.plist files, edits Swift sources. If the local instructions are stale, those edits could be wrong in ways that surface only at runtime (e.g. silently dropped events). "Better fail loud at preflight than break the project" is the core invariant.

**Why this check does NOT dedup across sibling skills:**

Each `vibe-tracer-swift-*` skill checks its own freshness independently. If one skill is current and another is stale, only the stale one aborts. Cross-skill dedup would silence the abort that matters; "no notice from any skill" would look like "everything is fresh," which is exactly the failure mode this preflight exists to prevent.

(The end-of-turn `## Keeping this skill current` notice still runs, on its own dedup, as a backstop after a successful workflow. That notice is informational; this preflight is gating.)

## Step 0 — Detect project state and run install-or-upgrade.sh

Before anything else (after the freshness preflight above), detect what state the user's project is in. The Iron Law (next section) and the full first-time workflow only apply when this is genuinely a first-time integration.

The colocated `install-or-upgrade.sh` script does the detection + routing for you. It branches internally:

- **Broken-state** (pbxproj has `INFOPLIST_KEY_VibeTracerApiKey` but no `INFOPLIST_FILE`) — a previous install hit Xcode's silent-key-drop bug. The script remediates by provisioning a file-based Info.plist via `wire-xcode.rb`. Run "Verifying the build" below to confirm the fix took, then the project is healthy and the user can resume normal work — no Iron Law / xcconfig recreation, those already exist.
- **First-time** (no VibeTracer SPM reference in pbxproj) — the script invokes `wire-xcode.rb` to add the package, link the product, provision Info.plist, and wire xcconfig refs. **You still need to do steps 1–2 of the workflow below first** (ask for the API key, create the xcconfig files) so the script's wiring lands against real files. After the script exits, run "Verifying the build" then continue with the workflow's `configure()` step.
- **Already-current** (`Package.resolved` at or above `sdk-version`) — script prints `✓ Already on …` and exits. Continue to the user's actual task (events / debug / etc.).
- **Drift** (`Package.resolved` below `sdk-version`) — script deletes `Package.resolved`, bumps `minimumVersion` via `wire-xcode.rb`, and prints the CHANGELOG migration delta. **Do NOT** continue to Iron Law / xcconfig recreation — those already exist. The script tells you to run xcodebuild's `-resolvePackageDependencies` (or instruct the user to do `File → Packages → Resolve Package Versions` in Xcode); follow that, then run "Verifying the build" below. If migration sections are non-`None.`, walk the user through call-site edits before declaring done.

```bash
~/.claude/skills/vibe-tracer-swift-install/scripts/install-or-upgrade.sh \
  <project-root> <target-name>
```

Substitute the actual skill-pack root for your agent tool (`~/.cursor/rules`, `~/.codex/skills`, etc.) — the script lives wherever this SKILL.md lives.

**Podfile-integrated projects** (`Podfile.lock` contains `VibeTracer` but no SPM reference): CocoaPods upgrade isn't automated. Tell the user to run `pod update VibeTracer` themselves, then re-invoke this skill if they want migration help. Do not run `install-or-upgrade.sh`.

## Verifying the build

Run a headless `xcodebuild build` after every mutation that could affect compilation or the built bundle: any `project.pbxproj` change, any `Info.plist` change, any `.entitlements` change, any `.swift` source you wrote or rewrote. The cost (10–90s per build, incremental after the first) is the price of catching a class of failures that otherwise compounds across steps.

**Choose a destination once per session:**

- If the user has named a preferred simulator anywhere in the conversation, use it.
- Otherwise ask, once at the top of the workflow, in one line: *"Which simulator do you usually test on? (Or say 'any' and I'll pick the first available iOS sim.)"* — reuse the answer for the rest of the session.
- For headless verification only (i.e. you are not launching the app for the user to interact with), `-destination 'generic/platform=iOS Simulator'` is acceptable and avoids needing a specific UDID. Default to this when the user is not present to ask.

**Run the build:**

```bash
xcodebuild build \
  -project <project>.xcodeproj \
  -scheme <scheme> \
  -destination '<destination>' \
  -derivedDataPath "$(mktemp -d)/vtr-verify"
```

- Pick `<scheme>` via `xcodebuild -list -project <project>.xcodeproj` and take the first shared scheme. If no shared scheme exists, ask the user which one to use — don't guess.
- The `-derivedDataPath` argument MUST point outside the user's project tree. `mktemp -d` puts the scratch directory in the OS temp area, which is reaped automatically. Do NOT write to the project's own `build/`, `DerivedData/`, or any sibling directory the user might be tracking.

**On success — check the runtime, not just the compile:**

If the mutation touched `Info.plist` (your own edits, or `vibe-tracer-swift-install`'s scripts), also assert the built plist contains the key the runtime reads:

```bash
app=$(ls -d "$DERIVED/Build/Products/Debug-iphonesimulator"/*.app | head -1)
key=$(/usr/libexec/PlistBuddy -c "Print :VibeTracerApiKey" "$app/Info.plist" 2>/dev/null)
```

- `$key` empty → the key isn't in the built plist. Most likely cause: `INFOPLIST_FILE` not wired into the configs, or `GENERATE_INFOPLIST_FILE = NO` without a complete file-based plist. Re-run `install-or-upgrade.sh` and re-build.
- `$key` literally `$(VIBETRACER_API_KEY)` → the xcconfig substitution didn't happen. The Secrets.xcconfig file isn't wired as the configs' `baseConfigurationReference`. Re-run `install-or-upgrade.sh`.
- `$key` starts with `vtr_live_` → ✓ pass.

**On failure — diagnose, then escalate (NEVER auto-rollback):**

1. **Read the error.** The first non-note line in the build log usually localizes the cause. Compile errors → check imports, type signatures, missing symbols (often an SDK-version mismatch — see this skill's "SDK skill freshness preflight" and Step 0). Linker errors → check the package product is linked. Plist errors → check the file shape and the `INFOPLIST_FILE` setting.
2. **Attempt a fix in place.** Re-edit the file you just wrote. Most failures are tractable in 1–2 attempts.
3. **DO NOT run any destructive git command** — no `git checkout`, no `git stash`, no `git reset`, no `git clean` — to "undo" your changes. Those can wipe co-located user work the agent didn't touch. The user's audience for this SDK includes non-engineers; a `git checkout` "to clean up" can vaporize hours of design work irreversibly.
4. **If the fix doesn't take in 1–2 attempts, escalate to the user with specifics.** Name the file you wrote, paste the exact error line, state your best theory of the cause, and ask one precise question. Vague asks ("could you check the project?") waste their time. Precise asks ("I added `import VibeTracer` to `DateAdjustScreen.swift:10`, but the compiler reports `No such module 'VibeTracer'`. Could you confirm the package shows up under Package Dependencies in the Xcode sidebar?") get a useful answer.

This is a hard rule for this skill. The agent diagnoses; the user inspects; nothing automatically rewrites or reverts working-tree state.
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
3. **Run `install-or-upgrade.sh`** — the script invokes `wire-xcode.rb` to add the SPM dependency, wire the xcconfig into the project, and provision the file-based Info.plist. See "Wire the Xcode project (run install-or-upgrade.sh)" below. The agent runs the script; the user never clicks through Xcode's Configurations UI.
4. **Verifying the build** — headless `xcodebuild build` + PlistBuddy assertion that `VibeTracerApiKey` resolved to `vtr_live_…`. See "Verifying the build" above. Do NOT skip this — it's the only way to catch the silent-key-drop class of bugs at install time instead of at first-event-doesn't-arrive time.
5. **Wire `configure()`** into the app's entry point — see "Where to put `configure()`".
6. **Verifying the build (again)** — Swift source change can break compilation if the entry point is non-standard. One more headless build before declaring done.

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

## Wire the Xcode project (run install-or-upgrade.sh)

The pbxproj edits + Info.plist provisioning that used to be "click through Project → Info → Configurations, then File → Add Package Dependencies, then add a custom plist key" are automated. The agent runs one bash script that internally invokes `wire-xcode.rb`; the user sees "✓ wired" or a precise error.

`install-or-upgrade.sh` is the same entry point Step 0 already pointed at — it handles first-time install, drift-driven upgrade, broken-state remediation, and the already-current no-op all in one place.

### Preflight (agent does these, in order)

1. **Ruby check.** `command -v ruby` — if missing, tell the user to run `xcode-select --install` and stop. Apple's Command Line Tools ship with Ruby; if they're missing, the user has bigger iOS-dev problems than this skill. Do not try to install Ruby yourself.

2. **xcodeproj gem check.** `ruby -r xcodeproj -e 'exit' 2>/dev/null` — if it fails, install it user-locally (no sudo):
   ```bash
   gem install --user-install xcodeproj
   ```
   Report outcome in one sentence. If the install itself fails (rare — locked-down managed Mac), surface the error verbatim to the user; do not silently retry.

3. **Git safety.** Run `git -C <project-root> status --porcelain`. If non-empty, pause and ask the user — pbxproj edits are cleanest to review against a clean tree. If they confirm to proceed anyway, proceed. No `--force` flag; the agent is the judgement. (Note: even if they say no, the script will not run any destructive git command — see "Verifying the build" for the failure-mode rules.)

### Running the script

```bash
~/.claude/skills/vibe-tracer-swift-install/scripts/install-or-upgrade.sh \
  <project-root> <target-name>
```

- **`<project-root>`** — directory containing exactly one `.xcodeproj`. The script will refuse if it finds zero or more than one.
- **`<target-name>`** — run `xcodebuild -list -project <path>` to enumerate, pick the app target (not tests or extensions unless the user specifies otherwise).
- The script reads `sdk-version` from this skill's frontmatter automatically — you don't pass it. That keeps the version source-of-truth in one place.

### What the script does

Deterministic. Touches `project.pbxproj` and one Info.plist. **Does not run any build** — verification is the agent's job (see "Verifying the build" above) because build environment and simulator preference vary per user.

Per branch:

- **First-time install** (no VibeTracer SPM reference) — invokes `wire-xcode.rb`, which:
  - Adds `XCRemoteSwiftPackageReference` for `https://github.com/vibetracer/vibetracer-sdk-swift` with `upToNextMajorVersion = <sdk-version>`.
  - Adds the `VibeTracer` product dependency to the target (including the Frameworks build phase entry the linker needs).
  - Adds file references for `Config/Secrets.xcconfig` and `Config/Secrets.xcconfig.example` under a `Config` group.
  - Sets `baseConfigurationReference` on the project's Debug + Release configurations to `Secrets.xcconfig`.
  - **Provisions a file-based `<Target>/Info.plist`** with `VibeTracerApiKey = $(VIBETRACER_API_KEY)` and sets `INFOPLIST_FILE` on Debug + Release. `GENERATE_INFOPLIST_FILE = YES` is preserved — Xcode treats the file as a seed and merges its auto-generated Apple keys (`CFBundleExecutable`, `UILaunchScreen_*`, etc.) on top, so nothing the user expects from auto-generation is lost.
  - **If the user already has an `INFOPLIST_FILE` set** to a different path (older project template), the script patches THAT existing file in place — preserving every other key the user has — instead of redirecting to a new location.
- **Broken-state remediation** (pbxproj has the legacy `INFOPLIST_KEY_VibeTracerApiKey` setting but no `INFOPLIST_FILE`) — the silently-dropped-key bug from older skill versions. Same `wire-xcode.rb` invocation provisions the file-based Info.plist and strips the stale `INFOPLIST_KEY_*` setting.
- **Drift** (`Package.resolved` below `sdk-version`) — script deletes `Package.resolved`(s) so SPM unambiguously re-resolves, invokes `wire-xcode.rb` to bump `minimumVersion`, prints the CHANGELOG migration delta. Agent then runs `xcodebuild -resolvePackageDependencies` (or instructs the user to do `File → Packages → Resolve Package Versions` in Xcode if the project has no shared scheme).
- **Already-current** — script prints `✓ Already on …` and exits 0.

Success on any mutating branch ends with a `→ The agent must now run a clean build to confirm` reminder. Run "Verifying the build" before declaring done.

### Why a file-based Info.plist (not `INFOPLIST_KEY_*`)

Xcode's auto-Info.plist generator only promotes `INFOPLIST_KEY_<Foo>` settings into the built `Info.plist` for keys on Apple's recognized-keys allowlist (`CFBundle*`, `NSCamera*`, `UILaunchScreen_*`, etc.). `VibeTracerApiKey` is a custom key — silently dropped. At runtime `Bundle.main.object(forInfoDictionaryKey: "VibeTracerApiKey")` returns `nil` → `??` → `""` → `configure(apiKey: "")` → every event dropped client-side, before the network. Headless `xcodebuild build` succeeds, the dashboard shows zero events, the user spends two hours debugging a "network problem" that isn't.

The fix is unconditional: provision a real Info.plist file with the custom key. If you ever see a project where `INFOPLIST_KEY_VibeTracerApiKey` is set on the target's build settings, that's the legacy-broken state — `install-or-upgrade.sh` detects it and remediates automatically.

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

**Version pinning in all cases:** use the `sdk-version` value from this skill's frontmatter. Read the frontmatter directly — do not hardcode a version from memory or from example snippets below.

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

The list below reflects the `sdk-version` in this skill's frontmatter. If the user's project is pinned to an older version (see `Step 0`), some symbols may not exist in their build — upgrade first, then call them.

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
