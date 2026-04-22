## SDK skill freshness preflight

At the **top** of every invocation — before any project work, before any other check — verify this skill's local copy is current with what's published. A stale local skill silently makes wrong decisions. The cost is one ~10s HTTP request per session; the benefit is refusing to touch the user's project when the agent is operating from outdated instructions.

```bash
remote=$(curl -sfm 10 https://api.vibetracer.xyz/sdk/swift/skills/__NAME__/SKILL.md 2>/dev/null \
  | awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}')
local=$(awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}' "$0")  # this SKILL.md
```

(`$0` here is illustrative — substitute the path the agent loaded the skill from.)

**Compare** lexicographically. `YYYY-MM-DD` strings sort correctly as plain strings.

- `remote` empty (network failure, timeout, malformed response) → continue without printing anything. False positives ("you're stale" when you're not) are strictly worse than missed notices.
- `local >= remote` → continue silently. Skill is current.
- `local < remote` → **ABORT** with the message below. Do **not** run the rest of the workflow. Do **not** touch the user's project.

```
✗ This vibe-tracer-swift skill (`__NAME__`) is out of date.
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
