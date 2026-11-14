// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamWatchProgressTests.swift
//  RivuletTests
//
//  Watch state for Xtream films and episodes, kept on the device.
//

import XCTest
@testable import Rivulet

@MainActor
final class XtreamWatchProgressTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "XtreamWatchProgressTests"
    private let movie = XtreamWatchProgressStore.key(source: "x", kind: .movie, id: "123")
    private let episode = XtreamWatchProgressStore.key(source: "x", kind: .episode, id: "9")

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func test_keys_separateKindsAndSources() {
        XCTAssertNotEqual(movie, XtreamWatchProgressStore.key(source: "x", kind: .episode, id: "123"))
        XCTAssertNotEqual(movie, XtreamWatchProgressStore.key(source: "y", kind: .movie, id: "123"))
    }

    func test_position_isKept_andIsAResumePoint() {
        let store = XtreamWatchProgressStore(defaults: defaults)
        store.update(movie, position: 1800, duration: 6000)
        let reloaded = XtreamWatchProgressStore(defaults: defaults)
        XCTAssertEqual(reloaded.record(movie)?.position, 1800)
        XCTAssertEqual(reloaded.inProgress(), [movie])
    }

    func test_pastTheCompletionPoint_isWatched_andLeavesContinueWatching() {
        let store = XtreamWatchProgressStore(defaults: defaults)
        store.update(movie, position: 5500, duration: 6000)
        XCTAssertEqual(store.record(movie)?.watched, true)
        XCTAssertEqual(store.record(movie)?.position, 0)
        XCTAssertTrue(store.inProgress().isEmpty)
    }

    func test_aFewSeconds_isNoResumePoint() {
        let store = XtreamWatchProgressStore(defaults: defaults)
        store.update(movie, position: 30, duration: 6000)
        XCTAssertTrue(store.inProgress().isEmpty)
    }

    func test_rewatch_keepsWatched_andHasAResumePoint() {
        let store = XtreamWatchProgressStore(defaults: defaults)
        store.markWatched(movie)
        store.update(movie, position: 1200, duration: 6000)
        XCTAssertEqual(store.record(movie)?.watched, true)
        XCTAssertEqual(store.inProgress(), [movie])
    }

    func test_inProgress_lastWatchedFirst() {
        let store = XtreamWatchProgressStore(defaults: defaults)
        store.update(movie, position: 1200, duration: 6000, now: Date(timeIntervalSince1970: 100))
        store.update(episode, position: 600, duration: 2400, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.inProgress(), [episode, movie])
        XCTAssertEqual(store.inProgress(limit: 1), [episode])
    }

    /// The record stays, emptied and newer, so iCloud's newest-wins merge carries the change
    /// instead of bringing the title back from another device.
    func test_markUnwatched_leavesABlankNewerRecord() throws {
        let store = XtreamWatchProgressStore(defaults: defaults)
        store.update(movie, position: 1200, duration: 6000, now: Date(timeIntervalSince1970: 100))
        store.markUnwatched(movie, now: Date(timeIntervalSince1970: 200))
        let record = try XCTUnwrap(XtreamWatchProgressStore(defaults: defaults).record(movie))
        XCTAssertTrue(record.isBlank)
        XCTAssertEqual(record.duration, 6000)
        XCTAssertEqual(record.updatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.inProgress(), [])
        XCTAssertNil(XtreamVODMapping.userState(record).lastViewedAt)
        // Nothing to forget: no record is made for a title never played.
        store.markUnwatched("other")
        XCTAssertNil(store.record("other"))
    }
}
