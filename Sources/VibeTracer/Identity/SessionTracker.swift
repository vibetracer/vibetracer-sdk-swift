import Foundation

/// Metadata describing a previously-active session that has since expired.
///
/// Returned inside ``SessionRolloverResult`` so that `VibeTracerCore` can
/// synthesize a `$session_end` event attributed to the prior session's id and
/// timestamp rather than the new session's.
public struct ExpiredSession: Sendable, Equatable {
    public let sessionId: UUID
    public let lastActivityAt: Date

    public init(sessionId: UUID, lastActivityAt: Date) {
        self.sessionId = sessionId
        self.lastActivityAt = lastActivityAt
    }
}

/// Result of a single ``SessionTracker/rollover(now:)`` call, describing
/// atomically what happened to the session identity:
///
/// - ``expired``: non-nil only if a previously-live session just aged out on
///   this call. Use its metadata for `$session_end` attribution.
/// - ``currentSessionId``: the id the caller should use for subsequent events
///   — either the live reused session or the freshly-minted one.
/// - ``wasMinted``: `true` only when `currentSessionId` was just created (i.e.
///   on a fresh install, or immediately after an expiry was reported).
public struct SessionRolloverResult: Sendable, Equatable {
    public let expired: ExpiredSession?
    public let currentSessionId: UUID
    public let wasMinted: Bool

    public init(expired: ExpiredSession?, currentSessionId: UUID, wasMinted: Bool) {
        self.expired = expired
        self.currentSessionId = currentSessionId
        self.wasMinted = wasMinted
    }
}

/// Tracks the live analytics session and reports when a prior session has
/// expired due to idle timeout.
///
/// This type is a pure identity store: it never emits analytics events. It
/// simply answers two questions for the Core actor:
///
/// 1. "Did a previously-running session idle out while we weren't looking?"
///    (either during this process, or while the app was killed between
///    launches) — see ``takeExpiredPriorSession()``.
/// 2. "What is the current session id?" — see ``startSessionIfNeeded()``
///    and ``currentSessionId``.
///
/// ### Idle timeout semantics
///
/// A session is considered active as long as activity has been noted within
/// the last `idleTimeout` (default 30 minutes). Crossing that threshold
/// rolls the session over: the next call to ``startSessionIfNeeded()`` mints
/// a fresh UUID, and ``takeExpiredPriorSession()`` will report the prior
/// session's metadata exactly until a new session is started (the
/// consumption signal).
///
/// ### Clock-skew tolerance
///
/// If `clock.now()` is earlier than the stored `lastActivityAt` (e.g. the
/// user rolled their system clock back), we treat the session as "still
/// fresh" rather than triggering a spurious rollover. Preferring
/// false-positive continuation over false-positive rollover keeps a single
/// user's activity glued to a single session id when the OS clock jitters.
///
/// ### Thread safety
///
/// All mutating operations serialize through an internal `NSLock`, so the
/// type is safe to call from any thread (or any actor). It is declared
/// `Sendable` via `@unchecked` because `NSLock` is not itself `Sendable`.
public final class SessionTracker: @unchecked Sendable {
    private static let sessionIdKey = "com.vibetracer.sessionId"
    private static let lastActivityKey = "com.vibetracer.sessionLastActivityAt"

    private let defaults: UserDefaults
    private let clock: Clock
    private let idleTimeout: Duration
    private let lock = NSLock()

    /// In-memory session id — authoritative once set. Nil until the first
    /// `startSessionIfNeeded()` in this process (or after a rollover that
    /// has not yet been consumed).
    private var _currentSessionId: UUID?

    /// Snapshot of the prior (persisted) session captured at init time, held
    /// until either consumed via `startSessionIfNeeded()` or invalidated by
    /// discovering it has not actually expired. `nil` means "already
    /// consumed" or "never existed".
    private var _pendingExpiredPrior: ExpiredSession?

