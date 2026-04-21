# Skill update notifier — implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` (or this session's `superpowers:subagent-driven-development`) to implement this plan task-by-task.

**Goal:** When a user runs one of the five `vibe-tracer-swift-*` skills and a newer version of that skill has been published, the agent prints a single italic blockquote line pointing to `vibetracer.xyz/skills/update`. That page hosts a copy-paste prompt which, pasted into any agent, atomically upgrades all installed skills without clobbering on failed fetch.

**Architecture:** Per-skill `version: YYYY-MM-DD` in frontmatter + short end-of-run check section in each SKILL.md. Web page on the existing React app renders human explanation + the copy-able update prompt. No backend changes — existing `/sdk/swift/skills/:name/SKILL.md` proxy already serves what the check and the update prompt need. Pre-commit hook in the SDK repo guards version-bump discipline.

**Tech Stack:** Existing — Swift skill files (plain markdown), Vite + React + Tailwind + shadcn/ui for the new `/skills/update` page, `navigator.clipboard` for copy button (pattern from `InstallPage`).

---

## Design decisions (locked from brainstorm)

1. **Version format:** date (`YYYY-MM-DD`), not semver. Skills iterate on content, not API. Semver stays in CHANGELOG for SDK releases.
2. **Cache:** none — one `curl` per skill invocation (~200ms). Side-car cache files were rejected because they'd pollute `~/.claude/skills/*` with state files outside the skill content.
3. **Trigger:** the skill content itself instructs the agent to do an end-of-run check. No host-tool hook (not portable across Claude Code / Cursor / Windsurf).
4. **Upgrade path:** user-invoked (paste prompt into agent), not self-upgrade. Agent self-mutating mid-session is a recursive footgun; user-invoked is atomic and resumable.
5. **Error tolerance:** update prompt validates frontmatter (`^---$`, `^name: <same>$`, `^version: YYYY-MM-DD$`) on fetched content before `mv`. Empty / 404-HTML / JSON-error / wrong-name responses leave local file untouched.
6. **URL:** `https://vibetracer.xyz/skills/update` (public route, no auth — the warning line may be seen by anonymous visitors).

---

## Pattern tension (surfaced for human decision)

> **Pattern tension:** The "Version check" section duplicates ~15 lines across all 5 SKILL.md files (identical modulo `<name>`). Reviewer recommended consolidating to only `vibe-tracer-swift-install`. I disagree with that consolidation and recommend keeping the duplication. Decision needed.
>
> - **Option A — Duplicate (this plan's current direction):** every skill runs its own check. Pro: a user who integrated once 6 months ago and today uses only `vibe-tracer-swift-events` still gets the notice during that session. That's the primary target scenario. Con: drift risk if edits diverge across files. Mitigated by a commit-time sync check (Task 5b, pre-commit hook).
> - **Option B — Only `install` skill owns the check:** no duplication, one owner. Pro: collapses drift risk. Con: users past first-install rarely re-invoke `install` — the feature becomes near-dormant after day 1. Undermines the whole point.
> - **Option C — Single shared generator:** `scripts/sync-version-check.sh` regenerates the section in all 5 from one template; pre-commit hook runs it. Equivalent in behavior to A, with mechanical drift guaranteed impossible.
>
> My recommendation: **A + pre-commit sync check** (the plan as written). C is correct-er but more machinery for a <40-line duplication; we can escalate to C only if drift actually bites.

---

## Task 1: Add `version` frontmatter to all 5 skills

**Files:**
- Modify: `skills/vibe-tracer-swift-install/SKILL.md` (frontmatter)
- Modify: `skills/vibe-tracer-swift-events/SKILL.md` (frontmatter)
- Modify: `skills/vibe-tracer-swift-identity/SKILL.md` (frontmatter)
- Modify: `skills/vibe-tracer-swift-debug/SKILL.md` (frontmatter)
- Modify: `skills/vibe-tracer-swift-platform-config/SKILL.md` (frontmatter)

**Step 1: Add `version: 2026-04-21` line to each file's frontmatter.**

Use today's date (`2026-04-21`). Insert as the third line (after `name:` and `description:`, before closing `---`).

```markdown
---
name: vibe-tracer-swift-events
description: Use when the user...
version: 2026-04-21
---
```

Claude Code's skill loader ignores unknown frontmatter keys, so this is additive and safe. The value must match `^version: \d{4}-\d{2}-\d{2}$` exactly (no quotes, single space after the colon) — the check bash greps for that pattern.

**Step 2: Commit.**

```bash
git add skills/vibe-tracer-swift-*/SKILL.md
git commit -m "skills: add version field to frontmatter"
```

---

## Task 2: Add end-of-run version-check section to all 5 skills

**Files:** same 5 SKILL.md files as Task 1.

**Step 1: Append this section to each skill, immediately above the `## Transparency` section.** Replace `<name>` with the actual skill name per file.

```markdown
## Keeping this skill current

At the end of substantive work with this skill, do a single lightweight check for a newer published version:

```bash
curl -sfm 3 https://api.vibetracer.xyz/sdk/swift/skills/<name>/SKILL.md 2>/dev/null \
  | awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}'
