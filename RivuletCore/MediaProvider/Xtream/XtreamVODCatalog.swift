// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamVODCatalog.swift
//  Rivulet
//
//  One panel's film and series lists, kept on the device for a day. A panel
//  can hold tens of thousands of titles in one reply and has no paging, so
//  every listing, sort and search reads these copies. A failed refresh keeps
//  the stale copy. Details and episodes are kept for the launch.
//

import Foundation

nonisolated struct XtreamVODLists<Title: Codable & Sendable>: Codable, Sendable {
    var titles: [Title]
    var categories: [XtreamVODCategory]
    var fetchedAt: Date
}

actor XtreamVODCatalog {
    /// How long a list is used before it is asked for again.
    static let lifetime: TimeInterval = 24 * 3600

    let service: XtreamService
    let sourceID: String
    private let directory: URL?

    private var movies: XtreamVODLists<XtreamMovie>?
    private var series: XtreamVODLists<XtreamSeries>?
    private var movieLoad: Task<XtreamVODLists<XtreamMovie>, Error>?
    private var seriesLoad: Task<XtreamVODLists<XtreamSeries>, Error>?
    private var movieInfos: [String: XtreamMovieInfo] = [:]
    private var seriesInfos: [String: XtreamSeriesInfo] = [:]
    private var seriesInfoLoads: [String: Task<XtreamSeriesInfo, Error>] = [:]

    /// Work done once per list rather than per page or keystroke: each sort's order,
    /// the names folded for search, the A to Z counts. Keyed by the list's fetch time.
    private struct Derived {
        var fetchedAt: Date
        var orders: [SortOption: [Int]] = [:]
        var searchNames: [String]?
        var letters: [PlexFirstCharacter]?
    }
    private var derived: [XtreamVODLibrary: Derived] = [:]

    /// The viewer's languages, and the lists as they show in them (`XtreamVODLanguages`).
    private var languages = XtreamVODLanguages.everything
    private var shownMovies: XtreamVODLists<XtreamMovie>?
    private var shownSeries: XtreamVODLists<XtreamSeries>?

    /// Sets the languages the shown lists keep; a change works them out again.
    func setLanguages(_ languages: XtreamVODLanguages) {
        guard languages != self.languages else { return }
        self.languages = languages
        shownMovies = nil
        shownSeries = nil
        derived = [:]
    }

    /// The films in the viewer's languages, one copy each, and the categories still holding one.
    /// Listing, search, collections and For You read these; lookups by id read `movieLists`.
    func shownMovieLists() async throws -> XtreamVODLists<XtreamMovie> {
        let all = try await movieLists()
        if let shownMovies, shownMovies.fetchedAt == all.fetchedAt { return shownMovies }
        let kept = languages.shown(all.titles.map { ($0.name, $0.year, $0.tag) }).map { all.titles[$0] }
        let lists = XtreamVODLists(titles: kept, categories: Self.holding(all.categories, kept.map(\.categoryId)),
                                   fetchedAt: all.fetchedAt)
        shownMovies = lists
        return lists
    }

    func shownSeriesLists() async throws -> XtreamVODLists<XtreamSeries> {
        let all = try await seriesLists()
        if let shownSeries, shownSeries.fetchedAt == all.fetchedAt { return shownSeries }
        let kept = languages.shown(all.titles.map { ($0.name, $0.year, $0.tag) }).map { all.titles[$0] }
        let lists = XtreamVODLists(titles: kept, categories: Self.holding(all.categories, kept.map(\.categoryId)),
                                   fetchedAt: all.fetchedAt)
        shownSeries = lists
        return lists
    }

    private static func holding(_ categories: [XtreamVODCategory], _ ids: [String?]) -> [XtreamVODCategory] {
        let used = Set(ids.compactMap { $0 })
        return categories.filter { used.contains($0.id) }
    }

    /// The languages both lists carry, most common first.
    func availableOrigins() async -> [(origin: String, count: Int)] {
        let movieTags = (try? await movieLists().titles.map(\.tag)) ?? []
        let seriesTags = (try? await seriesLists().titles.map(\.tag)) ?? []
        return XtreamVODLanguages.available(movieTags + seriesTags)
    }

    init(service: XtreamService, sourceID: String, directory: URL? = XtreamVODCatalog.defaultDirectory) {
        self.service = service
        self.sourceID = sourceID
        self.directory = directory
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(component: "XtreamVOD", directoryHint: .isDirectory)
    }

    // MARK: Lists

    func movieLists() async throws -> XtreamVODLists<XtreamMovie> {
        if let movies, Self.isFresh(movies.fetchedAt) { return movies }
        if let movieLoad { return try await movieLoad.value }
        let stale = movies ?? read("movies")
        if let stale, Self.isFresh(stale.fetchedAt) {
            movies = stale
            return stale
        }
        let service = service
        let task = Task<XtreamVODLists<XtreamMovie>, Error> {
            async let categories = service.vodCategories()
            let titles = try await service.movies()
            return XtreamVODLists(titles: titles, categories: (try? await categories) ?? [], fetchedAt: Date())
        }
        movieLoad = task
        defer { movieLoad = nil }
        do {
            let fetched = try await task.value
            movies = fetched
            write(fetched, "movies")
            return fetched
        } catch {
            guard let stale else { throw error }
            movies = stale
            return stale
        }
    }

    func seriesLists() async throws -> XtreamVODLists<XtreamSeries> {
        if let series, Self.isFresh(series.fetchedAt) { return series }
        if let seriesLoad { return try await seriesLoad.value }
        let stale = series ?? read("series")
        if let stale, Self.isFresh(stale.fetchedAt) {
            series = stale
            return stale
        }
        let service = service
        let task = Task<XtreamVODLists<XtreamSeries>, Error> {
            async let categories = service.seriesCategories()
            let titles = try await service.series()
            return XtreamVODLists(titles: titles, categories: (try? await categories) ?? [], fetchedAt: Date())
        }
        seriesLoad = task
        defer { seriesLoad = nil }
        do {
            let fetched = try await task.value
            series = fetched
            write(fetched, "series")
            return fetched
        } catch {
            guard let stale else { throw error }
            series = stale
            return stale
        }
    }

    // MARK: Listing

    /// One page of a library in `sort` order.
    func moviePage(sort: SortOption, page: Page) async throws -> (items: [XtreamMovie], total: Int) {
        let lists = try await shownMovieLists()
        let order = self.order(.movies, lists.fetchedAt, sort) { lists.titles.map(XtreamVODMapping.sortable) }
        return (Self.slice(order, page).map { lists.titles[$0] }, order.count)
    }

    func seriesPage(sort: SortOption, page: Page) async throws -> (items: [XtreamSeries], total: Int) {
        let lists = try await shownSeriesLists()
        let order = self.order(.series, lists.fetchedAt, sort) { lists.titles.map(XtreamVODMapping.sortable) }
        return (Self.slice(order, page).map { lists.titles[$0] }, order.count)
    }

    func searchMovies(_ query: String, limit: Int) async throws -> [XtreamMovie] {
        let lists = try await shownMovieLists()
        let names = searchNames(.movies, lists.fetchedAt) { lists.titles.map(\.name) }
        return XtreamVODMapping.search(query, in: names, limit: limit).map { lists.titles[$0] }
    }

    func searchSeries(_ query: String, limit: Int) async throws -> [XtreamSeries] {
        let lists = try await shownSeriesLists()
        let names = searchNames(.series, lists.fetchedAt) { lists.titles.map(\.name) }
        return XtreamVODMapping.search(query, in: names, limit: limit).map { lists.titles[$0] }
    }

    func letterCounts(_ library: XtreamVODLibrary) async throws -> [PlexFirstCharacter] {
        let fetchedAt: Date
        let names: [String]
        switch library {
        case .movies:
            let lists = try await shownMovieLists()
            fetchedAt = lists.fetchedAt
            if let letters = fresh(library, fetchedAt).letters { return letters }
            names = lists.titles.map(\.name)
        case .series:
            let lists = try await shownSeriesLists()
            fetchedAt = lists.fetchedAt
            if let letters = fresh(library, fetchedAt).letters { return letters }
            names = lists.titles.map(\.name)
        }
        var entry = fresh(library, fetchedAt)
        let letters = XtreamVODMapping.letterCounts(names)
        entry.letters = letters
        derived[library] = entry
        return letters
    }

    private func fresh(_ library: XtreamVODLibrary, _ fetchedAt: Date) -> Derived {
        if let entry = derived[library], entry.fetchedAt == fetchedAt { return entry }
        return Derived(fetchedAt: fetchedAt)
    }

    private func order(_ library: XtreamVODLibrary, _ fetchedAt: Date, _ sort: SortOption,
                       _ sortables: () -> [XtreamVODMapping.Sortable]) -> [Int] {
        var entry = fresh(library, fetchedAt)
        if let order = entry.orders[sort] { return order }
        let order = XtreamVODMapping.order(sortables(), by: sort)
        entry.orders[sort] = order
        derived[library] = entry
        return order
    }

    private func searchNames(_ library: XtreamVODLibrary, _ fetchedAt: Date, _ names: () -> [String]) -> [String] {
        var entry = fresh(library, fetchedAt)
        if let known = entry.searchNames { return known }
        let folded = names().map(LiveChannelSearch.normalized)
        entry.searchNames = folded
        derived[library] = entry
        return folded
    }

    private static func slice(_ order: [Int], _ page: Page) -> ArraySlice<Int> {
        let start = min(max(page.offset, 0), order.count)
        return order[start..<min(start + max(page.limit, 0), order.count)]
    }

    // MARK: Details

    func movieInfo(_ id: String) async throws -> XtreamMovieInfo {
        if let known = movieInfos[id] { return known }
        let info = try await service.movieInfo(id)
        movieInfos[id] = info
        return info
    }

    func seriesInfo(_ id: String) async throws -> XtreamSeriesInfo {
        if let known = seriesInfos[id] { return known }
        if let load = seriesInfoLoads[id] { return try await load.value }
        let service = service
        let task = Task { try await service.seriesInfo(id) }
        seriesInfoLoads[id] = task
        defer { seriesInfoLoads[id] = nil }
        let info = try await task.value
        seriesInfos[id] = info
        return info
    }

    // MARK: Disk

    static func isFresh(_ date: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(date) < lifetime && date <= now.addingTimeInterval(60)
    }

    private func file(_ name: String) -> URL? {
        let safe = sourceID.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        // v4: names without their tags or year, which moved to their own fields (v4: long tags too).
        return directory?.appending(component: "\(String(safe))-\(name)-v4.json")
    }

    private func read<T: Codable & Sendable>(_ name: String) -> XtreamVODLists<T>? {
        guard let url = file(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(XtreamVODLists<T>.self, from: data)
    }

    private func write<T: Codable & Sendable>(_ lists: XtreamVODLists<T>, _ name: String) {
        guard let directory, let url = file(name), let data = try? JSONEncoder().encode(lists) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // Copies an older build wrote: tens of MB each, never read again.
        let safe = String(sourceID.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        for old in Self.olderVersions(of: name) {
            try? FileManager.default.removeItem(at: directory.appending(component: "\(safe)-\(old).json"))
        }
    }

    /// The names earlier cache versions used for a list ("movies", "movies-v2", "movies-v3").
    nonisolated static func olderVersions(of name: String) -> [String] {
        [name, "\(name)-v2", "\(name)-v3"]
    }

    /// The source was removed: its lists go too.
    nonisolated static func forget(sourceID: String, directory: URL? = defaultDirectory) {
        guard let directory else { return }
        let safe = String(sourceID.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        for name in ["movies", "series", "movies-v2", "series-v2", "movies-v3", "series-v3", "movies-v4", "series-v4"] {
            try? FileManager.default.removeItem(at: directory.appending(component: "\(safe)-\(name).json"))
        }
    }
}
