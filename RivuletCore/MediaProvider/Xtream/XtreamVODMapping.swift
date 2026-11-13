// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamVODMapping.swift
//  Rivulet
//
//  Xtream films and series as `MediaItem`s, and the library work a panel does
//  not do: it lists a whole category or everything, unsorted and unpaged, so
//  sorting, paging, the A to Z counts and search happen here. Pure, so it is
//  tested without a panel.
//

import Foundation

/// The item ids an Xtream provider mints. Each kind carries what playing or
/// opening it needs, so no lookup table has to outlive a launch.
nonisolated enum XtreamVODID: Hashable, Sendable {
    case movie(String)
    case series(String)
    case season(seriesID: String, number: Int)
    case episode(seriesID: String, episodeID: String)
    /// A provider category, shown as a collection in its library.
    case category(library: XtreamVODLibrary, id: String)

    var itemID: String {
        switch self {
        case .movie(let id): "m|\(id)"
        case .series(let id): "s|\(id)"
        case .season(let series, let number): "n|\(series)|\(number)"
        case .episode(let series, let episode): "e|\(series)|\(episode)"
        case .category(let library, let id): "c|\(library.rawValue)|\(id)"
        }
    }

    init?(itemID: String) {
        let parts = itemID.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        switch (parts[0], parts.count) {
        case ("m", 2): self = .movie(parts[1])
        case ("s", 2): self = .series(parts[1])
        case ("n", 3):
            guard let number = Int(parts[2]) else { return nil }
            self = .season(seriesID: parts[1], number: number)
        case ("e", 3) where !parts[2].isEmpty: self = .episode(seriesID: parts[1], episodeID: parts[2])
        case ("c", 3) where !parts[2].isEmpty:
            guard let library = XtreamVODLibrary(rawValue: parts[1]) else { return nil }
            self = .category(library: library, id: parts[2])
        default: return nil
        }
    }
}

/// The two libraries a panel has.
nonisolated enum XtreamVODLibrary: String, Sendable, CaseIterable {
    case movies
    case series

    var kind: MediaLibrary.LibraryKind { self == .movies ? .movies : .shows }

    var title: String {
        self == .movies ? String(localized: "Movies") : String(localized: "TV Shows")
    }
}

