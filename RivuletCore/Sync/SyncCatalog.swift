// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Which `UserDefaults` keys iCloud carries. An explicit list: a new key does not sync by accident.
nonisolated enum SyncCatalog {
    /// Device-local: this device's switch, and what the mirror last agreed with the cloud.
    static let enabledKey = "iCloudSyncEnabled"
    static let stateKey = "iCloudSyncState"
    static let accountStateKey = "iCloudAccountState"
    static let accountPrintKey = "iCloudAccountPrint"
    static let heldKey = "iCloudSyncHeld"

    static let exactKeys: Set<String> = [
        // Home and Library
        "showHomeHero", "homeHeroContent", "showLibraryHero", "showLibraryRecentRows",
        "showLibraryRecommendations", "enablePersonalizedRecommendations", "showDiscoverTab", "showWatchlistTab", "showFavoritesTab",
        // Playback
        "autoplayLimit", "autoplayCountdown", "atTheCredits", "promptResumeOrRestart",
        "continueWatchingInstantResume", "skipPreviewCarousel", "useIntroDB", "cinemaTrailersCount",
        "detailRatingSource", "generatedSubtitlesFallback", "playerShowsClockTimes",
        "showSkipIntro", "showSkipRecap", "showSkipAds",
        "autoSkipIntro", "autoSkipRecap", "autoSkipAds",
        SkipLengthKeys.forward, SkipLengthKeys.back,
        // Content filter (not its list source URL, which can embed access)
        "contentFilter.enabled", "contentFilter.profanityStrength", "contentFilter.customWords",
        // Live TV (not recents or event slots: device habit). Viewings are what For You learns
        // from, so it suggests the same on every device.
        "liveTVLayout", "liveTVKeepPlayingInGuide", "combineLiveTVSources", "confirmExitMultiview",
        "liveTVSuggestions", "liveTVFavoriteChannelIds", "liveTVUnfavoritedChannelIds",
        "liveTVHiddenPlexServers", "liveTVHideJellyfin", "liveTVHideEmby",
        // The viewer's own and smart channel lists, and pinned categories
        channelListsKey, "liveTVPinnedCategories", viewingsKey,
        // Xtream films and series: where the viewer is, and their favorites (the panel keeps neither)
        watchProgressKey, "xtreamFavorites", "xtreamVODContentLanguages", "xtreamVODLanguageChoice",
        // Which servers tell Trakt what the viewer watches (the sign-in itself rides the vault)
        "traktScrobble_plex", "traktScrobble_jellyfin", "traktScrobble_emby", "traktScrobble_xtream",
        // Servers the user turned off, by machine id
        "plexDisabledServers",
        // Photos
        "photoSlideInterval", "photoSlideTransition", "photoSlidePlaysClips",
    ]

    /// Keys stored once per Plex Home profile (`_user_<id>`) or non-Plex server (`_provider_<id>`).
    static let profileFamilies: [String] = [
        "hiddenHomeRowIdentifiers", "homeRowOrder", "homeCollectionPins", "homePlaylistPins", "heroPlaylistPins",
        "homeHeroSources", "showHomeFavoriteMovies", "showHomeFavoriteShows", "libraryCollectionPins",
        "hiddenLibraryKeys", "hiddenSidebarLibraries", "libraryOrder", "libraryOrderAllServers", "librarySortOptions", "libraryViewMode", "libraryUnwatchedOnly",
        "trackIntent.subtitle", "trackIntent.audio",
    ]

    /// The words `DiagnosticsReport.settingsSnapshot` redacts by.
    static let secretWords = ["token", "pin", "password", "secret", "url", "server", "address", "user", "email", "name"]

    /// Allowlisted names that hit a secret word and are reviewed to be harmless:
    /// collection and playlist pins, "skip intro" (skIPINtro), machine ids of servers the user switched off,
    /// and the library order across all servers.
    static let reviewedSecretWordKeys: Set<String> = [
        "homeCollectionPins", "homePlaylistPins", "heroPlaylistPins", "libraryCollectionPins", "showSkipIntro", "autoSkipIntro",
        "liveTVHiddenPlexServers", "plexDisabledServers", "libraryOrderAllServers", "liveTVPinnedCategories",
    ]

    static func isSynced(_ key: String) -> Bool {
        if exactKeys.contains(key) { return true }
        if profileFamilies.contains(where: { key.hasPrefix($0 + "_user_") || key.hasPrefix($0 + "_provider_") })
            || profileFamilies.contains(key) { return true }
        for prefix in ["mediaLibrarySort.", "photoLibraryQuery."] where key.hasPrefix(prefix) { return key.count > prefix.count }
        // contentFilter.<category>.enabled
        if key.hasPrefix("contentFilter."), key.hasSuffix(".enabled") {
            let middle = key.dropFirst("contentFilter.".count).dropLast(".enabled".count)
            return !middle.isEmpty && !middle.contains(".")
        }
        return false
    }

    /// Lists of Live TV channel ids. Ids that embed an address or a login stay on the device they were made on.
    /// Pins are "<source id>|<category>", so they follow the same rule.
    static let channelListKeys: Set<String> = ["liveTVFavoriteChannelIds", "liveTVUnfavoritedChannelIds",
                                               "liveTVPinnedCategories"]

    /// `LiveChannelListStore.listsKey`: JSON lists whose channel ids and smart-list source ids
    /// follow the channel-id rule, list by list.
    static let channelListsKey = "liveTVChannelLists"
    /// `LiveTVDataStore`'s For You history: merged by channel and time, the newest kept.
    static let viewingsKey = "liveTVViewings"
    /// `XtreamWatchProgressStore.defaultsKey`: merged by title, the newest place wins.
    static let watchProgressKey = "xtreamWatchProgress"
    /// What iCloud carries of each, under the 64 KB a value may take.
    static let syncedViewings = 200
    static let syncedWatchRecords = 400

    /// A channel id is "<type>:<source id>:<channel>". Plex and Dispatcharr source ids hold the server address
    /// (which differs per device), and an M3U id from before the re-key held the whole playlist URL, login included.
    /// Anything URL-shaped or carrying a login stays home.
    static func isSyncableChannelId(_ id: String) -> Bool {
        let lower = id.lowercased()
        return !lower.contains("://") && !lower.contains("@") && !lower.contains("password=")
            && !lower.contains("username=") && !lower.contains("?")
    }

    /// The local value as the cloud may see it.
    static func outgoing(_ key: String, _ value: Any) -> Any {
        if key == channelListsKey { return lists(value).map { encode($0.map { shared($0) }) } ?? value }
        if key == viewingsKey { return viewings(value).map { encode(Array($0.filter(isSharedViewing).suffix(syncedViewings))) } ?? value }
        if key == watchProgressKey { return records(value).map { encode(newest($0, syncedWatchRecords)) } ?? value }
        guard channelListKeys.contains(key), let ids = value as? [String] else { return value }
        return ids.filter(isSyncableChannelId)
    }

    /// What this device keeps after taking the cloud's value: the cloud's ids, then the local ones that stay home.
    static func incoming(_ key: String, cloud: Any?, local: Any?) -> Any? {
        if key == channelListsKey { return incomingLists(cloud: cloud, local: local) }
        if key == viewingsKey { return incomingViewings(cloud: cloud, local: local) }
        if key == watchProgressKey { return incomingRecords(cloud: cloud, local: local) }
        guard channelListKeys.contains(key) else { return cloud }
        let shared = (cloud as? [String] ?? []).filter(isSyncableChannelId)
        let home = (local as? [String] ?? []).filter { !isSyncableChannelId($0) }
        let merged = shared + home
        return merged.isEmpty && cloud == nil ? nil : merged
    }

    // MARK: Channel lists

    /// The cloud's lists; a list this device also has keeps the ids that stay home, after the shared ones.
    private static func incomingLists(cloud: Any?, local: Any?) -> Any? {
        guard let cloudLists = lists(cloud as Any) else { return cloud }
        let localById = Dictionary((lists(local as Any) ?? []).compactMap { list in
            (list["id"] as? String).map { ($0, list) }
        }, uniquingKeysWith: { first, _ in first })
        let merged = cloudLists.map { list -> [String: Any] in
            var list = shared(list)
            guard let id = list["id"] as? String, let mine = localById[id] else { return list }
            let home = (mine["channelIds"] as? [String] ?? []).filter { !isSyncableChannelId($0) }
            list["channelIds"] = (list["channelIds"] as? [String] ?? []) + home
            if var rules = list["rules"] as? [String: Any], let myRules = mine["rules"] as? [String: Any] {
                let homeSources = (myRules["sourceIds"] as? [String] ?? []).filter { !isSyncableChannelId($0) }
                rules["sourceIds"] = (rules["sourceIds"] as? [String] ?? []) + homeSources
                list["rules"] = rules
            }
            return list
        }
        return encode(merged)
    }

    /// A list without the ids that stay home.
    private static func shared(_ list: [String: Any]) -> [String: Any] {
        var list = list
        if let ids = list["channelIds"] as? [String] { list["channelIds"] = ids.filter(isSyncableChannelId) }
        if var rules = list["rules"] as? [String: Any], let sources = rules["sourceIds"] as? [String] {
            rules["sourceIds"] = sources.filter(isSyncableChannelId)
            list["rules"] = rules
        }
        return list
    }

    private static func lists(_ value: Any) -> [[String: Any]]? {
        guard let data = value as? Data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    /// Sorted keys: the same lists always make the same bytes, so the mirror sees no false change.
    private static func encode(_ lists: [[String: Any]]) -> Any {
        (try? JSONSerialization.data(withJSONObject: lists, options: [.sortedKeys])) ?? Data()
    }

    // MARK: For You history and Xtream watch progress

    /// Both devices' viewings, one per channel and moment, oldest first, as the store keeps 300.
    private static func incomingViewings(cloud: Any?, local: Any?) -> Any? {
        guard let theirs = viewings(cloud as Any) else { return cloud }
        var seen = Set<String>()
        let merged = (theirs + (viewings(local as Any) ?? []))
            .filter { seen.insert("\($0["channelId"] as? String ?? "")|\(time($0["at"]))").inserted }
            .sorted { time($0["at"]) < time($1["at"]) }
        return encode(Array(merged.suffix(300)))
    }

    /// Every title either device has a place for, the newer place where both do.
    private static func incomingRecords(cloud: Any?, local: Any?) -> Any? {
        guard let theirs = records(cloud as Any) else { return cloud }
        var merged = records(local as Any) ?? [:]
        for (key, record) in theirs where time(record["updatedAt"]) >= time(merged[key]?["updatedAt"]) {
            merged[key] = record
        }
        // A dictionary, as the store saves it; JSONSerialization writes it as an object.
        return (try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])) ?? Data()
    }

    /// A viewing of a channel whose id may leave the device (`isSyncableChannelId`).
    private static func isSharedViewing(_ viewing: [String: Any]) -> Bool {
        (viewing["channelId"] as? String).map(isSyncableChannelId) ?? false
    }

    /// The `count` titles touched last.
    private static func newest(_ records: [String: [String: Any]], _ count: Int) -> [String: Any] {
        let kept = records.sorted { time($0.value["updatedAt"]) > time($1.value["updatedAt"]) }.prefix(count)
        return Dictionary(kept.map { ($0.key, $0.value as Any) }, uniquingKeysWith: { first, _ in first })
    }

    private static func viewings(_ value: Any) -> [[String: Any]]? { lists(value) }

    private static func records(_ value: Any) -> [String: [String: Any]]? {
        guard let data = value as? Data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
    }

    /// A JSONEncoder date (seconds since 2001), or the earliest when missing.
    private static func time(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? -.infinity }

    private static func encode(_ object: [String: Any]) -> Any {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// NSUbiquitousKeyValueStore raises on a key over 128 UTF-16 units.
    static func fitsKVS(key: String) -> Bool { key.utf16.count <= 128 }
}
