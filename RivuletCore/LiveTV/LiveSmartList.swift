// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveSmartList.swift
//  Rivulet
//
//  A channel list that fills itself from rules, as a smart playlist does:
//  channels from a country or in a language, of a genre, from a source, or
//  with a word in their name. Rules of one kind widen the list (Netherlands
//  or Belgium); rules of different kinds narrow it (Netherlands and Sports).
//  The list follows the lineup, so new channels join it on their own.
//
//  A channel's country is the tag its category carries ("┃NL┃ Sports"), else
//  one on its own name. Its genre is read from its category, then its name,
//  then what its guide mostly airs; what it airs right now does not count,
//  so a list holds still between programmes.
//

import Foundation

struct LiveSmartRules: Codable, Hashable {
    /// `ContentOrigin.origin` keys.
    var origins: [String] = []
    /// `LiveGenre` raw values.
    var genres: [String] = []
    var sourceIds: [String] = []
    /// Words a channel's name must hold, folded as search folds them.
    var words: [String] = []

    enum Rule: Hashable {
        case origin(String)
        case genre(LiveGenre)
        case source(String)
        case word(String)
    }

    init(_ rules: [Rule] = []) {
        for rule in rules { add(rule) }
    }

    var rules: [Rule] {
        origins.map(Rule.origin) + genres.compactMap { LiveGenre(rawValue: $0).map(Rule.genre) }
            + sourceIds.map(Rule.source) + words.map(Rule.word)
    }

    var isEmpty: Bool { rules.isEmpty }

    func contains(_ rule: Rule) -> Bool { rules.contains(rule) }

    mutating func add(_ rule: Rule) {
        guard !contains(rule) else { return }
        switch rule {
        case .origin(let key): origins.append(key)
        case .genre(let genre): genres.append(genre.rawValue)
        case .source(let id): sourceIds.append(id)
        case .word(let word):
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !words.contains(trimmed) { words.append(trimmed) }
        }
    }

    mutating func remove(_ rule: Rule) {
        switch rule {
        case .origin(let key): origins.removeAll { $0 == key }
        case .genre(let genre): genres.removeAll { $0 == genre.rawValue }
        case .source(let id): sourceIds.removeAll { $0 == id }
        case .word(let word): words.removeAll { $0 == word }
        }
    }

    /// The channels that match, in lineup order. No rules match nothing.
    func channels(in lineup: [UnifiedChannel], epg: [String: [UnifiedProgram]] = [:]) -> [UnifiedChannel] {
        indices(in: lineup, epg: epg).map { lineup[$0] }
    }

    /// The positions in `lineup` that match. Kept until the lineup or guide changes: the List
    /// layout and the guide ask on every refresh, and a large lineup takes a moment to match.
    func indices(in lineup: [UnifiedChannel], epg: [String: [UnifiedProgram]] = [:]) -> [Int] {
        guard !isEmpty else { return [] }
        let key = MatchKey(rules: self, count: lineup.count, first: lineup.first?.id, last: lineup.last?.id,
                           guide: genres.isEmpty ? 0 : epg.count)
        if let known = Self.matches[key] { return known }
        let found = match(lineup, epg: epg)
        if Self.matches.count > 64 { Self.matches.removeAll() }
        Self.matches[key] = found
        return found
    }

    private struct MatchKey: Hashable {
        let rules: LiveSmartRules
        let count: Int
        let first: String?
        let last: String?
        let guide: Int
    }
    private static var matches: [MatchKey: [Int]] = [:]

    private func match(_ lineup: [UnifiedChannel], epg: [String: [UnifiedProgram]]) -> [Int] {
        let origins = Set(origins), genres = Set(genres.compactMap(LiveGenre.init(rawValue:)))
        let sources = Set(sourceIds), words = words.map(LiveChannelSearch.normalized)
        // Per category rather than per channel: a lineup has thousands of channels in a few hundred groups.
        var originByGroup: [String: String?] = [:]
        var genreByGroup: [String: LiveGenre?] = [:]
        return lineup.indices.filter { index in
            let channel = lineup[index]
            if !sources.isEmpty, !sources.contains(channel.sourceId) { return false }
            let group = channel.groupTitle ?? ""
            if !origins.isEmpty {
                let fromGroup: String?
                if let known = originByGroup[group] { fromGroup = known } else {
                    fromGroup = ContentOrigin.origin(forTags: XtreamService.splitTags(group).tags)
                    originByGroup[group] = fromGroup
                }
                let origin = fromGroup ?? ContentOrigin.origin(forTags: XtreamService.splitTags(channel.name).tags)
                guard let origin, origins.contains(origin) else { return false }
            }
            if !genres.isEmpty {
                let fromGroup: LiveGenre?
                if let known = genreByGroup[group] { fromGroup = known } else {
                    fromGroup = LiveGenre.from(XtreamService.splitTags(group).name)
                    genreByGroup[group] = fromGroup
                }
                guard let genre = fromGroup ?? Self.genre(of: channel, epg: epg), genres.contains(genre) else { return false }
            }
            if !words.isEmpty {
                let name = LiveChannelSearch.normalized(channel.name)
                guard words.contains(where: name.contains) else { return false }
            }
            return true
        }
    }

    /// The genre a channel's name says, else what most of its next programmes are.
    private static func genre(of channel: UnifiedChannel, epg: [String: [UnifiedProgram]]) -> LiveGenre? {
        if let genre = LiveGenre.from(channel.name) { return genre }
        var counts: [LiveGenre: Int] = [:]
        for program in (epg[channel.id] ?? []).prefix(12) {
            if let genre = LiveGenre.from(program.category) { counts[genre, default: 0] += 1 }
        }
        guard let best = counts.values.max() else { return nil }
        return LiveGenre.allCases.first { counts[$0] == best }
    }

    // MARK: - Choices

    /// The countries and languages found in a lineup, by name.
    static func origins(in lineup: [UnifiedChannel]) -> [String] {
        var groups = Set<String>(), found = Set<String>()
        for channel in lineup {
            let group = channel.groupTitle ?? ""
            if groups.insert(group).inserted,
               let origin = ContentOrigin.origin(forTags: XtreamService.splitTags(group).tags) {
                found.insert(origin)
            }
        }
        let symbols: Set<String> = ["MULTI", "INT", "WORLD", "ASIA", "AFRICA"]
        // By name, the flag aside: "Arabic" among the A's.
        func name(_ key: String) -> String {
            let title = ContentOrigin.title(forOrigin: key), marker = ContentOrigin.marker(forOrigin: key)
            return title.hasPrefix(marker + " ") ? String(title.dropFirst(marker.count + 1)) : title
        }
        let places = found.subtracting(symbols).sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        return places + found.intersection(symbols).sorted()
    }

    /// A rule as a menu row or a list's name.
    static func title(of rule: Rule, sourceNames: [String: String] = [:]) -> String {
        switch rule {
        case .origin(let key): return ContentOrigin.title(forOrigin: key)
        case .genre(let genre): return genre.title
        case .source(let id): return sourceNames[id] ?? id
        case .word(let word): return String(localized: "Name Contains \u{201C}\(word)\u{201D}")
        }
    }

    /// A name for a new list from its first rule: "🇳🇱 Netherlands", "Sports", "BBC".
    static func suggestedName(for rule: Rule, sourceNames: [String: String] = [:]) -> String {
        if case .word(let word) = rule { return word }
        return title(of: rule, sourceNames: sourceNames)
    }
}
