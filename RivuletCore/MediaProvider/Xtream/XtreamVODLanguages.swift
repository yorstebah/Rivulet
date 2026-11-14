// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamVODLanguages.swift
//  Rivulet
//
//  Which of a panel's language copies the viewer sees. A large panel lists a
//  film once per language ("┃FR┃", "┃TR┃", "┃NL┃", "MULTI"), each with its
//  own poster, so its newest titles are mostly copies the viewer would never
//  pick. The viewer keeps a few languages in order of preference: every title
//  then shows once, in the first of them it has (MULTI, the original audio
//  with several subtitles, first by default). A title with no language tag
//  always shows.
//

import Foundation

nonisolated struct XtreamVODLanguages: Sendable, Hashable, Codable {
    /// `ContentOrigin.origin` keys ("MULTI", "NL", "GB", "US"), best first. Empty shows every
    /// copy of every title, as the panel lists them.
    var origins: [String]

    static let everything = XtreamVODLanguages(origins: [])

    /// Countries whose copies speak a language, for the defaults. Belgium is Dutch and French.
    private static let regionsByLanguage: [String: [String]] = [
        "nl": ["NL", "BE"], "en": ["GB", "US", "CA", "AU", "IE", "NZ"], "de": ["DE", "AT", "CH"],
        "fr": ["FR", "BE", "CA", "CH"], "es": ["ES", "MX"], "pt": ["PT", "BR"], "it": ["IT"],
        "sv": ["SE"], "da": ["DK"], "nb": ["NO"], "no": ["NO"], "fi": ["FI"], "el": ["GR"],
        "tr": ["TR"], "pl": ["PL"], "ar": ["AR"], "hi": ["IN"], "ja": ["JP"], "ko": ["KR"],
    ]

    /// MULTI first, then the device's languages in its order, then English for everyone:
    /// a Dutch device reads MULTI, NL, BE, GB, US…
    static func defaults(preferredLanguages: [String] = Locale.preferredLanguages) -> XtreamVODLanguages {
        var origins = ["MULTI"]
        let codes = preferredLanguages.map { String($0.split(separator: "-").first ?? "").lowercased() } + ["en"]
        for code in codes where !code.isEmpty {
            let regions = regionsByLanguage[code] ?? [code.uppercased()]
            for region in regions where !origins.contains(region) { origins.append(region) }
        }
        return XtreamVODLanguages(origins: origins)
    }

    var showsEverything: Bool { origins.isEmpty }

    /// "Multilingual, Netherlands, Belgium…", or All Languages: a Settings row's value.
    var summary: String {
        guard !origins.isEmpty else { return String(localized: "All Languages") }
        let names = origins.prefix(3).map { origin in
            let title = ContentOrigin.title(forOrigin: origin), marker = ContentOrigin.marker(forOrigin: origin)
            return title.hasPrefix(marker + " ") ? String(title.dropFirst(marker.count + 1)) : title
        }
        return names.joined(separator: ", ") + (origins.count > 3 ? "…" : "")
    }

    /// Whether a copy in this origin shows. Untagged copies, and tags that name no place, always do.
    func allows(_ origin: String?) -> Bool {
        guard !origins.isEmpty, let origin else { return true }
        return origins.contains(origin)
    }

    /// Lower is preferred; a copy without a known origin comes after the viewer's languages.
    func rank(_ origin: String?) -> Int {
        origin.flatMap { origins.firstIndex(of: $0) } ?? origins.count
    }

    /// The positions of the copies that show, in the list's order: those in the viewer's
    /// languages, one per title (folded name and year), the best-ranked copy of each.
    func shown(_ titles: [(name: String, year: Int?, tag: String?)]) -> [Int] {
        guard !origins.isEmpty else { return Array(titles.indices) }
        var originOfTag: [String: String?] = [:]
        var best: [String: (index: Int, rank: Int)] = [:]
        for (index, title) in titles.enumerated() {
            var origin: String?
            if let tag = title.tag {
                if let known = originOfTag[tag] { origin = known } else {
                    origin = ContentOrigin.origin(forTag: tag)
                    originOfTag[tag] = origin
                }
            }
            guard allows(origin) else { continue }
            let key = "\(LiveChannelSearch.normalized(title.name))|\(title.year.map(String.init) ?? "")"
            let rank = rank(origin)
            if let current = best[key], current.rank <= rank { continue }
            best[key] = (index, rank)
        }
        return best.values.map(\.index).sorted()
    }

    /// The origins a panel's titles carry, most common first, for the Settings list.
    static func available(_ tags: [String?]) -> [(origin: String, count: Int)] {
        var counts: [String: Int] = [:]
        var originOfTag: [String: String?] = [:]
        for tag in tags {
            guard let tag else { continue }
            let origin: String?
            if let known = originOfTag[tag] { origin = known } else {
                origin = ContentOrigin.origin(forTag: tag)
                originOfTag[tag] = origin
            }
            if let origin { counts[origin, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }
}
