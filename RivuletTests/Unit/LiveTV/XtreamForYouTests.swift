// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamForYouTests.swift
//  RivuletTests
//
//  The For You row of an Xtream source's films and series: what it starts from,
//  how TMDB's recommendations find the panel's copies, and how the viewer's
//  categories fill the rest, never offering what was already watched.
//

import XCTest
@testable import Rivulet

@MainActor
final class XtreamForYouTests: XCTestCase {
    private let source = "xtream:abc"
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func record(_ watched: Bool, position: TimeInterval = 0, daysAgo: Double = 1) -> XtreamWatchRecord {
        XtreamWatchRecord(position: position, duration: 6000, watched: watched,
                          updatedAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    private func candidate(_ id: String, _ name: String, year: Int? = nil, category: String = "c1",
                           rating: Double? = nil, addedDaysAgo: Double = 400) -> XtreamForYou.Candidate {
        .init(id: id, name: name, year: year, categoryId: category, rating: rating,
              addedAt: now.addingTimeInterval(-addedDaysAgo * 86_400))
    }

    func test_seeds_favoritesFirst_thenWatched_thenBegun_andSeriesFromTheirEpisodes() {
        var state = XtreamVODMapping.State()
        state.records[XtreamVODMapping.movieKey(source: source, movieID: "watched")] = record(true)
        state.records[XtreamVODMapping.movieKey(source: source, movieID: "begun")] = record(false, position: 600)
        state.records[XtreamVODMapping.movieKey(source: source, movieID: "glance")] = record(false, position: 20)
        state.records[XtreamVODMapping.episodeKey(source: source, seriesID: "s1", episodeID: "e1")] = record(true)
        state.favorites.insert(XtreamVODMapping.movieKey(source: source, movieID: "fav"))
        let movies = XtreamForYou.seeds(state, source: source, library: .movies, now: now).map(\.id)
        XCTAssertEqual(movies, ["fav", "watched", "begun"])
        XCTAssertEqual(XtreamForYou.seeds(state, source: source, library: .series, now: now).map(\.id), ["s1"])
        // Marked unwatched: a blank record, offered again.
        state.records[XtreamVODMapping.movieKey(source: source, movieID: "unwatched")] = record(false, position: 0)
        XCTAssertEqual(XtreamForYou.seen(state, source: source, library: .movies), ["watched", "begun", "glance", "fav"])
    }

    func test_tmdbRecommendations_findThePanelsCopy_byTitleOrOriginal_andYear() {
        let index = XtreamForYou.Index([
            candidate("1", "Heat", year: 1995), candidate("2", "Heat", year: 1986),
            candidate("3", "The Insider"), candidate("4", "Le Samouraï", year: 1967),
        ])
        func rec(_ title: String, original: String? = nil, _ year: Int?) -> TMDBRecommendation {
            TMDBRecommendation(id: 0, title: title, originalTitle: original, year: year)
        }
        XCTAssertEqual(index.match(rec("Heat", 1995)), "1")
        XCTAssertEqual(index.match(rec("Heat", 1987)), "2")
        XCTAssertEqual(index.match(rec("The Insider", 1999)), "3")
        XCTAssertEqual(index.match(rec("The Samurai", original: "Le Samouraï", 1967)), "4")
        XCTAssertNil(index.match(rec("Heat", 2026)))
    }

    func test_tmdbPicks_rankByHowManySeedsLeadThere_andSkipWhatWasSeen() {
        let index = XtreamForYou.Index([candidate("a", "Alpha"), candidate("b", "Beta"), candidate("c", "Gamma")])
        let rec = { (title: String) in TMDBRecommendation(id: 0, title: title, originalTitle: nil, year: nil) }
        let picks = XtreamForYou.tmdbPicks([
            (1, [rec("Alpha"), rec("Beta"), rec("Unknown")]),
            (1, [rec("Beta"), rec("Gamma")]),
        ], index: index, seen: ["c"])
        XCTAssertEqual(picks, ["b", "a"])
    }

    func test_categoryPicks_favorTheViewersCategories_thenRatingAndNewness() {
        let candidates = [
            candidate("seed", "Seed", category: "action"),
            candidate("old", "Old", category: "action", rating: 6),
            candidate("new", "New", category: "action", rating: 6, addedDaysAgo: 3),
            candidate("best", "Best", category: "action", rating: 9),
            candidate("drama", "Drama", category: "drama", rating: 10),
        ]
        let picks = XtreamForYou.categoryPicks(candidates, seeds: [.init(id: "seed", weight: 1)], seen: ["seed"], now: now)
        XCTAssertEqual(picks, ["best", "new", "old"])
        XCTAssertEqual(XtreamForYou.merge(["new", "x"], picks), ["new", "x", "best", "old"])
    }

    func test_tmdbRecommendationsReply_isRead() {
        let found = TMDBLookup.recommendations([
            ["id": 2, "name": "Dark", "original_name": "Dark", "first_air_date": "2017-12-01"],
            ["name": "No id"],
        ], kind: .tv)
        XCTAssertEqual(found, [TMDBRecommendation(id: 2, title: "Dark", originalTitle: "Dark", year: 2017)])
    }

    func test_genresOutweighTheCategory_andAPlaceholderTenRatesMiddling() {
        let seed = XtreamForYou.Candidate(id: "ted", name: "Ted Lasso", year: 2020, categoryId: "appletv", rating: 8,
                                          addedAt: nil, genres: XtreamForYou.genres("Drama / Comedy"))
        func series(_ id: String, _ name: String, rating: Double?, genre: String) -> XtreamForYou.Candidate {
            .init(id: id, name: name, year: 2024, categoryId: "appletv", rating: rating, addedAt: nil,
                  genres: XtreamForYou.genres(genre))
        }
        let candidates = [
            seed,
            series("new", "A New Thriller", rating: 10, genre: "Action & Adventure / Crime"),
            series("both", "Shrinking", rating: 8, genre: "Drama / Comedy"),
            series("drama", "Severance", rating: 8, genre: "Drama"),
            series("both2", "Shrinking", rating: 7, genre: "Comedy / Drama"),
        ]
        let picks = XtreamForYou.categoryPicks(candidates, seeds: [.init(id: "ted", weight: 1.5)], seen: ["ted"], now: now)
        // Both genres beat one; the placeholder 10 counts for nothing; one copy per name.
        XCTAssertEqual(picks, ["both", "drama", "new"])
        XCTAssertEqual(XtreamForYou.reliableRating(10), 6.5)
        XCTAssertEqual(XtreamForYou.reliableRating(8.2), 8.2)
        XCTAssertEqual(XtreamForYou.genres("Action & Adventure, Crime"), ["action adventure", "crime"])
    }

    func test_languages_keepTheViewers_thenUnknown_andFilterRecommendations() {
        XCTAssertEqual(XtreamForYou.inLanguages(["ko", "en", "unknown", "en2"], languages: ["en"],
                                                languageOf: ["ko": "ko", "en": "en", "en2": "en"]),
                       ["en", "en2", "unknown"])
        XCTAssertEqual(XtreamForYou.inLanguages(["a", "b"], languages: [], languageOf: ["a": "ko"]), ["a", "b"])
        let index = XtreamForYou.Index([candidate("1", "Kingdom"), candidate("2", "Succession")])
        let recs = [TMDBRecommendation(id: 1, title: "Kingdom", originalTitle: nil, year: nil, originalLanguage: "ko"),
                    TMDBRecommendation(id: 2, title: "Succession", originalTitle: nil, year: nil, originalLanguage: "en")]
        XCTAssertEqual(XtreamForYou.tmdbPicks([(1, recs)], index: index, seen: [], languages: ["en"]), ["2"])
        XCTAssertEqual(XtreamForYou.merge(["1"], ["3", "1", "4"], names: ["3": "kingdom", "1": "kingdom"]), ["1", "4"])
    }
}
