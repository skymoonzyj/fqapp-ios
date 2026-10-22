import XCTest
#if canImport(UIKit)
@testable import Runner
#endif

final class TextDecoderTests: XCTestCase {
    func testKnownChineseAndEmojiEncodings() throws {
        let utf8: [UInt8] = [228,184,173,230,150,135,240,159,152,128]
        let fixtures: [([UInt8], String)] = [
            (utf8, "中文😀"), ([239,187,191] + utf8, "中文😀"),
            ([255,254,45,78,135,101,61,216,0,222], "中文😀"),
            ([254,255,78,45,101,135,216,61,222,0], "中文😀"),
            ([214,208,206,196,148,57,252,54], "中文😀"),
            ([214,208,206,196,208,161,203,181], "中文小说")
        ]
        for (bytes, expected) in fixtures {
            XCTAssertEqual(try TextDecoder.decode(Data(bytes)), expected)
        }
    }
    func testMalformedBOMDoesNotSilentlyProduceReplacementText() {
        XCTAssertThrowsError(try TextDecoder.decode(Data([255,254,0])))
        XCTAssertThrowsError(try TextDecoder.decode(Data([239,187,191,255])))
    }
}
