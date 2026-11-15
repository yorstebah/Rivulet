// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  Posters for Xtream titles the panel lists without one, as panels do with what they added
//  last (the top of Recently Added). Asked per page, for the titles on it only, a few at a
//  time; a page waits a short while and what comes later is there on the next load. Each
//  title is asked once per session, found or not.

import Foundation

actor XtreamPosterFill {
    /// A title's poster, from wherever the provider finds one; nil when there is none.
    typealias Resolve = @Sendable (String) async -> URL?

    /// Seconds a page waits for its posters.
    static let budget: Double = 2.5
    /// Lookups at once: panels throttle bursts.
    static let concurrency = 6

    private var found: [String: URL] = [:]
    private var asked: Set<String> = []

    /// The posters known for `ids`, after asking for the ones not asked yet.
    func posters(for ids: [String], budget: Double = XtreamPosterFill.budget,
                 resolve: @escaping Resolve) async -> [String: URL] {
        var seen = Set<String>()
        let wanted = ids.filter { !asked.contains($0) && seen.insert($0).inserted }
        if !wanted.isEmpty {
            asked.formUnion(wanted)
            let batch = Task {
                await withTaskGroup(of: (String, URL?).self) { group in
                    var queue = wanted.makeIterator()
                    for _ in 0..<Self.concurrency {
                        guard let id = queue.next() else { break }
                        group.addTask { (id, await resolve(id)) }
                    }
                    while let (id, url) = await group.next() {
                        if let url { self.store(url, for: id) }
                        if let next = queue.next() { group.addTask { (next, await resolve(next)) } }
                    }
                }
            }
            _ = await CommunityMarkers.value(of: batch, within: budget)
        }
        return found.filter { ids.contains($0.key) }
    }

    private func store(_ url: URL, for id: String) {
        found[id] = url
    }
}
