import Foundation

public enum NetworkError: Error, Equatable {
    case httpStatus(Int, retryable: Bool)
    case transport
}

public actor Network {
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
        throw NetworkError.httpStatus(http.statusCode, retryable: classify(status: http.statusCode))
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
