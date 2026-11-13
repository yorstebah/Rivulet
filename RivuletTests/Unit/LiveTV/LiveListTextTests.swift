// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveListTextTests.swift
//  RivuletTests
//
//  The List layout's shared words and column sections, as all three apps draw them.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveListTextTests: XCTestCase {
    func test_detail_putsTheQualityBeforeTheFlaggedCategory() throws {
        let suite = "LiveListTextTests"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let quality = LiveStreamQualityStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let channel = UnifiedChannel(id: "x:1", sourceType: .xtream, sourceId: "x", name: "NPO 1", groupTitle: "┃NL┃ SPORT")
        XCTAssertEqual(LiveListText.detail(channel, quality: quality), "🇳🇱 SPORT")
        quality.record(channelId: "x:1", height: 1080, audioChannels: 2)
        XCTAssertEqual(LiveListText.detail(channel, quality: quality), "1080p · \(String(localized: "Stereo")) · 🇳🇱 SPORT")
        let bare = UnifiedChannel(id: "x:2", sourceType: .xtream, sourceId: "x", name: "Bare")
        XCTAssertNil(LiveListText.detail(bare, quality: quality))
    }

    func test_sections_splitAtSourceHeaders_andTheStartingRow() {
        let channels = [
            UnifiedChannel(id: "a:1", sourceType: .xtream, sourceId: "a", name: "One", groupTitle: "News"),
            UnifiedChannel(id: "b:1", sourceType: .xtream, sourceId: "b", name: "Two", groupTitle: "Sport"),
        ]
        let list = LiveCategoryList.build(LiveCategoryList.Input(channels: channels, sources: [("a", "A"), ("b", "B")]))
        let sections = list.sections
        XCTAssertNil(sections.first?.header)
        XCTAssertEqual(sections.dropFirst().map { $0.header?.title }, ["A", "B"])
        XCTAssertTrue(sections.allSatisfy { $0.rows.allSatisfy { $0.kind != .sourceHeader } })
        let first = list.startingCategoryId(remembered: nil)
        XCTAssertEqual(first, sections.first?.rows.first?.id)
        XCTAssertEqual(list.startingCategoryId(remembered: "gone"), first)
        let sport = sections.last?.rows.last?.id
        XCTAssertEqual(list.startingCategoryId(remembered: sport), sport)
    }
}
