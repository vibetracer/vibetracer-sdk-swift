import Foundation

/// One-file-per-event persistent queue. Atomic writes via temp + rename.
/// Load discards files that fail to parse (partial-write recovery).
///
/// ### Data-loss contract
///
/// The queue is bounded at `maxEvents` (default 10,000). Events are evicted
/// oldest-first on the next `persist` that would push the on-disk count over
/// the cap. This is the SDK's ONLY realistic data-loss path in normal
/// operation — every other failure mode (network error, 401/403, 408, 429,
/// 5xx, transport failure, process death mid-send) keeps events on disk and
/// retries indefinitely (see `FSM/Reducer.swift` retry matrix and
/// `Effects/Network.swift` `classify(status:)`).
///
/// The cap triggers only under a narrow scenario: sustained backend outage
/// **and** the host app continuing to emit events faster than the retry loop
/// can drain. With 20-event batches, the 5-second flush timer, and a 60s
/// backoff plateau, a device would need to emit >10k events while the backend
/// has been unreachable for longer than the retry can recover from — plausible
/// only during multi-hour outages on analytics-heavy apps.
///
/// If real-world telemetry ever shows the cap tripping, options (not yet
/// taken) include: raising the cap, switching to a compressed/packed storage
/// format to fit more events in the same footprint, or surfacing an eviction
/// count to the server so we can observe the truncation.
public actor DiskQueue {
    private let directory: URL
    private let maxEvents: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let dateFormatter: ISO8601DateFormatter

    public init(directory: URL, maxEvents: Int = 10_000) {
        self.directory = directory
        self.maxEvents = maxEvents
        // Encode/decode dates as TimeInterval since Date's own reference date
        // so round-trips are bit-exact. `.iso8601` (even with fractional
        // seconds) truncates to milliseconds; `.secondsSince1970` introduces a
        // constant-offset subtraction that round-trips lose the ULP on. Storing
        // the internal `timeIntervalSinceReferenceDate` directly is lossless.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.timeIntervalSinceReferenceDate)
        }
        enc.keyEncodingStrategy = .useDefaultKeys
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            return Date(timeIntervalSinceReferenceDate: try c.decode(TimeInterval.self))
        }
        self.decoder = dec
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.dateFormatter = f

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func persist(_ events: [AnalyticsEvent]) throws {
        for event in events {
            try writeAtomic(event)
        }
        try evictOldestIfNeeded()
    }

    public func remove(ids: [UUID]) throws {
        let idSet = Set(ids)
        let files = try sortedFiles()
        for file in files {
            if let id = parseIdFromFilename(file.lastPathComponent), idSet.contains(id) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    public func loadAll() throws -> [AnalyticsEvent] {
        let files = try sortedFiles()
        var events: [AnalyticsEvent] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let event = try? decoder.decode(AnalyticsEvent.self, from: data)
            else {
                try? FileManager.default.removeItem(at: file)   // corrupt — discard
                continue
            }
            events.append(event)
        }
        return events
    }

    public func count() throws -> Int {
        try sortedFiles().count
    }

    // MARK: - private

    private func writeAtomic(_ event: AnalyticsEvent) throws {
        // Separator is "__" (double underscore) because UUIDs contain
        // dashes. Using a single dash would break parseIdFromFilename —
        // `lastIndex(of: "-")` would match a dash inside the UUID and
        // return a malformed fragment.
        let name = "\(dateFormatter.string(from: event.timestamp))__\(event.clientEventId.uuidString).json"
        let final = directory.appendingPathComponent(name)
        let tmp = directory.appendingPathComponent("\(name).tmp")
        let data = try encoder.encode(event)
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.moveItem(at: tmp, to: final)
    }

    private func sortedFiles() throws -> [URL] {
        let all = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return all
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func parseIdFromFilename(_ name: String) -> UUID? {
        // "20200101T000000.000Z__<uuid>.json"  — separator is "__"
        let stripped = name.replacingOccurrences(of: ".json", with: "")
        guard let sep = stripped.range(of: "__") else { return nil }
        return UUID(uuidString: String(stripped[sep.upperBound...]))
    }

    private func evictOldestIfNeeded() throws {
        let files = try sortedFiles()
        if files.count <= maxEvents { return }
        let overflow = files.count - maxEvents
        for file in files.prefix(overflow) {
            try? FileManager.default.removeItem(at: file)
        }
        print("[VibeTracer] disk queue reached \(maxEvents) events; evicted \(overflow) oldest")
    }
}
