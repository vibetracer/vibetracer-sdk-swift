---
name: vibe-tracer-swift-events
description: Use when the user asks what events to track, is designing their initial tracking plan, or wants review of existing track() calls in a Swift app that has `vibetracer-sdk-swift` as a dependency. Do NOT use when the user has not picked an analytics vendor — decline and ask. Do NOT use as generic "analytics best practices" reference for other SDKs.
version: 2026-04-22
sdk-version: 2.2.0
---

# Tracking Events That Answer Questions

## Before anything else — SDK version check

This skill shares a drift gate with every other `vibe-tracer-swift-*` skill. Run it at the top of every invocation — the gate is cheap (idempotent, ~100ms when not behind) and prevents you from advising on symbols the user's build does not have.

1. Locate the user's `.xcodeproj` (ask if none obvious, multiple, or ambiguous).
2. Run the upgrade script colocated with the install skill:
   ```bash
   <skills-root>/vibe-tracer-swift-install/scripts/upgrade.sh <project-root> <target>
   ```
   `<skills-root>` is the parent of this SKILL.md's containing directory — e.g. `~/.claude/skills`, `~/.cursor/rules`, `~/.codex/skills`, depending on the agent tool.
3. If it prints `✓ Already on …`, continue to this skill's workflow.
4. Otherwise it bumped the pin and emitted CHANGELOG migration notes:
   - **Every section is `None.`** → tell the user "bumped VibeTracer to `<current>`, no migrations needed" and continue.
   - **Any section is not `None.`** → walk the user through the call-site edits **before** continuing. A symbol the user was asking about may have been renamed or removed between their pinned version and `<current>`.

This is a gate, not a notice. If the user's project is pinned to 2.0.1 and asks about `trackDebounced` (added in 2.1.0), there is no truthful answer without bumping first.

## The Iron Law

```
NO EVENT WITHOUT A DECISION IT HELPS MAKE
```

If you cannot state in one sentence:

1. The **question** this event answers
2. The **decision** the answer drives

then do not track it.

**Violating the letter of this rule is violating the spirit of this rule.**

## Why This Matters

Two failure modes kill tracking plans:

1. **"Track everything."** Ship 40+ events, none answer a specific question, dashboard becomes noise, nobody queries it, everyone stops trusting the data.
2. **"I'll figure it out later."** Ship 2 events, can't answer "why did users churn" when it matters, retrofit tracking after the fact.

Both produce the same outcome: analytics nobody trusts. Rework measured in months.

This skill defends against failure #1 specifically. Baseline observation: when asked "what should I track?" without this skill, AI agents default to 26–150+ events per app with **zero** decision-to-event mapping. That is the behavior you must prevent in yourself.

## The Gate Function

Before generating any `VibeTracer.track(...)` call:

1. **WRITE** (in your response to the user) the question this event answers.
   *Example: "Which onboarding step drops users?"*
2. **WRITE** the decision the answer enables.
   *Example: "Which step to redesign first, measured weekly."*
3. **VERIFY** the proposed event name + properties would actually answer that question when the user draws the chart (see Verification below).
4. **IF** steps 1–2 can't be completed in one crisp sentence each, **DO NOT** add the track call.

Skip any step = no event gets added.

## Do NOT Manually Track These

The SDK already auto-emits:

- `$session_start` — fires on app activate, or activate after 30 min idle
- `$session_end` — fires on the next launch after a session expired

The `$` prefix distinguishes SDK-emitted events on the dashboard. **Never** emit your own:

- `app_launched`, `app_opened`, `app_foregrounded`, `app_backgrounded`
- `session_start`, `session_end`, `session_resumed`
- Any equivalent with a different verb

Duplicate manual tracking will double-count session metrics and contaminate retention cohorts.

If you catch yourself writing one of these, delete it.

## Starter Kits — by app shape

Opinionated defaults per common app shape. **Use them as starter kits:** ship the ones that apply, delete those that don't, and add new events only by running each through the Gate Function above. Do NOT exceed the starter kit's event count without a specific question the kit can't answer.

### Utility / single-purpose tool

