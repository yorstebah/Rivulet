// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  How often an Xtream panel's film and series lists are fetched again: the viewer's choice,
//  one for every source, synced like the other preferences. Off keeps the lists until the
//  source page's Refresh Movies and TV Shows. Read by `XtreamVODCatalog.isFresh`.

import Foundation

nonisolated enum XtreamVODRefresh {
    static let defaultsKey = "xtreamVODRefreshHours"
    /// Hours; 0 is Off.
    static let choices = [6, 12, 24, 72, 168, 0]
    static let defaultHours = 24

    static var hours: Int {
        let saved = UserDefaults.standard.object(forKey: defaultsKey) as? Int
        return saved.flatMap { choices.contains($0) ? $0 : nil } ?? defaultHours
    }

    static func setHours(_ hours: Int) {
        UserDefaults.standard.set(hours, forKey: defaultsKey)
    }

    /// The next choice after `hours`, wrapping: a tvOS row cycles through them.
    static func next(after hours: Int) -> Int {
        let index = choices.firstIndex(of: hours) ?? choices.firstIndex(of: defaultHours) ?? 0
        return choices[(index + 1) % choices.count]
    }

    /// How long a list is used; nil when Off.
    static func lifetime(hours: Int = hours) -> TimeInterval? {
        hours > 0 ? TimeInterval(hours) * 3600 : nil
    }

    static func name(_ hours: Int) -> String {
        switch hours {
        case 0: String(localized: "Off")
        case 6: String(localized: "Every 6 Hours")
        case 12: String(localized: "Every 12 Hours")
        case 24: String(localized: "Daily")
        case 72: String(localized: "Every 3 Days")
        case 168: String(localized: "Weekly")
        default: String(localized: "Every \(hours) Hours")
        }
    }
}
