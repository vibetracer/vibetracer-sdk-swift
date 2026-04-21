import Foundation
import os

/// Integrates the pure FSM reducer with the effect runners, identity stores, and
/// platform lifecycle into a single actor. This is the engine behind the public
/// `VibeTracer` facade.
///
/// ### Mailbox serialization
///
/// Public API methods (`track`, `identify`, `reset`, `flush`, `setDisabled`) and
/// lifecycle callbacks all post a ``QueueSignal`` onto a single internal
/// `AsyncStream<QueueSignal>`. A single long-running `Task` drains the stream in
/// FIFO order, guaranteeing two concurrent `track()` calls from different
/// threads are processed in arrival order, and that lifecycle events cannot
/// corrupt state by racing with a mid-flight `track`.
///
/// ### Reentrancy discipline
///
/// ``handle(_:)`` loads the current on-disk batch (awaitable), then reads state,
/// computes `(newState, effects)`, commits state **before any further await**,
/// then runs effects. Because the actor model allows reentrant awaits to let
/// other messages interleave, the commit-before-await rule prevents a second
/// mailbox-drain iteration from clobbering a transition that was in flight.
///
/// ### Debug mode routing
///
/// The reducer stays pure and always emits `.httpPost` on flush. Debug mode
/// lives in ``run(_:)``: when `debug == true`, `.httpPost` is rewritten to
/// ``Logger`` output and a synthesized `.sendOk(batch:)` signal is enqueued so
/// the FSM advances identically to production (disk is cleared, state returns
/// to `.empty` / `.queuing`). Without the synthesized ack the FSM would stall
/// in `.flushing` forever.
///
/// ### Session rollover ownership
///
/// `SessionTracker` is a pure identity store and never emits analytics events.
/// This actor owns emission of `$session_start` and `$session_end`:
///
/// - On ``start()``: if the prior persisted session expired, emit `$session_end`
///   with the PRIOR session's id and lastActivity timestamp, then mint a new
///   session and emit `$session_start` with the new id.
/// - On ``handleActivate()`` (app-foregrounded after idle): same check, same
///   emission contract.
public actor VibeTracerCore {

    // MARK: - Configuration

    private let deviceId: UUID
    private let userIdStore: UserIdStore
    private let sessionTracker: SessionTracker
    private let sessionEmitter: SessionEmitter
    private let disk: DiskQueue
    private let network: Network
    private let clock: Clock
    private let lifecycle: LifecycleObserver
    private let connectivity: ConnectivityMonitor?
    private let debug: Bool
    private let logger: Logger
    private let batchLimit: Int

    // MARK: - FSM state

    private var state: QueueState = .empty

    // MARK: - Mailbox

    private let mailbox: AsyncStream<QueueSignal>
    private let mailboxContinuation: AsyncStream<QueueSignal>.Continuation
    private var drainTask: Task<Void, Never>?

    /// Number of signals enqueued but not yet finished processing. Used by
    /// ``_waitForIdle()`` so tests can deterministically wait for the mailbox
    /// to drain.
    private var pendingSignalCount: Int = 0

    // MARK: - Other state

    private var disabled: Bool = false
    private var activeTimerHandle: ClockHandle?
    private var started: Bool = false

    /// Cached current session id. Populated in ``start()`` from the rollover
    /// result, refreshed in ``handleActivate()`` when a new session is minted.
    /// `track()` uses this instead of calling back into `SessionTracker` on
    /// every event, avoiding a `UserDefaults` read per tracked event.
    private var currentSessionId: UUID?

    // MARK: - Lifecycle Task coalescing
    //
    // Lifecycle callbacks arrive on arbitrary threads. We can't reach into an
    // actor from a synchronous closure, so each callback spawns a `Task`. Under
    // rapid foreground↔background cycling (test harnesses, multi-scene apps),
    // N Tasks accumulate and contend for actor re-entry.
    //
    // We use a single `lifecycleTask` handle and cancel the prior pending one
    // before spawning a new handler. This coalesces bursts: if five
    // activate/background signals fire in 20ms, only the last runs to
    // completion. Strict per-event ordering is sacrificed (intentionally —
    // lifecycle signals are edge-triggered, and losing an intermediate edge is
    // preferable to spawning unbounded Tasks).

    private var lifecycleTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        deviceId: UUID,
        userIdStore: UserIdStore,
        sessionTracker: SessionTracker,
        disk: DiskQueue,
        network: Network,
        clock: Clock,
        lifecycle: LifecycleObserver,
        connectivity: ConnectivityMonitor? = nil,
        debug: Bool,
        logger: Logger,
        batchLimit: Int = 20,
        initiallyDisabled: Bool = false
    ) {
        self.deviceId = deviceId
        self.userIdStore = userIdStore
        self.sessionTracker = sessionTracker
        self.sessionEmitter = SessionEmitter(
            deviceId: deviceId,
            userIdStore: userIdStore,
            clock: clock
        )
        self.disk = disk
        self.network = network
        self.clock = clock
        self.lifecycle = lifecycle
        self.connectivity = connectivity
        self.debug = debug
        self.logger = logger
        self.batchLimit = batchLimit
        self.disabled = initiallyDisabled

        var cont: AsyncStream<QueueSignal>.Continuation!
        self.mailbox = AsyncStream { cont = $0 }
        self.mailboxContinuation = cont
    }

    // MARK: - Lifecycle

    /// Starts the mailbox drain, loads any persisted events from a previous
    /// launch, emits the session rollover pair if applicable, and subscribes to
    /// platform lifecycle callbacks. Idempotent — subsequent calls are no-ops.
    public func start() async {
        guard !started else {
            logger.warning("VibeTracerCore.start() called twice — ignoring")
            return
        }
        started = true

        // Wire lifecycle callbacks BEFORE draining the mailbox: callbacks all
        // enqueue via `enqueue(_:)`, which is safe even before drainTask is
        // spun up (the AsyncStream buffers).
        //
        // Each callback cancels any pending lifecycle Task before spawning a
        // new one — see `lifecycleTask` docs for the coalescing rationale.
        lifecycle.onActivate = { [weak self] in
            Task { [weak self] in await self?.scheduleLifecycleWork { await $0.handleActivate() } }
        }
        lifecycle.onBackground = { [weak self] in
            Task { [weak self] in await self?.scheduleLifecycleWork { await $0.handleBackground() } }
        }
        lifecycle.onTerminate = { [weak self] in
            Task { [weak self] in await self?.scheduleLifecycleWork { await $0.handleTerminate() } }
        }
        lifecycle.start()

        // Connectivity monitor: on offline→online edge, wake out of backoff
        // early. If no monitor was injected (e.g. in unit tests that don't
        // care), the clock-driven timer still fires as the safety net.
        connectivity?.onBecameReachable = { [weak self] in
            Task { [weak self] in await self?.scheduleLifecycleWork { await $0.handleConnectivityReturned() } }
        }
        connectivity?.start()

        // Spin up the drain task first so signals we enqueue in the rest of
        // start() begin flowing without waiting on an external Task scheduler.
        let stream = self.mailbox
        drainTask = Task { [weak self] in
            for await signal in stream {
                guard let self else { return }
                await self.handle(signal)
                await self.decrementPending()
            }
        }

        // Crash/restart recovery: if the disk has events from a prior launch,
        // prime the FSM into `.queuing` and schedule a flush timer. We don't
        // call persistToDisk again; we just surface the existing batch.
        let priorCount = (try? await disk.count()) ?? 0
        if priorCount > 0 {
            state = .queuing
            enqueueInternal(.timerFired) // timerFired in .queuing with non-empty batch flushes immediately
        }

        // Session rollover: emit $session_end for an expired prior session, then
        // mint the new session and emit $session_start.
        emitSessionRolloverIfNeeded()
    }

    /// Advance the session tracker by one lifecycle tick and enqueue the
    /// resulting analytics events (`$session_end`, `$session_start`, or
    /// neither, depending on whether the session expired and/or was minted).
    ///
    /// Call sites: ``start()`` (launch) and ``handleActivate()`` (foreground).
    /// The rollover decision is atomic inside `SessionTracker.rollover`, so
    /// back-to-back calls within the idle window produce zero events on the
    /// second call — this is the v1.1.1 fix for spurious `$session_start`
    /// emission on every foreground.
    private func emitSessionRolloverIfNeeded() {
        let result = sessionTracker.rollover(now: clock.now())
        let events = sessionEmitter.eventsFor(rollover: result)
        for event in events {
            enqueueInternal(.track(event))
        }
        if result.wasMinted {
            currentSessionId = result.currentSessionId
        } else {
            // Even without a mint, the live session id may have been adopted
            // from a fresh persisted-prior — keep the cache in sync with the
            // tracker's authoritative view.
            currentSessionId = result.currentSessionId
        }
    }

    // MARK: - Public API

    public func track(event: String, properties: [String: Any]?) {
        guard !disabled else { return }

        // Encode properties defensively: drop individual keys that AnyCodable
        // rejects so one bad property can't black-hole the whole event.
        var encoded: [String: AnyCodable] = [:]
        var droppedKeys: [String] = []
        for (k, v) in properties ?? [:] {
            do { encoded[k] = try AnyCodable(v) }
            catch { droppedKeys.append(k) }
        }
        if !droppedKeys.isEmpty {
            logger.warning("Dropped unencodable property keys: \(droppedKeys.joined(separator: ", "), privacy: .public) for event \(event, privacy: .public)")
        }

        // Bump the idle-window timestamp on every track — idle-timeout
        // accuracy depends on it. One UserDefaults write; O(1).
        sessionTracker.noteActivity()

        // Use the cached session id when we have one. This avoids a second
        // UserDefaults read per track (the old hot path called
        // `startSessionIfNeeded()` which read the persisted session id from
        // disk every time). If the cache is nil (e.g. `track()` beat `start()`
        // to the mailbox), fall back to a real rollover to be safe.
        let sid: UUID
        if let cached = currentSessionId {
            sid = cached
        } else {
            let result = sessionTracker.rollover(now: clock.now())
            sid = result.currentSessionId
            currentSessionId = sid
        }

        let ev = AnalyticsEvent(
            event: event,
            deviceId: deviceId.uuidString,
            userId: userIdStore.current,
            sessionId: sid.uuidString,
            timestamp: clock.now(),
            properties: encoded
        )
        enqueueInternal(.track(ev))
    }

    public func identify(userId: String) {
        userIdStore.identify(userId: userId)
    }

    public func reset() {
        userIdStore.reset()
    }

    /// Flushes the queue now and waits for the mailbox to drain. Synthesizes
    /// a `.flushRequested` signal, which the reducer treats as an immediate-
    /// flush trigger from `.queuing` AND forces an early retry from `.backoff`
    /// (unlike `.appBackgrounded`, which respects the backoff timer).
    public func flush() async {
        enqueueInternal(.flushRequested)
        await _waitForIdle()
    }

    public func setDisabled(_ newValue: Bool) {
        self.disabled = newValue
    }

    // MARK: - Lifecycle callbacks (actor-isolated entry points)

    private func handleActivate() {
        // A session may have idled out while the app was backgrounded. Same
        // rollover contract as at launch.
        emitSessionRolloverIfNeeded()
    }

    private func handleBackground() {
        enqueueInternal(.appBackgrounded)
    }

    private func handleTerminate() {
        enqueueInternal(.appTerminating)
    }

    /// Called on the offline→online edge from the ``ConnectivityMonitor``.
    /// Only meaningful when we're currently sitting in `.backoff` — in any
    /// other state the clock timer is either serving a different purpose
    /// (`.queuing`'s 5s flush timer) or not running at all, and waking early
    /// would be noise. Cancel the active backoff timer and advance the FSM
    /// with `.backoffExpired` to retry the flush immediately.
    private func handleConnectivityReturned() {
        if case .backoff = state {
            cancelActiveTimer()
            enqueueInternal(.backoffExpired)
        }
    }

    // MARK: - Mailbox

    /// Enqueue from within the actor. External (non-actor) callers go through
    /// the public API which is already actor-isolated.
    private func enqueueInternal(_ signal: QueueSignal) {
        pendingSignalCount += 1
        // Diagnostic: warn if queue depth grows unexpectedly. Does not apply
        // backpressure (intentional — `track()` is sync fire-and-forget per
        // design). A growing queue indicates either the drain task is stuck
        // or the host app is firing events faster than we can process.
        let depth = pendingSignalCount
        if depth == 100 || depth == 1_000 || depth == 10_000 {
            logger.warning("VibeTracer mailbox depth at \(depth, privacy: .public); drain may be slow or stuck")
        }
        mailboxContinuation.yield(signal)
    }

    /// Lifecycle callback coalescer. Called from the outer `Task { }` wrappers
    /// in ``start()``. Cancels the prior lifecycle Task (if any) and spawns a
    /// new one running the given body. Under rapid foreground/background
    /// cycling this caps the number of concurrent lifecycle-driven Tasks at 1
    /// rather than letting them pile up in the cooperative pool.
    private func scheduleLifecycleWork(_ body: @escaping @Sendable (VibeTracerCore) async -> Void) {
        lifecycleTask?.cancel()
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            await body(self)
        }
    }

    private func decrementPending() {
        pendingSignalCount = max(0, pendingSignalCount - 1)
    }

    /// Internal: wait until the mailbox has drained and no follow-up signals
    /// are scheduled. Used by ``flush()`` and by tests to synchronize.
    ///
    /// Implementation: polls with 500µs `Task.sleep` ticks (not `Task.yield()`,
    /// which can starve the separate drain `Task` when the caller and the
    /// drain share the cooperative pool). Requires 4 consecutive idle ticks
    /// before returning, to absorb signals that were enqueued from a Task
    /// scheduled by `TestClock.advance(by:)` but hadn't yet hopped onto the
    /// pool. Worst-case ceiling of 10 seconds (20,000 × 500µs) before it
    /// logs-and-aborts to avoid deadlocking a test.
    ///
    /// Consequence: every `flush()` call has a ~2ms floor (4 × 500µs stability
    /// window). Acceptable for tests; production `flush()` callers should not
    /// be on a hot path.
    internal func _waitForIdle() async {
        var stableTicks = 0
        let tickNanos: UInt64 = 500_000 // 0.5 ms
        let maxIterations = 20_000       // 10 seconds worst case
        var iterations = 0
        while true {
            if pendingSignalCount == 0 && !isActivelyFlushing() {
                stableTicks += 1
                if stableTicks >= 4 { return }
            } else {
                stableTicks = 0
            }
            try? await Task.sleep(nanoseconds: tickNanos)
            iterations += 1
            if iterations > maxIterations {
                logger.error("_waitForIdle exceeded \(maxIterations) iterations with pending=\(self.pendingSignalCount); aborting")
                return
            }
        }
    }

    private func isActivelyFlushing() -> Bool {
        if case .flushing = state { return true }
        return false
    }

    // MARK: - Test hooks

    internal func _state() -> QueueState { state }
    internal func _pending() -> Int { pendingSignalCount }

    // MARK: - FSM dispatch

    private func handle(_ signal: QueueSignal) async {
        // Read the current disk batch BEFORE reducing — the reducer needs it
        // for transitions like `.queuing + .timerFired -> .flushing(batch)`.
        // This is the one `await` that precedes the state commit; it's safe
        // because we re-read state AFTER it, before writing.
        //
        // For `.sendOk` / `.sendFailed`, the reducer's `currentBatch` contract
        // is "what remains on disk AFTER the acked batch is removed" (see
        // reducer tests). The acked events are still physically on disk at
        // this moment — removeFromDisk happens as an effect after we commit —
        // so we must filter them out here.
        let currentBatch = await loadBatchForFSM(excluding: excludedIds(for: signal))
        let stateBeforeReduce = state
        let (newState, effects) = reduce(
            stateBeforeReduce, signal,
            batchLimit: batchLimit,
            currentBatch: currentBatch
        )
        state = newState // commit synchronously before running any effect

        for effect in effects {
            await run(effect)
        }

        // After handling a `track` signal, check whether the queue just hit the
        // batch limit. The reducer doesn't inspect disk size on `track`; the
        // runner is responsible for surfacing the batch-full signal.
        if case .track = signal {
            if case .queuing = state {
                let count = (try? await disk.count()) ?? 0
                if count >= batchLimit {
                    enqueueInternal(.batchFull)
                }
            }
        }
    }

    private func excludedIds(for signal: QueueSignal) -> Set<UUID> {
        switch signal {
        case .sendOk(let batch), .sendFailed(let batch, _):
            return Set(batch.map(\.clientEventId))
        default:
            return []
        }
    }

    private func loadBatchForFSM(excluding excluded: Set<UUID> = []) async -> [AnalyticsEvent] {
        do {
            let all = try await disk.loadAll()
            let filtered = excluded.isEmpty
                ? all
                : all.filter { !excluded.contains($0.clientEventId) }
            return Array(filtered.prefix(batchLimit))
        } catch {
            logger.error("Failed to load disk queue: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    // MARK: - Effect runner

    private func run(_ effect: QueueEffect) async {
        switch effect {

        case .httpPost(let batch) where debug:
            for e in batch {
                logger.debug("[debug] would send: \(e.event, privacy: .public)")
            }
            enqueueInternal(.sendOk(batch: batch))

        case .httpPost(let batch):
            do {
                try await network.post(batch)
                enqueueInternal(.sendOk(batch: batch))
            } catch NetworkError.httpStatus(_, let retryable) {
                enqueueInternal(.sendFailed(batch: batch, permanent: !retryable))
            } catch {
                // Transport / connectivity — retryable.
                enqueueInternal(.sendFailed(batch: batch, permanent: false))
            }

        case .persistToDisk(let events):
            do { try await disk.persist(events) }
            catch { logger.error("Disk persist failed: \(String(describing: error), privacy: .public)") }

        case .removeFromDisk(let ids):
            do { try await disk.remove(ids: ids) }
            catch { logger.error("Disk remove failed: \(String(describing: error), privacy: .public)") }

        case .scheduleTimer(let duration):
            cancelActiveTimer()
            let handle = clock.scheduleAfter(duration) { [weak self] in
                Task { await self?.onTimerFired() }
            }
            activeTimerHandle = handle

        case .cancelTimer:
            cancelActiveTimer()

        case .localLog(let event):
            logger.debug("[localLog] \(event.event, privacy: .public)")

        case .batchDropped(let reason, let count):
            logger.warning("Dropped \(count) events: \(reason, privacy: .public)")
        }
    }

    private func onTimerFired() {
        // Timer fires can be backoffExpired (during .backoff) or timerFired
        // (during .queuing). Let the current state disambiguate.
        switch state {
        case .backoff:
            enqueueInternal(.backoffExpired)
        default:
            enqueueInternal(.timerFired)
        }
    }

    private func cancelActiveTimer() {
        if let h = activeTimerHandle {
            clock.cancel(h)
            activeTimerHandle = nil
        }
    }
}
