# Skill pack phase 2 — parked

**Parked:** 2026-04-21. **Status:** deferred, no active work. Revisit when a trigger below fires.

## Summary

After shipping v2.0.0 (5-skill pack: install / events / identity / debug / platform-config), 5 phase-2 skills were considered. Decision: ship **privacy** next, defer the rest until there's real-user signal.

## Candidate skills and status

| Skill | Status | Revisit when |
|---|---|---|
| `vibe-tracer-swift-privacy` | **Next up — not yet started.** | Pick up anytime; content is mature. ~2 hours incl. baseline scenario. |
| `vibe-tracer-swift-funnels` | Deferred. | After real users have built 10+ funnels and we see recurring failure modes. Consider merging with retention. |
| `vibe-tracer-swift-retention` | Deferred. Likely merge with funnels → `vibe-tracer-swift-analysis`. | Same trigger as funnels. |
| `vibe-tracer-swift-upgrade` | Deferred, premature. | When v2.x → v3.x ships with a real SDK API break. No real breaks exist today (v2.0 was docs-only). |
| `vibe-tracer-swift-dashboard` | Deferred, premature. | When dashboard v2 stabilizes. It's mid-flight (device flagging, sessions, annotations); writing the skill now would need rewriting in 6 weeks. |

## Privacy skill — scope note for when it's picked up

- Iron Law candidate: "NO PII IN EVENT PROPERTIES. EVER."
- Rationalization table seeds: "it's just for debugging", "I'll hash it later", "email is OK if I tell the user", "just this one field"
- Starter content:
  - `disable()` / `enable()` as the consent-flow API
  - What PrivacyInfo.xcprivacy declares (and what it doesn't)
  - Kids-app exceptions (COPPA); health-app exceptions (HIPAA)
  - GDPR subject-access workflows (you don't implement them, but you route them)
  - Raw-email / raw-phone / raw-device-name rejection patterns
- Baseline scenario: "I'm shipping in the EU, do I need anything special for GDPR?" — watch for both over-engineering (DPIA for an MVP) and under-engineering (just ship it).

## Reason for deferring funnels/retention

Writing these before real users have built funnels is speculation. The events skill already teaches "draw the chart first", which forces funnel-shaped thinking at event-design time. That may be enough. We'll know from real usage.

Merge signal: if, when we come back, funnels and retention skills would share >50% of their rationalization tables and red-flag lists, they should be one skill.

## Reason for deferring upgrade / dashboard

- **Upgrade**: no real API breaks have happened. A skill documenting migration patterns for non-existent migrations is cargo-cult documentation.
- **Dashboard**: actively churning. Device flagging, session detail pages, and annotation features are all landing or about to. A skill written today documents a dashboard that won't exist in a month.

## What to do instead

- **Ship privacy** when next sitting down with this pack.
- **Let real-user signal drive the rest.** If a specific failure mode shows up that none of the 5 current skills prevents — that's what the next skill should be about, not a speculative Phase 2 list.
- **Watch the events skill itself** for content drift. If a baseline regression shows up (AI starts recommending `app_opened` again despite the skill), that's a content-refresh trigger on the existing skill, not a new skill.

## Related

- Design doc: `docs/plans/2026-04-21-skill-pack-v2.md`
- Current skills: `skills/vibe-tracer-swift-*/SKILL.md`
- Validation baselines: `skills/testing/baselines.md`
