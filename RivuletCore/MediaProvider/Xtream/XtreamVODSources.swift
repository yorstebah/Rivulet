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

    /// Each source's languages (`XtreamVODLanguages`), by source id. A source not listed keeps the
    /// defaults, which follow the device's languages. Synced: a source has one id everywhere.
    static let languagesKey = "xtreamVODLanguages"

    static func languages(for sourceID: String, defaults: UserDefaults = .standard) -> XtreamVODLanguages {
        let saved = defaults.dictionary(forKey: languagesKey) as? [String: [String]]
        return saved?[sourceID].map(XtreamVODLanguages.init(origins:)) ?? .defaults()
    }

    static func setLanguages(_ languages: XtreamVODLanguages, for sourceID: String, defaults: UserDefaults = .standard) {
        var saved = defaults.dictionary(forKey: languagesKey) as? [String: [String]] ?? [:]
        saved[sourceID] = languages.origins
        defaults.set(saved, forKey: languagesKey)
        onChanged?()
    }

    /// The languages a source's titles carry, most common first, once its lists have loaded:
    /// what Settings offers. In memory only.
    static var availableOrigins: [String: [(origin: String, count: Int)]] = [:]

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