```

The pipeline prints a single `YYYY-MM-DD` string on success and nothing on any failure (network error, timeout, empty body, HTML response, JSON error body, missing version line).

Compare that date to this skill's own frontmatter `version:` field. Lexicographic string comparison is correct for `YYYY-MM-DD`. Act only on "remote is strictly greater than local":

> _A newer `<name>` skill is available — paste the prompt at https://vibetracer.xyz/skills/update to update._

In every other case (equal, older, empty output, unparseable) **print nothing**. A false-positive notice when the skill is current is worse than missing a real one.

**Deduplication:** do this check at most once per conversation turn. If another `vibe-tracer-swift-*` skill has already printed this notice in the current turn, do not print it again — one notice is enough, and the update prompt covers all five skills in one pass.
```

**Step 2: Commit.**

```bash
git add skills/vibe-tracer-swift-*/SKILL.md
git commit -m "skills: add end-of-run version check"
```

---

## Task 3: Create `/skills/update` page in web app

**Files:**
- Create: `apps/web/src/pages/SkillsUpdatePage.tsx`
- Modify: `apps/web/src/Router.tsx` (register route as top-level, no layout wrapper — `PublicLayout` is the auth-split with a marketing hero and is wrong for a documentation-style page)

**Step 1: Create `SkillsUpdatePage.tsx`.**

