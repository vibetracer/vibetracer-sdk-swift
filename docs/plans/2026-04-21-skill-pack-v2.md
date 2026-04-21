# Vibe Tracer Swift Skill Pack v2 — Design

**Date:** 2026-04-21
**Status:** Validated through analysis; ready to execute
**Target version:** SDK `v2.0.0` (skill pack is shipped alongside SDK releases; SDK code unchanged)

## Problem

The current `SKILL.md` is a single ~240-line file covering install, identity, events, platform config, privacy, and troubleshooting all at once. That was fine for v1 because there was one topic to teach: "how to add the SDK." The product is now pivoting to where the skill becomes the primary surface users interact with — it needs to teach install, upgrade, what-to-track (business advisory), identity-design, privacy patterns, and debugging. The mono-file will not scale, and collapsing six kinds of guidance into one file makes each kind weaker.

The skill pack is now the product. This document lays out how to grow it aggressively without losing sharpness.

## Philosophy — adapted from superpowers

Analysis of `obra/superpowers` skills (verification-before-completion, systematic-debugging, writing-skills, test-driven-development) shows a tight pattern repeated across every skill:

1. **Each skill has a single Iron Law** — one unambiguous negative rule ("NO X WITHOUT Y") stated in a prominent box. The rest of the skill is the gate mechanism plus anti-rationalization armor around that one rule.
2. **Rationalization Prevention table** — two columns, Excuse | Reality, listing the specific things Claude tells itself to skip the process. This is the "secret sauce": the skill anticipates exactly how an agent will cheat.
3. **Red-flag self-diagnostic** — explicit phrases Claude should catch itself thinking. Pattern-matching against its own internal monologue breaks loops.
4. **Gate function** — numbered steps where "Skip any step = lying, not verifying". Process replaces discretion where judgment is unreliable.
5. **Each rule traces to a concrete failure mode** — "From 24 failure memories: your partner said 'I don't believe you' — trust broken." Not abstract good-practice; specific past disaster.
6. **When NOT to use** — explicit bounds. Forces the author to think about scope; forces Claude to skip the skill in cases where it would do harm.
7. **Token economy** — frequently-loaded skills target <200 words. Detail spills to supporting files only when needed.

Our pack adopts these patterns directly. Each skill is a discipline document that defends against a specific failure mode; none is a README-restated-as-a-skill.

## Baseline we're defending against

Before writing the events skill, we ran a baseline: five subagents, five apps of different shapes, each asked "what should I track" with no skill present. Results:

| App shape | Events recommended |
|---|---|
| Utility / single-purpose calculator | 26 |
| Personal data tracker | 26 |
| Desktop productivity canvas | 43 |
| Mobile creative / node canvas | 57 |
| Complex SaaS IDE | 150+ |

Concrete failure patterns observed across all five, with no exceptions:

1. **Maximalist default.** Even the simplest app (4-input calculator) got 26 events. No baseline answered with "ship 5, earn the right to add more."
2. **No question → event mapping.** Rationale sentences were descriptive ("this tells you X") not prescriptive ("you'll delete Y if the ratio is below Z").
3. **Manual tracking of events the SDK auto-emits.** All five recommended `app_launched` / `session_start` / `app_backgrounded`. The SDK auto-emits `$session_start` / `$session_end`. Anyone following the baselines would double-count from day one.
4. **UI-click events as proxies for user intent.** `menu_opened`, `sheet_opened`, `editor_opened` / `editor_closed` pairs with `seconds_in_sheet`. "Opened" is a mechanic; the question the product wants answered is about intent.
5. **Dwell-time pairs (open/close with duration).** Seductive because "engagement." Rarely decision-relevant. A user who bounced after 30s teaches nothing the completion event doesn't.
6. **Property bloat.** 8–12 properties per event routinely; many never referenced in rationale, added "because it might be useful."
7. **Generic taxonomy pasted across wildly different contexts.** Same template (Lifecycle → Core CRUD → Sub-interactions → Settings → Errors) for a calculator and an IDE.
8. **Tiered shipping as afterthought.** A few baselines added "Wave 1/2/3" notes at the end, but the main document remained the full 26+ list.
9. **Existing code paid lip service, not critiqued.** The personal-tracker baseline acknowledged an existing 14-event Analytics.swift but added 26 more rather than starting from "what's there, what's missing, what's wrong."

