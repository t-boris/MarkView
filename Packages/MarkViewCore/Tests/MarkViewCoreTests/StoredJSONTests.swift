import Foundation
import XCTest
@testable import MarkViewCore

final class StoredJSONTests: XCTestCase {
    private struct Entry: Codable, Equatable { var id: Int; var name: String }

    func testAnyCodablePreservesNestedUnknownJSON() throws {
        let original = Data(#"{"nested":{"enabled":true,"count":-4,"ratio":1.25,"text":"привет 😀","nothing":null},"items":[1,false,{"x":"y"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: original)
        let encoded = try JSONEncoder().encode(decoded)
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? NSDictionary)
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        XCTAssertEqual(actual, expected)
    }

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

    /// A record in the preferences that cannot be read reads as absent, and its bytes are kept once, however often it is read.
    func testPreferenceRecordKeepsACopyOfWhatItCannotRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = Data(#"{"id":1,"name":"a"}"#.utf8)
        let bad = Data(#"{"id":"x"}"#.utf8)
        XCTAssertEqual(PreferenceRecord.decode(Entry.self, from: good, name: "entry", keepIn: folder), Entry(id: 1, name: "a"))
        XCTAssertTrue(PreferenceRecord.copies(named: "entry", in: folder).isEmpty, "a readable record leaves no copy")
        XCTAssertNil(PreferenceRecord.decode(Entry.self, from: bad, name: "entry", keepIn: folder))
        XCTAssertNil(PreferenceRecord.decode(Entry.self, from: bad, name: "entry", keepIn: folder))
        let copies = PreferenceRecord.copies(named: "entry", in: folder)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: copies[0]), bad)
        let other = Data("not json".utf8)
        XCTAssertNil(PreferenceRecord.decode(Entry.self, from: other, name: "entry", keepIn: folder))
        XCTAssertEqual(PreferenceRecord.copies(named: "entry", in: folder).count, 2, "another unreadable value is another copy")
    }

    func testUnreadableCopyNameSortsByTimeAndKeepsTheFileName() {
        let early = UnreadableCopy.name(of: "a.json", at: Date(timeIntervalSince1970: 1_700_000_000), suffix: "x")
        let late = UnreadableCopy.name(of: "a.json", at: Date(timeIntervalSince1970: 1_800_000_000), suffix: "x")
        XCTAssertEqual(early, "a.json.corrupt-20231114221320-x")
        XCTAssertTrue(early < late)
    }

    private struct Versioned: Codable, Equatable { var version = 1; var name = "" }

    /// A plain file that cannot be read is copied before a save replaces it; one that a newer build wrote is never replaced.
    func testPlainJSONFileCopiesWhatItCannotReadAndRefusesANewerFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("x.json")
        let field = PlainJSONFile.VersionField("version", supported: 1)
        func backups() -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("x.json.corrupt-") }
        }
        func write(_ value: Versioned) throws {
            try PlainJSONFile.write(try JSONEncoder().encode(value), replacing: Versioned.self, at: file, version: field, owner: "test")
        }

        guard case .missing = PlainJSONFile.read(Versioned.self, from: file, version: field, owner: "test") else { return XCTFail("missing") }
        try write(Versioned(name: "a"))
        XCTAssertEqual(PlainJSONFile.read(Versioned.self, from: file, version: field, owner: "test").value, Versioned(name: "a"))
        try write(Versioned(name: "b"))
        XCTAssertTrue(backups().isEmpty, "a file that reads is replaced without a backup")

        let cut = Data(#"{"version":1,"na"#.utf8)
        try cut.write(to: file)
        guard case .unreadable = PlainJSONFile.read(Versioned.self, from: file, version: field, owner: "test") else { return XCTFail("unreadable") }
        XCTAssertEqual(try Data(contentsOf: file), cut, "reading leaves the file as it is")
        try write(Versioned(name: "c"))
        XCTAssertEqual(backups().count, 1)
        XCTAssertEqual(try Data(contentsOf: backups()[0]), cut)
        XCTAssertEqual(PlainJSONFile.read(Versioned.self, from: file, version: field, owner: "test").value, Versioned(name: "c"))

        let future = Data(#"{"version":2,"name":"d","extra":true}"#.utf8)
        try future.write(to: file)
        guard case .newer(2) = PlainJSONFile.read(Versioned.self, from: file, version: field, owner: "test") else { return XCTFail("newer") }
        XCTAssertThrowsError(try write(Versioned(name: "e"))) { XCTAssertTrue($0 is PlainJSONFile.NewerVersion) }
        XCTAssertEqual(try Data(contentsOf: file), future, "a newer file is not replaced")
        XCTAssertEqual(backups().count, 1, "and not copied either")
    }
}
