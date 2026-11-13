// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBLookupTests.swift
//  RivuletTests
//
//  Details for Xtream titles from TMDB with the viewer's own key: only a sure
//  match counts, a v3 key and a v4 token travel differently, and the details
//  fill a page without replacing the panel's title.
//

import XCTest
@testable import Rivulet

private final class FakeTMDB: URLProtocol {
    nonisolated(unsafe) static var replies: [String: String] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        let path = request.url?.path ?? ""
        let language = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "language" }?.value ?? ""
        guard let body = Self.replies["\(path)|\(language)"] ?? Self.replies[path], let url = request.url else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                                                  headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class TMDBLookupTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FakeTMDB.requests = []
        FakeTMDB.replies = [
            "/3/search/movie": #"{"results": [{"id": 1, "title": "Heat", "release_date": "1986-01-01"}, {"id": 949, "title": "Heat", "release_date": "1995-12-15"}]}"#,
            "/3/movie/949|nl-NL": #"""
                {"id": 949, "title": "Heat", "overview": "", "release_date": "1995-12-15", "runtime": 170,
                 "genres": [{"name": "Misdaad"}, {"name": "Drama"}], "poster_path": "/p.jpg", "backdrop_path": "/b.jpg",
                 "credits": {"cast": [{"name": "Al Pacino", "character": "Vincent Hanna", "profile_path": "/al.jpg"}],
                             "crew": [{"name": "Michael Mann", "job": "Director"}, {"name": "X", "job": "Writer"}]}}
                """#,
            "/3/movie/949|en-US": #"{"id": 949, "title": "Heat", "overview": "A heist."}"#,
        ]
    }

    private func lookup(key: String? = "0123456789abcdef0123456789abcdef") -> TMDBLookup {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeTMDB.self]
        return TMDBLookup(apiKey: { key }, session: URLSession(configuration: configuration), language: "nl-NL")
    }

    func test_searchByNameAndYear_takesTheYearsMatch_withEnglishPlotWhenNoTranslation() async {
        let found = await lookup().title(.movie, tmdbID: nil, name: "Heat", year: 1995)
        XCTAssertEqual(found?.id, 949)
        XCTAssertEqual(found?.overview, "A heist.")
        XCTAssertEqual(found?.runtime, 170 * 60)
        XCTAssertEqual(found?.genres, ["Misdaad", "Drama"])
        XCTAssertEqual(found?.cast.first?.photoURL?.absoluteString, "https://image.tmdb.org/t/p/w185/al.jpg")
        XCTAssertEqual(found?.directors, ["Michael Mann"])
        XCTAssertTrue(FakeTMDB.requests.allSatisfy { $0.url?.query?.contains("api_key=") == true })
    }

    func test_withoutAYear_onlyTheSameTitleMatches() {
        let results: [[String: Any]] = [["id": 5, "title": "Heat Wave"], ["id": 949, "title": "Heat"]]
        XCTAssertEqual(TMDBLookup.match(results, kind: .movie, name: "heat", year: nil), 949)
        XCTAssertNil(TMDBLookup.match([["id": 5, "title": "Heat Wave"]], kind: .movie, name: "Heat", year: nil))
        XCTAssertNil(TMDBLookup.match([["id": 1, "title": "Heat", "release_date": "1986-01-01"]],
                                      kind: .movie, name: "Heat", year: 1995))
    }

    func test_noKey_asksNothing_andAV4TokenIsABearer() async {
        let none = await lookup(key: nil).title(.movie, tmdbID: "949", name: "Heat", year: nil)
        XCTAssertNil(none)
        XCTAssertTrue(FakeTMDB.requests.isEmpty)
        let token = String(repeating: "t", count: 200)
        _ = await lookup(key: token).title(.movie, tmdbID: "949", name: "Heat", year: nil)
        XCTAssertEqual(FakeTMDB.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertFalse(FakeTMDB.requests.first?.url?.query?.contains("api_key") ?? true)
    }

    func test_enriched_keepsThePanelsTitleAndPoster() async throws {
        let looked = await lookup().title(.movie, tmdbID: "949", name: "Heat", year: nil)
        let found = try XCTUnwrap(looked)
        let item = MediaItem(
            ref: MediaItemRef(providerID: "xtream:x", itemID: "m|1"), kind: .movie, title: "Heat", sortTitle: nil,
            overview: "Plot en français.", year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: URL(string: "http://panel/p.jpg"), backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil, editionTitle: "🇫🇷")
        let detail = MediaItemDetail(item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
                                     chapters: [], mediaSources: [], trailerURL: nil, contentRating: nil,
                                     nextEpisode: nil, collections: [])
        let enriched = XtreamVODMapping.enriched(detail, with: found)
        XCTAssertEqual(enriched.item.title, "Heat")
        XCTAssertEqual(enriched.item.artwork.poster?.absoluteString, "http://panel/p.jpg")
        XCTAssertEqual(enriched.item.artwork.backdrop?.absoluteString, "https://image.tmdb.org/t/p/w1280/b.jpg")
        XCTAssertEqual(enriched.item.overview, "A heist.")
        XCTAssertEqual(enriched.item.year, 1995)
        XCTAssertEqual(enriched.item.editionTitle, "🇫🇷")
        XCTAssertEqual(enriched.cast.map(\.name), ["Al Pacino"])
        XCTAssertEqual(enriched.externalIDs["tmdb"], "949")
    }
}
