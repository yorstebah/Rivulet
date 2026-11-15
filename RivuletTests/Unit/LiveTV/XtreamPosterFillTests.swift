// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class XtreamPosterFillTests: XCTestCase {
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    func test_fillsWhatIsFound_andAsksEachTitleOnce() async {
        let fill = XtreamPosterFill()
        let asked = Asked()
        let resolve: XtreamPosterFill.Resolve = { id in
            asked.add(id)
            return id == "b" ? nil : URL(string: "https://img.example/\(id).jpg")
        }
        let first = await fill.posters(for: ["a", "b", "a"], resolve: resolve)
        XCTAssertEqual(first, ["a": URL(string: "https://img.example/a.jpg")!])
        let second = await fill.posters(for: ["a", "b"], resolve: resolve)
        XCTAssertEqual(second, first)
        XCTAssertEqual(asked.all.sorted(), ["a", "b"])
    }

    func test_aSlowLookup_doesNotHoldThePage_andIsThereNextTime() async throws {
        let fill = XtreamPosterFill()
        let resolve: XtreamPosterFill.Resolve = { id in
            try? await Task.sleep(for: .milliseconds(300))
            return URL(string: "https://img.example/\(id).jpg")
        }
        let first = await fill.posters(for: ["slow"], budget: 0.05, resolve: resolve)
        XCTAssertTrue(first.isEmpty)
        try await Task.sleep(for: .milliseconds(600))
        let later = await fill.posters(for: ["slow"], budget: 0.05, resolve: resolve)
        XCTAssertEqual(later["slow"], URL(string: "https://img.example/slow.jpg"))
    }
}
