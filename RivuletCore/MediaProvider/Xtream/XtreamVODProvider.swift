// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamVODProvider.swift
//  Rivulet
//
//  An Xtream Codes panel's films and series as a media server: a Movies and a
//  TV Shows library, the panel's categories as their collections, details,
//  seasons and episodes, and direct play. One per Xtream Live TV source, with
//  the source's id and name and the same login. The panel keeps no watch
//  state, so `XtreamWatchProgressStore` keeps it on the device.
//

import Foundation
import os

final class XtreamVODProvider: MediaProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind = .xtream
    nonisolated let displayName: String
    let connectionState: ConnectionState = .connected
    let supportsWatchlist = false

    let catalog: XtreamVODCatalog
    let service: XtreamService

    /// Each title's runtime once known, for the progress reporter, which is built without a request.
    private let runtimes = OSAllocatedUnfairLock(initialState: [String: TimeInterval]())

    /// TMDB details for detail pages, with the viewer's own key; tests pass their own.
    let tmdb: TMDBLookup
    /// Where watch state is kept; tests pass their own.
    private let watchStore: @MainActor @Sendable () -> XtreamWatchProgressStore

    /// `sourceID` is the Live TV source's ("xtream:<hash>"), which is also a valid provider id.
    init(sourceID: String, displayName: String, account: XtreamAccount,
         cacheDirectory: URL? = XtreamVODCatalog.defaultDirectory, session: URLSession? = nil,
         tmdb: TMDBLookup? = nil,
         watchStore: @escaping @MainActor @Sendable () -> XtreamWatchProgressStore = { .shared }) {
        self.id = sourceID
        self.displayName = displayName
        let service = XtreamService(account: account, session: session)
        self.service = service
        self.catalog = XtreamVODCatalog(service: service, sourceID: sourceID, directory: cacheDirectory)
        self.watchStore = watchStore
        self.tmdb = tmdb ?? .shared
    }

    // MARK: - Watch state

    private func state() async -> XtreamVODMapping.State {
        await MainActor.run {
            let store = watchStore()
            return XtreamVODMapping.State(records: store.records, favorites: Set(store.favorites))
        }
    }

    private func key(for ref: MediaItemRef) -> String? {
        switch XtreamVODID(itemID: ref.itemID) {
        case .movie(let movie): XtreamVODMapping.movieKey(source: id, movieID: movie)
        case .episode(let series, let episode): XtreamVODMapping.episodeKey(source: id, seriesID: series, episodeID: episode)
        default: nil
        }
    }

    /// Every episode of a series or season, for marking them all.
    private func episodeKeys(of ref: MediaItemRef) async throws -> [String] {
        switch XtreamVODID(itemID: ref.itemID) {
        case .series(let series):
            return try await catalog.seriesInfo(series).episodes
                .map { XtreamVODMapping.episodeKey(source: id, seriesID: series, episodeID: $0.id) }
        case .season(let series, let number):
            return try await catalog.seriesInfo(series).episodes.filter { $0.season == number }
                .map { XtreamVODMapping.episodeKey(source: id, seriesID: series, episodeID: $0.id) }
        default:
            return key(for: ref).map { [$0] } ?? []
        }
    }

    func markPlayed(_ itemRef: MediaItemRef) async throws {
        let keys = try await episodeKeys(of: itemRef)
        await MainActor.run { keys.forEach { watchStore().markWatched($0) } }
    }

    func markUnplayed(_ itemRef: MediaItemRef) async throws {
        let keys = try await episodeKeys(of: itemRef)
        await MainActor.run { keys.forEach { watchStore().markUnwatched($0) } }
    }

    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        guard let key = key(for: itemRef) else { return }
        let runtime = runtimes.withLock { $0[itemRef.itemID] }
        await MainActor.run { watchStore().update(key, position: position, duration: runtime) }
    }

    func progressReporter(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?) -> any ProgressReporter {
        XtreamProgressReporter(key: key(for: itemRef), runtime: runtimes.withLock { $0[itemRef.itemID] }, store: watchStore)
    }

    // MARK: - Browse

    func libraries() async throws -> [MediaLibrary] {
        async let series = catalog.seriesLists()
        let movies = try await catalog.movieLists()
        let shows = (try? await series)?.titles ?? []
        var libraries: [MediaLibrary] = []
        if !movies.titles.isEmpty { libraries.append(library(.movies)) }
        if !shows.isEmpty { libraries.append(library(.series)) }
        return libraries
    }

    private func library(_ library: XtreamVODLibrary) -> MediaLibrary {
        MediaLibrary(id: library.rawValue, providerID: id, title: library.title, kind: library.kind)
    }

    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        let state = await state()
        let result: (items: [MediaItem], total: Int)
        switch XtreamVODLibrary(rawValue: library.id) {
        case .movies:
            let page = try await catalog.moviePage(sort: sort, page: page)
            result = (page.items.map { XtreamVODMapping.item($0, provider: id, state: state) }, page.total)
        case .series:
            let page = try await catalog.seriesPage(sort: sort, page: page)
            result = (page.items.map { XtreamVODMapping.item($0, provider: id, state: state) }, page.total)
        case nil:
            throw MediaProviderError.notFound
        }
        let end = page.offset + result.items.count
        return PagedResult(items: result.items, total: result.total,
                           nextPage: end < result.total ? Page(offset: end, limit: page.limit) : nil)
    }

    func sortOptions(for kind: MediaLibrary.LibraryKind) -> [LibrarySortOption] {
        var options: [LibrarySortOption] = [.addedAtDesc, .addedAtAsc, .titleAsc, .titleDesc,
                                            .releaseDateDesc, .releaseDateAsc, .ratingDesc]
        if kind == .shows { options.removeAll { $0 == .addedAtAsc } }
        return options
    }

    func letterCounts(in library: MediaLibrary) async throws -> [PlexFirstCharacter] {
        switch XtreamVODLibrary(rawValue: library.id) {
        case .movies: try await catalog.letterCounts(.movies)
        case .series: try await catalog.letterCounts(.series)
        case nil: []
        }
    }

    /// The panel's categories that hold a title, in the panel's order.
    func collections(in library: MediaLibrary) async throws -> [MediaItem] {
        switch XtreamVODLibrary(rawValue: library.id) {
        case .movies:
            let lists = try await catalog.movieLists()
            let posters = Dictionary(lists.titles.compactMap { movie in movie.categoryId.map { ($0, movie.posterURL) } },
                                     uniquingKeysWith: { first, _ in first })
            return lists.categories.filter { posters[$0.id] != nil }
                .map { XtreamVODMapping.item($0, library: .movies, poster: posters[$0.id] ?? nil, provider: id) }
        case .series:
            let lists = try await catalog.seriesLists()
            let posters = Dictionary(lists.titles.compactMap { show in show.categoryId.map { ($0, show.coverURL) } },
                                     uniquingKeysWith: { first, _ in first })
            return lists.categories.filter { posters[$0.id] != nil }
                .map { XtreamVODMapping.item($0, library: .series, poster: posters[$0.id] ?? nil, provider: id) }
        case nil:
            return []
        }
    }

    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] {
        let state = await state()
        switch XtreamVODID(itemID: itemRef.itemID) {
        case .category(.movies, let category):
            return try await catalog.movieLists().titles.filter { $0.categoryId == category }
                .map { XtreamVODMapping.item($0, provider: id, state: state) }
        case .category(.series, let category):
            return try await catalog.seriesLists().titles.filter { $0.categoryId == category }
                .map { XtreamVODMapping.item($0, provider: id, state: state) }
        case .series(let seriesID):
            let (series, info) = try await seriesAndInfo(seriesID)
            return info.seasons.map { XtreamVODMapping.item($0, of: series, provider: id) }
        case .season(let seriesID, let number):
            return try await episodes(of: seriesID).filter { $0.seasonNumber == number }
        default:
            return []
        }
    }

    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem] {
        guard case .series(let seriesID) = XtreamVODID(itemID: showRef.itemID) else { return [] }
        return try await episodes(of: seriesID)
    }

    private func series(_ seriesID: String) async throws -> XtreamSeries {
        guard let series = try await catalog.seriesLists().titles.first(where: { $0.id == seriesID }) else {
            throw MediaProviderError.notFound
        }
        return series
    }

    private func seriesAndInfo(_ seriesID: String) async throws -> (XtreamSeries, XtreamSeriesInfo) {
        async let info = catalog.seriesInfo(seriesID)
        let series = try await series(seriesID)
        return (series, try await info)
    }

    private func episodes(of seriesID: String) async throws -> [MediaItem] {
        let (series, info) = try await seriesAndInfo(seriesID)
        let state = await state()
        for episode in info.episodes {
            if let duration = episode.duration {
                let itemID = XtreamVODID.episode(seriesID: seriesID, episodeID: episode.id).itemID
                runtimes.withLock { $0[itemID] = duration }
            }
        }
        return info.episodes.map { XtreamVODMapping.item($0, of: series, provider: id, state: state) }
    }

    // MARK: - Search

    func search(_ query: String) async throws -> [MediaItem] {
        let state = await state()
        let movies = try await catalog.searchMovies(query, limit: 50)
            .map { XtreamVODMapping.item($0, provider: id, state: state) }
        let series = ((try? await catalog.searchSeries(query, limit: 50)) ?? [])
            .map { XtreamVODMapping.item($0, provider: id, state: state) }
        return movies + series
    }

    /// Other titles in the same panel category.
    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {
        let state = await state()
        switch XtreamVODID(itemID: ref.itemID) {
        case .movie(let movieID):
            let titles = try await catalog.movieLists().titles
            guard let category = titles.first(where: { $0.id == movieID })?.categoryId else { break }
            return RelatedContent(items: titles.filter { $0.categoryId == category && $0.id != movieID }.prefix(20)
                .map { XtreamVODMapping.item($0, provider: id, state: state) }, collection: nil)
        case .series(let seriesID):
            let titles = try await catalog.seriesLists().titles
            guard let category = titles.first(where: { $0.id == seriesID })?.categoryId else { break }
            return RelatedContent(items: titles.filter { $0.categoryId == category && $0.id != seriesID }.prefix(20)
                .map { XtreamVODMapping.item($0, provider: id, state: state) }, collection: nil)
        default:
            break
        }
        return RelatedContent(items: [], collection: nil)
    }

    // MARK: - Detail

    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail {
        let state = await state()
        switch XtreamVODID(itemID: itemRef.itemID) {
        case .movie(let movieID):
            return try await movieDetail(movieID)
        case .series(let seriesID):
            let (series, _) = try await seriesAndInfo(seriesID)
            let episodes = try await episodes(of: seriesID)
            let detail = Self.detail(XtreamVODMapping.item(series, provider: id, state: state),
                                     genres: XtreamVODMapping.genres(series.genre),
                                     nextEpisode: XtreamVODMapping.nextEpisode(episodes))
            guard let found = await tmdb.title(.tv, tmdbID: nil, name: series.name, year: series.year) else { return detail }
            return XtreamVODMapping.enriched(detail, with: found)
        case .season(let seriesID, let number):
            let (series, info) = try await seriesAndInfo(seriesID)
            guard let season = info.seasons.first(where: { $0.number == number }) else { throw MediaProviderError.notFound }
            return Self.detail(XtreamVODMapping.item(season, of: series, provider: id))
        case .episode(let seriesID, _):
            guard let episode = try await episodes(of: seriesID).first(where: { $0.ref == itemRef }) else {
                throw MediaProviderError.notFound
            }
            return Self.detail(episode, sources: [Self.source(runtime: episode.runtime, container: nil, url: nil)])
        case .category(let library, let categoryID):
            guard let category = try await collections(in: self.library(library))
                .first(where: { $0.ref.itemID == XtreamVODID.category(library: library, id: categoryID).itemID }) else {
                throw MediaProviderError.notFound
            }
            return Self.detail(category)
        case nil:
            throw MediaProviderError.notFound
        }
    }

    private func movieDetail(_ movieID: String) async throws -> MediaItemDetail {
        async let info = catalog.movieInfo(movieID)
        guard let movie = try await catalog.movieLists().titles.first(where: { $0.id == movieID }) else {
            throw MediaProviderError.notFound
        }
        let state = await state()
        let listed = XtreamVODMapping.item(movie, provider: id, state: state)
        // Details are a bonus: a panel that fails `get_vod_info` still plays the film.
        guard let info = try? await info else {
            let bare = Self.detail(listed, sources: [Self.source(runtime: nil, container: movie.containerExtension, url: nil)])
            guard let found = await tmdb.title(.movie, tmdbID: nil, name: movie.name, year: movie.year) else { return bare }
            return XtreamVODMapping.enriched(bare, with: found)
        }
        if let duration = info.duration {
            runtimes.withLock { $0[listed.ref.itemID] = duration }
        }
        let year = movie.year ?? info.releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
        let item = MediaItem(
            ref: listed.ref, kind: .movie, title: movie.name, sortTitle: nil, overview: info.plot, year: year,
            releaseDate: info.releaseDate.map { $0.formatted(.iso8601.year().month().day()) },
            runtime: info.duration,
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: listed.userState,
            artwork: MediaArtwork(poster: info.posterURL ?? movie.posterURL, backdrop: info.backdropURL,
                                  thumbnail: info.posterURL ?? movie.posterURL, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil,
            editionTitle: ContentOrigin.badge(forTag: movie.tag),
            genres: XtreamVODMapping.genres(info.genre),
            externalIDs: info.tmdbId.map { ["tmdb": $0] },
            libraryID: XtreamVODLibrary.movies.rawValue)
        let detail = Self.detail(item, genres: XtreamVODMapping.genres(info.genre),
                                 cast: Self.people(info.cast, role: nil),
                                 directors: Self.people(info.director, role: String(localized: "Director")),
                                 sources: [Self.source(runtime: info.duration,
                                                       container: info.containerExtension ?? movie.containerExtension,
                                                       url: nil)])
        var withID = detail
        if let tmdbID = info.tmdbId { withID.externalIDs = ["tmdb": tmdbID] }
        guard let found = await tmdb.title(.movie, tmdbID: info.tmdbId, name: movie.name, year: year) else { return withID }
        return XtreamVODMapping.enriched(withID, with: found)
    }

    private static func people(_ names: String?, role: String?) -> [MediaPerson] {
        (XtreamVODMapping.genres(names) ?? []).prefix(20).map { MediaPerson(id: "name:\($0)", name: $0, role: role, imageURL: nil) }
    }

    private static func detail(_ item: MediaItem, genres: [String]? = nil, cast: [MediaPerson] = [],
                               directors: [MediaPerson] = [], sources: [MediaSource] = [],
                               nextEpisode: MediaItem? = nil) -> MediaItemDetail {
        MediaItemDetail(item: item, tagline: nil, genres: genres ?? item.genres ?? [], studios: [], cast: cast,
                        directors: directors, writers: [], chapters: [], mediaSources: sources, trailerURL: nil,
                        contentRating: nil, nextEpisode: nextEpisode, collections: [])
    }

    /// The panel's one file. Its tracks are unknown until the engine opens it.
    private static func source(runtime: TimeInterval?, container: String?, url: URL?) -> MediaSource {
        MediaSource(id: "file", container: container.map(XtreamService.fileExtension), duration: runtime ?? 0,
                    bitrate: nil, fileSize: nil, fileName: nil, videoResolution: nil,
                    videoTracks: [], audioTracks: [], subtitleTracks: [], streamKind: .directPlay, streamURL: url)
    }

    // MARK: - Playback

    /// The file itself: a panel never transcodes, so a cap changes nothing.
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo {
        let url: URL
        let container: String
        switch XtreamVODID(itemID: itemRef.itemID) {
        case .movie(let movieID):
            guard let movie = try await catalog.movieLists().titles.first(where: { $0.id == movieID }) else {
                throw MediaProviderError.notFound
            }
            container = (try? await catalog.movieInfo(movieID))?.containerExtension ?? movie.containerExtension
            url = service.movieURL(movieId: movieID, containerExtension: container)
        case .episode(let seriesID, let episodeID):
            guard let episode = try await catalog.seriesInfo(seriesID).episodes.first(where: { $0.id == episodeID }) else {
                throw MediaProviderError.notFound
            }
            container = episode.containerExtension
            url = service.episodeURL(episodeId: episodeID, containerExtension: container)
            if let duration = episode.duration { runtimes.withLock { $0[itemRef.itemID] = duration } }
        default:
            throw MediaProviderError.notPlayable
        }
        let runtime = runtimes.withLock { $0[itemRef.itemID] }
        return StreamInfo(source: Self.source(runtime: runtime, container: container, url: url), playSessionID: nil,
                          trackInfoAvailable: false, headers: LiveTVClientIdentity.streamHeaders)
    }

    func setSelectedAudioTrack(_ trackID: String, source sourceID: String, of itemRef: MediaItemRef) async throws {}
    func setSelectedSubtitleTrack(_ trackID: String?, source sourceID: String, of itemRef: MediaItemRef) async throws {}

    // MARK: - Home

    /// Titles with a resume point on this source, watched last first.
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        let keys = await MainActor.run { watchStore().inProgress(limit: limit) }
        let ids = keys.compactMap { XtreamVODMapping.id(fromKey: $0, source: id) }
        guard !ids.isEmpty else { return [] }
        let state = await state()
        var items: [MediaItem] = []
        for itemID in ids {
            switch itemID {
            case .movie(let movieID):
                if let movie = try? await catalog.movieLists().titles.first(where: { $0.id == movieID }) {
                    items.append(XtreamVODMapping.item(movie, provider: id, state: state))
                }
            case .episode(let seriesID, _):
                let ref = MediaItemRef(providerID: id, itemID: itemID.itemID)
                if let episode = try? await episodes(of: seriesID).first(where: { $0.ref == ref }) {
                    items.append(episode)
                }
            default:
                break
            }
        }
        return items
    }

    func recentlyAdded(limit: Int) async throws -> [MediaItem] {
        try await items(in: library(.movies), sort: .addedAtDesc, page: Page(offset: 0, limit: limit)).items
    }

    func hubs() async throws -> [MediaHub] { [] }

    /// The library page's rows: what is in progress there, the favorites, then Recently Added.
    /// The first two are the device's own state, so a failure costs only them.
    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        var hubs: [MediaHub] = []
        let kind: MediaKind = library.id == XtreamVODLibrary.movies.rawValue ? .movie : .episode
        let continuing = ((try? await continueWatching(limit: 24)) ?? []).filter { $0.kind == kind }
        if !continuing.isEmpty {
            hubs.append(MediaHub(id: "\(library.id).continueWatching", providerID: id,
                                 title: String(localized: "Continue Watching"), style: .shelf, items: continuing))
        }
        let favorites = (try? await favorites(in: library, limit: 50)) ?? []
        if !favorites.isEmpty {
            hubs.append(MediaHub(id: "\(library.id).favorites", providerID: id,
                                 title: String(localized: "Favorites"), style: .shelf, items: favorites))
        }
        if let forYou = await forYouHub(in: library) { hubs.append(forYou) }
        if let added = try await recentlyAddedHub(in: library) { hubs.append(added) }
        return hubs
    }

    // MARK: - For You

    private let forYouCache = OSAllocatedUnfairLock(initialState: [String: (key: String, ids: [String], at: Date)]())
    private let forYouWork = OSAllocatedUnfairLock(initialState: [String: (key: String, task: Task<[String], Never>)]())

    /// The library's For You row (`XtreamForYou`), also on Home. Worked out again only when
    /// what it starts from changes or after six hours: Home asks for its rows on every reload.
    /// With TMDB that takes a few seconds the first time, so the page waits at most three and
    /// shows the row on its next load when the work runs longer.
    func forYouHub(in library: MediaLibrary, now: Date = Date()) async -> MediaHub? {
        guard let kind = XtreamVODLibrary(rawValue: library.id) else { return nil }
        let state = await state()
        let seeds = XtreamForYou.seeds(state, source: id, library: kind, now: now)
        guard !seeds.isEmpty else { return nil }
        let hasKey = await tmdb.hasKey()
        // The newest place too: a synced device can change records without changing their count.
        let newest = state.records.values.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let cacheKey = seeds.map(\.id).joined(separator: ",") + "|\(hasKey)|\(state.records.count)|\(newest)"
        let cached = forYouCache.withLock { $0[library.id] }
        var ids = cached?.ids
        if cached == nil || cached?.key != cacheKey || now.timeIntervalSince(cached!.at) >= 6 * 3600 {
            let work = forYouWork.withLock { running -> Task<[String], Never> in
                if let current = running[library.id], current.key == cacheKey { return current.task }
                let task = Task { [weak self] () -> [String] in
                    guard let self else { return [] }
                    let found = await self.forYouIDs(kind, seeds: seeds, state: state, useTMDB: hasKey, now: now)
                    self.forYouCache.withLock { $0[library.id] = (cacheKey, found, Date()) }
                    self.forYouWork.withLock { $0[library.id] = nil }
                    return found
                }
                running[library.id] = (cacheKey, task)
                return task
            }
            let fresh = await withTaskGroup(of: [String]?.self) { group in
                group.addTask { await work.value }
                group.addTask {
                    try? await Task.sleep(for: .seconds(3))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let fresh { ids = fresh }
        }
        guard let ids, ids.count >= XtreamForYou.minimumRow, let items = try? await titles(ids, in: kind, state: state),
              items.count >= XtreamForYou.minimumRow else { return nil }
        return MediaHub(id: "\(library.id).forYou", providerID: id, title: String(localized: "For You"),
                        style: .shelf, items: items, isPromoted: true)
    }

    private func forYouIDs(_ kind: XtreamVODLibrary, seeds: [XtreamForYou.Seed], state: XtreamVODMapping.State,
                           useTMDB: Bool, now: Date) async -> [String] {
        let seen = XtreamForYou.seen(state, source: id, library: kind)
        let candidates: [XtreamForYou.Candidate]
        switch kind {
        case .movies:
            guard let movies = try? await catalog.movieLists().titles else { return [] }
            candidates = movies.map { .init(id: $0.id, name: $0.name, year: $0.year, categoryId: $0.categoryId,
                                            rating: $0.rating, addedAt: $0.addedAt) }
        case .series:
            guard let series = try? await catalog.seriesLists().titles else { return [] }
            candidates = series.map { .init(id: $0.id, name: $0.name, year: $0.year, categoryId: $0.categoryId,
                                            rating: $0.rating, addedAt: $0.updatedAt,
                                            genres: XtreamForYou.genres($0.genre)) }
        }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let names = byID.mapValues { LiveChannelSearch.normalized($0.name) }
        var tmdbPicks: [String] = []
        var languages = Set<String>()
        let tmdbKind: TMDBLookup.Kind = kind == .movies ? .movie : .tv
        if useTMDB {
            var lists: [(seedWeight: Double, recommendations: [TMDBRecommendation])] = []
            for seed in seeds.prefix(XtreamForYou.tmdbSeedLimit) {
                guard let title = byID[seed.id] else { continue }
                // The language the viewer watches it in is the title's own, whatever the panel's tag.
                if let language = await tmdb.originalLanguage(tmdbKind, name: title.name, year: title.year) {
                    languages.insert(language)
                }
                // The panel's TMDB id when it gives one (a film's info), else TMDB's search.
                var tmdbID: Int?
                if kind == .movies { tmdbID = (try? await catalog.movieInfo(seed.id))?.tmdbId.flatMap(Int.init) }
                if tmdbID == nil {
                    tmdbID = await tmdb.title(tmdbKind, tmdbID: nil, name: title.name, year: title.year)?.id
                }
                guard let tmdbID else { continue }
                lists.append((seed.weight, await tmdb.recommendations(tmdbKind, tmdbID: tmdbID)))
            }
            tmdbPicks = XtreamForYou.tmdbPicks(lists, index: XtreamForYou.Index(candidates), seen: seen,
                                               languages: languages)
        }
        var categoryPicks = XtreamForYou.categoryPicks(candidates, seeds: seeds, seen: seen, now: now,
                                                       limit: languages.isEmpty ? XtreamForYou.rowSize : 40)
        if !languages.isEmpty {
            // A streaming service's category mixes every country: keep the viewer's languages.
            var languageOf: [String: String] = [:]
            for pick in categoryPicks {
                guard let title = byID[pick] else { continue }
                if let language = await tmdb.originalLanguage(tmdbKind, name: title.name, year: title.year) {
                    languageOf[pick] = language
                }
            }
            categoryPicks = XtreamForYou.inLanguages(categoryPicks, languages: languages, languageOf: languageOf)
        }
        return XtreamForYou.merge(tmdbPicks, categoryPicks, names: names)
    }

    /// The library's titles with these ids, in this order.
    private func titles(_ ids: [String], in kind: XtreamVODLibrary, state: XtreamVODMapping.State) async throws -> [MediaItem] {
        switch kind {
        case .movies:
            let byID = Dictionary(try await catalog.movieLists().titles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { byID[$0] }.map { XtreamVODMapping.item($0, provider: id, state: state) }
        case .series:
            let byID = Dictionary(try await catalog.seriesLists().titles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { byID[$0] }.map { XtreamVODMapping.item($0, provider: id, state: state) }
        }
    }

    func recentlyAddedHub(in library: MediaLibrary) async throws -> MediaHub? {
        let added = try await items(in: library, sort: .addedAtDesc, page: Page(offset: 0, limit: 24)).items
        return added.isEmpty ? nil : MediaHub(
            id: "\(library.id).recentlyAdded", providerID: id,
            title: String(localized: "Recently Added in \(library.title)"), style: .shelf, items: added,
            pagingKey: library.id)
    }

    /// See All on a Recently Added row: the library newest first.
    func hubPage(_ hub: MediaHub, page: Page) async throws -> PagedResult<MediaItem> {
        guard let key = hub.pagingKey, let library = XtreamVODLibrary(rawValue: key) else {
            return PagedResult(items: page.offset == 0 ? hub.items : [], total: hub.items.count, nextPage: nil)
        }
        return try await items(in: self.library(library), sort: .addedAtDesc, page: page)
    }

    // MARK: - Favorites

    /// Kept on the device, as the panel keeps none.
    var supportsFavorites: Bool { true }

    /// The library's favorites by title, as the other servers' rows list them.
    func favorites(in library: MediaLibrary, limit: Int) async throws -> [MediaItem] {
        let state = await state()
        guard !state.favorites.isEmpty else { return [] }
        let items: [MediaItem]
        switch XtreamVODLibrary(rawValue: library.id) {
        case .movies:
            items = try await catalog.movieLists().titles
                .filter { state.favorites.contains(XtreamVODMapping.movieKey(source: id, movieID: $0.id)) }
                .map { XtreamVODMapping.item($0, provider: id, state: state) }
        case .series:
            items = try await catalog.seriesLists().titles
                .filter { state.favorites.contains(XtreamVODMapping.seriesKey(source: id, seriesID: $0.id)) }
                .map { XtreamVODMapping.item($0, provider: id, state: state) }
        case nil:
            items = []
        }
        return Array(FavoritesOrder.byTitle(items).prefix(limit))
    }

    func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        let key: String
        switch XtreamVODID(itemID: ref.itemID) {
        case .movie(let movieID): key = XtreamVODMapping.movieKey(source: id, movieID: movieID)
        case .series(let seriesID): key = XtreamVODMapping.seriesKey(source: id, seriesID: seriesID)
        default: throw MediaProviderError.backendSpecific(underlying: "only films and series are favorites")
        }
        await MainActor.run { watchStore().setFavorite(favorite, key: key) }
    }

    // MARK: - Watchlist

    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool { false }
    func addToWatchlist(_ ref: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: "Xtream has no watchlist")
    }
    func removeFromWatchlist(_ ref: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: "Xtream has no watchlist")
    }
}

/// Writes the player's position to the device's watch state.
struct XtreamProgressReporter: ProgressReporter {
    let key: String?
    let runtime: TimeInterval?
    let store: @MainActor @Sendable () -> XtreamWatchProgressStore

    func start(position: TimeInterval) async throws { await save(position) }
    func progress(position: TimeInterval) async { await save(position) }
    func paused(at position: TimeInterval) async { await save(position) }
    func stopped(at position: TimeInterval) async { await save(position) }

    private func save(_ position: TimeInterval) async {
        guard let key, position > 0 else { return }
        let runtime = runtime
        let store = store
        await MainActor.run { store().update(key, position: position, duration: runtime) }
    }
}
