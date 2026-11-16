import Foundation
import XCTest
@testable import MarkViewCore

final class StoredJSONTests: XCTestCase {
    private struct Entry: Codable, Equatable { var id: Int; var name: String }

    func testDecodeReturnsTheValue() {
        let data = Data(#"{"id":1,"name":"a"}"#.utf8)
        XCTAssertEqual(StoredJSON.decode(Entry.self, from: data, owner: "test"), Entry(id: 1, name: "a"))
    }

    /// A value that cannot be decoded reads as absent (the caller decides what that means); it is described without its content.
    func testDecodeOfDamagedDataIsNilAndDescribedWithoutContent() {
        let data = Data(#"{"id":"secret-token","name":"a"}"#.utf8)
        XCTAssertNil(StoredJSON.decode(Entry.self, from: data, owner: "test"))
        do { _ = try JSONDecoder().decode(Entry.self, from: data) } catch {
            let text = StoredJSON.describe(error)
            XCTAssertTrue(text.contains("id"), text)
            XCTAssertFalse(text.contains("secret-token"), text)
        }
    }

    /// Lines that do not decode are counted and left out; the others keep their order; blank lines are not lines.
    func testJSONLinesSkipsDamagedLinesAndCountsThem() {
        let text = #"{"id":1,"name":"a"}"# + "\n{ damaged\n\n   \n" + #"{"id":2,"name":"b"}"# + "\r\n" + #"{"id":3}"# + "\n"
        let (records, skipped) = JSONLinesFile.decode(Entry.self, from: text, using: JSONDecoder(), owner: "test")
        XCTAssertEqual(records.map(\.id), [1, 2])
        XCTAssertEqual(skipped, 2)
    }

    func testJSONLinesLastReadsOnlyTheTail() {
        let text = (1...10).map { #"{"id":\#($0),"name":"n"}"# }.joined(separator: "\n") + "\n"
        let (records, skipped) = JSONLinesFile.decode(Entry.self, from: text, using: JSONDecoder(), owner: "test", last: 3)
        XCTAssertEqual(records.map(\.id), [8, 9, 10])
        XCTAssertEqual(skipped, 0)
    }

    /// An append ends a line that an interrupted write left open, so the new record stands on its own, and a reader skips only the cut line.
    func testAppendEndsAnOpenLineAndTheReaderSkipsOnlyTheCutLine() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jsonl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("log.jsonl")
        try JSONLinesFile.append(Data(#"{"id":1,"name":"a"}"#.utf8) + Data("\n".utf8), to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(#"{"id":2,"na"#.utf8)); try handle.close()
        try JSONLinesFile.append(Data(#"{"id":3,"name":"c"}"#.utf8), to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        let (records, skipped) = JSONLinesFile.decode(Entry.self, from: text, using: JSONDecoder(), owner: "test")
        XCTAssertEqual(records.map(\.id), [1, 3])
        XCTAssertEqual(skipped, 1)
        XCTAssertTrue(text.contains(#"{"id":2,"na"#), "the cut line stays in the file")
    }
}
