// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamForYou.swift
//  Rivulet
//
//  The For You row of an Xtream source's Movies and TV Shows, as a panel has no
//  recommendations of its own. It starts from the titles the viewer cares
//  about here (favorites, and what they watched or began, newest first). With
//  their TMDB key, TMDB's "people who liked this also liked" for those titles,
//  kept to what the panel carries, comes first; the rest are unwatched titles
//  from the categories the viewer watches most, better rated and newer first.
//  Worked out on the device.
//

import Foundation

enum XtreamForYou {
    /// A title the row starts from: the panel's id and how much it says about the viewer.
    struct Seed: Equatable {
        let id: String
        let weight: Double
    }

    /// A title the row may offer, as the catalogue lists it.
    struct Candidate: Equatable {
        let id: String
        let name: String
        let year: Int?
        let categoryId: String?
        let rating: Double?
        let addedAt: Date?
    }

    /// How many titles the row holds, and the fewest worth a row.
    static let rowSize = 24
    static let minimumRow = 4
    /// How many titles TMDB is asked about.
    static let tmdbSeedLimit = 6

    // MARK: - Seeds

    /// The library's titles the viewer cares about, strongest first: a favorite counts most, a
    /// title watched to the end next, one begun least, and each fades over two months unused.
    static func seeds(_ state: XtreamVODMapping.State, source: String, library: XtreamVODLibrary,
                      now: Date = Date(), limit: Int = 10) -> [Seed] {
        var weights: [String: Double] = [:]
        func add(_ id: String, _ weight: Double, at date: Date?) {
            let ageDays = date.map { max(now.timeIntervalSince($0), 0) / 86_400 } ?? 0
            weights[id, default: 0] += weight * pow(0.5, ageDays / 60)
        }
        for (key, record) in state.records {
            switch XtreamVODMapping.id(fromKey: key, source: source) {
            case .movie(let id) where library == .movies:
                guard record.watched || record.position >= 60 else { continue }
                add(id, record.watched ? 1 : 0.6, at: record.updatedAt)
            case .episode(let seriesID, _) where library == .series:
                guard record.watched || record.position >= 60 else { continue }
                add(seriesID, record.watched ? 0.5 : 0.3, at: record.updatedAt)
            default:
                continue
            }
        }
        for key in state.favorites {
            switch XtreamVODMapping.id(fromKey: key, source: source) {
            case .movie(let id) where library == .movies: add(id, 1.5, at: nil)
            case .series(let id) where library == .series: add(id, 1.5, at: nil)
            default: continue
            }
        }
        return weights.map { Seed(id: $0.key, weight: $0.value) }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.id < $1.id }
            .prefix(limit).map { $0 }
    }

    /// Titles not to offer: those already watched or begun, and the favorites.
    static func seen(_ state: XtreamVODMapping.State, source: String, library: XtreamVODLibrary) -> Set<String> {
        var ids = Set<String>()
        for key in state.records.keys {
            switch XtreamVODMapping.id(fromKey: key, source: source) {
            case .movie(let id) where library == .movies: ids.insert(id)
            case .episode(let seriesID, _) where library == .series: ids.insert(seriesID)
            default: continue
            }
        }
        for key in state.favorites {
            switch XtreamVODMapping.id(fromKey: key, source: source) {
            case .movie(let id) where library == .movies: ids.insert(id)
            case .series(let id) where library == .series: ids.insert(id)
            default: continue
            }
        }
        return ids
    }

    // MARK: - TMDB

    /// The catalogue by folded name with and without the year, so a recommendation finds the
    /// panel's copy. The first title with a name wins.
    struct Index {
        fileprivate var byNameYear: [String: String] = [:]
        fileprivate var byName: [String: (id: String, year: Int?)] = [:]

        init(_ candidates: [Candidate]) {
            for candidate in candidates {
                let name = LiveChannelSearch.normalized(candidate.name)
                guard !name.isEmpty else { continue }
                if let year = candidate.year, byNameYear["\(name)|\(year)"] == nil {
                    byNameYear["\(name)|\(year)"] = candidate.id
                }
                if byName[name] == nil { byName[name] = (candidate.id, candidate.year) }
            }
        }

        /// The panel's title for a recommendation: by title or original title, with the year
        /// (a year apart allowed: release dates differ by country). A panel title without a
        /// year matches by name; one with another year is another film (a remake).
        func match(_ recommendation: TMDBRecommendation) -> String? {
            let names = [recommendation.title, recommendation.originalTitle].compactMap { $0 }
                .map(LiveChannelSearch.normalized).filter { !$0.isEmpty }
            for name in names {
                if let year = recommendation.year,
                   let id = byNameYear["\(name)|\(year)"] ?? byNameYear["\(name)|\(year - 1)"]
                    ?? byNameYear["\(name)|\(year + 1)"] {
                    return id
                }
                guard let entry = byName[name] else { continue }
                if let theirs = entry.year, let ours = recommendation.year, abs(theirs - ours) > 1 { continue }
                return entry.id
            }
            return nil
        }
    }

    /// Recommendations after each seed, ranked by how many seeds lead to a title, weighted by
    /// the seed and the place in its list; kept to the panel's titles the viewer has not seen.
    static func tmdbPicks(_ lists: [(seedWeight: Double, recommendations: [TMDBRecommendation])],
                          index: Index, seen: Set<String>) -> [String] {
        var scores: [String: Double] = [:]
        var firstSeen: [String: Int] = [:]
        var order = 0
        for list in lists {
            for (place, recommendation) in list.recommendations.enumerated() {
                guard let id = index.match(recommendation), !seen.contains(id) else { continue }
                scores[id, default: 0] += list.seedWeight * (1 - Double(place) / 40)
                if firstSeen[id] == nil { firstSeen[id] = order; order += 1 }
            }
        }
        return scores.keys.sorted {
            scores[$0] != scores[$1] ? scores[$0]! > scores[$1]! : firstSeen[$0]! < firstSeen[$1]!
        }
    }

    // MARK: - The viewer's categories

    /// Unseen titles from the seeds' categories, by how much those categories weigh, then by
    /// rating and how new the title is on the panel.
    static func categoryPicks(_ candidates: [Candidate], seeds: [Seed], seen: Set<String>,
                              now: Date = Date(), limit: Int = rowSize) -> [String] {
        let byId = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var categoryWeight: [String: Double] = [:]
        for seed in seeds {
            guard let category = byId[seed.id]?.categoryId else { continue }
            categoryWeight[category, default: 0] += seed.weight
        }
        guard let strongest = categoryWeight.values.max(), strongest > 0 else { return [] }
        func score(_ candidate: Candidate) -> Double {
            let category = (candidate.categoryId.flatMap { categoryWeight[$0] } ?? 0) / strongest
            let rating = min(max(candidate.rating ?? 5, 0), 10) / 10
            let ageDays = candidate.addedAt.map { max(now.timeIntervalSince($0), 0) / 86_400 } ?? 365
            let newness = pow(0.5, ageDays / 90)
            // Quality outweighs freshness: newness only breaks near-ties in rating.
            return category * 3 + rating + newness * 0.25
        }
        var scored: [(id: String, score: Double)] = []
        for candidate in candidates where !seen.contains(candidate.id) {
            guard let category = candidate.categoryId, categoryWeight[category] != nil else { continue }
            scored.append((candidate.id, score(candidate)))
        }
        scored.sort { lhs, rhs in lhs.score != rhs.score ? lhs.score > rhs.score : lhs.id < rhs.id }
        return scored.prefix(limit).map { $0.id }
    }

    /// TMDB's picks first, then the viewer's categories, without repeats, `rowSize` at most.
    static func merge(_ tmdb: [String], _ categories: [String]) -> [String] {
        var seen = Set<String>()
        return (tmdb + categories).filter { seen.insert($0).inserted }.prefix(rowSize).map { $0 }
    }
}
