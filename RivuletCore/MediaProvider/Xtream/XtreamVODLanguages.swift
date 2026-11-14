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

    /// Countries whose copies speak a language. A country listed twice counts for the first
    /// language in `languageOfRegion`'s order only (`regions(ofLanguage:)`).
    private static let regionsByLanguage: [String: [String]] = [
        "nl": ["NL", "BE"], "en": ["GB", "US", "CA", "AU", "IE", "NZ"], "de": ["DE", "AT", "CH"],
        "fr": ["FR", "BE", "CA", "CH"], "es": ["ES", "MX"], "pt": ["PT", "BR"], "it": ["IT"],
        "sv": ["SE"], "da": ["DK"], "nb": ["NO"], "no": ["NO"], "fi": ["FI"], "el": ["GR"],
        "tr": ["TR"], "pl": ["PL"], "ar": ["AR"], "hi": ["IN"], "ja": ["JP"], "ko": ["KR"],
    ]

    /// Which language a country's copies are read as, where a country has several: Belgium is
    /// Dutch, Canada and Switzerland their first language above.
    private static let languageOfRegion: [String: String] = {
        var map: [String: String] = [:]
        for language in ["nl", "en", "de", "fr", "es", "pt", "it", "sv", "da", "nb", "fi", "el", "tr", "pl", "ar", "hi", "ja", "ko"] {
            for region in regionsByLanguage[language] ?? [] where map[region] == nil { map[region] = language }
        }
        return map
    }()

    // MARK: - Languages as the viewer picks them

    /// The language an origin belongs to, as Settings and the filter show it: "multi", "nl", "en",
    /// or the origin itself where it names no language of its own (a region group, "EXYU").
    static func language(of origin: String) -> String {
        if origin == "MULTI" { return "multi" }
        return languageOfRegion[origin] ?? origin
    }

    /// A language's name: "Multi", "Dutch", "English", else the origin's own name.
    static func name(ofLanguage language: String) -> String {
        if language == "multi" { return String(localized: "Multi") }
        if language.count == 2, language == language.lowercased(),
           let name = Locale.current.localizedString(forLanguageCode: language) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        let title = ContentOrigin.title(forOrigin: language), marker = ContentOrigin.marker(forOrigin: language)
        return title.hasPrefix(marker + " ") ? String(title.dropFirst(marker.count + 1)) : title
    }

    /// Every origin a language covers: its countries, and those `available` lists for it.
    static func origins(ofLanguage language: String, available: [String] = []) -> [String] {
        if language == "multi" { return ["MULTI"] }
        let known = regionsByLanguage[language] != nil ? regions(ofLanguage: language) : [language]
        return known + available.filter { self.language(of: $0) == language && !known.contains($0) }
    }

    /// A language's own countries: those read as it. A country with several languages belongs to
    /// one (Belgium to Dutch), so no two languages share a country and ticking one never moves another.
    private static func regions(ofLanguage code: String) -> [String] {
        guard let regions = regionsByLanguage[code], let own = regions.first.map(language(of:)) else { return [] }
        return regions.filter { language(of: $0) == own }
    }

    /// The viewer ticked or unticked a language in Settings: its origins join at the end, or all leave.
    func toggling(_ language: String, available: [String] = []) -> XtreamVODLanguages {
        var next = self
        if languages.contains(language) {
            next.origins.removeAll { Self.language(of: $0) == language }
        } else {
            next.origins += Self.origins(ofLanguage: language, available: available).filter { !origins.contains($0) }
        }
        return next
    }

    /// Settings' rows: the chosen languages in order of preference (those the titles carry, or all
    /// of them while the lists load), then the rest by how many titles they hold.
    func order(available: [(origin: String, count: Int)]) -> [String] {
        let counts = Self.languageCounts(available).map(\.language)
        let carried = Set(counts), chosen = languages
        return chosen.filter { carried.contains($0) || available.isEmpty } + counts.filter { !chosen.contains($0) }
    }

    /// The languages these origins make, in their order: Multi, Dutch, English…
    var languages: [String] {
        var seen = Set<String>()
        return origins.map(Self.language(of:)).filter { seen.insert($0).inserted }
    }

    /// Only one language's copies, the preference within it kept ("Show: English").
    func focused(on language: String, available: [String] = []) -> XtreamVODLanguages {
        let covered = Set(Self.origins(ofLanguage: language, available: available))
        let kept = origins.filter(covered.contains)
        return XtreamVODLanguages(origins: kept.isEmpty ? Self.origins(ofLanguage: language, available: available) : kept)
    }

    /// The languages these origins carry, with their titles, most first.
    static func languageCounts(_ available: [(origin: String, count: Int)]) -> [(language: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in available { counts[language(of: entry.origin), default: 0] += entry.count }
        return counts.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }

    /// MULTI first, then the device's languages in its order, then English for everyone:
    /// a Dutch device reads MULTI, NL, BE, GB, US…
    static func defaults(preferredLanguages: [String] = Locale.preferredLanguages) -> XtreamVODLanguages {
        var origins = ["MULTI"]
        let codes = preferredLanguages.map { String($0.split(separator: "-").first ?? "").lowercased() } + ["en"]
        for code in codes where !code.isEmpty {
            let regions = regionsByLanguage[code] != nil ? regions(ofLanguage: code) : [code.uppercased()]
            for region in regions where !origins.contains(region) { origins.append(region) }
        }
        return XtreamVODLanguages(origins: origins)
    }

    var showsEverything: Bool { origins.isEmpty }

    /// "Multi, Dutch, English", or All Languages: a Settings row's value.
    var summary: String {
        guard !origins.isEmpty else { return String(localized: "All Languages") }
        let names = languages.map(Self.name(ofLanguage:))
        return names.prefix(3).joined(separator: ", ") + (names.count > 3 ? "…" : "")
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
