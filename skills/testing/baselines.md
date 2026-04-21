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

**Last validated:** 2026-04-21. **Scenario:** `metastrip` (clean iOS-only app, no existing analytics). **Prompt:** user supplies a `vtr_live_...` key and says "just hardcode it for now".

**Predicted baseline failures (without skill):**

- Hardcoded live API key in source (accepts the user's "just hardcode it" ask)
- `configure()` placed inside `ContentView.init()` or `.onAppear` (View re-init hazard)
- Missing the xcconfig / `#if DEBUG` + Info.plist pattern
- Cluttering the response with irrelevant platform concerns (ATS, sandbox, CocoaPods)

**Validated signature (with skill loaded):** 5/5 compliance.

- Pushed back on "just hardcode it" → recommended Option 3 (`#if DEBUG` + Info.plist for Release) with the live key isolated behind the debug gate only.
- `configure()` placed in `App.init()` with explicit call-out on why View init is wrong.
- Recommended xcconfig setup now rather than deferred ("cheaper while integration is fresh than to retrofit before release") — took a stance with reason.
- Correctly skipped ATS / sandbox / CocoaPods as non-applicable for this iOS-only target.
- Ended with "OK to go with that?" stance rather than neutral A/B/C menu.

---

## Identity skill — `vibe-tracer-swift-identity`

**Last validated:** 2026-04-21. **Scenario:** user with a `User { id: UUID, email, displayName }` model asks: "what do I pass to `identify()` — UUID or email? where do I call it? what about logout?"

**Predicted baseline failures (without skill):**

- Recommending raw email as `userId` (PII leak)
- `identify("")` on logout instead of `reset()`
- Calling `identify()` on every `track()` or every launch (lifecycle-event misuse)
- Calling `identify()` before `configure()` (silent drop)

**Validated signature (with skill loaded):** 5/5 compliance.

- Recommended `user.id.uuidString` (the UUID) and flagged email as PII.
- Placed `identify()` inside `handleLogin` after login success, explicitly noted `configure()` must already have run, and that pre-`configure()` calls are dropped.
- Prescribed `reset()` on logout, explicitly called out `identify("")` as wrong.
- Said "call it once, here; not on every track, not on every cold start — SDK persists across launches."
- Took a stance on all three of the user's questions rather than listing options.

---

## Debug skill — `vibe-tracer-swift-debug`

**Last validated:** 2026-04-21. **Scenario:** user reports "events not in dashboard, I see `[debug] would send: app_started` in the console".

**Predicted baseline failures (without skill):**

- Flailing through unrelated hypotheses (network, ATS, sandbox, DNS) before checking the obvious
- Missing that `debug: true` means events are logged locally and NOT sent
- Skipping the API-key-matches-dashboard-key check
- Conflating SDK proxy cache (5-min TTL, unrelated) with event ingestion

**Validated signature (with skill loaded):** 5/5 compliance.

- First sentence: "that's `debug: true` doing exactly what it says on the tin." Root cause identified immediately from the user's own console output.
- Gave concrete fix: flip `debug: false` or drop the argument; rebuild; wait 5–10s.
- Relegated API-key / `/health` / time-range filter to a conditional fallback tail rather than leading with them.
- Did not mention ATS, DNS, sandbox, or proxy-cache — none applied here.
- Took a stance: "I'd bet the house this is just the debug flag."

---

## Platform-config skill — `vibe-tracer-swift-platform-config`

**Last validated:** 2026-04-21. **Scenario:** user reports "iOS + iPad works, Mac Catalyst silently drops events, same code".

**Predicted baseline failures (without skill):**

- Chasing ATS / TLS / DNS hypotheses before the sandbox entitlement
- Not knowing `com.apple.security.network.client` is the Catalyst-default-sandbox cause
- Recommending `NSAppTransportSecurity` exceptions (unnecessary)
- Recommending disabling App Sandbox entirely (loses Mac App Store eligibility)

**Validated signature (with skill loaded):** 6/6 compliance.

- Identified `com.apple.security.network.client` as the most likely cause in the first sentence, grounded in "Catalyst inherits iOS build but runs under macOS App Sandbox."
- Explicitly told the user to skip ATS / TLS / DNS / proxy — named as not-the-issue.
- Did not recommend relaxing ATS.
- Did not recommend disabling App Sandbox — called out the App Store eligibility cost.
- Pointed to the exact Xcode path: Target → Signing & Capabilities → App Sandbox → Network → Outgoing Connections (Client).
- Took a stance: "I'd do exactly that rather than disabling App Sandbox entirely… OK to go with that?"

---

## Adding a new skill

When authoring a new skill in this pack:

1. Add a section to this file with the baseline scenario prompt and expected failure signature.
2. Run the baseline scenario — record actual failures.
3. Write the skill against those specific failures.
4. Re-run the scenario with the skill loaded — record the validated signature.
5. Commit both this file and the new SKILL.md in the same change.
