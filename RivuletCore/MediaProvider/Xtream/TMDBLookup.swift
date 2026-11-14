// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBLookup.swift
//  Rivulet
//
//  Details for an Xtream film or series from The Movie Database, with the
//  viewer's own API key: the plot in their language, year, runtime, genres,
//  cast with photos, director and a backdrop, where the panel says little.
//  Rivulet's own TMDB access goes through the maintainer's attested relay,
//  which a fork cannot use and which has no search, hence this direct client.
//
//  A title is found by the panel's TMDB id, else by searching its name: a
//  match must agree on the year, or without a year carry the same title, so a
//  wrong film's details never land on a page. Asked only when a detail page
//  opens; answers (misses included) are kept for the session.
//

import Foundation

nonisolated struct TMDBTitle: Codable, Sendable, Equatable {
    struct Person: Codable, Sendable, Equatable {
        let name: String
        let role: String?
        let photoURL: URL?
    }

    let id: Int
    let title: String
    let overview: String?
    let year: Int?
    /// Seconds.
    let runtime: TimeInterval?
    let genres: [String]
    let posterURL: URL?
    let backdropURL: URL?
    let cast: [Person]
    let directors: [String]
}

/// A title TMDB recommends after another, as much as matching it to a panel needs.
nonisolated struct TMDBRecommendation: Sendable, Hashable {
    let id: Int
    let title: String
    let originalTitle: String?
    let year: Int?
    /// ISO 639-1 ("en", "ko").
    var originalLanguage: String? = nil
}

