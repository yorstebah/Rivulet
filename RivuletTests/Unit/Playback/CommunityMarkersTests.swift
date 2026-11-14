// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CommunityMarkersTests.swift
//  RivuletTests
//
//  Community skip markers: TheIntroDB.org's replies, the order the databases
//  and the server win in, and the fill for providers (Jellyfin, Emby) whose
//  episodes carry their show's external ids.
//

import XCTest
import os
@testable import Rivulet

final class CommunityMarkersTests: XCTestCase {

    // MARK: - TheIntroDB replies

    func test_theIntroDB_firstSegmentPerKind_creditsToTheEndNeedADuration() {
        let reply = Data(#"""
            {"tmdb_id": 1438, "type": "tv", "season": 1, "episode": 2,
             "intro": [{"start_ms": 101222, "end_ms": 196777}, {"start_ms": 900000, "end_ms": 950000}],
             "recap": [{"start_ms": 0, "end_ms": 45000}],
             "credits": [{"start_ms": 3397120, "end_ms": null}]}
            """#.utf8)
        let withDuration = TheIntroDBClient.decode(reply, duration: 3460)
        XCTAssertEqual(withDuration.map(\.type), ["recap", "intro", "credits"])
        XCTAssertEqual(withDuration[1].startTimeOffset, 101_222)
        XCTAssertEqual(withDuration[1].endTimeOffset, 196_777)
        XCTAssertEqual(withDuration[2].endTimeOffset, 3_460_000)
        XCTAssertEqual(Set(withDuration.compactMap(\.id)).count, 3)

        let without = TheIntroDBClient.decode(reply, duration: nil)
        XCTAssertEqual(without.map(\.type), ["recap", "intro"])
    }

    func test_theIntroDB_badSegmentsAndEmptyRepliesGiveNothing() {
        XCTAssertTrue(TheIntroDBClient.decode(Data(#"{"intro": [{"start_ms": 500, "end_ms": 100}]}"#.utf8), duration: 60).isEmpty)
        XCTAssertTrue(TheIntroDBClient.decode(Data(#"{"tmdb_id": 1}"#.utf8), duration: 60).isEmpty)
        XCTAssertTrue(TheIntroDBClient.decode(Data("not json".utf8), duration: 60).isEmpty)
    }

    // MARK: - Who wins

    func test_merged_primaryWinsPerKind_fallbackFillsTheRest() {
        let introDB = [PlexMarker(id: -9001, type: "intro", startTimeOffset: 10_000, endTimeOffset: 70_000)]
        let theIntroDB = [PlexMarker(id: -9011, type: "intro", startTimeOffset: 12_000, endTimeOffset: 72_000),
                          PlexMarker(id: -9013, type: "credits", startTimeOffset: 2_000_000, endTimeOffset: 2_100_000)]
        let merged = CommunityMarkers.merged(primary: introDB, fallback: theIntroDB)
        XCTAssertEqual(merged.map(\.id), [-9001, -9013])
    }

    func test_filling_keepsTheServersKinds() {
        let server = [PlaybackMarker(kind: .intro, start: 5, end: 60)]
        let community = [PlexMarker(id: -9011, type: "intro", startTimeOffset: 0, endTimeOffset: 90_000),
                         PlexMarker(id: -9012, type: "recap", startTimeOffset: 0, endTimeOffset: 4_000)]
        let filled = CommunityMarkers.filling(server, with: community)
        XCTAssertEqual(filled, [PlaybackMarker(kind: .recap, start: 0, end: 4), PlaybackMarker(kind: .intro, start: 5, end: 60)])
    }

    // MARK: - Provider fill

    private func episode(provider: String) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: provider, itemID: "ep1"), kind: .episode, title: "Pilot", sortTitle: nil,
            overview: nil, year: nil, runtime: 3000, parentRef: MediaItemRef(providerID: provider, itemID: "season1"),
            grandparentRef: MediaItemRef(providerID: provider, itemID: "show1"),
            episodeNumber: 4, seasonNumber: 2, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil)
    }

    private func showDetail(_ item: MediaItem, ids: [String: String]) -> MediaItemDetail {
        var detail = MediaItemDetail(item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
                                     chapters: [], mediaSources: [], trailerURL: nil, contentRating: nil,
                                     nextEpisode: nil, collections: [])
        detail.externalIDs = ids
        return detail
    }

    func test_jellyfinEpisode_isFilledByTheShowsIDs() async {
        let provider = StubMediaProvider(id: "jf", kind: .jellyfin)
        let item = episode(provider: "jf")
        provider.extrasResult = PlaybackExtras(markers: [PlaybackMarker(kind: .credits, start: 2900, end: 3000)])
        provider.detailResult = showDetail(item, ids: ["tmdb": "1438", "imdb": "tt0306414", "tvdb": "79126"])
        let asked = OSAllocatedUnfairLock<[String]>(initialState: [])
        let extras = await CommunityMarkers.extras(from: provider, item: item, sourceID: "s", enabled: true) { ids, season, ep, duration in
            asked.withLock { $0.append("\(ids.tmdb ?? 0) \(ids.imdb ?? "-") \(ids.tvdb ?? 0) S\(season)E\(ep) \(Int(duration ?? 0))") }
            return [PlexMarker(id: -9011, type: "intro", startTimeOffset: 30_000, endTimeOffset: 90_000),
                    PlexMarker(id: -9013, type: "credits", startTimeOffset: 2_800_000, endTimeOffset: 3_000_000)]
        }
        XCTAssertEqual(asked.withLock { $0 }, ["1438 tt0306414 79126 S2E4 3000"])
        XCTAssertEqual(provider.playbackCalls, ["extras(ep1,s)", "detail(show1)"])
        XCTAssertEqual(extras.markers, [PlaybackMarker(kind: .intro, start: 30, end: 90),
                                        PlaybackMarker(kind: .credits, start: 2900, end: 3000)])
    }

    func test_noLookup_whenOff_forPlexOrXtream_orWhenTheServerHasEveryKind() async {
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let lookup: CommunityMarkers.Lookup = { _, _, _, _ in asked.withLock { $0 += 1 }; return [] }

        let off = StubMediaProvider(id: "jf", kind: .jellyfin)
        _ = await CommunityMarkers.extras(from: off, item: episode(provider: "jf"), sourceID: nil, enabled: false, lookup: lookup)
        for kind in [MediaProviderKind.plex, .xtream] {
            let own = StubMediaProvider(id: "p", kind: kind)
            _ = await CommunityMarkers.extras(from: own, item: episode(provider: "p"), sourceID: nil, enabled: true, lookup: lookup)
        }
        let full = StubMediaProvider(id: "emby", kind: .emby)
        full.extrasResult = PlaybackExtras(markers: [PlaybackMarker(kind: .intro, start: 1, end: 2),
                                                     PlaybackMarker(kind: .recap, start: 0, end: 1),
                                                     PlaybackMarker(kind: .credits, start: 50, end: 60)])
        _ = await CommunityMarkers.extras(from: full, item: episode(provider: "emby"), sourceID: nil, enabled: true, lookup: lookup)
        XCTAssertEqual(asked.withLock { $0 }, 0)
    }
}
