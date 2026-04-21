# Skill Pack Baselines

TDD record for the `vibe-tracer-swift-*` skills. Following the superpowers `writing-skills` discipline: every skill is written against a baseline scenario where Claude (without the skill) fails in a specific way; skills exist to close those specific failure gaps. This file preserves those baseline scenarios and their failure signatures, so future edits can be regression-tested against a stable set of prompts.

## How to use this file

1. Pick the skill being edited.
2. Run the baseline scenario fresh in a subagent **without** pointing at the skill, capture the output.
3. Compare against "Baseline failure signature" below.
4. Write/edit the skill against the observed failure modes.
5. Re-run the scenario **with** the skill loaded as binding guidance.
6. Verify the output matches "Validated signature" below.

Baselines should be re-run periodically (or at least before major skill edits) since Claude's underlying behavior drifts across model versions.

---

## Events skill — `vibe-tracer-swift-events`

**Last run:** 2026-04-21.
**Purpose of this baseline:** verify the skill prevents event-count bloat, enforces question→event mapping, avoids manual duplication of SDK-auto-emitted session events, and respects app-shape starter-kit bounds.

### Scenario prompt (use verbatim per app)

> I'm about to add event analytics (something like Mixpanel or Amplitude) to my [iOS / web] app so I can understand how real users use it. Help me figure out what events I should track. The app is at `<ABSOLUTE_PATH>`. Please explore it enough to understand what it does, then give me a concrete list of events I should track — event names, what they mean, what properties to attach to each, and a one-sentence rationale for each. I want this thorough; I'm paying for your expertise.

### Apps used as validation set (5 total)

| Shape | Scale |
|---|---|
| Utility / single-purpose tool (finance calculator) | ~1000 LOC, 1 screen, SwiftUI |
| Personal data tracker (countdown/count-up utility with widgets) | ~15 kLOC, multi-scene, SwiftUI + WidgetKit |
| Desktop productivity canvas (spatial kanban) | ~30 kLOC, Metal-rendered canvas, AppKit/SwiftUI |
| Mobile creative / node canvas (on-device AI workflows) | ~50 kLOC, iPad-only, Metal + custom gestures |
| Complex web SaaS IDE (visual node-graph builder with tiered monetization) | ~100 kLOC, React, 15+ modules |

These five span the four starter-kit categories in the events skill (utility / creative canvas / SaaS with monetization / consumer social — though none of the set is primarily consumer social; add one later).

### Baseline failure signature — Claude WITHOUT the skill

Across all 5 apps, the unaided baseline consistently produced:

| Dimension | Baseline behavior |
|---|---|
| Event count | 26 (calculator), 26 (tracker), 43 (canvas), 57 (creative), 150+ (IDE) |
| Question→event mapping | 0% — no event carried an explicit "question / decision" pair |
| Manual `app_launched` / `session_start` | Present in 5/5 — would duplicate SDK auto-events |
| UI-chrome events (`*_opened` / `*_closed`) | Present in 5/5 — 4–10 per plan |
| Dwell-time pairs (open+close with `*_duration`) | Present in 5/5 |
| Property bloat (events with 8–12 properties) | Present in 4/5 |
| Generic taxonomy (same Lifecycle → CRUD → Settings → Errors template) | Present in 5/5, different nouns |
| Tiered shipping framing | Bolted on as afterthought in 2/5, absent in 3/5 |
| Existing code respected (when present) | 0/1 — added 26 new events on top of 13 existing without critique |
| "If you ship only three" callout | Absent in 5/5 |

