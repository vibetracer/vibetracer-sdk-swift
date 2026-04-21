import Foundation

/// A single tracked event, complete with identity metadata. Immutable.
/// JSON-encoded exactly as it will POST to `/v1/events`.
public struct AnalyticsEvent: Codable, Equatable, Sendable {
    public let clientEventId: UUID
    public let event: String
    public let deviceId: String
    public let userId: String?
    public let sessionId: String
    public let timestamp: Date
    public let properties: [String: AnyCodable]

    public init(
        clientEventId: UUID = UUID(),
        event: String,
        deviceId: String,
        userId: String?,
        sessionId: String,
        timestamp: Date = Date(),
        properties: [String: AnyCodable] = [:]
    ) {
        self.clientEventId = clientEventId
        self.event = event
        self.deviceId = deviceId
        self.userId = userId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.properties = properties
    }
}

/// Type-erased JSON-compatible value, so `properties: [String: Any]` can round-trip
/// through Codable without losing fidelity. Handles String, Int, Double, Bool,
/// Array, Dictionary, and null. Any other input (Date, URL, custom types, etc.)
/// is coerced where possible; truly unencodable types throw at construction,
/// caught at the `track()` boundary.
public struct AnyCodable: Codable, Equatable, Sendable {
    public let storage: Storage

    public indirect enum Storage: Equatable, Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([AnyCodable])
        case object([String: AnyCodable])
    }

    public init(_ value: Any) throws {
        self.storage = try Self.encode(value)
    }

    public init(storage: Storage) {
        self.storage = storage
    }

    private static func encode(_ value: Any) throws -> Storage {
        // IMPORTANT: NSNumber branch MUST come before Bool/Int/Double because
        // Swift's ObjC bridging makes `1 as Any` arrive as NSNumber which
        // ambiguously matches `Bool` (NSNumber(1).boolValue == true).
        // Without this guard, `track("x", properties: ["count": 1])` stores
        // count as `.bool(true)`. Classic Swift footgun.
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let type = String(cString: n.objCType)
            // f/d = float/double; q/i/s/c/l = integer types.
            if type == "f" || type == "d" { return .double(n.doubleValue) }
            return .int(n.intValue)
        }
        switch value {
        case is NSNull: return .null
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)   // pure Swift Bool (rare after NSNumber branch)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        case let date as Date:
            // Coerce Date → ISO8601 string. Server stores event.timestamp separately;
            // if a caller puts a Date in properties, they almost certainly want a
            // string representation for display/filter.
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return .string(f.string(from: date))
        case let url as URL:
            return .string(url.absoluteString)
        case let arr as [Any]:
            return .array(try arr.map { try AnyCodable($0) })
        case let obj as [String: Any]:
            var out: [String: AnyCodable] = [:]
            for (k, v) in obj { out[k] = try AnyCodable(v) }
            return .object(out)
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription:
                "AnyCodable cannot encode value of type \(type(of: value)). " +
                "Supported: Bool, Int, Double, String, Date, URL, NSNull, " +
                "[Any] and [String: Any] of the above. " +
                "This error is caught at track() and the event is still sent " +
                "with the offending property dropped (logged at warn level)."))
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { storage = .null; return }
        if let b = try? c.decode(Bool.self) { storage = .bool(b); return }
        if let i = try? c.decode(Int.self) { storage = .int(i); return }
        if let d = try? c.decode(Double.self) { storage = .double(d); return }
        if let s = try? c.decode(String.self) { storage = .string(s); return }
        if let a = try? c.decode([AnyCodable].self) { storage = .array(a); return }
        if let o = try? c.decode([String: AnyCodable].self) { storage = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown AnyCodable type")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch storage {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
