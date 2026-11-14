// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Content Languages (Playback settings): which copies of the Xtream providers' films and series
/// show. All Languages, then each language their titles carry, the chosen ones first in order of
/// preference; the first chosen is the copy shown when a title has several. Logic:
/// `XtreamVODLanguages` and `XtreamVODSources`, as on tvOS.
struct IOSContentLanguagesView: View {
    @State private var languages = XtreamVODLanguages.everything
    @State private var available: [(origin: String, count: Int)] = []

    var body: some View {
        List {
            Section {
                row(title: String(localized: "All Languages"), count: nil, selected: languages.showsEverything) {
                    update(.everything)
                }
            }
            Section {
                ForEach(order, id: \.self) { language in
                    row(title: XtreamVODLanguages.name(ofLanguage: language),
                        count: counts.first { $0.language == language }?.count,
                        selected: languages.languages.contains(language)) {
                        update(languages.toggling(language, available: available.map(\.origin)))
                    }
                }
                if available.isEmpty { ProgressView() }
            } footer: {
                Text("Your IPTV provider lists films and series once per language. Each title shows once, in the first of your languages it has. Plex, Jellyfin and Emby list a title once with all its languages: Audio Language and Subtitle Language choose there.")
            }
            Section {
                Button("Restore Defaults") { update(.defaults()) }
            } footer: {
                Text("Multi first, then your device's languages, then English.")
            }
        }
        .navigationTitle("Content Languages")
        .task {
            languages = XtreamVODSources.languages()
            if XtreamVODSources.allAvailableOrigins.isEmpty { await XtreamVODSources.loadAvailableOrigins() }
            available = XtreamVODSources.allAvailableOrigins
        }
    }

    private var counts: [(language: String, count: Int)] { XtreamVODLanguages.languageCounts(available) }

    /// The chosen languages in order of preference, then the rest by how many titles they hold.
    private var order: [String] { languages.order(available: available) }

    private func update(_ next: XtreamVODLanguages) {
        languages = next
        XtreamVODSources.setLanguages(next)
    }

    private func row(title: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(verbatim: title).foregroundStyle(.primary)
                Spacer()
                if let count { Text(count, format: .number).foregroundStyle(.secondary) }
                Image(systemName: "checkmark").foregroundStyle(.tint).opacity(selected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