nonisolated enum XtreamVODMapping {
    /// The watch state a list is mapped with: each title's record, by `XtreamWatchProgressStore` key.
    typealias Records = [String: XtreamWatchRecord]

    // MARK: Watch-state keys

    static func movieKey(source: String, movieID: String) -> String {
        XtreamWatchProgressStore.key(source: source, kind: .movie, id: movieID)
    }

    /// An episode's id is unique on the panel, but its series is what Continue Watching needs.
    static func episodeKey(source: String, seriesID: String, episodeID: String) -> String {
        XtreamWatchProgressStore.key(source: source, kind: .episode, id: "\(seriesID)/\(episodeID)")
    }

    /// A key back to its title, for Continue Watching. Nil for another source's key or a bad one.
    static func id(fromKey key: String, source: String) -> XtreamVODID? {
        let prefix = "\(source)|"
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let bar = rest.firstIndex(of: "|") else { return nil }
        let kind = rest[..<bar]
        let id = String(rest[rest.index(after: bar)...])
        switch kind {
        case XtreamWatchProgressStore.Kind.movie.rawValue:
            return id.isEmpty ? nil : .movie(id)
        case XtreamWatchProgressStore.Kind.episode.rawValue:
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return .episode(seriesID: parts[0], episodeID: parts[1])
        default:
            return nil
        }
    }

    static func userState(_ record: XtreamWatchRecord?) -> MediaUserState {
        MediaUserState(isPlayed: record?.watched ?? false, viewOffset: record?.position ?? 0,
                       isFavorite: false, lastViewedAt: record?.updatedAt)
    }

    // MARK: Items

    static func item(_ movie: XtreamMovie, provider: String, records: Records) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: provider, itemID: XtreamVODID.movie(movie.id).itemID),
            kind: .movie, title: movie.name, sortTitle: nil, overview: nil, year: movie.year,
            runtime: nil,
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: userState(records[movieKey(source: provider, movieID: movie.id)]),
            artwork: MediaArtwork(poster: movie.posterURL, backdrop: nil, thumbnail: movie.posterURL, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil,
            libraryID: XtreamVODLibrary.movies.rawValue)
    }

    static func item(_ series: XtreamSeries, provider: String) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: provider, itemID: XtreamVODID.series(series.id).itemID),
            kind: .show, title: series.name, sortTitle: nil, overview: series.plot, year: series.year,
            runtime: nil,
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: userState(nil),
            artwork: MediaArtwork(poster: series.coverURL, backdrop: series.backdropURL,
                                  thumbnail: series.coverURL, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil,
            genres: genres(series.genre),
            libraryID: XtreamVODLibrary.series.rawValue)
    }

    static func item(_ season: XtreamSeason, of series: XtreamSeries, provider: String) -> MediaItem {
        let showRef = MediaItemRef(providerID: provider, itemID: XtreamVODID.series(series.id).itemID)
        let seriesArt = MediaArtwork(poster: series.coverURL, backdrop: series.backdropURL,
                                     thumbnail: series.coverURL, logo: nil)
        return MediaItem(
            ref: MediaItemRef(providerID: provider,
                              itemID: XtreamVODID.season(seriesID: series.id, number: season.number).itemID),
            kind: .season, title: season.name ?? String(localized: "Season \(season.number)"),
            sortTitle: nil, overview: nil, year: nil, runtime: nil,
            parentRef: showRef, grandparentRef: nil, seriesTitle: series.name,
            episodeNumber: nil, seasonNumber: season.number, childProgress: nil,
            userState: userState(nil),
            artwork: MediaArtwork(poster: season.coverURL ?? series.coverURL, backdrop: series.backdropURL,
                                  thumbnail: season.coverURL ?? series.coverURL, logo: nil),
            parentArtwork: seriesArt, grandparentArtwork: nil,
            libraryID: XtreamVODLibrary.series.rawValue)
    }

    static func item(_ episode: XtreamEpisode, of series: XtreamSeries, provider: String,
                     records: Records) -> MediaItem {
        let showRef = MediaItemRef(providerID: provider, itemID: XtreamVODID.series(series.id).itemID)
        let seasonRef = MediaItemRef(providerID: provider,
                                     itemID: XtreamVODID.season(seriesID: series.id, number: episode.season).itemID)
        let seriesArt = MediaArtwork(poster: series.coverURL, backdrop: series.backdropURL,
                                     thumbnail: series.coverURL, logo: nil)
        let title = episode.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Episode \(episode.number)")
        return MediaItem(
            ref: MediaItemRef(providerID: provider,
                              itemID: XtreamVODID.episode(seriesID: series.id, episodeID: episode.id).itemID),
            kind: .episode, title: title, sortTitle: nil, overview: episode.plot, year: nil,
            runtime: episode.duration,
            parentRef: seasonRef, grandparentRef: showRef, seriesTitle: series.name,
            episodeNumber: episode.number, seasonNumber: episode.season, childProgress: nil,
            userState: userState(records[episodeKey(source: provider, seriesID: series.id, episodeID: episode.id)]),
            artwork: MediaArtwork(poster: series.coverURL, backdrop: series.backdropURL,
                                  thumbnail: episode.imageURL ?? series.backdropURL ?? series.coverURL, logo: nil),
            parentArtwork: seriesArt, grandparentArtwork: seriesArt,
            libraryID: XtreamVODLibrary.series.rawValue)
    }

    /// A provider category as a collection tile, with the first poster in it.
    static func item(_ category: XtreamVODCategory, library: XtreamVODLibrary, poster: URL?,
                     provider: String) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: provider,
                              itemID: XtreamVODID.category(library: library, id: category.id).itemID),
            kind: .collection, title: category.name, sortTitle: nil, overview: nil, year: nil, runtime: nil,
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: userState(nil),
            artwork: MediaArtwork(poster: poster, backdrop: nil, thumbnail: poster, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil, libraryID: library.rawValue)
    }

    /// "Drama, Thriller" or "Drama / Thriller" as names.
    static func genres(_ text: String?) -> [String]? {
        let names = (text ?? "").split { $0 == "," || $0 == "/" || $0 == "|" }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }

    // MARK: Sorting and the A to Z bar

    /// What a listing sorts on, whatever the title type.
    struct Sortable: Sendable {
        let name: String
        let added: Date?
        let year: Int?
        let rating: Double?
    }

    /// The A to Z bucket of a title: its first letter, or "#" for anything else.
    static func bucket(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = folded.first, first.isASCII, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    /// The order of `values` under `sort`. By name, "#" comes before A; ties keep the panel's order.
    static func order(_ values: [Sortable], by sort: SortOption) -> [Int] {
        let keys = values.map { (bucket($0.name), $0.name) }
        func byName(_ a: Int, _ b: Int) -> Bool {
            if keys[a].0 != keys[b].0 { return keys[a].0 == "#" || (keys[b].0 != "#" && keys[a].0 < keys[b].0) }
            let compared = keys[a].1.localizedStandardCompare(keys[b].1)
            return compared == .orderedSame ? a < b : compared == .orderedAscending
        }
        /// Present values first in the asked direction, then the rest by name.
        func by<T: Comparable>(_ value: @escaping (Sortable) -> T?, descending: Bool) -> (Int, Int) -> Bool {
            { a, b in
                switch (value(values[a]), value(values[b])) {
                case let (x?, y?) where x != y: return descending ? x > y : x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return byName(a, b)
                }
            }
        }
        let indices = Array(values.indices)
        switch sort {
        case .titleAsc: return indices.sorted(by: byName)
        case .titleDesc: return indices.sorted { byName($1, $0) }
        case .addedAtDesc, .lastContentAddedDesc: return indices.sorted(by: by(\.added, descending: true))
        case .addedAtAsc: return indices.sorted(by: by(\.added, descending: false))
        case .releaseDateDesc: return indices.sorted(by: by(\.year, descending: true))
        case .releaseDateAsc: return indices.sorted(by: by(\.year, descending: false))
        case .ratingDesc: return indices.sorted(by: by(\.rating, descending: true))
        }
    }

    /// Title counts per bucket, "#" first then A to Z, as the A to Z bar takes them.
    static func letterCounts(_ names: [String]) -> [PlexFirstCharacter] {
        var counts: [String: Int] = [:]
        for name in names { counts[bucket(name), default: 0] += 1 }
        return counts.keys.sorted { $0 == "#" || ($1 != "#" && $0 < $1) }
            .map { PlexFirstCharacter(title: $0, size: counts[$0] ?? 0) }
    }

    static func sortable(_ movie: XtreamMovie) -> Sortable {
        Sortable(name: movie.name, added: movie.addedAt, year: movie.year, rating: movie.rating)
    }

    static func sortable(_ series: XtreamSeries) -> Sortable {
        Sortable(name: series.name, added: series.updatedAt, year: series.year, rating: series.rating)
    }

    /// One page of `values` in `sort` order.
    static func page<T>(_ values: [T], sortable: (T) -> Sortable, sort: SortOption, page: Page) -> (items: [T], total: Int) {
        let order = order(values.map(sortable), by: sort)
        let start = min(max(page.offset, 0), order.count)
        let end = min(start + max(page.limit, 0), order.count)
        return (order[start..<end].map { values[$0] }, order.count)
    }

    // MARK: Search

    /// Titles whose every query word starts a word of the name, or appears in it; word starts first.
    static func search<T>(_ query: String, in values: [T], name: (T) -> String, limit: Int) -> [T] {
        let tokens = LiveChannelSearch.normalized(query).split(separator: " ")
        guard !tokens.isEmpty else { return [] }
        var starts: [T] = []
        var anywhere: [T] = []
        for value in values {
            let normalized = LiveChannelSearch.normalized(name(value))
            let words = normalized.split(separator: " ")
            if tokens.allSatisfy({ token in words.contains { $0.hasPrefix(token) } }) {
                starts.append(value)
            } else if tokens.allSatisfy({ normalized.contains($0) }) {
                anywhere.append(value)
            }
            if starts.count >= limit { break }
        }
        return Array((starts + anywhere).prefix(limit))
    }

    // MARK: Episodes

    /// The episode Play means in a series: the one in progress watched last, else the first
    /// unwatched after the last watched one, else the first.
    static func nextEpisode(_ episodes: [MediaItem]) -> MediaItem? {
        if let resuming = episodes.filter({ $0.userState.viewOffset > 0 && !$0.userState.isPlayed })
            .max(by: { ($0.userState.lastViewedAt ?? .distantPast) < ($1.userState.lastViewedAt ?? .distantPast) }) {
            return resuming
        }
        if let last = episodes.lastIndex(where: \.userState.isPlayed) {
            return episodes[(last + 1)...].first { !$0.userState.isPlayed }
        }
        return episodes.first
    }
}
