// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamVODSources.swift
//  Rivulet
//
//  Which Xtream Live TV sources offer their films and series: all of them,
//  unless switched off on the source's page. One provider per source, kept
//  while its login is unchanged so its lists stay in memory.
//

import Foundation

@MainActor
enum XtreamVODSources {
    /// Source ids whose films and series are switched off. Stored as the exceptions, so a new source is on.
    static let disabledKey = "xtreamVODDisabledSources"

    /// Told when a switch changes; the app repopulates the registry and reloads its servers.
    static var onChanged: (() -> Void)?

    static func isEnabled(_ sourceID: String, defaults: UserDefaults = .standard) -> Bool {
        !(defaults.stringArray(forKey: disabledKey) ?? []).contains(sourceID)
    }

    static func setEnabled(_ enabled: Bool, for sourceID: String, defaults: UserDefaults = .standard) {
        var disabled = Set(defaults.stringArray(forKey: disabledKey) ?? [])
        if enabled { disabled.remove(sourceID) } else { disabled.insert(sourceID) }
        defaults.set(disabled.sorted(), forKey: disabledKey)
        onChanged?()
    }

    // MARK: - Languages

    /// The viewer's film and series languages (`XtreamVODLanguages`), for every Xtream source: a
    /// playback choice, as Audio Language is. Unset keeps the defaults, which follow the device's
    /// languages. Synced.
    static let languagesKey = "xtreamVODContentLanguages"
    /// One language every listing is narrowed to from a library ("Show: English"); Home,
    /// libraries, collections, search and For You follow until it is cleared. Synced.
    static let languageFocusKey = "xtreamVODLanguageChoice"
    /// The first build kept languages per source; the first source's carry over.
    private static let legacyLanguagesKey = "xtreamVODLanguages"

    static func languages(defaults: UserDefaults = .standard) -> XtreamVODLanguages {
        if let saved = defaults.stringArray(forKey: languagesKey) { return XtreamVODLanguages(origins: saved) }
        if let legacy = (defaults.dictionary(forKey: legacyLanguagesKey) as? [String: [String]])?
            .sorted(by: { $0.key < $1.key }).first?.value {
            return XtreamVODLanguages(origins: legacy)
        }
        return .defaults()
    }

    static func setLanguages(_ languages: XtreamVODLanguages, defaults: UserDefaults = .standard) {
        defaults.set(languages.origins, forKey: languagesKey)
        defaults.removeObject(forKey: legacyLanguagesKey)
        // "Show: French" ends when French is no longer one of the viewer's languages (All Languages keeps it).
        if let focus = languageFocus(defaults: defaults), !languages.showsEverything, !languages.languages.contains(focus) {
            defaults.removeObject(forKey: languageFocusKey)
        }
        changed()
    }

    static func languageFocus(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: languageFocusKey)
    }

    static func setLanguageFocus(_ language: String?, defaults: UserDefaults = .standard) {
        defaults.set(language, forKey: languageFocusKey)
        changed()
    }

    /// What the listings show: the viewer's languages, narrowed to the chosen one when there is one.
    static func shownLanguages() -> XtreamVODLanguages {
        let languages = self.languages()
        // A choice another device left behind for a language this viewer no longer keeps is not followed.
        guard let focus = languageFocus(), languages.showsEverything || languages.languages.contains(focus) else { return languages }
        return languages.focused(on: focus, available: allAvailableOrigins.map(\.origin))
    }

    /// Posted when the languages or the chosen one change, for screens that list titles.
    static let languagesChanged = Notification.Name("XtreamVODSources.languagesChanged")

    private static func changed() {
        onChanged?()
        NotificationCenter.default.post(name: languagesChanged, object: nil)
    }

    /// The languages each source's titles carry, most common first, once its lists have loaded:
    /// what Settings offers. In memory only.
    static var availableOrigins: [String: [(origin: String, count: Int)]] = [:]

    /// Every source's languages together.
    static var allAvailableOrigins: [(origin: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in availableOrigins.values.joined() { counts[entry.origin, default: 0] += entry.count }
        return counts.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }

    /// Whether any Xtream source shows films and series: only then do the language settings show.
    static func offersLanguages(store: LiveTVDataStore? = nil) -> Bool {
        (store ?? .shared).xtreamSources.contains { isEnabled($0.id) }
    }

    /// Loads each source's lists once, for the languages Settings offers.
    static func loadAvailableOrigins() async {
        for provider in providers() where availableOrigins[provider.id] == nil {
            _ = try? await provider.libraries()
        }
    }

    private static var built: [String: (account: XtreamAccount, name: String, provider: XtreamVODProvider)] = [:]

    /// A provider for each switched-on Xtream source in Live TV.
    static func providers(store: LiveTVDataStore? = nil) -> [XtreamVODProvider] {
        let sources = (store ?? .shared).xtreamSources.filter { isEnabled($0.id) }
        var next: [String: (account: XtreamAccount, name: String, provider: XtreamVODProvider)] = [:]
        for source in sources {
            if let kept = built[source.id], kept.account == source.account, kept.name == source.name {
                next[source.id] = kept
            } else {
                next[source.id] = (source.account, source.name,
                                   XtreamVODProvider(sourceID: source.id, displayName: source.name, account: source.account))
            }
        }
        built = next
        return sources.compactMap { next[$0.id]?.provider }
    }
}