Calculator, converter, timer, counter, reference lookup — apps where one hero output is the whole product.

**3–5 events. That's it.**

| Event | Question it answers |
|---|---|
| `primary_output_viewed` | What configurations do real users compute? The output itself is the product — its distribution is the whole usage story. |
| `input_changed` | Which inputs get tuned vs. left at default? Use `trackDebounced()` — this is the canonical settled-state case; see "Call shape" below. |
| `preset_saved` / `preset_applied` | Do people return? For a utility app, saving a preset is the only retention hook. |
| `share_completed` | Does the output get shared? If zero after launch, remove the share UI. |

Example properties: `input_method` (one of the specific inputs), `value_bucket` (bucketed, never raw PII), `output_category` (if multiple output types).

### Creative / canvas authoring tool

Visual editor, node graph, design tool, drawing app, IDE-like app — anything where the user composes primitives into a larger artifact.

**5–8 events.** The product loop is: *create → compose → execute/preview → save for reuse*.

| Event | Question it answers |
|---|---|
| `project_created` | Are users starting new work? Top-of-funnel for creation. |
| `<primary>_added` (e.g. `node_added`, `card_created`, `layer_added`) | Which primitives are used / discoverable? Properties: the specific type. Tells you which primitives to promote, demote, or cut. |
| `<primary>_connected` (if composition is the product) | Which primitive combinations reveal the product's language? Properties: source type + target type. Reveals user mental model. |
| `execute_completed` with `outcome` | Conversion from "authored" to "ran" to "succeeded". `outcome` is `success` / `partial` / `error` / `canceled`. |
| `project_reopened` | Do projects get revisited, or are they one-shots? |
| `save_for_reuse` (snippet / template / preset / component) | Is the reuse loop landing? If zero, the feature should be deprioritized. |

Skip all UI-chrome events (`panel_opened`, `sidebar_toggled`, `menu_shown`). Those are mechanics, not product questions.

### SaaS with tiered monetization

The above creative/utility kits (whichever shape fits), **plus three monetization events** that carry the entire upgrade funnel.

| Event | Question it answers |
|---|---|
| `feature_gate_hit` | Which features drive upgrade intent? Single most important monetization event. Properties: `feature_id`, `required_tier`, `current_tier`. |
| `upgrade_cta_clicked` | Which upgrade surfaces actually convert? Properties: `source` (where in the app), `target_tier`. |
| `subscription_changed` | Activations and churn, broken down by tier. Properties: `from_tier`, `to_tier`, `change_type` (`activated` / `upgraded` / `downgraded` / `churned`). |

These three are enough to wire the full monetization funnel: *gate hit → CTA clicked → subscription changed*. Do not add more monetization events without a specific question they answer.

### Consumer social / content

Apps with a create → share → react loop.

**5–8 events** around the loop:

| Event | Question it answers |
|---|---|
| `post_created` | Is the creation side active? |
| `content_shared` | Is the product being distributed by users (viral coefficient input)? |
| `reaction_applied` | Is passive engagement present? |
| `feed_end_reached` | Is the consumption side running out of content? |

If **none** of these (or equivalents) are being tracked, there is no product-analytics story and the tracking plan is wrong. Start over.

---

## Rationalization Prevention

These are the specific excuses you will tell yourself to break the Iron Law. Recognize them. Reject them.

| Excuse | Reality |
|---|---|
| "Let me be thorough and cover all the cases." | Thoroughness without questions = dashboard noise. A 5-event plan used daily beats a 26-event plan nobody queries. |
| "Better to have data than not." | Data you never query costs storage, onboarding time, and analyst trust. Unused events are debt, not assets. |
| "I'll also add `app_launched` for completeness." | The SDK auto-emits `$session_start`. Manual duplication double-counts; users who follow your plan get polluted retention cohorts from day one. |
| "Open/close pair gives me dwell time." | Dwell time ≠ value. A 30-second bounce teaches you nothing the completion event doesn't. Track the completed action, not the inspection. |
| "Every screen should have a view event." | Screens aren't decisions. Intents are. Replace `*_opened` / `*_closed` with the completion of the action the screen enables. |
| "This property might be useful later." | You won't remember what it means later. You won't name it right now. Future-useful ≠ worth-tracking-now. |
| "Track every tap for UX research." | Analytics is for business decisions. Use session replay or heatmaps for UX research — different tool, different bar. Don't pollute analytics with UX telemetry. |
| "This feature is complex, so it needs many events." | Complexity is per-feature; tracking is per-decision. Complex features often need 1–2 events, not 10. |
| "The existing Analytics.swift has 14 events; let me add 26 more." | Start with what exists. Critique first. Every event you add earns its place through the Gate Function. History is no exemption. |

