// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamVOD.swift
//  Rivulet
//
//  Films and series from an Xtream Codes (XC) panel: categories, lists,
//  details, seasons and episodes, and their stream URLs. Like the live side
//  (`XtreamService`), replies are walked by hand: panels mix `1` and `"1"`,
//  send `[]`, `{}`, `false` or `null` for an empty list, and list a series'
//  episodes keyed by season or as an array of seasons. One malformed entry
//  is skipped, not the whole list. No reply body ever goes into an error or
//  a log: `player_api.php` echoes the password.
//

import Foundation

nonisolated struct XtreamVODCategory: Sendable, Equatable, Codable {
    let id: String
    let name: String
}

/// A film as `get_vod_streams` lists it.
nonisolated struct XtreamMovie: Sendable, Equatable, Codable {
    let id: String
    let name: String
    let categoryId: String?
    let posterURL: URL?
    /// Out of 10.
    let rating: Double?
    let addedAt: Date?
    let year: Int?
    /// The file's container, which is also the stream URL's extension.
    let containerExtension: String
    /// The tags the panel put before the name ("NL", "FR-4K"): one film is often listed once
    /// per language, and this tells the copies apart.
    var tag: String? = nil
}

/// A film's details from `get_vod_info`.
nonisolated struct XtreamMovieInfo: Sendable, Equatable {
    let plot: String?
    let genre: String?
    let cast: String?
    let director: String?
    let releaseDate: Date?
    let duration: TimeInterval?
    let backdropURL: URL?
    let posterURL: URL?
    let tmdbId: String?
    let containerExtension: String?
}

/// A series as `get_series` lists it.
nonisolated struct XtreamSeries: Sendable, Equatable, Codable {
    let id: String
    let name: String
    let categoryId: String?
    let coverURL: URL?
    let backdropURL: URL?
    let plot: String?
    let genre: String?
    let rating: Double?
    let year: Int?
    let updatedAt: Date?
    /// As on `XtreamMovie`.
    var tag: String? = nil
}

nonisolated struct XtreamSeason: Sendable, Equatable {
    let number: Int
    let name: String?
    let coverURL: URL?
}

nonisolated struct XtreamEpisode: Sendable, Equatable {
    let id: String
    let season: Int
    let number: Int
    let title: String?
    let plot: String?
    let duration: TimeInterval?
    let imageURL: URL?
    let addedAt: Date?
    let containerExtension: String
}

/// A series' seasons and episodes from `get_series_info`, episodes in season then episode order.
nonisolated struct XtreamSeriesInfo: Sendable, Equatable {
    let seasons: [XtreamSeason]
    let episodes: [XtreamEpisode]
    /// The show's TMDB id, when the panel gives one (`info.tmdb`).
    var tmdbId: String? = nil
}

extension XtreamService {
    // MARK: Requests

    func vodCategories() async throws -> [XtreamVODCategory] {
        Self.categories(from: try await vod("get_vod_categories"))
    }

    func movies(inCategory categoryId: String? = nil) async throws -> [XtreamMovie] {
        Self.movies(from: try await vod("get_vod_streams", categoryId.map { [URLQueryItem(name: "category_id", value: $0)] } ?? []))
    }

    func movieInfo(_ movieId: String) async throws -> XtreamMovieInfo {
        Self.movieInfo(from: try await vod("get_vod_info", [URLQueryItem(name: "vod_id", value: movieId)]))
    }

    func seriesCategories() async throws -> [XtreamVODCategory] {
        Self.categories(from: try await vod("get_series_categories"))
    }

    func series(inCategory categoryId: String? = nil) async throws -> [XtreamSeries] {
        Self.series(from: try await vod("get_series", categoryId.map { [URLQueryItem(name: "category_id", value: $0)] } ?? []))
    }

    func seriesInfo(_ seriesId: String) async throws -> XtreamSeriesInfo {
        Self.seriesInfo(from: try await vod("get_series_info", [URLQueryItem(name: "series_id", value: seriesId)]))
    }

