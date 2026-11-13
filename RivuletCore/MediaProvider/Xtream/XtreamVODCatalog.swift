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
        return directory?.appending(component: "\(String(safe))-\(name).json")
    }

    private func read<T: Codable & Sendable>(_ name: String) -> XtreamVODLists<T>? {
        guard let url = file(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(XtreamVODLists<T>.self, from: data)
    }

    private func write<T: Codable & Sendable>(_ lists: XtreamVODLists<T>, _ name: String) {
        guard let directory, let url = file(name), let data = try? JSONEncoder().encode(lists) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The source was removed: its lists go too.
    nonisolated static func forget(sourceID: String, directory: URL? = defaultDirectory) {
        guard let directory else { return }
        let safe = String(sourceID.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        for name in ["movies", "series"] {
            try? FileManager.default.removeItem(at: directory.appending(component: "\(safe)-\(name).json"))
        }
    }
}
