// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveCategoryList.swift
//  Rivulet
//
//  The List layout's categories: Recently Watched, Favorites and All Channels
//  first, then each source's groups in the source's own order (#568). With two
//  or more sources in view, each gets a section of its own, headed by its name,
//  with its own All Channels. Data only; each app draws it its own way.
//

import Foundation

/// One row of the category column.
struct LiveCategory: Identifiable, Hashable {
    enum Kind: Hashable {
        case recent
        case favorites
        /// Every channel in view, or one source's when `sourceId` is set.
        case all
        /// A source's name over its own categories. Not a category itself.
        case sourceHeader
        /// A channel group, by its trimmed title.
        case group(String)
    }

    let id: String
    let kind: Kind
    /// Localized for the fixed rows; the source's own text for sources and groups.
    let title: String
    /// The section's source, nil for the rows over every source in view.
    let sourceId: String?
    let channelCount: Int
}

/// Which guide a category opens: the source it is limited to and the tab.
struct LiveGuideTarget: Hashable {
    enum Tab: Hashable {
        case all
        case favorites
        /// A tab by its title: a channel group, or a source's name in a combined guide.
        case group(String)
    }

    let sourceId: String?
    let tab: Tab
}

/// What a channel airs now and next, from its guide.
struct LiveNowNext: Equatable {
    let current: UnifiedProgram?
    let next: UnifiedProgram?

    /// How far through `current` the clock is, 0...1.
    func progress(at now: Date) -> Double? {
        guard let current else { return nil }
        let length = current.endTime.timeIntervalSince(current.startTime)
        guard length > 0 else { return nil }
        return min(max(now.timeIntervalSince(current.startTime) / length, 0), 1)
    }

    /// The guide's programmes for a channel, sorted by start. Placeholder
    /// blocks ("No guide data available.") say nothing, so they count as none.
    static func of(_ programs: [UnifiedProgram]?, at now: Date) -> LiveNowNext {
        let programs = programs ?? []
        let isReal = { (program: UnifiedProgram) in !program.id.contains(":placeholder:") }
        return LiveNowNext(current: programs.first { $0.startTime <= now && $0.endTime > now && isReal($0) },
                           next: programs.first { $0.startTime > now && isReal($0) })
    }
}

/// The category column and the channels behind each row. Built once per
/// change of channels, favorites, recents or sources, then read per row.
struct LiveCategoryList {
    /// The store state the list is built from.
    struct Input {
        /// The merged lineup, in the store's order (by number, then name).
        var channels: [UnifiedChannel]
        /// Every source, in the store's order: id and display name.
        var sources: [(id: String, name: String)] = []
        var favoriteIds: [String] = []
        var unfavoritedIds: Set<String> = []
        /// Newest first.
        var recentChannelIds: [String] = []
        /// One source's sidebar entry; nil shows every source.
        var sourceIdFilter: String?
        /// Sources whose sections are folded to their header.
        var collapsedSourceIds: Set<String> = []
    }

    /// The column's rows in order, source headers included.
    let categories: [LiveCategory]
    let sourceIdFilter: String?
    private let lineup: [UnifiedChannel]
    /// Every row, folded ones too, in column order.
    private let allRows: [LiveCategory]
    /// Each row's channels, as positions in `lineup`.
    private let members: [String: [Int]]

