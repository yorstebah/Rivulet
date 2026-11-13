// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamWatchProgress.swift
//  Rivulet
//
//  Where the viewer is in Xtream films and episodes. An Xtream panel keeps no
//  watch state, so Rivulet keeps it on this device: a position and a watched
//  flag per title, judged by `WatchProgressPolicy` like every other server's.
//

import Foundation
import Combine

/// One title's place.
struct XtreamWatchRecord: Codable, Equatable, Sendable {
    var position: TimeInterval
    var duration: TimeInterval?
    var watched: Bool
    var updatedAt: Date
}

@MainActor
final class XtreamWatchProgressStore: ObservableObject {
    static let shared = XtreamWatchProgressStore()

    /// Keyed by `key(source:kind:id:)`.
    @Published private(set) var records: [String: XtreamWatchRecord] = [:]

    private let defaults: UserDefaults
    static let defaultsKey = "xtreamWatchProgress"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: XtreamWatchRecord].self, from: data) {
            records = saved
        }
    }

    enum Kind: String, Sendable { case movie, episode }

    /// A title on one source: ids are only unique within a panel.
    nonisolated static func key(source: String, kind: Kind, id: String) -> String {
        "\(source)|\(kind.rawValue)|\(id)"
    }

    func record(_ key: String) -> XtreamWatchRecord? { records[key] }

    /// The player's position. Passing the completion point marks the title
    /// watched and clears its place, as a server does at its played threshold.
    func update(_ key: String, position: TimeInterval, duration: TimeInterval?, now: Date = Date()) {
        let fraction = WatchProgressPolicy.progress(offsetSeconds: position, runtimeSeconds: duration)
        if let fraction, fraction >= WatchProgressPolicy.completionThreshold {
            records[key] = XtreamWatchRecord(position: 0, duration: duration, watched: true, updatedAt: now)
        } else {
            let watched = records[key]?.watched ?? false
            records[key] = XtreamWatchRecord(position: max(position, 0), duration: duration, watched: watched, updatedAt: now)
        }
        save()
    }

    func markWatched(_ key: String, now: Date = Date()) {
        records[key] = XtreamWatchRecord(position: 0, duration: records[key]?.duration, watched: true, updatedAt: now)
        save()
    }

    func markUnwatched(_ key: String) {
        records[key] = nil
        save()
    }

    /// Titles with a resume point, last watched first: the Continue Watching row.
    func inProgress(limit: Int = 30) -> [String] {
        records
            .filter { Self.hasResumePoint($0.value) }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(limit)
            .map(\.key)
    }

    /// By `WatchProgressPolicy` when the length is known. Panels often leave it out, and the
    /// policy then answers no, so an unwatched title a minute or more in counts instead.
    static func hasResumePoint(_ record: XtreamWatchRecord) -> Bool {
        if let duration = record.duration, duration > 0 {
            return WatchProgressPolicy.hasResumePoint(offsetSeconds: record.position, runtimeSeconds: duration)
        }
        return !record.watched && record.position >= 60
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
