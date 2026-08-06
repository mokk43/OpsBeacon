import XCTest
@testable import OpsBeacon

final class PushSignalDecoderTests: XCTestCase {
    func testDecoderAcceptsStableEnvelopeAndPreservesTypedAttributes() throws {
        let signal = try PushSignalDecoder.decode(
            Data("{\"name\":\"backup.failed\",\"occurredAt\":\"2026-08-06T01:02:03Z\",\"attributes\":{\"exitCode\":1,\"retry\":false,\"empty\":null}}".utf8),
            receiptTime: .distantPast
        )

        XCTAssertEqual(signal.name, "backup.failed")
        XCTAssertEqual(signal.attributes["exitCode"], .number("1"))
        XCTAssertEqual(signal.attributes["retry"], .boolean(false))
        XCTAssertEqual(signal.attributes["empty"], .null)
    }

    func testDecoderRejectsUnknownFieldAndTimezoneFreeTimestamp() {
        XCTAssertThrowsError(try PushSignalDecoder.decode(Data("{\"name\":\"x\",\"secret\":\"no\"}".utf8), receiptTime: .now))
        XCTAssertThrowsError(try PushSignalDecoder.decode(Data("{\"name\":\"x\",\"occurredAt\":\"2026-08-06T01:02:03\"}".utf8), receiptTime: .now))
    }
}