    static func build(_ input: Input) -> LiveCategoryList {
        let filter = input.sourceIdFilter
        let lineup = filter.map { id in input.channels.filter { $0.sourceId == id } } ?? input.channels
        var members: [String: [Int]] = [:]
        var rows: [LiveCategory] = []
        var folded: Set<String> = []

        func add(_ kind: LiveCategory.Kind, title: String, sourceId: String?, positions: [Int]) {
            let id = Self.id(kind, sourceId: sourceId)
            // A merged lineup can list a channel twice; one row each.
            var seen = Set<String>()
            let unique = positions.filter { seen.insert(lineup[$0].id).inserted }
            guard kind == .sourceHeader || !unique.isEmpty else { return }
            members[id] = unique
            rows.append(LiveCategory(id: id, kind: kind, title: title, sourceId: sourceId, channelCount: unique.count))
        }

        var position: [String: Int] = [:]
        for (index, channel) in lineup.enumerated() where position[channel.id] == nil {
            position[channel.id] = index
        }
        add(.recent, title: String(localized: "Recently Watched"), sourceId: nil,
            positions: input.recentChannelIds.compactMap { position[$0] })
        let favorites = LiveTVDataStore.favorites(in: lineup, order: input.favoriteIds,
                                                  unfavorited: input.unfavoritedIds)
        add(.favorites, title: String(localized: "Favorites"), sourceId: nil,
            positions: favorites.compactMap { position[$0.id] })
        add(.all, title: String(localized: "All Channels"), sourceId: nil, positions: Array(lineup.indices))

        // Sections when two or more sources are in view, as the guide's source
        // tabs; with one, its groups follow All Channels directly.
        var bySource: [String: [Int]] = [:]
        for (index, channel) in lineup.enumerated() { bySource[channel.sourceId, default: []].append(index) }
        let known = input.sources.map(\.id)
        let present = known.filter { bySource[$0] != nil }
            + bySource.keys.filter { !known.contains($0) }.sorted()
        let names = Dictionary(input.sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        func addGroups(of positions: [Int], sourceId: String?) {
            var byGroup: [String: [Int]] = [:]
            for index in positions {
                guard let title = LiveGroupOrder.trimmed(lineup[index].groupTitle) else { continue }
                byGroup[title, default: []].append(index)
            }
            for title in LiveGroupOrder.titles(in: positions.map { lineup[$0] }) {
                add(.group(title), title: title, sourceId: sourceId, positions: byGroup[title] ?? [])
            }
        }

        if filter == nil && present.count > 1 {
            for sourceId in present {
                let positions = bySource[sourceId] ?? []
                add(.sourceHeader, title: names[sourceId] ?? "", sourceId: sourceId, positions: positions)
                let before = rows.count
                add(.all, title: String(localized: "All Channels"), sourceId: sourceId, positions: positions)
                addGroups(of: positions, sourceId: sourceId)
                // Folded: the rows leave the column but keep their channels, so
                // a selected row that folds away keeps its list.
                if input.collapsedSourceIds.contains(sourceId) { folded.formUnion(rows[before...].map(\.id)) }
            }
        } else {
            addGroups(of: Array(lineup.indices), sourceId: nil)
        }

        return LiveCategoryList(categories: rows.filter { !folded.contains($0.id) }, sourceIdFilter: filter,
                                lineup: lineup, allRows: rows, members: members)
    }

    static func id(_ kind: LiveCategory.Kind, sourceId: String?) -> String {
        let source = sourceId ?? ""
        switch kind {
        case .recent: return "recent"
        case .favorites: return "favorites"
        case .all: return "all|\(source)"
        case .sourceHeader: return "source|\(source)"
        case .group(let title): return "group|\(source)|\(title)"
        }
    }

    // MARK: - Reading

    /// The row's channels, in the guide's order for that tab: favorites as
    /// arranged, recents newest first, everything else as the lineup.
    func channels(in categoryId: String) -> [UnifiedChannel] {
        (members[categoryId] ?? []).map { lineup[$0] }
    }

    /// Any row, folded ones too.
    func category(_ id: String) -> LiveCategory? {
        allRows.first { $0.id == id }
    }

    /// The guide a row opens, with the same channels where the guide has such
    /// a tab. Recently Watched has none, so it opens on All Channels.
    func guideTarget(for categoryId: String) -> LiveGuideTarget? {
        guard let row = category(categoryId) else { return nil }
        let source = row.sourceId ?? sourceIdFilter
        switch row.kind {
        case .recent: return LiveGuideTarget(sourceId: sourceIdFilter, tab: .all)
        case .favorites: return LiveGuideTarget(sourceId: sourceIdFilter, tab: .favorites)
        case .all: return LiveGuideTarget(sourceId: source, tab: .all)
        case .group(let title): return LiveGuideTarget(sourceId: source, tab: .group(title))
        case .sourceHeader: return nil
        }
    }

    /// The row for the guide's tab on the way back, so a tab changed in the
    /// guide becomes the list's selection. nil when the list has no such row.
    func categoryId(for target: LiveGuideTarget) -> String? {
        // The rows over every source carry no source id.
        let source = target.sourceId == sourceIdFilter ? nil : target.sourceId
        let match: LiveCategory?
        switch target.tab {
        case .favorites:
            match = category(Self.id(.favorites, sourceId: nil))
        case .all:
            match = category(Self.id(.all, sourceId: source))
        case .group(let title):
            if let source {
                match = category(Self.id(.group(title), sourceId: source))
            } else if let header = allRows.first(where: { $0.kind == .sourceHeader && $0.title == title }) {
                // A source's own tab in the combined guide.
                match = category(Self.id(.all, sourceId: header.sourceId))
            } else {
                // A group the combined guide merges: the first source that has it.
                match = allRows.first { $0.kind == .group(title) }
            }
        }
        return match?.id
    }
}

extension LiveTVDataStore {
    /// The List layout's categories for a source (nil: every source).
    func liveCategoryList(sourceIdFilter: String?, collapsedSourceIds: Set<String> = []) -> LiveCategoryList {
        LiveCategoryList.build(LiveCategoryList.Input(
            channels: channels,
            sources: sources.map { (id: $0.id, name: $0.displayName) },
            favoriteIds: favoriteIds, unfavoritedIds: unfavoritedIds,
            recentChannelIds: recentChannelIds,
            sourceIdFilter: sourceIdFilter, collapsedSourceIds: collapsedSourceIds))
    }
}
