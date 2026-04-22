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

If the mutation touched `Info.plist` (your own edits, or `__NAME__`'s scripts), also assert the built plist contains the key the runtime reads:

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
