import XCTest
@testable import VibeTracer

final class AnyCodableTests: XCTestCase {

    // MARK: - Classification (construction)

    func test_bool_staysBool() throws {
        let a = try AnyCodable(true)
        XCTAssertEqual(a.storage, .bool(true))
    }

    /// The critical footgun: NSNumber(1) bridged via `Any` ambiguously
    /// matches `Bool`. The NSNumber-first branch must classify it as Int.
    func test_nsnumberOne_isInt_notBool() throws {
        let value: Any = 1   // bridges to NSNumber
        let a = try AnyCodable(value)
        XCTAssertEqual(a.storage, .int(1))
    }

    func test_double_staysDouble() throws {
        let a = try AnyCodable(1.5)
        XCTAssertEqual(a.storage, .double(1.5))
    }

    func test_nestedDictAndArray_roundTrip() throws {
        let dict: [String: Any] = [
            "flag": true,
            "count": 1,
            "ratio": 1.5,
            "name": "x",
            "tags": ["a", "b"],
            "meta": ["nested": 7],
        ]
        let a = try AnyCodable(dict)

        // Encode then decode; the full classification must survive.
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)

        guard case .object(let obj) = decoded.storage else {
            XCTFail("expected object"); return
        }
        XCTAssertEqual(obj["flag"]?.storage, .bool(true))
        XCTAssertEqual(obj["count"]?.storage, .int(1))
        // JSON has no int/double distinction; 1.5 must remain double.
        XCTAssertEqual(obj["ratio"]?.storage, .double(1.5))
        XCTAssertEqual(obj["name"]?.storage, .string("x"))

        guard case .array(let tags) = obj["tags"]?.storage else {
            XCTFail("expected array"); return
        }
        XCTAssertEqual(tags.map(\.storage), [.string("a"), .string("b")])

        guard case .object(let meta) = obj["meta"]?.storage else {
            XCTFail("expected nested object"); return
        }
        XCTAssertEqual(meta["nested"]?.storage, .int(7))
    }

    func test_unencodableType_throws() {
        // NSObject is not in the supported list → encode() must throw.
        XCTAssertThrowsError(try AnyCodable(NSObject())) { err in
            guard case EncodingError.invalidValue = err else {
                XCTFail("expected EncodingError.invalidValue, got \(err)"); return
            }
        }
    }

    // MARK: - Extras: Date, URL, null

    func test_date_coercedToISO8601String() throws {
        let date = Date(timeIntervalSince1970: 0)
        let a = try AnyCodable(date)
        guard case .string(let s) = a.storage else {
            XCTFail("expected string"); return
        }
        XCTAssertTrue(s.hasPrefix("1970-01-01T00:00:00"))
    }

    func test_url_coercedToAbsoluteString() throws {
        let a = try AnyCodable(URL(string: "https://example.com/x")!)
        XCTAssertEqual(a.storage, .string("https://example.com/x"))
    }

    func test_nsnull_becomesNull() throws {
        let a = try AnyCodable(NSNull())
        XCTAssertEqual(a.storage, .null)
    }

    // MARK: - Codable round-trip preserves types

    func test_jsonRoundTrip_preservesBoolNotInt() throws {
        let a = try AnyCodable(true)
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.storage, .bool(true))
    }
}
