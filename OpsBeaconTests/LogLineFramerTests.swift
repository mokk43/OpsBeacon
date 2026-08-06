import XCTest
@testable import OpsBeacon

final class LogLineFramerTests: XCTestCase {
    func testFramerEmitsOnlyCompletedLinesAcrossChunksAndNormalizesCRLF() {
        var framer = LogLineFramer(maximumLineBytes: 32)
        XCTAssertEqual(framer.append(Data("first\r".utf8)).lines, [])
        let result = framer.append(Data("\nsecond\npartial".utf8))
        XCTAssertEqual(result.lines, ["first", "second"])
        XCTAssertEqual(framer.append(Data(" tail\n".utf8)).lines, ["partial tail"])
    }

    func testFramerDiscardsOversizedLineThroughNewlineThenRecovers() {
        var framer = LogLineFramer(maximumLineBytes: 4)
        let result = framer.append(Data("12345\nnext\n".utf8))
        XCTAssertEqual(result.lines, ["next"])
        XCTAssertEqual(result.oversizedLineCount, 1)
    }

    func testFramerUsesReplacementCharactersForInvalidUTF8() {
        var framer = LogLineFramer(maximumLineBytes: 8)
        let result = framer.append(Data([0x66, 0x80, 0x0A]))
        XCTAssertEqual(result.lines, ["f�"])
    }
}