    private func vod(_ action: String, _ query: [URLQueryItem] = []) async throws -> Any {
        var components = URLComponents(url: account.server.appendingPathComponent("player_api.php"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "username", value: account.username),
                                 URLQueryItem(name: "password", value: account.password),
                                 URLQueryItem(name: "action", value: action)] + query
        // `+` is a space to PHP's query parser, so a literal one must be escaped.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let (data, response) = try await BoundedDownload.data(for: URLRequest(url: components.url!),
                                                              limit: BoundedDownload.playlistLimit,
                                                              configuration: session.configuration)
        return try Self.parse(data, status: (response as? HTTPURLResponse)?.statusCode ?? 200)
    }

    // MARK: URLs

    /// `/movie/<user>/<pass>/<id>.<ext>`, each part one escaped path segment.
    nonisolated func movieURL(movieId: String, containerExtension: String) -> URL {
        vodURL("movie", id: movieId, containerExtension: containerExtension)
    }

    /// `/series/<user>/<pass>/<episode id>.<ext>`.
    nonisolated func episodeURL(episodeId: String, containerExtension: String) -> URL {
        vodURL("series", id: episodeId, containerExtension: containerExtension)
    }

    private nonisolated func vodURL(_ kind: String, id: String, containerExtension: String) -> URL {
        // `appending(component:)` escapes `/`; `appendingPathComponent` does not.
        account.server
            .appending(component: kind)
            .appending(component: account.username)
            .appending(component: account.password)
            .appending(component: "\(id).\(Self.fileExtension(containerExtension))")
    }

    /// A container name as a file extension: letters and digits only, `mp4` when there is none.
    nonisolated static func fileExtension(_ container: String) -> String {
        let cleaned = container.lowercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? "mp4" : cleaned
    }

    // MARK: Decoding

    nonisolated static func categories(from json: Any) -> [XtreamVODCategory] {
        list(json).compactMap { entry in
            guard let id = string(entry["category_id"]), let name = string(entry["category_name"]) else { return nil }
            return XtreamVODCategory(id: id, name: name)
        }
    }

    nonisolated static func movies(from json: Any) -> [XtreamMovie] {
        list(json).compactMap { entry in
            guard let id = string(entry["stream_id"]),
                  let listed = string(entry["name"]), !isSectionHeader(listed) else { return nil }
            let (bare, tags) = splitTags(listed)
            let (name, nameYear) = splitYear(bare)
            return XtreamMovie(
                id: id, name: name,
                categoryId: string(entry["category_id"]),
                posterURL: url(entry["stream_icon"]),
                rating: rating(entry),
                addedAt: date(entry["added"]),
                year: year(entry["year"]) ?? year(entry["releaseDate"]) ?? year(entry["release_date"]) ?? nameYear,
                containerExtension: string(entry["container_extension"]) ?? "mp4",
                tag: tags.isEmpty ? nil : tags.joined(separator: " "))
        }
    }

    nonisolated static func movieInfo(from json: Any) -> XtreamMovieInfo {
        let root = json as? [String: Any] ?? [:]
        let info = root["info"] as? [String: Any] ?? [:]
        let data = root["movie_data"] as? [String: Any] ?? [:]
        return XtreamMovieInfo(
            plot: string(info["plot"]) ?? string(info["description"]),
            genre: string(info["genre"]),
            cast: string(info["cast"]) ?? string(info["actors"]),
            director: string(info["director"]),
            releaseDate: day(info["releasedate"]) ?? day(info["release_date"]),
            duration: duration(info),
            backdropURL: firstURL(info["backdrop_path"]),
            posterURL: url(info["movie_image"]) ?? url(info["cover_big"]),
            tmdbId: string(info["tmdb_id"]).flatMap { $0 == "0" ? nil : $0 },
            containerExtension: string(data["container_extension"]))
    }

    nonisolated static func series(from json: Any) -> [XtreamSeries] {
        list(json).compactMap { entry in
            guard let id = string(entry["series_id"]),
                  let listed = string(entry["name"]), !isSectionHeader(listed) else { return nil }
            let (bare, tags) = splitTags(listed)
            let (name, nameYear) = splitYear(bare)
            return XtreamSeries(
                id: id, name: name,
                categoryId: string(entry["category_id"]),
                coverURL: url(entry["cover"]),
                backdropURL: firstURL(entry["backdrop_path"]),
                plot: string(entry["plot"]),
                genre: string(entry["genre"]),
                rating: rating(entry),
                year: year(entry["year"]) ?? year(entry["releaseDate"]) ?? year(entry["release_date"]) ?? nameYear,
                updatedAt: date(entry["last_modified"]),
                tag: tags.isEmpty ? nil : tags.joined(separator: " "))
        }
    }

    nonisolated static func seriesInfo(from json: Any) -> XtreamSeriesInfo {
        let root = json as? [String: Any] ?? [:]
        // Episodes come keyed by season ("1": [...]) or as an array of seasons.
        var groups: [(key: Int?, entries: [[String: Any]])] = []
        if let byKey = root["episodes"] as? [String: Any] {
            groups = byKey.map { (Int($0.key), $0.value as? [[String: Any]] ?? []) }
        } else if let nested = root["episodes"] as? [Any] {
            groups = nested.map { (nil, $0 as? [[String: Any]] ?? []) }
        }
        var episodes: [XtreamEpisode] = []
        var seen = Set<String>()
        for group in groups {
            for entry in group.entries {
                guard let id = string(entry["id"]), seen.insert(id).inserted,
                      let season = int(entry["season"]) ?? group.key else { continue }
                let info = entry["info"] as? [String: Any] ?? [:]
                episodes.append(XtreamEpisode(
                    id: id, season: season,
                    number: int(entry["episode_num"]) ?? 0,
                    title: string(entry["title"]),
                    plot: string(info["plot"]),
                    duration: duration(info),
                    imageURL: url(info["movie_image"]),
                    addedAt: date(entry["added"]),
                    containerExtension: string(entry["container_extension"]) ?? "mp4"))
            }
        }
        episodes.sort { ($0.season, $0.number) < ($1.season, $1.number) }

        // Seasons as listed; any with episodes but no entry are added, so none goes missing.
        var seasons = list(root["seasons"] as Any).compactMap { entry -> XtreamSeason? in
            guard let number = int(entry["season_number"]) else { return nil }
            return XtreamSeason(number: number, name: string(entry["name"]), coverURL: url(entry["cover"]))
        }
        for number in Set(episodes.map(\.season)) where !seasons.contains(where: { $0.number == number }) {
            seasons.append(XtreamSeason(number: number, name: nil, coverURL: nil))
        }
        // Only seasons with episodes: panels list empty "Specials" seasons.
        let withEpisodes = Set(episodes.map(\.season))
        seasons = seasons.filter { withEpisodes.contains($0.number) }.sorted { $0.number < $1.number }
        var seenSeasons = Set<Int>()
        seasons = seasons.filter { seenSeasons.insert($0.number).inserted }
        let info = root["info"] as? [String: Any] ?? [:]
        let tmdb = (string(info["tmdb"]) ?? string(info["tmdb_id"])).flatMap { Int($0).map(String.init) }
        return XtreamSeriesInfo(seasons: seasons, episodes: episodes, tmdbId: tmdb)
    }

    // MARK: Field helpers

    /// The title a viewer reads: without the language or quality tags panels put in front
    /// ("┃NL┃ ", "┃FR-4K┃", "[EN] ", "NL | ", "┃NL " with its closing bar missing), and with
    /// single spaces. Never a colon, which titles use ("CSI: Miami"). The category already says
    /// the language. A name that is only tags keeps them.
    nonisolated static func cleanName(_ name: String) -> String { splitTags(name).name }

    /// `cleanName` with the tags it left out, each without its bars ("NL", "FR-4K").
    nonisolated static func splitTags(_ name: String) -> (name: String, tags: [String]) {
        var rest = Substring(name)
        var tags: [String] = []
        let tag = #"^\s*(?:┃[^┃|\n]{1,20}[┃|]|┃[A-Z]{2,5}(?=\s)|\|\s*[A-Z0-9+-]{2,8}\s*[┃|]|\[[A-Z]{2}\]|[A-Z]{2,4}(?:-[A-Z0-9]{2,4})?\s*[┃|])\s*"#
        while let match = rest.range(of: tag, options: .regularExpression), match.upperBound < rest.endIndex {
            let text = rest[match].trimmingCharacters(in: CharacterSet(charactersIn: "┃|[]").union(.whitespaces))
            if !text.isEmpty { tags.append(text) }
            rest = rest[match.upperBound...]
        }
        let single = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return single.isEmpty ? (name, []) : (single, tags)
    }

    /// A year many panels put at the end of the name instead of in a field ("White Chicks - 2004",
    /// "Wildschut (1985)"): the name without it, and the year. A name that is only a year keeps it.
    nonisolated static func splitYear(_ name: String) -> (name: String, year: Int?) {
        let patterns = [#"\s*[-–|]\s*((?:19|20)\d\d)\s*$"#, #"\s*\(((?:19|20)\d\d)\)(?:\s*\([A-Za-z]{2,8}\))?\s*$"#]
        for pattern in patterns {
            guard let match = name.range(of: pattern, options: .regularExpression) else { continue }
            let rest = name[..<match.lowerBound].trimmingCharacters(in: .whitespaces)
            let digits = name[match].filter(\.isNumber)
            guard !rest.isEmpty, let year = Int(digits), year <= Calendar.current.component(.year, from: Date()) + 1 else {
                continue
            }
            return (rest, year)
        }
        return (name, nil)
    }

    private nonisolated static func list(_ json: Any) -> [[String: Any]] {
        json as? [[String: Any]] ?? []
    }

    nonisolated static func url(_ value: Any?) -> URL? {
        guard let text = string(value), text.lowercased().hasPrefix("http"), let url = URL(string: text) else { return nil }
        return url
    }

    /// A backdrop field is an array of URLs, or one URL.
    private nonisolated static func firstURL(_ value: Any?) -> URL? {
        if let array = value as? [Any] { return array.lazy.compactMap { url($0) }.first }
        return url(value)
    }

    /// Unix seconds, as a number or a string.
    private nonisolated static func date(_ value: Any?) -> Date? {
        int(value).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
    }

    /// `2020-05-01` (sometimes with a time after it), as a day in UTC.
    nonisolated static func day(_ value: Any?) -> Date? {
        guard let text = string(value), text.count >= 10 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 1800 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// A year from `2020` or the start of a date.
    private nonisolated static func year(_ value: Any?) -> Int? {
        guard let text = string(value), text.count >= 4, let year = Int(text.prefix(4)), year > 1800 else { return nil }
        return year
    }

    /// `rating` out of 10, else `rating_5based` doubled. 0 means unrated.
    private nonisolated static func rating(_ entry: [String: Any]) -> Double? {
        if let ten = double(entry["rating"]), ten > 0 { return min(ten, 10) }
        if let five = double(entry["rating_5based"]), five > 0 { return min(five * 2, 10) }
        return nil
    }

    /// `duration_secs`, else `duration` as `HH:MM:SS`.
    private nonisolated static func duration(_ info: [String: Any]) -> TimeInterval? {
        if let seconds = double(info["duration_secs"]), seconds > 0 { return seconds }
        guard let text = string(info["duration"]) else { return nil }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        let total = parts[0] * 3600 + parts[1] * 60 + parts[2]
        return total > 0 ? total : nil
    }
}