    public init(
        defaults: UserDefaults,
        clock: Clock,
        idleTimeout: Duration = .seconds(30 * 60)
    ) {
        self.defaults = defaults
        self.clock = clock
        self.idleTimeout = idleTimeout

        // On construction, consider any persisted session a *prior* session.
        // It becomes "the current session" only after we verify it hasn't
        // idled out — see takeExpiredPriorSession() / startSessionIfNeeded().
        if let prior = Self.loadPersistedSession(defaults: defaults) {
            self._pendingExpiredPrior = prior
        }
    }

    // MARK: - Public API

    /// Atomically advances the session identity and reports what happened.
    ///
    /// This is the single source of truth for session rollover decisions. A
    /// caller at any lifecycle edge (launch, foreground, first track) invokes
    /// `rollover(now:)` once and uses the result to decide whether to emit
    /// `$session_end` (`expired != nil`), `$session_start` (`wasMinted`), or
    /// neither (session reused within the idle window).
    ///
    /// The `wasMinted` flag is the critical bit that distinguishes a freshly-
    /// created session from a reused one — it prevents spurious `$session_start`
    /// events on every foreground.
    ///
    /// Call this exactly once per lifecycle edge. Back-to-back calls within
    /// the idle window will report `wasMinted: false` on the second call (the
    /// session is reused) — this is the invariant `VibeTracerCore` relies on
    /// to suppress duplicate `$session_start` events.
    @discardableResult
    public func rollover(now: Date? = nil) -> SessionRolloverResult {
        lock.lock(); defer { lock.unlock() }
        let t = now ?? clock.now()

        // 1. Check if a live in-memory session has idled out.
        var expiredToReport: ExpiredSession? = nil
        if let current = _currentSessionId,
           let lastActivity = Self.readLastActivity(defaults: defaults) {
            let age = t.timeIntervalSince(lastActivity)
            if age > idleTimeout.seconds {
                expiredToReport = ExpiredSession(
                    sessionId: current,
                    lastActivityAt: lastActivity
                )
                _currentSessionId = nil
                // Clear any stale cross-process pending prior — the in-memory
                // expiry supersedes it (they describe the same session).
                _pendingExpiredPrior = nil
            }
        }

        // 2. If no in-memory expiry, consider the persisted-from-prior-process
        //    session: either report it as expired or adopt it as current.
        if expiredToReport == nil, _currentSessionId == nil,
           let prior = _pendingExpiredPrior {
            let age = t.timeIntervalSince(prior.lastActivityAt)
            if age > idleTimeout.seconds {
                expiredToReport = prior
                _pendingExpiredPrior = nil
            } else {
                // Still fresh — adopt it as the live session. No expiry, no
                // mint; the caller gets back a reused id with `wasMinted: false`.
                _currentSessionId = prior.sessionId
                _pendingExpiredPrior = nil
                Self.persist(
                    sessionId: prior.sessionId,
                    lastActivity: t,
                    defaults: defaults
                )
                return SessionRolloverResult(
                    expired: nil,
                    currentSessionId: prior.sessionId,
                    wasMinted: false
                )
            }
        }

        // 3. If we still have a live current session (no expiry, no adoption),
        //    this is the hot path — reuse as-is.
        if let current = _currentSessionId {
            return SessionRolloverResult(
                expired: expiredToReport,
                currentSessionId: current,
                wasMinted: false
            )
        }

        // 4. Nothing live and nothing adoptable — mint a fresh session.
        let new = UUID()
        _currentSessionId = new
        Self.persist(
            sessionId: new,
            lastActivity: t,
            defaults: defaults
        )
        return SessionRolloverResult(
            expired: expiredToReport,
            currentSessionId: new,
            wasMinted: true
        )
    }