## Red Flags — STOP if you catch yourself

If any of these surface in your head while designing the plan, **stop and re-run the Gate Function**:

- "I'll track this for completeness"
- "This might be useful later"
- "Let me add `X_opened` AND `X_closed` with dwell time"
- Writing `app_launched` or `session_start` (SDK does it)
- Listing more than 10 events for any single feature
- Writing a plan with more than 15 events total and no "if you ship only three, ship these three" callout
- Using "tap", "click", "pressed", "viewed" as event verbs (those are mechanics, not intent)
- Adding a property without referencing it in your rationale
- Producing a plan that could have been written about any other app with minor noun swaps

Any one of these = STOP. The plan is going maximalist. Re-run the Gate Function and cut ruthlessly.

## Property Discipline

Rule of thumb: **≤5 properties per event**. More requires explicit justification — each extra property must map to a specific filter, segment, or funnel step you will actually build. Unreferenced properties are future garbage; they don't get deleted, they just sit there.

**Always include when applicable:**

- `source` — if the action can originate from multiple UI surfaces, carry this as a property rather than splitting the event itself across surfaces. Lets you redesign the UI without breaking historical charts.
- `duration_ms` — only if completion time is meaningfully cohort-able. Not for "time spent on screen" unless that directly drives a decision.

**Never include:**

- **Free-form user text** (`note_content`, `prompt_text`, `title`, `notes`). Log `length_chars` or `length_bucket` instead.
- **PII that isn't already in the user identity**: file paths, email addresses, phone numbers, device names, network SSIDs, contact names, personal IDs from other systems.
- **A custom `timestamp` property.** The event's top-level timestamp is auto-set; a property named `timestamp` will appear as a custom field and won't override the real one.
- **A custom `userId`, `deviceId`, or `sessionId` property.** Same reason. Those are attached automatically.
- **Indexed-for-nothing-in-particular fields.** If you can't name the chart it enables, don't add it.

**Prefer:** counts, categories, buckets, booleans, enum strings, hashed IDs.

## Event Naming

- `snake_case`, past tense where the action is discrete (`checkout_started`, `subscription_cancelled`).
- **`object_action`, not `action_object`**: `project_created`, not `create_project`. This groups events by object in any dashboard's sorted list.
- **Never prefix with UI-tier language**: no `button_*`, `screen_*`, `page_*`, `tap_*`, `click_*`. UI can change; event names must survive UI redesigns.
- Lock event names in a single Swift enum:

   ```swift
   enum AnalyticsEvent: String {
       case projectCreated = "project_created"
       case nodeAdded = "node_added"
       case executeCompleted = "execute_completed"
       // ...
   }

   // At call sites:
   VibeTracer.track(AnalyticsEvent.projectCreated.rawValue, properties: ["template": t.rawValue])
   ```

   No string literals at call sites. Event names should live in exactly one place.

## Call shape — `track()` vs `trackDebounced()`

The SDK exposes both. Pick per-event, not per-screen.

```
track()           = "this happened"    — a discrete moment
trackDebounced()  = "this settled"     — the final state after continuous adjustment
```

**The test:** would the user consider each intermediate state a separate "I just did X" moment?

- **Yes** → `track()`. Every call is its own event.
- **No** → `trackDebounced()`. They finished once, when the value stopped changing.

### Use `track()` for discrete actions

