// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamVODTests.swift
//  RivuletTests
//
//  Films and series from an Xtream panel: the replies panels really send,
//  with their mixed types, and the stream URLs.
//

import XCTest
@testable import Rivulet

final class XtreamVODTests: XCTestCase {
    private func json(_ text: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private let service = XtreamService(account: XtreamAccount(server: URL(string: "http://panel.example:8080")!,
                                                               username: "user", password: "p/a?ss"))

    // MARK: Lists

    func test_categories_mixedTypes_andEmptyReplies() {
        let parsed = XtreamService.categories(from: json(#"""
            [{"category_id": 5, "category_name": "Films NL"}, {"category_id": "7", "category_name": " Kids "},
             {"category_id": "8"}]
            """#))
        XCTAssertEqual(parsed, [XtreamVODCategory(id: "5", name: "Films NL"), XtreamVODCategory(id: "7", name: "Kids")])
        for empty in ["[]", "{}", "false", "null"] {
            XCTAssertTrue(XtreamService.categories(from: json(empty)).isEmpty, empty)
        }
    }

    func test_movies() {
        let parsed = XtreamService.movies(from: json(#"""
            [{"num": 1, "name": "Heat (1995)", "stream_type": "movie", "stream_id": 123,
              "stream_icon": "http://img.example/heat.jpg", "rating": "8.3", "rating_5based": 4.1,
              "added": "1690000000", "category_id": "5", "container_extension": "mkv", "year": "1995"},
             {"name": "##### NEW #####", "stream_id": 1},
             {"name": "Unrated", "stream_id": "124", "rating": "0", "rating_5based": "3.5", "stream_icon": "",
              "added": 0},
             {"name": "No id"}]
            """#))
        XCTAssertEqual(parsed.count, 2)
        let heat = parsed[0]
        XCTAssertEqual(heat.id, "123")
        XCTAssertEqual(heat.categoryId, "5")
        XCTAssertEqual(heat.posterURL, URL(string: "http://img.example/heat.jpg"))
        XCTAssertEqual(heat.rating, 8.3)
        XCTAssertEqual(heat.addedAt, Date(timeIntervalSince1970: 1_690_000_000))
        XCTAssertEqual(heat.year, 1995)
        XCTAssertEqual(heat.containerExtension, "mkv")
        let unrated = parsed[1]
        XCTAssertEqual(unrated.rating, 7.0)
        XCTAssertNil(unrated.posterURL)
        XCTAssertNil(unrated.addedAt)
        XCTAssertEqual(unrated.containerExtension, "mp4")
    }

    func test_movieInfo() {
        let info = XtreamService.movieInfo(from: json(#"""
            {"info": {"plot": "A heist.", "genre": "Crime", "cast": "Al Pacino", "director": "Michael Mann",
                      "releasedate": "1995-12-15", "duration_secs": "10200", "duration": "02:50:00",
                      "backdrop_path": ["", "http://img.example/heat-bd.jpg"], "movie_image": "http://img.example/p.jpg",
                      "tmdb_id": "949"},
             "movie_data": {"stream_id": 123, "container_extension": "mkv"}}
            """#))
        XCTAssertEqual(info.plot, "A heist.")
        XCTAssertEqual(info.duration, 10200)
        XCTAssertEqual(info.backdropURL, URL(string: "http://img.example/heat-bd.jpg"))
        XCTAssertEqual(info.tmdbId, "949")
        XCTAssertEqual(info.containerExtension, "mkv")
        XCTAssertEqual(info.releaseDate, XtreamService.day("1995-12-15"))
    }

    func test_movieInfo_durationFromClock_andMissingParts() {
        let info = XtreamService.movieInfo(from: json(#"{"info": {"duration": "01:30:05", "tmdb_id": 0}}"#))
        XCTAssertEqual(info.duration, 5405)
        XCTAssertNil(info.tmdbId)
        XCTAssertNil(XtreamService.movieInfo(from: json("[]")).plot)
    }

    func test_series() {
        let parsed = XtreamService.series(from: json(#"""
            [{"num": 1, "name": "The Wire", "series_id": 12, "cover": "http://img.example/wire.jpg",
              "plot": "Baltimore.", "genre": "Drama", "releaseDate": "2002-06-02", "last_modified": "1700000000",
              "rating": "9.3", "backdrop_path": "http://img.example/wire-bd.jpg", "category_id": 3}]
            """#))
        XCTAssertEqual(parsed, [XtreamSeries(
            id: "12", name: "The Wire", categoryId: "3", coverURL: URL(string: "http://img.example/wire.jpg"),
            backdropURL: URL(string: "http://img.example/wire-bd.jpg"), plot: "Baltimore.", genre: "Drama",
            rating: 9.3, year: 2002, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))])
    }

    // MARK: Series info

    func test_seriesInfo_episodesKeyedBySeason() {
        let info = XtreamService.seriesInfo(from: json(#"""
            {"seasons": [{"season_number": 0, "name": "Specials"}, {"season_number": "2", "name": "Season 2"},
                         {"season_number": 1, "name": "Season 1", "cover": "http://img.example/s1.jpg"}],
             "episodes": {"2": [{"id": "2001", "episode_num": "1", "title": "S2E1", "container_extension": "mp4",
                                 "season": 2, "info": {"duration_secs": 3600}}],
                          "1": [{"id": "1002", "episode_num": 2, "title": "S1E2", "container_extension": "mkv",
                                 "info": {"plot": "Two.", "movie_image": "http://img.example/e2.jpg"}},
                                {"id": "1001", "episode_num": 1, "title": "S1E1", "season": "1",
                                 "container_extension": "mkv", "added": "1690000000"}]}}
            """#))
        XCTAssertEqual(info.episodes.map(\.id), ["1001", "1002", "2001"])
        XCTAssertEqual(info.episodes[1].season, 1)
        XCTAssertEqual(info.episodes[1].plot, "Two.")
        XCTAssertEqual(info.episodes[2].duration, 3600)
        // The empty Specials season is left out.
        XCTAssertEqual(info.seasons.map(\.number), [1, 2])
        XCTAssertEqual(info.seasons[0].coverURL, URL(string: "http://img.example/s1.jpg"))
    }

    func test_seriesInfo_episodesAsArrayOfSeasons_andSeasonsMissingFromTheList() {
        let info = XtreamService.seriesInfo(from: json(#"""
            {"seasons": [], "episodes": [[{"id": 11, "episode_num": 1, "season": 1}],
                                         [{"id": 21, "episode_num": 1, "season": 2}, {"id": "bad"}]]}
            """#))
        XCTAssertEqual(info.episodes.map(\.id), ["11", "21"])
        XCTAssertEqual(info.seasons.map(\.number), [1, 2])
        XCTAssertEqual(info.episodes[0].containerExtension, "mp4")
    }

    func test_seriesInfo_emptyReplies() {
        for empty in ["[]", "{}", "null", #"{"episodes": null}"#] {
            let info = XtreamService.seriesInfo(from: json(empty))
            XCTAssertTrue(info.episodes.isEmpty && info.seasons.isEmpty, empty)
        }
    }

    // MARK: URLs

    func test_streamURLs_escapeEachSegment() {
        XCTAssertEqual(service.movieURL(movieId: "123", containerExtension: "mkv").absoluteString,
                       "http://panel.example:8080/movie/user/p%2Fa%3Fss/123.mkv")
        XCTAssertEqual(service.episodeURL(episodeId: "1001", containerExtension: ".MP4").absoluteString,
                       "http://panel.example:8080/series/user/p%2Fa%3Fss/1001.mp4")
    }

    func test_fileExtension() {
        XCTAssertEqual(XtreamService.fileExtension("MKV"), "mkv")
        XCTAssertEqual(XtreamService.fileExtension(""), "mp4")
        XCTAssertEqual(XtreamService.fileExtension("m/p4"), "mp4")
    }

    // MARK: Year in the name

    func test_yearAtTheEndOfTheName_becomesTheYear() {
        XCTAssertEqual(XtreamService.splitYear("┃MULTI┃ White Chicks - 2004").name, "┃MULTI┃ White Chicks")
        XCTAssertEqual(XtreamService.splitYear("┃MULTI┃ White Chicks - 2004").year, 2004)
        XCTAssertEqual(XtreamService.splitYear("Wildschut [Stronghold] (1985)").year, 1985)
        XCTAssertEqual(XtreamService.splitYear("Wildschut [Stronghold] (1985)").name, "Wildschut [Stronghold]")
        XCTAssertNil(XtreamService.splitYear("2012").year)
        XCTAssertNil(XtreamService.splitYear("Blade Runner 2049").year)
        XCTAssertEqual(XtreamService.splitYear("Blade Runner 2049 - 2017").name, "Blade Runner 2049")
        let parsed = XtreamService.movies(from: try! JSONSerialization.jsonObject(with: Data(#"[{"stream_id": 1, "name": "┃NL┃  Heat (1995)"}]"#.utf8)))
        XCTAssertEqual(parsed.first?.name, "Heat")
        XCTAssertEqual(parsed.first?.year, 1995)
        XCTAssertEqual(parsed.first?.tag, "NL")
        XCTAssertEqual(XtreamService.splitTags("[EN] ┃FR-4K┃ Dune").tags, ["EN", "FR-4K"])
        XCTAssertTrue(XtreamService.splitTags("Dune").tags.isEmpty)
    }

    func test_tagsInFrontOfTheName_areLeftOut() {
        XCTAssertEqual(XtreamService.cleanName("┃NL┃  Origin"), "Origin")
        XCTAssertEqual(XtreamService.cleanName("┃DE┃Das etruskische Lächeln (2018)"), "Das etruskische Lächeln (2018)")
        XCTAssertEqual(XtreamService.cleanName("┃FR-4K┃ Dune"), "Dune")
        XCTAssertEqual(XtreamService.cleanName("┃VO| Heat"), "Heat")
        XCTAssertEqual(XtreamService.cleanName("[EN] ┃MULTI┃ Up"), "Up")
        XCTAssertEqual(XtreamService.cleanName("NL | Flikken Maastricht"), "Flikken Maastricht")
        XCTAssertEqual(XtreamService.cleanName("┃MULTI / LINGO┃ NETFLIX"), "NETFLIX")
        XCTAssertEqual(XtreamService.cleanName("┃GR┃ Μάρκο Πόλο [Marco Polo: One Hundred Eyes]"), "Μάρκο Πόλο [Marco Polo: One Hundred Eyes]")
        // Not tags: a title's own words, and a name that is nothing else.
        XCTAssertEqual(XtreamService.cleanName("Mission: Impossible"), "Mission: Impossible")
        XCTAssertEqual(XtreamService.cleanName("┃US┃ CSI: Miami"), "CSI: Miami")
        XCTAssertEqual(XtreamService.cleanName("M*A*S*H"), "M*A*S*H")
        XCTAssertEqual(XtreamService.cleanName("┃NL┃ [REC] 2"), "[REC] 2")
        XCTAssertEqual(XtreamService.cleanName("| PAK\u{00A0}| Golden Boy"), "Golden Boy")
        XCTAssertEqual(XtreamService.cleanName("| USA┃ Malditos"), "Malditos")
        XCTAssertEqual(XtreamService.cleanName("┃NL┃"), "┃NL┃")
        XCTAssertEqual(XtreamService.cleanName("┃NL Liever verliefd"), "Liever verliefd")
        XCTAssertEqual(XtreamService.splitYear("Mutronics (1991) (VF)").name, "Mutronics")
        XCTAssertEqual(XtreamService.splitYear("Mutronics (1991) (VF)").year, 1991)
        XCTAssertEqual(XtreamService.splitYear(XtreamService.cleanName("┃GR┃ Human.Vapor [ガス人間 ](2026)")).year, 2026)
    }

    func test_episodeTitle_withoutTagsShowAndNumber() {
        XCTAssertEqual(XtreamVODMapping.episodeTitle("| LINGO |   Breaking Bad - S01E01 - Pilot"), "Pilot")
        XCTAssertEqual(XtreamVODMapping.episodeTitle("┃NL┃ S.W.A.T. - S02E10 - Fallen"), "Fallen")
        XCTAssertEqual(XtreamVODMapping.episodeTitle("The Wire S1E3 The Buys"), "The Buys")
        XCTAssertEqual(XtreamVODMapping.episodeTitle("Breaking Bad - S01E01"), nil)
        XCTAssertEqual(XtreamVODMapping.episodeTitle("Pilot"), "Pilot")
        XCTAssertEqual(XtreamVODMapping.episodeTitle("CSI: Miami"), "CSI: Miami")
        XCTAssertNil(XtreamVODMapping.episodeTitle(""))
    }
}
