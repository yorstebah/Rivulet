// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TraktScrobbler.swift
//  Rivulet
//
//  What the viewer watches, told to Trakt. Every player already reports to
//  its server through `PlaybackTimeline`; the same reports come here, and only
//  the changes reach Trakt: playing starts a scrobble, pausing or stopping
//  stops it with the progress. Trakt counts a stop past 80% as watched, and
//  saves anything less as a resume point.
//
//  Films go by their own ids. Episodes go by their own ids when the server
//  has them, else by the show's ids with season and number (an Xtream panel
//  has no episode ids). An item without any id is not sent.
//

import Foundation

/// The ids and numbers Trakt finds a film or episode by.
nonisolated struct TraktScrobbleItem: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case movie(ids: [String: String])
        case episode(ids: [String: String])
        case showEpisode(showIDs: [String: String], season: Int, number: Int)
    }

    let kind: Kind
    let title: String?
    let year: Int?

    /// The objects a scrobble sends.
    var body: [String: any Sendable] {
        switch kind {
        case .movie(let ids):
            var movie: [String: any Sendable] = ["ids": Self.wire(ids)]
            if let title { movie["title"] = title }
            if let year { movie["year"] = year }
            return ["movie": movie]
        case .episode(let ids):
            return ["episode": ["ids": Self.wire(ids)] as [String: any Sendable]]
        case .showEpisode(let showIDs, let season, let number):
            var show: [String: any Sendable] = ["ids": Self.wire(showIDs)]
            if let title { show["title"] = title }
            return ["show": show, "episode": ["season": season, "number": number] as [String: any Sendable]]
        }
    }

    /// Trakt's id keys: numbers for tmdb, tvdb and trakt, text for imdb.
    private static func wire(_ ids: [String: String]) -> [String: any Sendable] {
        var out: [String: any Sendable] = [:]
        for (key, value) in ids {
            switch key {
            case "imdb": if value.hasPrefix("tt") { out[key] = value }
            case "tmdb", "tvdb", "trakt": if let number = Int(value) { out[key] = number }
            default: break
            }
        }
        return out
    }

    /// The external ids Trakt can use from a server's set (any case: Emby mixes them).
    static func ids(_ raw: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in raw {
            let key = key.lowercased()
            guard ["imdb", "tmdb", "tvdb", "trakt"].contains(key), !value.isEmpty else { continue }
            out[key] = value
        }
        return out
    }

    /// The ids in a Plex item's guids ("imdb://tt…", "tmdb://…", "tvdb://…").
    static func ids(guids: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for guid in guids {
            if out["imdb"] == nil, let imdb = PlexMetadata.extractImdbId(from: guid) { out["imdb"] = imdb }
            if out["tmdb"] == nil, let tmdb = PlexMetadata.extractTmdbId(from: guid) { out["tmdb"] = String(tmdb) }
            if out["tvdb"] == nil, let tvdb = PlexMetadata.extractTvdbId(from: guid) { out["tvdb"] = String(tvdb) }
        }
        return out
    }

    /// The item for what is playing: a film or an episode, by its own ids, else (episodes) by
    /// the show's, which `showIDs` fetches only when needed. nil when nothing identifies it.
    static func make(for item: PlexMetadata, showIDs: @Sendable () async -> [String: String]) async -> TraktScrobbleItem? {
        let own = ids(guids: (item.Guid ?? []).compactMap(\.id) + [item.guid].compactMap { $0 })
        switch item.type {
        case "movie":
            guard !own.isEmpty else { return nil }
            return TraktScrobbleItem(kind: .movie(ids: own), title: item.title, year: item.year)
        case "episode":
            if !own.isEmpty { return TraktScrobbleItem(kind: .episode(ids: own), title: nil, year: nil) }
            guard let season = item.parentIndex, let number = item.index, number > 0 else { return nil }
            let show = ids(await showIDs())
            guard !show.isEmpty else { return nil }
            return TraktScrobbleItem(kind: .showEpisode(showIDs: show, season: season, number: number),
                                     title: item.grandparentTitle, year: nil)
        default:
            return nil
        }
    }
}

