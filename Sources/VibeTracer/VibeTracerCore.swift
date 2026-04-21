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
    private let disk: DiskQueue
    private let network: Network
    private let clock: Clock
    private let lifecycle: LifecycleObserver
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

    // MARK: - Init

    public init(
        deviceId: UUID,
        userIdStore: UserIdStore,
        sessionTracker: SessionTracker,
        disk: DiskQueue,
        network: Network,
        clock: Clock,
        lifecycle: LifecycleObserver,
        debug: Bool,
        logger: Logger,
        batchLimit: Int = 20,
        initiallyDisabled: Bool = false
    ) {
        self.deviceId = deviceId
        self.userIdStore = userIdStore
        self.sessionTracker = sessionTracker
        self.disk = disk
        self.network = network
        self.clock = clock
        self.lifecycle = lifecycle
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
        lifecycle.onActivate = { [weak self] in
            Task { await self?.handleActivate() }
        }
        lifecycle.onBackground = { [weak self] in
            Task { await self?.handleBackground() }
        }
        lifecycle.onTerminate = { [weak self] in
            Task { await self?.handleTerminate() }
        }
        lifecycle.start()

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

    private func emitSessionRolloverIfNeeded() {
        if let expired = sessionTracker.takeExpiredPriorSession() {
            let endEvent = AnalyticsEvent(
                event: "$session_end",
                deviceId: deviceId.uuidString,
                userId: userIdStore.current,
                sessionId: expired.sessionId.uuidString,
                timestamp: expired.lastActivityAt,
                properties: [:]
            )
            enqueueInternal(.track(endEvent))
        }
        let newSessionId = sessionTracker.startSessionIfNeeded()
        let startEvent = AnalyticsEvent(
            event: "$session_start",
            deviceId: deviceId.uuidString,
            userId: userIdStore.current,
            sessionId: newSessionId.uuidString,
            timestamp: clock.now(),
            properties: [:]
        )
        enqueueInternal(.track(startEvent))
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

        sessionTracker.noteActivity()
        let sid = sessionTracker.startSessionIfNeeded()
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

    /// Flushes the queue now and waits for the mailbox to drain. Internally
    /// synthesizes an `.appBackgrounded` signal which the reducer treats as an
    /// immediate-flush trigger from `.queuing`.
    public func flush() async {
        enqueueInternal(.appBackgrounded)
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

    // MARK: - Mailbox

    /// Enqueue from within the actor. External (non-actor) callers go through
    /// the public API which is already actor-isolated.
    private func enqueueInternal(_ signal: QueueSignal) {
        pendingSignalCount += 1
        mailboxContinuation.yield(signal)
    }

    private func decrementPending() {
        pendingSignalCount = max(0, pendingSignalCount - 1)
    }

    /// Internal: wait until the mailbox has drained and no follow-up signals
    /// are scheduled. Used by ``flush()`` and by tests to synchronize.
    ///
    /// Yields the cooperative pool (no `Task.sleep`) so tests run in
    /// deterministic zero time. The double-drain check accounts for signals
    /// that may be enqueued from a scheduled `Task { ... }` block fired by
    /// the TestClock's synchronous `advance(by:)` — those tasks hop onto the
    /// cooperative pool and show up as pending only after a couple of yields.
    internal func _waitForIdle() async {
        // Sleep briefly (not `Task.yield()`): `yield` can starve the drain
        // task under heavy contention because it re-enters this actor-
        // isolated loop on the same cooperative thread pool before the
        // separate drain `Task` gets scheduled.
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
