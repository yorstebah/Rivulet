// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CommunityMarkers.swift
//  Rivulet
//
//  Skip markers from the two community databases, for episodes whose server
//  has none: introdb.app (by the show's IMDb id) and TheIntroDB.org (by its
//  TMDB, TVDB or IMDb id). The server's own markers always win; introdb.app
//  fills the kinds the server lacks, then TheIntroDB.org the rest, as Infuse
//  does. Opt-in ("useIntroDB"): it sends the show's id, season and episode.
//

import Foundation
import os

/// The show's ids a community database looks an episode up by.
nonisolated struct CommunityShowIDs: Sendable, Equatable {
    var imdb: String?
    var tmdb: Int?
    var tvdb: Int?

    init(imdb: String? = nil, tmdb: Int? = nil, tvdb: Int? = nil) {
        self.imdb = imdb.flatMap { $0.hasPrefix("tt") ? $0 : nil }
        self.tmdb = tmdb
        self.tvdb = tvdb
    }

    /// From a provider's `externalIDs` ("imdb", "tmdb", "tvdb").
    init(externalIDs: [String: String]) {
        self.init(imdb: externalIDs["imdb"], tmdb: externalIDs["tmdb"].flatMap { Int($0) },
                  tvdb: externalIDs["tvdb"].flatMap { Int($0) })
    }

    var isEmpty: Bool { imdb == nil && tmdb == nil && tvdb == nil }
}

nonisolated enum CommunityMarkers {
    /// Both databases for one episode; `duration` closes credits that run to the end.
    typealias Lookup = @Sendable (CommunityShowIDs, Int, Int, TimeInterval?) async -> [PlexMarker]

    static let defaultsKey = "useIntroDB"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// Seconds a lookup may take before playback goes on without its markers:
    /// iPhone and Mac wait for markers before playing.
    static let budget: Double = 6

    /// The kinds a server's markers are checked against.
    static let kinds = ["intro", "recap", "credits"]

    static let live: Lookup = { ids, season, episode, duration in
        async let introDB: [PlexMarker] = {
            guard let imdb = ids.imdb else { return [] }
            return await IntroDBClient().markers(imdbID: imdb, season: season, episode: episode)
        }()
        async let theIntroDB = TheIntroDBClient().markers(ids, season: season, episode: episode, duration: duration)
        return merged(primary: await introDB, fallback: await theIntroDB)
    }

    /// `primary`'s markers, then `fallback`'s of the kinds `primary` lacks, by start.
    static func merged(primary: [PlexMarker], fallback: [PlexMarker]) -> [PlexMarker] {
        let present = Set(primary.compactMap(\.type))
        let extra = fallback.filter { marker in marker.type.map { !present.contains($0) } ?? false }
        return (primary + extra).sorted { ($0.startTimeOffset ?? 0) < ($1.startTimeOffset ?? 0) }
    }

    /// A server's markers plus the community ones of the kinds it lacks.
    static func filling(_ server: [PlaybackMarker], with community: [PlexMarker]) -> [PlaybackMarker] {
        let present = Set(server.map(\.kind.rawValue))
        let extra = PlexPlaybackMarkers.playbackMarkers(community).filter { !present.contains($0.kind.rawValue) }
        return (server + extra).sorted { $0.start < $1.start }
    }

    /// Whether a server's markers already cover every kind the databases know.
    static func isComplete(_ server: [PlaybackMarker]) -> Bool {
        Set(kinds).isSubset(of: Set(server.map(\.kind.rawValue)))
    }

    /// A provider episode's server markers, filled from the databases when the viewer opted in.
    /// Plex and Xtream fill their own (their ids come from elsewhere); this serves Jellyfin, Emby
    /// and any other provider whose episodes carry their show's external ids.
    static func extras(
        from provider: any MediaProvider, item: MediaItem, sourceID: String?,
        enabled: Bool = CommunityMarkers.isEnabled, lookup: @escaping Lookup = CommunityMarkers.live
    ) async -> PlaybackExtras {
        var extras = await provider.playbackExtras(for: item.ref, sourceID: sourceID)
        guard enabled, provider.kind != .plex, provider.kind != .xtream, item.kind == .episode,
              let show = item.grandparentRef, let season = item.seasonNumber, let episode = item.episodeNumber,
              episode > 0, !isComplete(extras.markers) else { return extras }
        let runtime = item.runtime
        let fetch = Task { () -> [PlexMarker] in
            let ids = CommunityShowIDs(externalIDs: (try? await provider.fullDetail(for: show))?.externalIDs ?? [:])
            guard !ids.isEmpty else { return [] }
            return await lookup(ids, season, episode, runtime)
        }
        let community = await value(of: fetch, within: budget) ?? []
        extras.markers = filling(extras.markers, with: community)
        return extras
    }

    /// The task's value, or nil once `seconds` have passed (the task runs on, unheard).
    static func value<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
        let answered = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let answer: @Sendable (T?) -> Void = { value in
                let first = answered.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            Task { answer(await task.value) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                answer(nil)
            }
        }
    }
}

/// TheIntroDB.org's markers for an episode. No key for reads; 30 requests per 10 s per client.
nonisolated struct TheIntroDBClient {
    private static let mediaURL = "https://api.theintrodb.org/v2/media"

    /// Synthetic ids, negative and clear of introdb.app's -900x and the providers' small ones.
    private static let syntheticIds: [String: Int] = [
        "intro": -9011, "recap": -9012, "credits": -9013, "preview": -9014,
    ]

    func markers(_ ids: CommunityShowIDs, season: Int, episode: Int, duration: TimeInterval?,
                 session: URLSession = .shared) async -> [PlexMarker] {
        guard var components = URLComponents(string: Self.mediaURL) else { return [] }
        // One id is enough; TMDB first, as the database keys on it.
        var query: [URLQueryItem]
        if let tmdb = ids.tmdb {
            query = [URLQueryItem(name: "tmdb_id", value: String(tmdb))]
        } else if let tvdb = ids.tvdb {
            query = [URLQueryItem(name: "tvdb_id", value: String(tvdb))]
        } else if let imdb = ids.imdb {
            query = [URLQueryItem(name: "imdb_id", value: imdb)]
        } else {
            return []
        }
        query += [URLQueryItem(name: "season", value: String(season)),
                  URLQueryItem(name: "episode", value: String(episode))]
        components.queryItems = query
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Self.decode(data, duration: duration)
    }

    /// The first segment of each kind. A segment without an end runs to the end of the episode,
    /// so it needs `duration`; without one it is dropped.
    static func decode(_ data: Data, duration: TimeInterval?) -> [PlexMarker] {
        struct Segment: Decodable {
            let start_ms: Int?
            let end_ms: Int?
        }
        struct Wire: Decodable {
            let intro: [Segment]?
            let recap: [Segment]?
            let credits: [Segment]?
            let preview: [Segment]?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return [] }
        let endOfFile = duration.flatMap { $0 > 0 ? Int($0 * 1000) : nil }

        func marker(_ segments: [Segment]?, _ type: String) -> PlexMarker? {
            guard let segment = segments?.first, let start = segment.start_ms, start >= 0,
                  let end = segment.end_ms ?? endOfFile, end > start, end < 10_000_000_000 else { return nil }
            return PlexMarker(id: syntheticIds[type], type: type, startTimeOffset: start, endTimeOffset: end)
        }
        return [
            marker(wire.recap, "recap"),
            marker(wire.intro, "intro"),
            marker(wire.credits, "credits"),
            marker(wire.preview, "preview"),
        ].compactMap { $0 }
    }
}