    /// Returns the prior session's metadata if it has expired. Idempotent
    /// until the prior session is consumed by ``startSessionIfNeeded()``
    /// minting a new one.
    ///
    /// If the prior session has *not* expired (i.e. we are within the idle
    /// window), this returns nil and, as a side effect, promotes the prior
    /// session to the current in-memory session so subsequent calls to
    /// ``startSessionIfNeeded()`` reuse its id.
    ///
    /// Prefer ``rollover(now:)`` in new code — it atomically reports both the
    /// expiry AND whether a new session was just minted. This method exists
    /// for backward-compat with earlier call sites that expected idempotency
    /// across multiple pokes.
    public func takeExpiredPriorSession() -> ExpiredSession? {
        lock.lock(); defer { lock.unlock() }
        let now = clock.now()

        // Case A: a live in-memory session has gone idle. Detect here so
        // callers that poll `takeExpiredPriorSession()` at lifecycle events
        // discover mid-process rollovers (not just cross-process ones).
        if let current = _currentSessionId,
           let lastActivity = Self.readLastActivity(defaults: defaults) {
            let age = now.timeIntervalSince(lastActivity)
            if age > idleTimeout.seconds {
                let expired = ExpiredSession(
                    sessionId: current,
                    lastActivityAt: lastActivity
                )
                _pendingExpiredPrior = expired
                _currentSessionId = nil
                return expired
            }
        }

        // Case B: a session persisted from a previous process is pending.
        guard let prior = _pendingExpiredPrior else { return nil }
        let age = now.timeIntervalSince(prior.lastActivityAt)
        if age > idleTimeout.seconds {
            // Expired — keep it pending so the caller can take it again.
            return prior
        }

        // Still fresh — adopt the persisted session as the live one and
        // drop the pending-expired flag so we don't report it later.
        _currentSessionId = prior.sessionId
        _pendingExpiredPrior = nil
        return nil
    }

    /// The currently-active session id, or nil if no session has been started
    /// in this process yet.
    public var currentSessionId: UUID? {
        lock.lock(); defer { lock.unlock() }
        return _currentSessionId
    }

    /// Ensures a live session exists, minting a new one if necessary, and
    /// returns the current session id. Thin wrapper around ``rollover(now:)``
    /// that discards the `expired` / `wasMinted` signals — kept for
    /// backward-compat with `track()`'s hot path, which just needs the id.
    @discardableResult
    public func startSessionIfNeeded() -> UUID {
        return rollover().currentSessionId
    }

    /// Bumps the last-activity timestamp to "now", extending the idle window
    /// for the live session. Safe to call from any thread.
    public func noteActivity() {
        lock.lock()
        let now = clock.now()
        // Only persist if we actually have a session — otherwise there is
        // no session to associate the activity with.
        if let sid = _currentSessionId {
            Self.persist(sessionId: sid, lastActivity: now, defaults: defaults)
        }
        lock.unlock()
    }

    // MARK: - Persistence helpers

    private static func loadPersistedSession(defaults: UserDefaults) -> ExpiredSession? {
        guard let raw = defaults.string(forKey: sessionIdKey),
              let uuid = UUID(uuidString: raw) else { return nil }
        let seconds = defaults.double(forKey: lastActivityKey)
        // `double(forKey:)` returns 0 when the key is absent; treat absent
        // as "no last activity recorded" and skip. A real 0.0 timestamp
        // would be 2001-01-01 which is far enough in the past that we'd
        // always treat it as expired anyway — the two interpretations
        // agree.
        guard seconds != 0 else { return nil }
        return ExpiredSession(
            sessionId: uuid,
            lastActivityAt: Date(timeIntervalSinceReferenceDate: seconds)
        )
    }

    private static func readLastActivity(defaults: UserDefaults) -> Date? {
        let seconds = defaults.double(forKey: lastActivityKey)
        guard seconds != 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static func persist(
        sessionId: UUID,
        lastActivity: Date,
        defaults: UserDefaults
    ) {
        defaults.set(sessionId.uuidString, forKey: sessionIdKey)
        defaults.set(lastActivity.timeIntervalSinceReferenceDate, forKey: lastActivityKey)
    }
}

// MARK: - Duration seconds helper

private extension Duration {
    var seconds: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) * 1e-18
    }
}
