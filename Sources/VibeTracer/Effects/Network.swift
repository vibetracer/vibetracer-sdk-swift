import Foundation

public enum NetworkError: Error, Equatable {
    /// An HTTP response outside the 2xx range.
    ///
    /// - Parameters:
    ///   - statusCode: the raw status from the response.
    ///   - retryable: result of `classify(status:)`. 400/422 = false (permanent
    ///     client error — drop the batch); everything else = true.
    ///   - retryAfter: server-supplied hint from the `Retry-After` response
    ///     header when the SDK can parse it (integer delta-seconds, capped at
    ///     `Network.maxRetryAfter`). `nil` when absent, zero, negative, non-
    ///     integer, or an HTTP-date (we don't implement HTTP-date parsing —
    ///     our own server only emits integer seconds; third-party proxies
    ///     that emit HTTP-date fall back to the local exp-backoff ladder,
    ///     which is still correct, just less precise).
    case httpStatus(Int, retryable: Bool, retryAfter: Duration?)
    case transport
}

public actor Network {
    /// Upper bound on `Retry-After` the SDK will honor, in seconds. A well-
    /// behaved server asking us to wait >5 minutes almost certainly indicates
    /// a misconfiguration or an attempt to stall the client indefinitely; the
    /// exp-backoff ladder's 60s plateau is our baseline, and 300s gives
    /// legitimate overload scenarios headroom while bounding worst-case
    /// starvation. If server operators need longer pauses, they should
    /// return 5xx rather than a multi-hour Retry-After.
    public static let maxRetryAfter: Duration = .seconds(300)

    private let endpoint: URL
    private let apiKey: String
    private let sdkVersion: String
    private let session: URLSession
    private let encoder: JSONEncoder

    public init(endpoint: URL, apiKey: String, sdkVersion: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.sdkVersion = sdkVersion
        self.session = session
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    public func post(_ batch: [AnalyticsEvent]) async throws {
        var req = URLRequest(url: endpoint.appendingPathComponent("/v1/events"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(sdkVersion, forHTTPHeaderField: "X-Vibetracer-SDK")
        // Single event = object; multiple = array. Backend accepts both.
        req.httpBody = batch.count == 1 ? try encoder.encode(batch[0]) : try encoder.encode(batch)

        let resp: URLResponse
        do {
            (_, resp) = try await session.data(for: req)
        } catch {
            throw NetworkError.transport
        }
        guard let http = resp as? HTTPURLResponse else {
            // Non-HTTP response is conceivable under custom URLSession test setups
            // or future schemes. Don't crash the host app.
            throw NetworkError.transport
        }
        if (200...299).contains(http.statusCode) { return }
        let retryAfter = parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
        throw NetworkError.httpStatus(
            http.statusCode,
            retryable: classify(status: http.statusCode),
            retryAfter: retryAfter
        )
    }
}

/// Public for FSM tests to call directly. 400/422 = permanent, everything else = retry.
/// No kill switch — 401/403 are treated as transient (could be transient backend auth
/// outage; the SDK should not silently drop events forever on one bad response).
public func classify(status: Int) -> Bool {
    switch status {
    case 400, 422: return false   // permanent — payload shape problem
    default: return true          // retryable (401/403/500s/etc — no kill switch)
    }
}

/// Parse an HTTP `Retry-After` header value (RFC 7231 §7.1.3) into a
/// `Duration`. Only the delta-seconds form (a non-negative integer) is
/// honored — HTTP-date form returns `nil` and the caller falls back to the
/// exp-backoff ladder. Zero and negative values also return `nil` (zero is a
/// valid spec encoding of "retry immediately", but honoring it literally
/// would hammer the server; the ladder's 1s minimum is safer). Values above
/// `Network.maxRetryAfter` are clamped to that ceiling.
///
/// Public for test access; not part of the stable API surface.
public func parseRetryAfter(_ value: String?) -> Duration? {
    guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
          let seconds = Int(raw), seconds > 0
    else { return nil }
    let cap = Int(Network.maxRetryAfter.components.seconds)
    return .seconds(min(seconds, cap))
}
