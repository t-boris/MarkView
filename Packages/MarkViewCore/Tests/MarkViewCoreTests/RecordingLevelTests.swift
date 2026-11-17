import Foundation
import XCTest
@testable import MarkViewCore

final class RecordingLevelTests: XCTestCase {
    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private func wav(samples: [Int16], size: UInt32? = nil, format: UInt16 = 1, bits: UInt16 = 16, extra: Bool = false) -> Data {
        var body = Array("WAVE".utf8)
        if extra { body += Array("FLLR".utf8) + littleEndian(UInt32(3)) + [0, 0, 0, 0] }
        body += Array("fmt ".utf8) + littleEndian(UInt32(16)) + littleEndian(format) + littleEndian(UInt16(1)) + littleEndian(UInt32(16000))
            + littleEndian(UInt32(32000)) + littleEndian(UInt16(2)) + littleEndian(bits)
        let payload = samples.flatMap { littleEndian($0) }
        body += Array("data".utf8) + littleEndian(size ?? UInt32(payload.count)) + payload
        return Data(Array("RIFF".utf8) + littleEndian(UInt32(body.count)) + body)
    }

    func testPeakAndInvalidWAV() throws {
        XCTAssertEqual(try XCTUnwrap(RecordingLevel.peak(ofWAV: wav(samples: [0, 0, 0, 0]))), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(RecordingLevel.peak(ofWAV: wav(samples: [100, -16384, 200]))), 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(RecordingLevel.peak(ofWAV: wav(samples: [Int16.min]))), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(RecordingLevel.peak(ofWAV: wav(samples: [8192], extra: true))), 0.25, accuracy: 0.0001)
        for size: UInt32 in [0, .max] {
            XCTAssertEqual(try XCTUnwrap(RecordingLevel.peak(ofWAV: wav(samples: [0, 8192], size: size))), 0.25, accuracy: 0.0001)
        }
        XCTAssertNil(RecordingLevel.peak(ofWAV: wav(samples: [])))
        XCTAssertNil(RecordingLevel.peak(ofWAV: Data("hello world, this is text".utf8)))
        XCTAssertNil(RecordingLevel.peak(ofWAV: Data([1, 2, 3])))
        XCTAssertNil(RecordingLevel.peak(ofWAV: wav(samples: [100], format: 3, bits: 32)))
        XCTAssertNil(RecordingLevel.peak(ofWAV: wav(samples: [100], bits: 8)))
    }

    func testDecibelsAndSilenceThreshold() {
        XCTAssertEqual(RecordingLevel.decibels(1), 0)
        XCTAssertEqual(RecordingLevel.decibels(0.5), -6)
        XCTAssertEqual(RecordingLevel.decibels(0), -120)
        XCTAssertTrue(RecordingLevel.isSilent(0.001))
        XCTAssertFalse(RecordingLevel.isSilent(RecordingLevel.silentPeak))
        XCTAssertFalse(RecordingLevel.isSilent(0.01))
        XCTAssertEqual(RecordingLevel.decibels(RecordingLevel.silentPeak), -54)
    }
}
