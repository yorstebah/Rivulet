// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamVODWiring.swift
//  Rivulet
//
//  Xtream films and series on tvOS: switched on at launch, and the servers
//  rebuilt whenever an Xtream source is added, renamed or removed, or its
//  films and series are switched on or off.
//

import Combine
import Foundation

@MainActor
enum XtreamVODWiring {
    private static var sourceWatch: AnyCancellable?

    /// From the app's init, before the registries first populate.
    static func install() {
        // Not in the unit-test host: tests own the registry, and the device's
        // sources would download their whole lists in the background of the run.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        MediaProviderRegistry.includesXtreamVOD = true
        XtreamVODSources.onChanged = refresh
        sourceWatch = LiveTVDataStore.shared.$sources
            .map { sources in sources.filter { $0.sourceType == .xtream }.map { "\($0.id)\n\($0.displayName)" } }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in refresh() }
    }

    private static func refresh() {
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        ServerDataStore.shared.reload()
    }
}