@MainActor
final class TraktScrobbler {
    static let shared = TraktScrobbler()

    private struct Session {
        let key: String
        var item: Task<TraktScrobbleItem?, Never>
        var started = false
        /// The last progress reported, for the stop sent when another item takes over.
        var progress: Double = 0
    }

    private var session: Session?
    /// Scrobbles go out in order: a stop must never reach Trakt ahead of its start.
    private var queue: Task<Void, Never>?
    private let client: TraktClient
    private let isSignedIn: @MainActor () -> Bool
    private let isOn: (MediaProviderKind) -> Bool

    init(client: TraktClient = .shared,
         isSignedIn: @escaping @MainActor () -> Bool = { TraktConfig.isConfigured && TraktAccount.shared.isSignedIn },
         isOn: @escaping (MediaProviderKind) -> Bool = { TraktScrobbleSettings.isOn($0) }) {
        self.client = client
        self.isSignedIn = isSignedIn
        self.isOn = isOn
    }

    /// One of a player's server reports. `server` is the item's server kind; `showIDs` gives the
    /// show's external ids for an episode with none of its own.
    func report(_ item: PlexMetadata, server: MediaProviderKind, state: PlaybackTimeline.State, at time: TimeInterval,
                showIDs: @escaping @Sendable () async -> [String: String] = { [:] }) {
        guard isSignedIn(), isOn(server), item.type == "movie" || item.type == "episode",
              let ms = item.duration, ms > 0, let ratingKey = item.ratingKey else { return }
        let progress = min(max(time / (Double(ms) / 1000) * 100, 0), 100)
        let key = "\(server.rawValue)|\(ratingKey)"
        if session?.key != key {
            // A new item: the last one stops where it was, if it was still running.
            if let old = session, old.started, old.progress >= 1 { enqueue(old.item, .stop, progress: old.progress) }
            let snapshot = item
            session = Session(key: key, item: Task { await TraktScrobbleItem.make(for: snapshot, showIDs: showIDs) })
        }
        guard var current = session else { return }
        current.progress = progress
        switch state {
        case .playing where !current.started:
            current.started = true
            enqueue(current.item, .start, progress: progress)
        case .paused, .stopped:
            if current.started {
                current.started = false
                // Under 1% Trakt refuses a stop (422); it is the same as never having started.
                if progress >= 1 { enqueue(current.item, .stop, progress: progress) }
            }
            if state == .stopped { session = nil; return }
        default:
            break
        }
        session = current
    }

    private func enqueue(_ item: Task<TraktScrobbleItem?, Never>, _ action: TraktClient.ScrobbleAction, progress: Double) {
        let previous = queue
        let client = client
        queue = Task {
            await previous?.value
            guard let resolved = await item.value else { return }
            await client.scrobble(action, body: resolved.body, progress: progress)
        }
    }

    /// Waits for every queued scrobble (tests).
    func drain() async { await queue?.value }
}

extension TraktScrobbler {
    /// A report from the iPhone, iPad or Mac player, which plays every server through a request.
    func report(_ request: PlexPlaybackRequest, state: PlaybackTimeline.State, at time: TimeInterval) {
        if let playback = request.providerPlayback {
            let provider = playback.provider
            let show = playback.item.grandparentRef
            report(request.item, server: provider.kind, state: state, at: time) {
                guard let show else { return [:] }
                return (try? await provider.fullDetail(for: show))?.externalIDs ?? [:]
            }
            return
        }
        let serverURL = request.serverURL, token = request.token, showKey = request.item.grandparentRatingKey
        report(request.item, server: .plex, state: state, at: time) {
            guard let showKey, !serverURL.isEmpty, let show = try? await PlexNetworkManager.shared.getMetadata(
                serverURL: serverURL, authToken: token, ratingKey: showKey, includeGuids: true) else { return [:] }
            return TraktScrobbleItem.ids(guids: (show.Guid ?? []).compactMap(\.id) + [show.guid].compactMap { $0 })
        }
    }
}