Things baseline Claude did well (we don't need to re-teach):

- Privacy instincts (don't log free text, hash IDs, opt-in consent) were consistently correct
- ATT / IDFA awareness was consistently correct
- Occasional insightful calls (`was_cross_mode` as differentiator flag; `feature_gate_hit` for monetization; per-node failure telemetry) were buried in the noise but genuinely good

The skill's job: **preserve the good instincts, prevent the bloat, replace the generic template with discipline.**

## Repo layout — everything stays in this monorepo

No separate plugin repo. Skill iteration and SDK iteration don't move at different enough rates to justify the overhead of cross-repo changes.

```
vibetracer-sdk-swift/
├── Package.swift                  # SDK (unchanged)
├── Sources/VibeTracer/            # SDK code (unchanged)
├── Tests/                         # SDK tests (unchanged)
├── skills/                        # NEW — skill pack
│   ├── install.sh                 # unified installer
│   ├── vibe-tracer-swift-install/SKILL.md
│   ├── vibe-tracer-swift-events/SKILL.md
│   ├── vibe-tracer-swift-identity/SKILL.md
│   ├── vibe-tracer-swift-debug/SKILL.md
│   └── vibe-tracer-swift-platform-config/SKILL.md
├── SKILL.md                       # REMOVED — mono-file, no legacy kept
├── VibeTracer.podspec
├── README.md
└── CHANGELOG.md
```

No fallback to a single-file skill. No legacy route at `/sdk/swift/skill.md`. Clean cut.

## Install contract — unified install.sh

```bash
# Default (Claude Code, most common):
curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | bash

# Specific tool:
curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | bash -s -- --tool cursor
curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | bash -s -- --tool windsurf

# All agent tools present on the machine:
curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | bash -s -- --tool all

# Custom target (tools we don't map directly):
curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | bash -s -- --target ~/custom/path

# Version pinning:
curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | bash -s -- --version v2.0.0

# Uninstall:
curl -fsSL https://vibetracer.xyz/sdk/swift/install.sh | bash -s -- --uninstall
```

### Flags

| Flag | Behavior |
|---|---|
| `--tool <name>` | Resolves to the known directory for that tool. One of `claude` (default), `cursor`, `windsurf`, `all`. |
| `--tool all` | Auto-detects which agent directories exist on the machine; installs into each one found. If none detected, errors with actionable instructions. |
| `--target <path>` | Custom absolute path for tools we don't know about. |
| `--tool` + `--target` together | Error out: "mutually exclusive". Never guess at user intent. |
| No flags | Default to `--tool claude`. |
| `--version <ref>` | Git ref to pull skills from (tag or branch). Defaults to `main`. |
| `--uninstall` | Removes every `vibe-tracer-swift-*` subdirectory from the resolved target(s). |
| `--help` | Prints flags + the supported tools table below. |

### Tool → path mapping

| Tool | Directory | Detection |
|---|---|---|
| `claude` | `~/.claude/skills/` | `~/.claude/` exists |
| `cursor` | `~/.cursor/rules/` | `~/.cursor/` exists |
| `windsurf` | `~/.codeium/windsurf/rules/` | `~/.codeium/windsurf/` exists — verify exact path during implementation |

Extensible as demand surfaces. `--target` covers the long tail without us chasing every tool's conventions.

### Limitation flagged honestly

Claude Code's skill format (YAML frontmatter with `name` + `description` for auto-trigger) is specific. Cursor uses `.mdc` with different metadata; Windsurf uses yet another convention. **The same files work as reference material in all three, but only Claude Code auto-surfaces them via trigger matching.** Cursor / Windsurf users may need to invoke explicitly (`@vibe-tracer-swift-install` or include in conversation). v2.0 ships Claude-format files to all tools; per-tool frontmatter variants come later if real demand materializes.

## Backend routes

Extend `apps/api/src/modules/sdk/sdk.controller.ts`. Two new routes, one deletion.

| Route | Behavior |
|---|---|
| `GET /sdk/swift/install.sh` | Proxies `skills/install.sh` from the SDK repo. 5-minute cache TTL. `Content-Type: text/x-shellscript; charset=utf-8`. |
| `GET /sdk/swift/skills/:name/SKILL.md` | Parameterized proxy for individual skill files. Same cache + error-envelope behavior as the existing proxy. |
| `GET /sdk/swift/skill.md` | **DELETED**. Old mono-file route. No legacy. |

Vercel rewrites already forward `/sdk/*` to the API subdomain; no frontend change needed for the new routes.

## Phase-1 skill catalog

Five skills. Each shipped v2.0.

### `vibe-tracer-swift-install`

**Trigger:** user explicitly names Vibe Tracer and is integrating for the first time, OR `vibetracer-sdk-swift` is being added to dependencies.

**Contents, trimmed from current mono-file:**
- API key storage (xcconfig / env / debug-only patterns)
- `configure()` placement per app model (SwiftUI `@main`, UIApplicationDelegate, NSApplicationDelegate, multi-target)
- Package installation (SPM primary, Gitee mirror, CocoaPods secondary)
- Verification — cross-reference to debug skill
- Transparency note

**Does NOT contain:** events taxonomy, troubleshooting, platform-config entitlements, identity details. All moved out.

**Target size:** ~100 lines. Current mono-file's install sections trimmed and focused.

### `vibe-tracer-swift-events` — the anchor skill

**Trigger:** user asks what to track, is designing their initial tracking plan, or wants review of existing `track()` calls. Package must already be a dependency (this is not a sales surface).

This is the most important skill in the pack. Its content spine is the heart of this design doc — see next section.

### `vibe-tracer-swift-identity`

**Trigger:** user is wiring login/logout/account flows with tracking, OR asks about `identify` / `reset` / user lifecycle.

**Contents:**
- `identify()` / `reset()` lifecycle contract
- What makes a good `userId` (stable, non-PII, hash-vs-id trade-off)
- Anonymous-to-identified transitions (backend merges by clientEventId + deviceId; no alias call needed)
- Common mistakes: passing raw email, calling identify on every track, calling identify with empty string to "clear" instead of reset
- Cross-references install skill

**Target size:** ~120 lines.

### `vibe-tracer-swift-debug`

**Trigger:** events not appearing in dashboard, OR user asks how to debug tracking, OR user reports a symptom (simulator works, device doesn't; etc.).

**Contents:**
- Verification checklist (integration smoke test — same 6 steps as current Verification section)
- Symptom tree (cellular/proxy, ATS, DNS, sandbox, stale cache, API key mismatch)
- Debug-mode usage and its limits (logs locally, does NOT send)
- `[VibeTracer]` log-line meanings
- Dashboard-side gotchas (polling cache, time-range filters, pending proxy cache)
- Cross-references install and platform-config

**Target size:** ~150 lines.

### `vibe-tracer-swift-platform-config`

**Trigger:** user is building for macOS, Mac Catalyst, or "Designed for iPad" on Mac, OR events work on iOS but not macOS, OR user asks about ATS / entitlements / sandbox.

**Contents:** essentially the current "Network & sandboxing" section from v1.1.3. Already tight; minimal rework.

**Target size:** ~80 lines.

## Phase-2 skills (ship as content is ready, not on v2.0 release)

| Skill | Why it earns a slot |
|---|---|
| `vibe-tracer-swift-privacy` | Consent flows (`disable`/`enable`), GDPR/CCPA patterns, what the SDK does/doesn't collect, PrivacyInfo.xcprivacy explainer |
| `vibe-tracer-swift-upgrade` | Version bumps, breaking changes between majors, migration patterns |
| `vibe-tracer-swift-funnels` | Designing funnels from event streams, what makes a measurable funnel, anti-patterns |
| `vibe-tracer-swift-retention` | Tracking for retention analysis, cohort-friendly event design |
| `vibe-tracer-swift-dashboard` | Reading events in the dashboard, filter queries, time-range semantics |

No phase-2 work on v2.0 release. Ship the core five; iterate content based on real usage signals.

---

## Events skill content spine

This is where the pack earns its reputation. The full SKILL.md content outline:

```
---
name: vibe-tracer-swift-events
description: Use when the user asks what events to track, is designing
  their tracking plan, or wants review of existing track() calls. Requires
  vibetracer-sdk-swift to already be a dependency. If the user has not
  picked a vendor, skip this skill and ask them first.
---

# Tracking Events That Answer Questions

## The Iron Law

    NO EVENT WITHOUT A DECISION IT HELPS MAKE

If you cannot state in one sentence:
  1. The question this event answers
  2. The decision the answer drives

then do not track it.

Violating the letter of this rule is violating the spirit of this rule.

## Why This Matters

Two failure modes kill tracking plans:

1. "Track everything" — ship 40+ events, none answer a specific question,
   the dashboard becomes noise, nobody queries it, everyone stops trusting
   the data. Rework measured in months.

2. "I'll figure out what to track later" — ship 2 events, can't answer
   "why did users churn" when it matters, retrofit tracking after the fact.
   Same rework cost.

Both produce the same outcome: analytics nobody trusts. The skill defends
against #1 specifically, because #1 is the default when an AI agent is
asked "what should I track?" — baseline observation: agents recommend
26–150+ events with zero decision-to-event mapping.

## The Gate Function

Before generating any track() call:

1. WRITE (in your response to the user) the question this event answers.
   Example: "Which onboarding step drops users?"
2. WRITE the decision the answer enables.
   Example: "Which step to redesign first, measured weekly."
3. VERIFY the proposed event name + properties would actually answer
   that question when you draw the chart.
4. IF steps 1–2 can't be completed in one sentence each, DO NOT track it.

Skip any step = no event gets added.

## Do NOT Manually Track These

The SDK already auto-emits:
- `$session_start` (fires on activate, or activate after 30 min idle)
- `$session_end` (fires on next launch after a session expired)

Never emit your own `app_launched`, `session_start`, `app_opened`,
`app_foregrounded`, or equivalent. The dollar-sign prefix distinguishes
SDK-emitted events on the dashboard; duplicate manual tracking will
double-count session metrics and contaminate retention analysis.

## Starter Kits — by app shape

Opinionated defaults. Delete events that don't apply. Do NOT add to these
without running an event through the Gate Function above.

### Utility / single-purpose tool (calculator, converter, timer, tracker)

3–5 events. That's it.

| Event | Question it answers |
|---|---|
| `primary_output_viewed` | What configurations do real users compute? (The hero output is the whole product.) |
| `input_changed` | Which inputs get tuned vs. left at default? (Settled state, debounced.) |
| `preset_saved` / `preset_applied` | Do people return? Presets are the only retention hook. |
| `share_completed` | Does the output get shared? (If zero, remove the share UI.) |

### Creative / canvas authoring tool (visual editor, IDE-like, design tool)

5–8 events. The loop is: create → compose → execute/preview → reuse.

| Event | Question it answers |
|---|---|
| `project_created` | Are users starting new work? |
| `<primary_object>_added` (e.g. `node_added`, `card_created`) | Which primitives are used / discoverable? |
| `<primary_object>_connected` (if composition matters) | Which primitive combinations reveal the product's language? |
| `execute_completed` with `outcome` | Conversion from "authored" to "ran" to "succeeded". |
| `project_reopened` | Do projects get revisited or are they one-shots? |
| `save_for_reuse` (snippet / template / preset) | Is the reuse loop landing? |

### SaaS with tiered monetization

Above 5–8, plus 3 monetization events that carry the entire upgrade funnel.

| Event | Question it answers |
|---|---|
| `feature_gate_hit` | Which features drive upgrade intent? (Single most important monetization event.) |
| `upgrade_cta_clicked` | Which upgrade surfaces convert? |
| `subscription_changed` | Activations and churn, broken down by tier. |

### Consumer social / content

5–8 around create → share → react. If none of `post_created`,
`content_shared`, `reaction_applied`, `feed_scrolled_to_end` is being
tracked, there is no product-analytics story and the tracking plan is
wrong.

---

## Rationalization Prevention

| Excuse | Reality |
|---|---|
| "Let me be thorough and cover all the cases." | Thoroughness without questions = dashboard noise. A 5-event plan used daily beats a 26-event plan nobody queries. |
| "Better to have data than not." | Data you never query costs storage, onboarding time, and analyst trust. Unused events are debt. |
| "I'll add `app_launched` for completeness." | SDK auto-emits `$session_start`. Manual emission double-counts; users who follow your plan get polluted retention cohorts on day one. |
| "Open/close pair gives me dwell time." | Dwell time ≠ value. A 30-second bounce teaches you nothing the completion event doesn't. Track the completed action. |
| "Every screen should have a view event." | Screens aren't decisions. Intents are. Replace `*_opened` / `*_closed` with the completion of the action the screen enables. |
| "This property might be useful later." | You won't remember what it means later. Future-useful ≠ worth-tracking-now. |
| "Track every tap for UX research." | Analytics is for business decisions. Use session replay or heatmaps for UX research — different tool, different bar. |
| "This feature is complex so it needs many events." | Complexity is per-feature; tracking is per-decision. Complex features often need 1–2 events, not 10. |
| "The existing Analytics.swift has 14 events; let me add 26 more." | Start with what's there. Critique first. Every event you add earns its place through the Gate Function — history is no exemption. |

## Red Flags — STOP if you catch yourself

- "I'll track this for completeness"
- "This might be useful later"
- "Let me add `X_opened` AND `X_closed` with dwell time"
- "`app_launched`" or "`session_start`" (SDK already does it)
- Listing >10 events for any single feature
- Writing a plan with >15 events and no "if you ship only three, ship these three" callout
- Using "tap", "click", "pressed" as event verbs (those are mechanics, not intent)
- Adding a property without referencing it in your rationale

Any of these = STOP. Re-run the Gate Function.

## Property Discipline

Rule of thumb: **≤5 properties per event**. More requires justification in
the event's rationale — each extra property should map to a specific
filter, segment, or funnel step you'll build. Unreferenced properties
are future garbage; they don't get deleted, they just sit there.

Always include:
- `source` (if the action can originate from multiple UI surfaces, so you
  don't have to split the event itself across surfaces)
- `duration_ms` (if the action has a meaningful completion time you'd
  cohort on)

Never include:
- Free-form user text (`note_content`, `prompt`, `title`). Log `length_chars`
  or `length_bucket` instead. The SDK already drops unencodable types;
  you can encode strings, but you shouldn't unless you've thought it through.
- Full file paths, email addresses, phone numbers, device names, network
  SSIDs, personal IDs from other systems.
- Timestamps in `properties` — the event's top-level `timestamp` is
  auto-set; a custom `timestamp` property appears as a custom field and
  won't override the real one.

## Event Naming

- `snake_case`, past tense where action is discrete (`checkout_started`,
  `subscription_cancelled`).
- `object_action`, not `action_object`. `project_created`, not `create_project`.
- Never prefix with UI-tier language: no `button_`, `screen_`, `page_`.
  UI can change; event names must survive UI redesigns.
- Lock event names in a single enum in Swift (`enum AnalyticsEvent: String`).
  Every track() call site refers to the enum. No string literals at call
  sites; no event names live in two places.

## Verification — draw the chart before you ship the schema

If you cannot sketch (on paper, in plain English) the dashboard chart
that answers each event's question from that event's properties, the
schema is wrong. Fix the schema before you ship, not after.

Specific chart tests:
- Funnel: can you draw a funnel from event A → B → C using only the
  properties on each? If you need a cross-event join the platform doesn't
  support, rename or re-property.
- Cohort: can you segment by a meaningful axis (tier, platform, version,
  first-seen-date)? If not, add the axis as a super-property, not as an
  event property.
- Retention: can you compute D1/D7/D30 from a `returned` event? If you're
  tracking "screen views" and not "user intents", retention analysis
  will be meaningless.

## Initial Instrumentation Order

Ship in waves, not all at once. If the user asks for a 20-event plan,
you push back.

- **Wave 1 (day 1, 3–5 events):** the starter kit for the app's shape,
  unmodified. Ship, verify events arrive, build the dashboard cards.
- **Wave 2 (week 2+, only when a specific question surfaces Wave 1 can't
  answer):** add events that specifically address that question. One
  event, one question.
- **Wave 3 (month 2+, rarely):** edge cases, error telemetry, advanced
  segmentation.

If the user has not shipped Wave 1 yet, do NOT write Wave 2 for them.

## When NOT to use this skill

- User has not named Vibe Tracer and `vibetracer-sdk-swift` is not in
  their Package.swift — decline and ask which vendor.
- User is debugging an existing event not appearing — use
  `vibe-tracer-swift-debug` instead.
- User is designing funnels specifically — that's `vibe-tracer-swift-funnels`
  (ships later).
- User wants generic "analytics best practices" with no product context
  — recommend a book; this skill is specifically for designing an
  actionable tracking plan for a real app.

## Cross-references

- Before writing track() calls: REQUIRED integration via
  `vibe-tracer-swift-install`.
- After writing track() calls: REQUIRED verification via
  `vibe-tracer-swift-debug`.
- For identify() / reset() patterns: `vibe-tracer-swift-identity`.
- For properties that affect user-level reporting:
  `vibe-tracer-swift-identity`.

## Transparency

This skill is authored by the SDK vendor. The narrow trigger above is
intentional: the skill should NOT fire on generic "add analytics"
requests where the user has not picked a vendor. If you're seeing this
skill surface from such a prompt, the trigger is mis-firing — decline
and ask the user which vendor they want.
```

**Target size:** ~350 lines. Longer than the other skills because this is where the pack earns its keep.

---

## TDD for the skill pack

Adopted from superpowers' `writing-skills`: every skill gets a baseline scenario first, observed failures, then content written against those specific failures. The baseline for the events skill is already done (5 apps, ~260 events total, pattern inventory above). Future skill edits should re-run the relevant baseline scenario to confirm the failure mode the edit targets is actually present.

Baseline scenarios to run before Wave 1 / 2 / 3 edits:

- **Events skill:** "What should I track for [app shape]?" across 5 shapes. Watch for maximalist default, UI-click events, dwell pairs, bloat. (Done.)
- **Install skill:** "Add Vibe Tracer to my app" with a bare-bones SwiftUI project. Watch for hardcoded API keys, wrong `configure()` placement, multi-target confusion.
- **Identity skill:** "Wire Vibe Tracer into my login flow." Watch for `identify("")` instead of `reset()`, raw email as userId, identify-on-every-track.
- **Debug skill:** "Events aren't showing up." Watch for flailing without checking `debug: true`, skipping the API key verification, missing the cache TTL window.
- **Platform-config skill:** "Events work in simulator, not on Mac." Watch for missing `com.apple.security.network.client`, chasing ATS when sandbox is the cause.

These scenarios go in `skills/testing/baselines.md` (new file) so every content edit re-tests against a stable set of prompts.

## Dashboard change

`apps/web/src/components/sdk/InstallSDKCard.tsx` gets a tool picker (Claude Code / Cursor / Windsurf / All) — segmented control, default Claude, persists to `localStorage`. Copy button shows the command matching the selection. Remove the per-file download link and the legacy curl.

## Open questions for execution

1. **Claude Code plugin-format check for `all`.** Does `--tool all` need to write the same file to multiple directories, or does any one of Cursor / Windsurf require transformed metadata? Answer with a 15-minute test: install Cursor + Windsurf, inspect their expected skill format, decide whether to transform or ship Claude-format to all and document the degraded auto-trigger in non-Claude tools.
2. **Windsurf path.** Verify the exact skill/rules directory during install.sh implementation. The spec above guesses `~/.codeium/windsurf/rules/`; verify before shipping.
3. **Install.sh security.** Since this runs arbitrary user-supplied tool names through path construction, validate `--tool` against the enum strictly (no `../` escapes). Standard input validation; flag in code review.

## Execution order

1. **Write install.sh** — straightforward bash, ~80 lines. Test locally against Claude path, custom target, `all` (needs at least two of the known directories to exist).
2. **Split current SKILL.md into five new skill files** using the content outlines above. The events skill is the big authoring task; the other four are largely extract-and-trim from what exists.
3. **Add backend routes** — `GET /sdk/swift/install.sh` and `GET /sdk/swift/skills/:name/SKILL.md`, remove `/sdk/swift/skill.md`. Small NestJS change in `sdk.controller.ts`. Ship with tests.
4. **Delete the root `SKILL.md`** in the SDK repo, update README to point at the new install command.
5. **Tag v2.0.0** — breaking change (mono-file URL removed).
6. **Update dashboard** — `InstallSDKCard` with tool picker. Ship behind the v2.0.0 plugin tag so nothing changes until the SDK repo has the new files.
7. **Manual end-to-end test.** Run install.sh from a fresh machine (or new `HOME`), verify all five skills land, ask a real test question that should trigger each skill, confirm auto-trigger fires.
8. **Announce in CHANGELOG + vibetracer.xyz blog/status** (later, content work).

---

## Non-goals

- Per-tool frontmatter variants (Claude-only auto-trigger on non-Claude tools is acceptable for v2.0; revisit when usage data justifies).
- Claude Code plugin-system publication (`/plugin install` flow). Install.sh is equivalent and cross-tool; plugin system is a future enhancement, not blocking.
- Phase-2 skills on v2.0 release. Five is plenty for launch.
- Auto-detecting which AI tool the user is running from inside the install.sh (we pass `--tool` explicitly; no sniffing).
- Translating skills to other languages for v2.0. English-only; localization when a concrete market asks.