actor TMDBLookup {
    enum Kind: String, Sendable { case movie, tv }

    /// The viewer's key, in the Keychain: a v3 API key or a v4 read access token.
    static let keychainKey = "tmdbAPIKey"

    static let shared = TMDBLookup(apiKey: { await MainActor.run { KeychainHelper.get(TMDBLookup.keychainKey) } })

    private let apiKey: @Sendable () async -> String?
    private let session: URLSession
    private let language: String
    private var cache: [String: TMDBTitle?] = [:]
    private var recommendationCache: [String: [TMDBRecommendation]] = [:]
    private var languageCache: [String: String?] = [:]
    private var imdbCache: [String: String?] = [:]

    init(apiKey: @escaping @Sendable () async -> String?, session: URLSession = .shared,
         language: String = Locale.preferredLanguages.first ?? "en-US") {
        self.apiKey = apiKey
        self.session = session
        self.language = language
    }

    /// The title's details, nil without a key, without a sure match, or when TMDB is unreachable.
    func title(_ kind: Kind, tmdbID: String?, name: String, year: Int?) async -> TMDBTitle? {
        guard let key = await apiKey(), !key.isEmpty else { return nil }
        let cacheKey = "\(kind.rawValue)|\(tmdbID ?? "")|\(name)|\(year.map(String.init) ?? "")"
        if let known = cache[cacheKey] { return known }
        var id = tmdbID.flatMap(Int.init)
        if id == nil { id = await search(kind, name: name, year: year, key: key) }
        let found: TMDBTitle?
        if let id { found = await details(kind, id: id, key: key) } else { found = nil }
        cache[cacheKey] = found
        return found
    }

    /// Whether a key is set: without one nothing is asked.
    func hasKey() async -> Bool {
        guard let key = await apiKey() else { return false }
        return !key.isEmpty
    }

    /// What TMDB recommends after a title ("people who liked this also liked"), best first,
    /// kept for the session. Empty without a key or an answer.
    func recommendations(_ kind: Kind, tmdbID: Int) async -> [TMDBRecommendation] {
        guard let key = await apiKey(), !key.isEmpty else { return [] }
        let cacheKey = "\(kind.rawValue)|\(tmdbID)"
        if let known = recommendationCache[cacheKey] { return known }
        let query = [URLQueryItem(name: "language", value: language), URLQueryItem(name: "page", value: "1")]
        guard let json = await get("\(kind.rawValue)/\(tmdbID)/recommendations", query, key: key) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        let found = Self.recommendations(results, kind: kind)
        recommendationCache[cacheKey] = found
        return found
    }

    /// A title's IMDb id ("tt0306414") from TMDB's external ids, kept for the session.
    /// nil without a key, an answer, or an id. IntroDB looks skip markers up by it.
    func imdbID(_ kind: Kind, tmdbID: Int) async -> String? {
        guard let key = await apiKey(), !key.isEmpty else { return nil }
        let cacheKey = "\(kind.rawValue)|\(tmdbID)"
        if let known = imdbCache[cacheKey] { return known }
        let json = await get("\(kind.rawValue)/\(tmdbID)/external_ids", [], key: key) as? [String: Any]
        let found = (json?["imdb_id"] as? String).flatMap { $0.hasPrefix("tt") ? $0 : nil }
        // Only an answer is kept: a dropped connection may find it next time.
        if json != nil { imdbCache[cacheKey] = found }
        return found
    }

    /// A title's original language (ISO 639-1) by one search: the first result agreeing on the
    /// year, or without a year carrying the same title. Kept for the session; nil when unsure.
    func originalLanguage(_ kind: Kind, name: String, year: Int?) async -> String? {
        guard let key = await apiKey(), !key.isEmpty else { return nil }
        let cacheKey = "\(kind.rawValue)|\(name)|\(year.map(String.init) ?? "")"
        if let known = languageCache[cacheKey] { return known }
        var query = [URLQueryItem(name: "query", value: name), URLQueryItem(name: "language", value: language)]
        if let year {
            query.append(URLQueryItem(name: kind == .movie ? "year" : "first_air_date_year", value: String(year)))
        }
        var found: String?
        if let json = await get("search/\(kind.rawValue)", query, key: key) as? [String: Any],
           let results = json["results"] as? [[String: Any]],
           let id = Self.match(results, kind: kind, name: name, year: year) {
            found = results.first { $0["id"] as? Int == id }?["original_language"] as? String
        }
        languageCache[cacheKey] = found
        return found
    }

    static func recommendations(_ results: [[String: Any]], kind: Kind) -> [TMDBRecommendation] {
        results.compactMap { result in
            guard let id = result["id"] as? Int,
                  let title = result[kind == .movie ? "title" : "name"] as? String else { return nil }
            let date = result[kind == .movie ? "release_date" : "first_air_date"] as? String
            return TMDBRecommendation(id: id, title: title,
                                      originalTitle: result[kind == .movie ? "original_title" : "original_name"] as? String,
                                      year: date.flatMap { Int($0.prefix(4)) },
                                      originalLanguage: result["original_language"] as? String)
        }
    }

    // MARK: - Requests

    private func search(_ kind: Kind, name: String, year: Int?, key: String) async -> Int? {
        var query = [URLQueryItem(name: "query", value: name), URLQueryItem(name: "language", value: language)]
        if let year {
            query.append(URLQueryItem(name: kind == .movie ? "year" : "first_air_date_year", value: String(year)))
        }
        guard let json = await get("search/\(kind.rawValue)", query, key: key) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        return Self.match(results, kind: kind, name: name, year: year)
    }

    private func details(_ kind: Kind, id: Int, key: String) async -> TMDBTitle? {
        let query = [URLQueryItem(name: "language", value: language),
                     URLQueryItem(name: "append_to_response", value: "credits")]
        guard let json = await get("\(kind.rawValue)/\(id)", query, key: key) as? [String: Any],
              var title = Self.title(json, kind: kind) else { return nil }
        // No translation in the viewer's language: the English plot rather than none.
        if (title.overview ?? "").isEmpty, !language.hasPrefix("en"),
           let english = await get("\(kind.rawValue)/\(id)", [URLQueryItem(name: "language", value: "en-US")],
                                   key: key) as? [String: Any],
           let overview = english["overview"] as? String, !overview.isEmpty {
            title = TMDBTitle(id: title.id, title: title.title, overview: overview, year: title.year,
                              runtime: title.runtime, genres: title.genres, posterURL: title.posterURL,
                              backdropURL: title.backdropURL, cast: title.cast, directors: title.directors)
        }
        return title
    }

    private func get(_ path: String, _ query: [URLQueryItem], key: String) async -> Any? {
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        var items = query
        // A v3 key travels as a parameter, a v4 read token (a long JWT) as a bearer token.
        let isToken = key.count > 40
        if !isToken { items.append(URLQueryItem(name: "api_key", value: key)) }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isToken { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Reading replies

    /// The first result that agrees on the year (search was limited to it), or without a year
    /// one whose title or original title is the name, ignoring case and accents.
    static func match(_ results: [[String: Any]], kind: Kind, name: String, year: Int?) -> Int? {
        let wanted = LiveChannelSearch.normalized(name)
        for result in results {
            guard let id = result["id"] as? Int else { continue }
            let titles = (kind == .movie ? ["title", "original_title"] : ["name", "original_name"])
                .compactMap { result[$0] as? String }.map { LiveChannelSearch.normalized($0) }
            if let year {
                let date = result[kind == .movie ? "release_date" : "first_air_date"] as? String
                if date.flatMap({ Int($0.prefix(4)) }) == year { return id }
            } else if titles.contains(wanted) {
                return id
            }
        }
        return nil
    }

    static func title(_ json: [String: Any], kind: Kind) -> TMDBTitle? {
        guard let id = json["id"] as? Int,
              let name = (json[kind == .movie ? "title" : "name"] as? String) else { return nil }
        let date = json[kind == .movie ? "release_date" : "first_air_date"] as? String
        let minutes: Int? = kind == .movie
            ? json["runtime"] as? Int
            : (json["episode_run_time"] as? [Int])?.first
        let credits = json["credits"] as? [String: Any]
        let cast = ((credits?["cast"] as? [[String: Any]]) ?? []).prefix(20).compactMap { entry -> TMDBTitle.Person? in
            guard let name = entry["name"] as? String else { return nil }
            return TMDBTitle.Person(name: name, role: entry["character"] as? String,
                                    photoURL: image(entry["profile_path"], size: "w185"))
        }
        let directors: [String] = kind == .movie
            ? ((credits?["crew"] as? [[String: Any]]) ?? []).filter { $0["job"] as? String == "Director" }
                .compactMap { $0["name"] as? String }
            : ((json["created_by"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        return TMDBTitle(
            id: id, title: name,
            overview: (json["overview"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            year: date.flatMap { Int($0.prefix(4)) },
            runtime: minutes.flatMap { $0 > 0 ? TimeInterval($0 * 60) : nil },
            genres: ((json["genres"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String },
            posterURL: image(json["poster_path"], size: "w500"),
            backdropURL: image(json["backdrop_path"], size: "w1280"),
            cast: Array(cast), directors: directors)
    }

    private static func image(_ path: Any?, size: String) -> URL? {
        guard let path = path as? String, path.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}
