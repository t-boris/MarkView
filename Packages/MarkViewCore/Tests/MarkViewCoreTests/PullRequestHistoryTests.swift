import Foundation
import XCTest
@testable import MarkViewCore

private actor FakePullRequestHistory {
    private(set) var calls = 0
    let result: PullRequestHistory.Fetched
    init(status: Int32 = 0, stdout: String = "[]") { result = (status, stdout) }
    func run() -> PullRequestHistory.Fetched { calls += 1; return result }
}

final class PullRequestHistoryTests: XCTestCase {
    func testIntegrationAndUnavailableResults() async {
        let listing = """
        [{"number":7,"title":"Add X-Ray","body":"Why it exists","url":"https://github.com/o/r/pull/7"},
         {"number":8,"title":"Fix it","body":null,"url":"https://github.com/o/r/pull/8"}]
        """
        let off = FakePullRequestHistory(stdout: listing)
        let offSection = await PullRequestHistory.section(enabled: false) { await off.run() }
        let offCalls = await off.calls
        XCTAssertEqual(offCalls, 0)
        XCTAssertTrue(offSection.text.contains("PR data unavailable"))
        XCTAssertTrue(offSection.text.contains("turned off"))
        XCTAssertTrue(offSection.text.contains("Do not invent PRs"))
        XCTAssertTrue(offSection.urls.isEmpty)
        XCTAssertFalse(offSection.text.contains("Add X-Ray"))

        let on = FakePullRequestHistory(stdout: listing)
        let onSection = await PullRequestHistory.section(enabled: true) { await on.run() }
        let onCalls = await on.calls
        XCTAssertEqual(onCalls, 1)
        XCTAssertTrue(onSection.text.hasPrefix("\n\nRead-only pull requests:\n"))
        XCTAssertTrue(onSection.text.contains("Add X-Ray"))
        XCTAssertTrue(onSection.text.contains("Why it exists"))
        XCTAssertEqual(onSection.urls, ["https://github.com/o/r/pull/7", "https://github.com/o/r/pull/8"])
        XCTAssertFalse(onSection.text.contains("PR data unavailable"))

        for fake in [FakePullRequestHistory(status: -1, stdout: ""), FakePullRequestHistory(status: 1),
                     FakePullRequestHistory(stdout: "oops"), FakePullRequestHistory(stdout: "{\"a\":1}")] {
            let section = await PullRequestHistory.section(enabled: true) { await fake.run() }
            let calls = await fake.calls
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(section.text, "\n\n" + PullRequestHistory.unavailableNote)
            XCTAssertTrue(section.urls.isEmpty)
        }
        XCTAssertNotEqual(PullRequestHistory.unavailableNote, PullRequestHistory.integrationOffNote)
        let empty = await PullRequestHistory.section(enabled: true) { (0, "[]") }
        XCTAssertTrue(empty.text.hasSuffix("\nNo pull requests found."))
    }

    func testBoundsKeepValidJSON() async throws {
        let body = String(repeating: "b", count: 2000)
        let listing = "[" + (1...60).map { "{\"number\":\($0),\"title\":\"t\",\"body\":\"\(body)\",\"url\":\"https://github.com/o/r/pull/\($0)\"}" }
            .joined(separator: ",") + "]"
        let bounded = await PullRequestHistory.section(enabled: true) { (0, listing) }
        XCTAssertEqual(bounded.urls.count, 50)
        let json = bounded.text.replacingOccurrences(of: "\n\nRead-only pull requests:\n", with: "")
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(records.count, 50)
        XCTAssertTrue(records.allSatisfy { ($0["body"] as? String)?.count == 1600 })
    }
}