Render its own minimal shell (the same header pattern as `PublicLayout`'s top bar — Vibe Tracer wordmark + live dot, linked to `/` — with the paper grid + grain background, but NO hero column). Reuse the `navigator.clipboard` pattern from `InstallPage` (transient `copied` state, Lucide `Copy`/`Check` swap, toast on failure).

Page structure:

1. Top bar (shared chrome with auth pages — wordmark left, nothing right).
2. Heading: "Update your `vibe-tracer-swift-*` skills".
3. One-sentence lead: "Paste the prompt into Claude Code, Cursor, Windsurf, or any agent with filesystem access. It will atomically update all installed `vibe-tracer-swift-*` skills, leaving any failed fetches untouched."
4. `<pre>` code block with the prompt below + Copy button.
5. "What this does" — 3 bullets:
   - Downloads each `SKILL.md` to a temp file (`mktemp`).
   - Validates frontmatter (`^---$` on line 1, `^name: vibe-tracer-swift-<expected>$`, `^version: YYYY-MM-DD$` within the pre-`---` block) before touching the local file.
   - Only on validation success, atomically `mv`s the temp file over the installed skill.
6. Safety line: "If any skill fails to fetch or validate, its local copy is left untouched. The agent reports per-skill status: `updated N, current M, skipped K`."

The prompt content (verbatim inside the `<pre>`, exactly as follows):

````
Update my installed `vibe-tracer-swift-*` Claude Code skills to the latest versions.

Use the `Bash` tool for filesystem operations. Run these steps:

1. Pick the tempdir: `TMP="${TMPDIR:-/tmp}"`.
2. Discover installed skills: list `~/.claude/skills/vibe-tracer-swift-*/SKILL.md` (bash glob). If none match, report "no vibe-tracer-swift-* skills installed" and stop.
3. For each local SKILL.md:
   a. Extract the skill's name from its `name:` frontmatter line (`grep -m1 '^name: ' <file> | awk '{print $2}'`). Expect a `vibe-tracer-swift-*` name.
   b. Download: `curl -sfm 10 -o "$TMP/skill-$name.md" "https://api.vibetracer.xyz/sdk/swift/skills/$name/SKILL.md"`. If curl exits non-zero, mark skipped with reason "fetch failed" and move on. Do NOT touch the local file.
   c. Validate the temp file in this exact order; fail the first that doesn't hold:
      - File exists and size > 0.
      - Line 1 is exactly `---`.
      - `grep -cE "^name: $name$"` on the file returns 1 (anchored, exact match to the expected skill name).
      - `grep -cE "^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$"` on the file returns 1.
   d. If any validation step fails, delete the temp file, mark skipped with reason "invalid content", and move on. Do NOT touch the local file.
   e. If validation passes, compare the remote `version:` value to the local one (lexicographic — `YYYY-MM-DD` is ordered correctly). Then:
      - Remote strictly greater than local: `mv "$TMP/skill-$name.md" ~/.claude/skills/$name/SKILL.md`. Mark updated with "local → remote".
      - Otherwise: delete temp file. Mark current.
4. Print a one-line summary: `updated N, current M, skipped K`, followed by any per-skill skip reasons.

Hard rules:
- Never overwrite a local SKILL.md with unvalidated content.
- Never delete a local SKILL.md, even on 404 or total failure.
- The atomic `mv` is the only write into `~/.claude/skills/**`. No partial or in-place edits.

Fetches are independent; run them in parallel to keep total latency small:
```bash
for name in "${names[@]}"; do
  (curl -sfm 10 -o "$TMP/skill-$name.md" "https://api.vibetracer.xyz/sdk/swift/skills/$name/SKILL.md") &
done
wait
```
Then do validation + mv sequentially (validation is cheap, and sequential reporting is clearer).
````

**Step 2: Register the route in `Router.tsx`.**

Add a new top-level route at the same level as `/login` and `/signup`, but **without** a layout wrapper (the page renders its own chrome):

```tsx
// import
import { SkillsUpdatePage } from '@/pages/SkillsUpdatePage'

// route (sibling to /login, /signup)
{
  path: '/skills/update',
  element: <SkillsUpdatePage />,
},
```

**Step 3: Cross-link from the Install page.**

Add a single muted line at the bottom of `apps/web/src/pages/InstallPage.tsx`:

```
Already installed? Update to the latest skills at /skills/update.
```

This is the backstop for users whose skills never notice a new version (proxy outage, network filtering, etc.) — they can still find the update page without an in-agent notice.

**Step 4: Verify.**

- Run `pnpm --filter @vibe-tracer/web dev`
- Visit `http://localhost:5173/skills/update` — page renders without auth redirect, no marketing hero leaking through.
- Click Copy — clipboard contains the prompt exactly as shown.
- Narrow viewport (≤640px) — `<pre>` block scrolls horizontally without overflowing the viewport; header does not wrap awkwardly.
- Visit `/projects/<slug>/install` (logged in) — cross-link at bottom points to `/skills/update`.

**Step 5: Commit (monorepo).**

```bash
cd /Users/dev/Documents/dev/next-studio/vibe-tracer
git add apps/web/src/pages/SkillsUpdatePage.tsx apps/web/src/Router.tsx apps/web/src/pages/InstallPage.tsx
git commit -m "feat(web): add /skills/update page with copy-paste update prompt"
```

---

## Task 4: CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md` (in SDK repo)

**Step 1: Add v2.0.1 section at the top.**

```markdown
## v2.0.1 — 2026-04-21

### Added

- **Per-skill version field** (`version: YYYY-MM-DD` in each SKILL.md frontmatter) so agents can detect out-of-date installs.
- **End-of-run version check** in all 5 skills. If a newer version is available, the agent prints a single italic notice pointing to `https://vibetracer.xyz/skills/update`.
- **`/skills/update` page** with a copy-paste prompt that atomically upgrades all installed `vibe-tracer-swift-*` skills. Validates frontmatter before overwriting; failed fetches leave local files untouched.
- **Cross-link** from the dashboard Install page to `/skills/update` so users can find the updater without relying on the in-agent notice.

### Notes

- Existing v2.0.0 installs do NOT have the version-check section — they must be updated once (via the prompt at `/skills/update`) to start receiving notices. After that, updates are detected automatically at the end of the next relevant session.
```

**Step 2: Commit and tag.**

```bash
cd vibetracer-sdk-swift
git add CHANGELOG.md
git commit -m "docs: changelog v2.0.1"
git tag v2.0.1
git push && git push --tags
```

---

## Task 5a: Pre-commit hook for version-bump discipline

**Files:**
- Create: `scripts/check-version-bump.sh`
- Create: `.githooks/pre-commit`
- Modify: repo root `package.json` (or `Makefile` / a README note) to install the hook via `git config core.hooksPath .githooks`

**Step 1: `scripts/check-version-bump.sh`.**

```bash
#!/usr/bin/env bash
# Fail the commit if any skills/vibe-tracer-swift-*/SKILL.md is staged
# but its `version:` frontmatter line is not today's date.
set -euo pipefail

today="$(date -u +%Y-%m-%d)"
fail=0

while IFS= read -r file; do
  [ -z "$file" ] && continue
  staged_version="$(git show ":$file" | awk '/^version: / {print $2; exit}')"
  if [ "$staged_version" != "$today" ]; then
    echo "error: $file has version '$staged_version' but today is $today." >&2
    echo "  Bump the frontmatter: sed -i '' 's/^version: .*/version: $today/' '$file'" >&2
    fail=1
  fi
done < <(git diff --cached --name-only --diff-filter=ACMR | grep -E '^skills/vibe-tracer-swift-[^/]+/SKILL\.md$' || true)

exit $fail
```

**Step 2: `.githooks/pre-commit`.**

```bash
#!/usr/bin/env bash
exec bash scripts/check-version-bump.sh
```

Make both executable: `chmod +x scripts/check-version-bump.sh .githooks/pre-commit`.

**Step 3: Install the hook path.**

```bash
git config core.hooksPath .githooks
```

Document in README how new contributors activate it. Note: `core.hooksPath` is per-clone; setting it in-repo does not propagate. A bootstrap script (`scripts/setup-dev.sh`) is the clean fix — out of scope for this task, but capture as a follow-up if hook coverage matters more.

**Step 4: Verify.**

- Edit `skills/vibe-tracer-swift-events/SKILL.md` (add a trailing newline, stage, commit). Expect the hook to pass because the version line matches today.
- Stage a version line with yesterday's date. Expect the hook to print the error with the exact `sed` fix and exit non-zero.
- Staging changes to non-skill files: hook is silent.

**Step 5: Commit.**

```bash
git add scripts/check-version-bump.sh .githooks/pre-commit
git commit -m "build: pre-commit hook for skill version-bump discipline"
```

---

## Task 5b: Sync check for duplicated "Keeping this skill current" section

**Files:**
- Modify: `scripts/check-version-bump.sh` (extend) OR create `scripts/check-skill-sync.sh`

**Rationale:** The same ~15-line block appears in all 5 SKILL.md files (option A in the pattern tension above). A commit-time check that they stay byte-identical (modulo the `<name>` substitution) is the cheap way to prevent silent drift.

**Step 1: Extract the canonical section text to `scripts/.skill-version-check.template.md`** (one file, with `__NAME__` placeholder where each skill's name goes).

**Step 2: Add a check.**

```bash
# scripts/check-skill-sync.sh
set -euo pipefail

tmpl="$(cat scripts/.skill-version-check.template.md)"
for f in skills/vibe-tracer-swift-*/SKILL.md; do
  name="$(basename "$(dirname "$f")")"
  expected="${tmpl//__NAME__/$name}"
  # Extract the "## Keeping this skill current" section from f
  actual="$(awk '/^## Keeping this skill current/{flag=1} /^## Transparency/{flag=0} flag' "$f")"
  if [ "$actual" != "$expected" ]; then
    echo "error: $f 'Keeping this skill current' section is out of sync with template." >&2
    exit 1
  fi
done
```

**Step 3: Chain from `.githooks/pre-commit`.**

```bash
#!/usr/bin/env bash
set -e
exec bash scripts/check-version-bump.sh
bash scripts/check-skill-sync.sh
```

**Step 4: Verify.**

- Edit one skill's "Keeping this skill current" section only. Stage. Commit. Expect hook failure.
- Edit the template and regenerate all 5 sections in sync. Commit. Expect hook pass.

**Step 5: Commit.**

```bash
git add scripts/.skill-version-check.template.md scripts/check-skill-sync.sh .githooks/pre-commit
git commit -m "build: pre-commit check that per-skill version-check sections stay in sync"
```

---

## Verification (end-to-end)

After all tasks, walk this to confirm the feature works:

1. From a clean `~/.claude/skills/vibe-tracer-swift-events/` install (pre-v2.0.1), run an event-design task. Expected: no notice (old skill, no checker). This is the one-time transition.
2. Visit `vibetracer.xyz/skills/update`, copy prompt, paste into Claude Code. Agent fetches all 5, validates, atomic-mv's each. Reports `updated 5, current 0, skipped 0`. `ls -la ~/.claude/skills/vibe-tracer-swift-*/SKILL.md` shows new mtimes.
3. Run another event-design task. At end, agent runs the curl+awk, gets a date, compares to its own `version:`, finds them equal, stays silent.
4. Bump `skills/vibe-tracer-swift-events/SKILL.md` `version:` to `2026-04-22` and deploy. Run an event-design task. At end, agent prints:
   > _A newer `vibe-tracer-swift-events` skill is available — paste the prompt at https://vibetracer.xyz/skills/update to update._
5. Paste the prompt. Expected: `updated 1, current 4, skipped 0`. Events skill is now `2026-04-22`.
6. Simulate a failure: block `https://api.vibetracer.xyz/sdk/swift/skills/vibe-tracer-swift-debug/SKILL.md` at the network level (`/etc/hosts` hack or firewall rule). Paste the prompt. Expected: `updated 0, current 4, skipped 1` with reason `fetch failed`. Local debug SKILL.md's mtime is unchanged.
7. Simulate a bad-content response (serve JSON error body at 200). Paste the prompt. Expected: `skipped 1` with reason `invalid content`. Local file untouched.
8. Make a whitespace-only edit to a skill and try to commit without bumping `version:`. Expected: pre-commit hook fails with the exact `sed` remediation line.

---

## Related

- Design doc parent: `docs/plans/2026-04-21-skill-pack-v2.md`
- Parked phase-2 skills: `docs/todos/2026-04-21-skill-pack-phase-2.md`
- Alternative rejected: Claude Code plugin/marketplace distribution. Would give this for free via native plugin system (how `obra/superpowers` does it) but requires building a plugin manifest + marketplace listing. Phase-3 candidate; track separately if skills stabilize and a plugin-distribution push becomes warranted.
