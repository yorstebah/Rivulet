// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamVODProviderTests.swift
//  RivuletTests
//
//  Xtream films and series as a media server: the ids it mints, the sorting,
//  A to Z and search it does for the panel, the day-long list cache, and the
//  provider against a fake panel.
//

import XCTest
import os
@testable import Rivulet

/// Answers `player_api.php` by its `action`, and counts the requests.
private final class FakePanel: URLProtocol {
    nonisolated(unsafe) static var replies: [String: String] = [:]
    nonisolated(unsafe) static var requests: [String] = []
    nonisolated(unsafe) static var failing = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let action = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "action" }?.value ?? (request.url?.path ?? "")
        Self.requests.append(action)
        guard !Self.failing, let body = Self.replies[action], let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class XtreamVODProviderTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var store: XtreamWatchProgressStore!
    private let source = "xtream:abc123"
    private let account = XtreamAccount(server: URL(string: "http://panel.example:8080")!, username: "user", password: "pass")

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(component: "XtreamVODTests-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "XtreamVODProviderTests-\(UUID().uuidString)")
        store = XtreamWatchProgressStore(defaults: defaults)
        FakePanel.requests = []
        FakePanel.failing = false
        FakePanel.replies = [
            "get_vod_categories": #"[{"category_id": "1", "category_name": "Action"}, {"category_id": "2", "category_name": "Kids"}, {"category_id": "9", "category_name": "Empty"}]"#,
            "get_vod_streams": #"""
                [{"stream_id": 10, "name": "Heat", "category_id": "1", "added": "1000", "year": "1995", "rating": "8.3",
                  "container_extension": "mkv", "stream_icon": "http://img.example/heat.jpg"},
                 {"stream_id": 11, "name": "Up", "category_id": "2", "added": "3000", "year": "2009", "container_extension": "mp4"},
                 {"stream_id": 12, "name": "1917", "category_id": "1", "added": "2000", "year": "2019"}]
                """#,
            "get_vod_info": #"{"info": {"plot": "A heist.", "genre": "Crime, Drama", "director": "Michael Mann", "duration_secs": 10200, "tmdb_id": "949"}, "movie_data": {"container_extension": "mkv"}}"#,
            "get_series_categories": #"[{"category_id": "5", "category_name": "Drama"}]"#,
            "get_series": #"[{"series_id": 70, "name": "The Wire", "category_id": "5", "last_modified": "5000", "cover": "http://img.example/wire.jpg"}]"#,
            "get_series_info": #"""
                {"seasons": [{"season_number": 1, "name": "Season 1"}, {"season_number": 0, "name": "Specials"}],
                 "episodes": {"1": [{"id": "701", "episode_num": 1, "title": "The Target", "container_extension": "mkv",
                                     "info": {"duration_secs": 3600}},
                                    {"id": "702", "episode_num": 2, "title": "The Detail", "container_extension": "mkv"}]}}
                """#,
        ]
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakePanel.self]
        return URLSession(configuration: configuration)
    }

    private func provider() -> XtreamVODProvider {
        let store = store!
        // No key: tests never reach TMDB, whatever the simulator's Keychain holds.
        return XtreamVODProvider(sourceID: source, displayName: "IPTV", account: account, cacheDirectory: directory,
                                 session: session(), tmdb: TMDBLookup(apiKey: { nil }), watchStore: { store })
    }

    private func ref(_ id: XtreamVODID) -> MediaItemRef { MediaItemRef(providerID: source, itemID: id.itemID) }

    // MARK: - Ids and keys

    func test_ids_roundTrip_andBadOnesAreRejected() {
        let ids: [XtreamVODID] = [.movie("10"), .series("70"), .season(seriesID: "70", number: 0),
                                  .episode(seriesID: "70", episodeID: "701"), .category(library: .series, id: "5")]
        for id in ids { XCTAssertEqual(XtreamVODID(itemID: id.itemID), id, id.itemID) }
        for bad in ["", "m|", "x|1", "n|70|one", "e|70|", "c|films|1", "m"] { XCTAssertNil(XtreamVODID(itemID: bad), bad) }
    }

    func test_watchKeys_leadBackToTheirTitles_onTheirOwnSourceOnly() {
        let movie = XtreamVODMapping.movieKey(source: source, movieID: "10")
        let episode = XtreamVODMapping.episodeKey(source: source, seriesID: "70", episodeID: "701")
        XCTAssertEqual(XtreamVODMapping.id(fromKey: movie, source: source), .movie("10"))
        XCTAssertEqual(XtreamVODMapping.id(fromKey: episode, source: source), .episode(seriesID: "70", episodeID: "701"))
        XCTAssertNil(XtreamVODMapping.id(fromKey: movie, source: "xtream:other"))
    }

    // MARK: - Sorting, A to Z and search

    private func sortable(_ name: String, added: Double? = nil, year: Int? = nil) -> XtreamVODMapping.Sortable {
        .init(name: name, added: added.map(Date.init(timeIntervalSince1970:)), year: year, rating: nil)
    }

    func test_byName_numbersAndSymbolsFirst_thenLetters_accentsFolded() {
        let values = ["Up", "1917", "Écoute", "alien", "[NL] Heat"].map { sortable($0) }
        XCTAssertEqual(XtreamVODMapping.order(values, by: .titleAsc).map { values[$0].name },
                       ["[NL] Heat", "1917", "alien", "Écoute", "Up"])
        XCTAssertEqual(XtreamVODMapping.letterCounts(values.map(\.name)).map(\.title), ["#", "A", "E", "U"])
        XCTAssertEqual(XtreamVODMapping.letterCounts(values.map(\.name)).first?.size, 2)
    }

    func test_byDate_titlesWithoutOneGoLast() {
        let values = [sortable("A", added: 1), sortable("B"), sortable("C", added: 3)]
        XCTAssertEqual(XtreamVODMapping.order(values, by: .addedAtDesc), [2, 0, 1])
        XCTAssertEqual(XtreamVODMapping.order(values, by: .addedAtAsc), [0, 2, 1])
    }

    func test_page_isASliceOfTheSortedList() {
        let names = ["d", "a", "c", "b", "e"]
        let page = XtreamVODMapping.page(names, sortable: { self.sortable($0) }, sort: .titleAsc, page: Page(offset: 2, limit: 2))
        XCTAssertEqual(page.items, ["c", "d"])
        XCTAssertEqual(page.total, 5)
        XCTAssertTrue(XtreamVODMapping.page(names, sortable: { self.sortable($0) }, sort: .titleAsc,
                                            page: Page(offset: 9, limit: 2)).items.isEmpty)
    }

    func test_search_wordStartsFirst_andEveryWordMustMatch() {
        let names = ["Superheat", "Heat", "The Heat Is On", "Up"]
        XCTAssertEqual(XtreamVODMapping.search("heat", in: names, name: { $0 }, limit: 10), ["Heat", "The Heat Is On", "Superheat"])
        XCTAssertEqual(XtreamVODMapping.search("heat on", in: names, name: { $0 }, limit: 10), ["The Heat Is On"])
        XCTAssertTrue(XtreamVODMapping.search("  ", in: names, name: { $0 }, limit: 10).isEmpty)
    }

    func test_nextEpisode_resumesFirst_thenFollowsTheLastWatched() {
        func episode(_ n: Int, played: Bool = false, offset: TimeInterval = 0) -> MediaItem {
            var item = XtreamVODMapping.item(
                XtreamEpisode(id: "\(n)", season: 1, number: n, title: nil, plot: nil, duration: nil, imageURL: nil,
                              addedAt: nil, containerExtension: "mkv"),
                of: XtreamSeries(id: "70", name: "S", categoryId: nil, coverURL: nil, backdropURL: nil, plot: nil,
                                 genre: nil, rating: nil, year: nil, updatedAt: nil),
                provider: source, state: .init())
            item.userState = MediaUserState(isPlayed: played, viewOffset: offset, isFavorite: false, lastViewedAt: nil)
            return item
        }
        XCTAssertEqual(XtreamVODMapping.nextEpisode([episode(1, played: true), episode(2), episode(3)])?.episodeNumber, 2)
        XCTAssertEqual(XtreamVODMapping.nextEpisode([episode(1, played: true), episode(2), episode(3, offset: 300)])?.episodeNumber, 3)
        XCTAssertEqual(XtreamVODMapping.nextEpisode([episode(1), episode(2)])?.episodeNumber, 1)
    }

    // MARK: - Cache

    func test_savingAList_removesTheCopiesOlderBuildsLeft() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = String(source.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        let old = ["movies", "movies-v2", "movies-v3"].map { directory.appending(component: "\(safe)-\($0).json") }
        for url in old { try Data("old".utf8).write(to: url) }
        let provider = provider()
        let movies = try await provider.libraries()[0]
        _ = try await provider.items(in: movies, sort: .titleAsc, page: Page(offset: 0, limit: 5))
        for url in old { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains("\(safe)-movies-v4.json"))
    }

    func test_lists_areFetchedOnce_thenReadFromDisk_andAStaleCopyOutlivesAFailure() async throws {
        let first = provider()
        _ = try await first.libraries()
        let fetched = FakePanel.requests.filter { $0 == "get_vod_streams" }.count
        XCTAssertEqual(fetched, 1)

        // A new launch reads the day-old-at-most copy without asking.
        FakePanel.failing = true
        let second = provider()
        let reread = try await second.libraries()
        XCTAssertEqual(reread.map(\.id), ["movies", "series"])
        XCTAssertEqual(FakePanel.requests.filter { $0 == "get_vod_streams" }.count, fetched)

        // Two days old and the panel is down: the stale copy still lists.
        let catalog = XtreamVODCatalog(service: XtreamService(account: account, session: session()),
                                       sourceID: source, directory: directory)
        XCTAssertTrue(XtreamVODCatalog.isFresh(Date().addingTimeInterval(-3600)))
        XCTAssertFalse(XtreamVODCatalog.isFresh(Date().addingTimeInterval(-2 * 86400)))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains("-movies") })
        var stale = try JSONDecoder().decode(XtreamVODLists<XtreamMovie>.self, from: Data(contentsOf: file))
        stale.fetchedAt = Date().addingTimeInterval(-2 * 86400)
        try JSONEncoder().encode(stale).write(to: file)
        let staleTitles = try await catalog.movieLists().titles
        XCTAssertEqual(staleTitles.count, 3)
    }

    // MARK: - Provider

    func test_libraries_listing_andCategoriesAsCollections() async throws {
        let provider = provider()
        let libraries = try await provider.libraries()
        XCTAssertEqual(libraries.map(\.kind), [.movies, .shows])
        let movies = libraries[0]

        let newest = try await provider.items(in: movies, sort: .addedAtDesc, page: Page(offset: 0, limit: 2))
        XCTAssertEqual(newest.items.map(\.title), ["Up", "1917"])
        XCTAssertEqual(newest.total, 3)
        XCTAssertEqual(newest.nextPage, Page(offset: 2, limit: 2))

        // Only categories that hold a title; a category opens on its titles.
        let collections = try await provider.collections(in: movies)
        XCTAssertEqual(collections.map(\.title), ["Action", "Kids"])
        let action = try await provider.children(of: collections[0].ref)
        XCTAssertEqual(action.map(\.title), ["Heat", "1917"])
        let letters = try await provider.letterCounts(in: movies)
        XCTAssertEqual(letters.map(\.title), ["#", "H", "U"])
    }

    func test_aFilmListedWithoutAPoster_takesTheOneInItsDetails() async throws {
        FakePanel.replies["get_vod_info"] = #"{"info": {"movie_image": "http://img.example/details.jpg"}, "movie_data": {}}"#
        let provider = provider()
        let movies = try await provider.libraries()[0]
        let newest = try await provider.items(in: movies, sort: .addedAtDesc, page: Page(offset: 0, limit: 3))
        let posters = Dictionary(uniqueKeysWithValues: newest.items.map { ($0.title, $0.artwork.poster) })
        XCTAssertEqual(posters["Up"], URL(string: "http://img.example/details.jpg"))
        XCTAssertEqual(posters["1917"], URL(string: "http://img.example/details.jpg"))
        // The panel's own poster stays, and its film is not asked about.
        XCTAssertEqual(posters["Heat"], URL(string: "http://img.example/heat.jpg"))
        XCTAssertEqual(FakePanel.requests.filter { $0 == "get_vod_info" }.count, 2)
    }

    func test_aCategory_takesTheFirstPosterAmongItsTitles() {
        let heat = URL(string: "http://img.example/heat.jpg")
        let posters = XtreamVODProvider.firstPosters([("1", nil), ("1", heat), ("2", nil), (nil, heat)])
        XCTAssertEqual(posters["1"], .some(heat))
        XCTAssertEqual(posters["2"], .some(nil))
        XCTAssertEqual(posters.count, 2)
    }

    func test_series_seasonsWithEpisodesOnly_andEpisodesInOrder() async throws {
        let provider = provider()
        let seasons = try await provider.children(of: ref(.series("70")))
        XCTAssertEqual(seasons.map(\.seasonNumber), [1])
        let episodes = try await provider.children(of: seasons[0].ref)
        XCTAssertEqual(episodes.map(\.title), ["The Target", "The Detail"])
        XCTAssertEqual(episodes.first?.grandparentRef, ref(.series("70")))
        XCTAssertEqual(episodes.first?.seriesTitle, "The Wire")
    }

    func test_movieDetail_andStream() async throws {
        let provider = provider()
        let detail = try await provider.fullDetail(for: ref(.movie("10")))
        XCTAssertEqual(detail.item.overview, "A heist.")
        XCTAssertEqual(detail.item.runtime, 10200)
        XCTAssertEqual(detail.genres, ["Crime", "Drama"])
        XCTAssertEqual(detail.directors.map(\.name), ["Michael Mann"])
        XCTAssertEqual(detail.externalIDs["tmdb"], "949")

        let stream = try await provider.resolveStream(for: ref(.movie("10")), sourceID: nil, maxBitrate: 1_000_000)
        XCTAssertEqual(stream.source.streamURL?.absoluteString, "http://panel.example:8080/movie/user/pass/10.mkv")
        XCTAssertEqual(stream.source.streamKind, .directPlay)
        XCTAssertEqual(stream.source.duration, 10200)
        XCTAssertEqual(stream.headers, LiveTVClientIdentity.streamHeaders)

        let episode = try await provider.resolveStream(for: ref(.episode(seriesID: "70", episodeID: "702")),
                                                       sourceID: nil, maxBitrate: nil)
        XCTAssertEqual(episode.source.streamURL?.absoluteString, "http://panel.example:8080/series/user/pass/702.mkv")

        // Once played, a listed film knows its length (Continue Watching's progress bar).
        try await provider.updateProgress(ref(.movie("10")), position: 600)
        let listed = try await provider.continueWatching(limit: 5).first { $0.title == "Heat" }
        XCTAssertEqual(listed?.runtime, 10200)
    }

    func test_watchState_continueWatching_andMarkingASeries() async throws {
        let provider = provider()
        // An episode with a known length, a third in.
        let target = ref(.episode(seriesID: "70", episodeID: "701"))
        _ = try await provider.resolveStream(for: target, sourceID: nil, maxBitrate: nil)
        let reporter = provider.progressReporter(for: target, sourceID: nil, playSessionID: nil)
        await reporter.stopped(at: 1200)
        // A film the panel gives no length for, ten minutes in.
        try await provider.updateProgress(ref(.movie("11")), position: 600)

        let continuing = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(Set(continuing.map(\.title)), ["The Target", "Up"])
        XCTAssertEqual(continuing.first { $0.title == "The Target" }?.userState.viewOffset, 1200)
        XCTAssertEqual(continuing.first { $0.title == "The Target" }?.runtime, 3600)

        try await provider.markPlayed(ref(.series("70")))
        let episodes = try await provider.allEpisodes(of: ref(.series("70")))
        XCTAssertTrue(episodes.allSatisfy(\.userState.isPlayed))
        let after = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(after.map(\.title), ["Up"])
    }

    func test_continueWatching_oneEpisodePerSeries_andRemovingTakesTheSeriesOff() async throws {
        let provider = provider()
        try await provider.updateProgress(ref(.episode(seriesID: "70", episodeID: "701")), position: 600)
        try await Task.sleep(for: .milliseconds(10))
        try await provider.updateProgress(ref(.episode(seriesID: "70", episodeID: "702")), position: 700)
        try await provider.updateProgress(ref(.movie("11")), position: 600)

        let continuing = try await provider.continueWatching(limit: 10)
        // The episode watched last stands for its series.
        XCTAssertEqual(Set(continuing.map(\.title)), ["The Detail", "Up"])
        let episode = try XCTUnwrap(continuing.first { $0.kind == .episode })
        XCTAssertTrue(provider.canRemoveFromContinueWatching(episode))

        try await provider.removeFromContinueWatching(episode)
        // The older episode does not take its place.
        let afterEpisode = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(afterEpisode.map(\.title), ["Up"])
        let film = try XCTUnwrap(continuing.first { $0.kind == .movie })
        try await provider.removeFromContinueWatching(film)
        let afterFilm = try await provider.continueWatching(limit: 10)
        XCTAssertTrue(afterFilm.isEmpty)
        // Removed, not watched.
        let records = await MainActor.run { store.records.values.map(\.watched) }
        XCTAssertFalse(records.contains(true))
    }

    func test_favorites_markedOnTheDevice_listedByTitle_andRowsOnTheLibraryPage() async throws {
        let provider = provider()
        let movies = try await provider.libraries()[0]
        try await provider.setFavorite(true, for: ref(.movie("11")))
        try await provider.setFavorite(true, for: ref(.movie("10")))
        try await provider.setFavorite(true, for: ref(.series("70")))
        let favorites = try await provider.favorites(in: movies, limit: 10)
        XCTAssertEqual(favorites.map(\.title), ["Heat", "Up"])
        XCTAssertTrue(favorites.allSatisfy(\.userState.isFavorite))
        let detail = try await provider.fullDetail(for: ref(.series("70")))
        XCTAssertTrue(detail.item.userState.isFavorite)

        try await provider.updateProgress(ref(.movie("12")), position: 600)
        let rows = try await provider.hubs(in: movies)
        XCTAssertEqual(rows.map(\.id), ["movies.continueWatching", "movies.favorites", "movies.recentlyAdded"])
        XCTAssertEqual(rows[0].items.map(\.title), ["1917"])

        try await provider.setFavorite(false, for: ref(.movie("11")))
        let after = try await provider.favorites(in: movies, limit: 10)
        XCTAssertEqual(after.map(\.title), ["Heat"])
        do {
            try await provider.setFavorite(true, for: ref(.episode(seriesID: "70", episodeID: "701")))
            XCTFail("an episode is not a favorite")
        } catch {}
    }

    func test_unwatchedFilter_leavesOutFilmsWatchedToTheEnd() async throws {
        let provider = provider()
        let movies = try await provider.libraries()[0]
        try await provider.markPlayed(ref(.movie("10")))
        try await provider.updateProgress(ref(.movie("12")), position: 600)
        let page = try await provider.items(in: movies, sort: .titleAsc, filter: LibraryFilter(unwatchedOnly: true),
                                            page: Page(offset: 0, limit: 10))
        XCTAssertEqual(page.items.map(\.title), ["1917", "Up"])
        XCTAssertEqual(page.total, 2)
    }

    func test_search_findsFilmsAndSeries() async throws {
        let found = try await provider().search("the")
        XCTAssertEqual(found.map(\.title), ["The Wire"])
        let up = try await provider().search("up")
        XCTAssertEqual(up.map(\.kind), [.movie])
    }

    // MARK: - Skip markers

    private func markerProvider(optedIn: Bool, asked: OSAllocatedUnfairLock<[String]>) -> XtreamVODProvider {
        let store = store!
        FakePanel.replies["/3/search/tv"] = #"{"results": [{"id": 1438, "name": "The Wire", "first_air_date": "2002-06-02"}]}"#
        FakePanel.replies["/3/tv/1438"] = #"{"id": 1438, "name": "The Wire"}"#
        FakePanel.replies["/3/tv/1438/external_ids"] = #"{"imdb_id": "tt0306414"}"#
        let tmdb = TMDBLookup(apiKey: { "0123456789abcdef0123456789abcdef" }, session: session(), language: "en-US")
        return XtreamVODProvider(
            sourceID: source, displayName: "IPTV", account: account, cacheDirectory: directory, session: session(),
            tmdb: tmdb, watchStore: { store },
            communityMarkers: { ids, season, episode, _ in
                asked.withLock { $0.append("\(ids.imdb ?? "-") \(ids.tmdb ?? 0) S\(season)E\(episode)") }
                return [PlexMarker(id: -9001, type: "intro", startTimeOffset: 30_000, endTimeOffset: 95_000)]
            },
            usesCommunityMarkers: { optedIn })
    }

    func test_episodeMarkers_comeFromTheDatabases_byTheShowsIDs() async {
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let extras = await markerProvider(optedIn: true, asked: asked)
            .playbackExtras(for: ref(.episode(seriesID: "70", episodeID: "702")), sourceID: nil)
        XCTAssertEqual(asked.withLock { $0 }, ["tt0306414 1438 S1E2"])
        XCTAssertEqual(extras.markers, [PlaybackMarker(kind: .intro, start: 30, end: 95)])
    }

    func test_episodeMarkers_withoutATMDBKey_useThePanelsTMDBID() async {
        FakePanel.replies["get_series_info"] = FakePanel.replies["get_series_info"]!
            .replacingOccurrences(of: #"{"seasons""#, with: #"{"info": {"name": "The Wire", "tmdb": "1438"}, "seasons""#)
        let store = store!
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let provider = XtreamVODProvider(
            sourceID: source, displayName: "IPTV", account: account, cacheDirectory: directory, session: session(),
            tmdb: TMDBLookup(apiKey: { nil }), watchStore: { store },
            communityMarkers: { ids, season, episode, _ in
                asked.withLock { $0.append("\(ids.imdb ?? "-") \(ids.tmdb ?? 0) S\(season)E\(episode)") }
                return [PlexMarker(id: -9011, type: "intro", startTimeOffset: 1_000, endTimeOffset: 50_000)]
            },
            usesCommunityMarkers: { true })
        let extras = await provider.playbackExtras(for: ref(.episode(seriesID: "70", episodeID: "701")), sourceID: nil)
        XCTAssertEqual(asked.withLock { $0 }, ["- 1438 S1E1"])
        XCTAssertEqual(extras.markers.map(\.kind), [.intro])
        let detail = try? await provider.fullDetail(for: ref(.series("70")))
        XCTAssertEqual(detail?.externalIDs["tmdb"], "1438")
    }

    func test_noMarkers_withoutTheOptIn_orForAFilm() async {
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let off = await markerProvider(optedIn: false, asked: asked)
            .playbackExtras(for: ref(.episode(seriesID: "70", episodeID: "701")), sourceID: nil)
        let film = await markerProvider(optedIn: true, asked: asked)
            .playbackExtras(for: ref(.movie("10")), sourceID: nil)
        XCTAssertTrue(off.markers.isEmpty)
        XCTAssertTrue(film.markers.isEmpty)
        XCTAssertTrue(asked.withLock { $0 }.isEmpty)
    }
}
