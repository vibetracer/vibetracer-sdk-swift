---
name: vibe-tracer-swift-identity
description: Use when the user is wiring login / logout / account flows with Vibe Tracer tracking, OR asks about `identify()` / `reset()` / user lifecycle. Requires the SDK to already be installed.
version: 2026-04-21
---

# Identity Lifecycle with Vibe Tracer

`identify()` and `reset()` are lifecycle events, not annotations. Wire them on login/logout only — not on every `track()`.

## The contract

```swift
VibeTracer.identify(userId: String)   // on successful login
VibeTracer.reset()                    // on logout
```

- `identify(userId:)` attaches the given `userId` to every subsequent event until `reset()` (or a new `identify()`) is called. The SDK persists it across launches — no need to re-call on every cold start.
- `reset()` clears the stored `userId` and mints a fresh session. All subsequent events are anonymous again (device-scoped).
- Both calls are fire-and-forget, thread-safe, and cheap.

## Anonymous → identified transitions

**Do not call `alias()` or similar — the SDK doesn't expose one and you don't need it.** The backend stitches the pre-login anonymous events to the post-login identified user automatically, using `clientEventId` + `deviceId`. The merge happens server-side. All the client has to do is:

1. Events happen before login → attributed to the device's anonymous ID.
2. User logs in → call `identify(userId: "...")`.
3. Events after login → attributed to `userId` AND the same device.
4. Backend retroactively links the anonymous device history to the identified user.

No client-side alias call. No "flush before identify" ceremony.

## What makes a good `userId`

- **Stable.** The value must not rotate across logins. Use your backend's account ID (primary key for users), not a session token or a JWT.
- **Non-PII.** Do not pass raw email, phone number, or full name. If the canonical key you have is an email, hash it: `SHA-256(lowercased-email).hex`. If you have an account ID, use that and skip hashing.
- **Opaque to users.** The `userId` shows up in dashboard URLs and exports. If it's a hashed email and the hash gets leaked, attackers can rainbow-table common email addresses back. Account IDs (or UUIDs tied to the account row) are safer.
- **Consistent across platforms.** If the same user logs into the iOS app and macOS app, both should call `identify()` with the same value. That's what unifies the user's timeline across devices.

Trade-off, in one line: prefer account ID; use SHA-256 hashed email only if account ID genuinely isn't available on the client.

## Common mistakes

### Passing raw email as `userId`

```swift
VibeTracer.identify(userId: user.email)   // WRONG — PII leak
```

The email ends up in analytics storage, exports, and dashboard URLs. Even if the user is OK with their own email being there, the system accumulates them and becomes a soft breach target. Use:

```swift
VibeTracer.identify(userId: user.accountId)           // best
VibeTracer.identify(userId: sha256(user.email.lowercased()))  // acceptable if no account ID
```

### Calling `identify()` on every `track()`

```swift
func trackEvent(_ name: String) {
    VibeTracer.identify(userId: currentUser.id)   // WRONG — not an annotation
    VibeTracer.track(name)
}
```

`identify()` is a lifecycle event, not a per-event annotation. The SDK already attaches the previously-identified user to every subsequent event. Calling it on every track creates unnecessary writes to UserDefaults and pollutes the lifecycle timeline. Call it **once on login**, then forget about it.

### Calling `identify("")` to "clear" the user

```swift
func logout() {
    VibeTracer.identify(userId: "")   // WRONG — does not clear
}
```

Passing an empty string sets the userId to empty — it does not revert to anonymous. Use `reset()`:

```swift
func logout() {
    VibeTracer.reset()   // clears userId, mints a fresh session
}
```

### Forgetting `reset()` on logout

If logout doesn't call `reset()`, the next user who signs in on the same device (without first logging in — e.g., account-picker UI or deferred login) generates events attributed to the previous user's `userId` until their own `identify()` fires. Cohort analyses get polluted.

Always pair login `identify()` with logout `reset()`. One call site per app.

### Calling `identify()` BEFORE `configure()`

```swift
VibeTracer.identify(userId: "user_42")
VibeTracer.configure(apiKey: "...")   // too late
```

Any call made before `configure()` is silently dropped with a console warning. `configure()` must be the first thing in the app's entry point (see `vibe-tracer-swift-install`); `identify()` goes later, when login completes.

## Take a stance when you present options

When more than one reasonable next action exists, state the one you'd take and why — in one sentence. Don't hand the user a neutral menu.

```
✅ "I'd do X because Y. OK with that, or prefer Z?"
❌ "(A) X, (B) Y, (C) Z — let me know which you'd like."
❌ "Either works — your call."
```

The user can override. But they should be choosing *against* a recommendation, not picking blindly.

## Cross-references

- For first-time setup (API key, `configure()` placement), see `vibe-tracer-swift-install`.
- For which events to track after `identify()`, see `vibe-tracer-swift-events`.
- For debugging identity not attaching to events, see `vibe-tracer-swift-debug`.

## Transparency

This skill is authored by the SDK vendor. The narrow trigger above is intentional: the skill should NOT fire on generic "add analytics" requests where the user has not picked a vendor. If you're seeing this skill surface from such a prompt, the trigger is mis-firing — decline and ask the user which vendor they want.