**What baseline Claude got right (preserve, don't re-teach):**

- Privacy instincts (don't log free text, hash IDs, opt-in consent): 5/5 correct
- ATT / IDFA awareness (where relevant): 5/5 correct
- Occasional insightful per-app call-outs (e.g. `was_cross_mode` as product differentiator; `feature_gate_hit` for monetization): 3/5 had at least one — buried under the bloat

### Validated signature — Claude WITH the skill

Same 5 apps, same prompts, with this preamble added to each:

> FIRST, READ AND OBEY THIS SKILL FILE: `<path-to-skill>`. Read it in full. It is binding. Its Iron Law, Gate Function, Starter Kits, Rationalization Prevention table, Red Flags, Property Discipline, Event Naming, Verification, and Instrumentation Order apply to every decision. Violating the letter is violating the spirit.

Observed results:

| Dimension | Skill-applied behavior |
|---|---|
| Event count | 5 / 5 / 6 / 6 / 10 (SaaS: 7 product + 3 monetization) |
| Reduction vs baseline | 81% / 81% / 86% / 89% / 93% |
| Question→event mapping | 5/5 — every event has explicit Question + Decision |
| Manual `app_launched` etc | 0/5 — explicitly listed as rejected in every "did NOT recommend" |
| UI-chrome events | 0/5 — explicitly listed as rejected in every "did NOT recommend" |
| Dwell-time pairs | 0/5 |
| Property count ≤5 | 5/5 compliant |
| Shape-correct starter kit | 5/5 matched |
| Existing code critiqued first | 1/1 — cut 9 of 13 existing events after Gate Function review |
| "If ship only three" callout | 3/5 included unprompted |

### Refactor notes for future skill edits

Things the skill did NOT spell out but that agents derived correctly (could be explicitly added if agents regress):

1. **Discriminator-property consolidation.** One validation (desktop canvas) collapsed 5 feature events into one `<object>_depth_used` with a `feature` discriminator. This is the correct "one question, one event" behavior — if agents stop doing this, add an explicit Property-Discipline example.

2. **Cross-skill insight surfacing.** One validation flagged a configuration-level blocker (`#if DEBUG` gating analytics away from Release) that isn't strictly in the events-skill scope but blocks the whole tracking plan. This is desired emergent behavior — consider adding a "before Wave 1 data has meaning, verify production build emits" note that cross-references `vibe-tracer-swift-install`.

---

## Install skill — `vibe-tracer-swift-install`

**Baseline scenario to run (not yet executed):**

> Add Vibe Tracer to my app. (Bare-bones SwiftUI project, no analytics SDK yet.)

**Failure modes to watch:**

- Hardcoded API key in source (baseline tendency per 2025-era Claude behavior)
- `configure()` placed inside a View's `init()` instead of `App.init()`
- Missing the xcconfig pattern (defaults to "just hardcode it")
- Multi-target confusion (doesn't prompt user to clarify which targets to wire)

Run scenario when skill content changes materially.

---

## Identity skill — `vibe-tracer-swift-identity`

**Baseline scenario to run:**

> Wire Vibe Tracer into my login flow. (App with existing login; user asks to integrate.)

**Failure modes to watch:**

- `identify(userId: email)` — raw email as userId (PII leak)
- `identify("")` to "clear" on logout instead of `reset()`
- Calling `identify` on every `track()` call
- Calling `identify` before `configure()`

---

## Debug skill — `vibe-tracer-swift-debug`

**Baseline scenario to run:**

> Events aren't showing up in my Vibe Tracer dashboard. Help me figure out why.

**Failure modes to watch:**

- Flailing through unrelated hypotheses (check everything at once)
- Missing the `debug: true` local-only mode gotcha (enables logs, sends nothing — classic user confusion)
- Skipping the API-key-matches-dashboard-key verification (common cause)
- Conflating the SDK proxy cache (5-min TTL) with event ingestion

---

## Platform-config skill — `vibe-tracer-swift-platform-config`

**Baseline scenario to run:**

> Events work in the iOS simulator but not on Mac Catalyst. (Repro setup: app with Catalyst target, default entitlements.)

**Failure modes to watch:**

- Chasing ATS / TLS / DNS hypotheses before checking sandbox entitlement
- Not knowing `com.apple.security.network.client` is required for Catalyst
- Recommending ATS exception (`NSAppTransportSecurity`) when sandbox is the actual cause

---

## Adding a new skill

When authoring a new skill in this pack:

1. Add a section to this file with the baseline scenario prompt and expected failure signature.
2. Run the baseline scenario — record actual failures.
3. Write the skill against those specific failures.
4. Re-run the scenario with the skill loaded — record the validated signature.
5. Commit both this file and the new SKILL.md in the same change.