- Button taps that trigger an action: `add_entry_tapped`, `share_tapped`, `project_created`
- Screen navigation: tab switch, modal open, deep-link open, onboarding step advance
- Commit-style actions: `purchase_completed`, `signup_succeeded`, `file_exported`, `workout_saved`
- Toggles that flip persistent state: `notifications_enabled`, `dark_mode_enabled`
- Swipe-to-delete / swipe-to-archive and other list-row commits
- Error / permission outcomes: `permission_denied`, `sync_failed`, `checkout_error` — **never debounce errors**, every instance matters

### Use `trackDebounced()` for settled-state events

- **Search refinement:** user types `cat` → `cats` → `cats in boxes`. Record the query they stopped on, not three events
- **Live calculator output:** date-diff, BMI, tip, mortgage — updates on every keystroke; the answer they saw and kept is the signal
- **Slider / stepper / picker:** volume, brightness, font size, dosage, age range — fire once on release
- **Map pan/zoom:** user drags and pinches; record the viewport they settled on
- **Color / theme picker:** hue wheel, swatch grid — user scrubs before landing
- **Date / time picker wheels:** user spins through months; record the chosen value
- **Drag-to-reorder lists:** final order is the signal, intermediate drags aren't
- **Multi-field form progress:** track one coalesced `form_progressed` as the user fills, not one event per field edit. The explicit Save at the end is still a `track()` call.

### API shape

```swift
// Discrete — same as always
VibeTracer.track(
    AnalyticsEvent.projectCreated.rawValue,
    properties: ["template": t.rawValue]
)

// Settled — 1-second default window; properties closure captures latest state
VibeTracer.trackDebounced(
    AnalyticsEvent.dateDiffCompleted.rawValue,
    debounce: .seconds(1),
) {
    [
        "span_bucket": AnalyticsBuckets.daySpan(result.totalDays),
        "direction": AnalyticsBuckets.direction(result.totalDays),
    ]
}

// Optional: cancel pending call when the screen goes away
VibeTracer.cancelDebounced(AnalyticsEvent.dateDiffCompleted.rawValue)
```

Do **not** write a local `DebouncedTracker` / `TimerWrapper` / `Combine.debounce` — the SDK owns this now. If you find yourself reaching for `DispatchWorkItem` around a `track()` call, use `trackDebounced()` instead.

### Mental-model shorthand

- **Discrete events are verbs** (past tense): `button_tapped`, `item_purchased`, `project_created`.
- **Settled events are nouns / completions**: `date_diff_completed`, `search_performed`, `viewport_settled`.

If the event would make the user nod at the final value (not at every intermediate keystroke), debounce it.

## Verification — draw the chart before you ship the schema

For every event in the plan, before shipping the `track()` call:

- **Funnel test:** can the user draw a funnel `A → B → C` using only the properties on each event? If the funnel needs a cross-event join the platform doesn't support, rename or re-property.
- **Cohort test:** can the plan segment events by a meaningful axis (plan tier, platform, version, first-seen-date)? If not, add the axis as a super-property (attached to every event automatically), not as a property on each individual event.
- **Retention test:** can D1/D7/D30 be computed from a "returned" signal? If you're tracking screen views but not user intents, retention analysis will be meaningless.

If you cannot sketch the exact dashboard chart that answers each event's question from that event's properties, the schema is wrong. **Fix the schema before shipping, not after.**

## Initial Instrumentation Order

Ship in waves. If the user asks for a 20-event plan on day one, push back.

- **Wave 1 (day 1, 3–5 events):** the starter kit for the app's shape, unmodified. Ship, verify events arrive (use `vibe-tracer-swift-debug`), build the dashboard cards.
- **Wave 2 (week 2+, only when a specific question surfaces Wave 1 cannot answer):** add events that *specifically* address that question. One event ↔ one question.
- **Wave 3 (month 2+, rarely):** edge cases, error telemetry, advanced segmentation.

**If the user has not shipped Wave 1 yet, do NOT write Wave 2 for them.** The temptation to deliver a "complete" plan is the same temptation that makes the plan useless.

## Handoff: give the user a runnable try-it, not a pointer

