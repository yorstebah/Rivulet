// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamVODWiring.swift
//  Rivulet
//
//  Xtream films and series in an app: switched on at launch, and the servers
//  rebuilt whenever an Xtream source is added, renamed or removed, or its
//  films and series are switched on or off. Every app calls `install` from its
//  launch, before the registry first populates.
//

import Combine
import Foundation

@MainActor
enum XtreamVODWiring {
    private static var sourceWatch: AnyCancellable?
    private static var afterChange: (() -> Void)?

    /// `afterChange` runs once the registry is rebuilt (tvOS reloads its server store; the
    /// iOS and Mac stores follow the registry by themselves).
    static func install(afterChange: (() -> Void)? = nil) {
        // Not in the unit-test host: tests own the registry, and the device's
        // sources would download their whole lists in the background of the run.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        MediaProviderRegistry.includesXtreamVOD = true
        Self.afterChange = afterChange
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
        afterChange?()
    }
}
