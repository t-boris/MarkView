import Foundation
import XCTest
@testable import MarkViewCore

final class ImageSiblingsTests: XCTestCase {
    func testFinderOrderAndNavigation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("siblings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["10.png", "2.png", "1.png", "notes.txt", ".hidden.png"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }

        let images = ImageSiblings.list(in: directory) { $0.pathExtension == "png" }
        XCTAssertEqual(images.map(\.lastPathComponent), ["1.png", "2.png", "10.png"])
        let first = try XCTUnwrap(images.first)
        let second = try XCTUnwrap(images.dropFirst().first)
        let last = try XCTUnwrap(images.last)
        XCTAssertEqual(ImageSiblings.neighbour(of: first, in: images, step: 1, wrap: false)?.lastPathComponent, "2.png")
        XCTAssertNil(ImageSiblings.neighbour(of: first, in: images, step: -1, wrap: false))
        XCTAssertNil(ImageSiblings.neighbour(of: last, in: images, step: 1, wrap: false))
        XCTAssertEqual(ImageSiblings.neighbour(of: last, in: images, step: 1, wrap: true), first)
        XCTAssertEqual(ImageSiblings.neighbour(of: first, in: images, step: -1, wrap: true), last)
        XCTAssertNil(ImageSiblings.neighbour(of: first, in: [first], step: 1, wrap: true))
        XCTAssertEqual(ImageSiblings.position(of: second, in: images), "2 / 3")
        XCTAssertNil(ImageSiblings.position(of: first, in: [first]))
    }
}