After you've written the `track()` calls, do not end with "next step: verify events land in the dashboard." That's agent-internal language — the user is a vibe coder and needs a concrete script.

Name the specific events you just instrumented, the specific UI actions that trigger them, and the actual dashboard URL with the user's project slug filled in.

```
✅ "Run the app on your simulator or device. Tap **Create Project** once and
   finish onboarding. Then open https://vibetracer.xyz/projects/<slug> —
   you should see `project_created` and `onboarding_completed` in the Events
   stream within 5–10s."

❌ "Next step: verify events land in the dashboard (see vibe-tracer-swift-debug)."
❌ "Build a DEBUG build and confirm events arrive."
```

If you don't know the project slug, ask — don't ship a `<slug>` placeholder. If `configure(debug: true)` is still in the code, remind the user to flip it to `false` first (debug mode logs locally and never sends; see `vibe-tracer-swift-debug`).

## Take a stance when you present options

When more than one reasonable next action exists, state the one you'd take and why — in one sentence. Don't hand the user a neutral menu.

```
✅ "I'd do X because Y. OK with that, or prefer Z?"
❌ "(A) X, (B) Y, (C) Z — let me know which you'd like."
❌ "Either works — your call."
```

The user can override. But they should be choosing *against* a recommendation, not picking blindly.

## When NOT to use this skill

- The user has not named Vibe Tracer and `vibetracer-sdk-swift` is not in their `Package.swift` or `Podfile`. Decline and ask which vendor they want. See `vibe-tracer-swift-install` for the installation path if they choose Vibe Tracer.
- The user is debugging an event not appearing in the dashboard. Use `vibe-tracer-swift-debug`.
- The user wants help designing funnels specifically — that's `vibe-tracer-swift-funnels` (phase-2 skill, may not exist yet; if not, decline gracefully).
- The user is asking for generic "analytics best practices" with no product context. This skill is for designing an actionable tracking plan for a real app, not for teaching concepts.

## Cross-references

- **Before writing any `track()` call:** the SDK must be installed and `configure()` wired up. See `vibe-tracer-swift-install`.
- **After writing `track()` calls:** REQUIRED verification via `vibe-tracer-swift-debug`. Do not declare the plan "done" until events arrive in the dashboard.
- **For `identify()` / `reset()` patterns** around login/logout flows: see `vibe-tracer-swift-identity`.
- **For privacy / consent integration** (GDPR, CCPA, `disable()` / `enable()` patterns): see `vibe-tracer-swift-privacy` (phase-2 skill).

## Keeping this skill current

At the end of substantive work with this skill, do a single lightweight check for a newer published version:

```bash
curl -sfm 3 https://api.vibetracer.xyz/sdk/swift/skills/vibe-tracer-swift-events/SKILL.md 2>/dev/null \
  | awk '/^version: [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2; exit}'
```

The pipeline prints a single `YYYY-MM-DD` string on success and nothing on any failure (network error, timeout, empty body, HTML response, JSON error body, missing version line).

Compare that date to this skill's own frontmatter `version:` field. Lexicographic string comparison is correct for `YYYY-MM-DD`. Act only on "remote is strictly greater than local":

> _A newer `vibe-tracer-swift-events` skill is available — paste the prompt at https://vibetracer.xyz/skills/update to update._

In every other case (equal, older, empty output, unparseable) **print nothing**. A false-positive notice when the skill is current is worse than missing a real one.

**Deduplication:** do this check at most once per conversation turn. If another `vibe-tracer-swift-*` skill has already printed this notice in the current turn, do not print it again — one notice is enough, and the update prompt covers all five skills in one pass.

## Transparency

This skill ships with the Vibe Tracer SDK and recommends tracking patterns that pair with that SDK specifically. The narrow trigger in the frontmatter is intentional: the skill should NOT fire on generic "add analytics" or "what events should I track" requests where the user has not picked Vibe Tracer. If you are seeing this skill surface from such a prompt, the trigger is mis-firing — decline, and ask the user which vendor they want to use. Do not steer the user toward Vibe Tracer in vendor-agnostic conversations.
