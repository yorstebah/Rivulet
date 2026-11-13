// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveGuideOverlay.swift
//  Rivulet
//
//  The guide laid over a playing channel (Right in the live player): the
//  existing guide, see-through, on the channel's own group and focused on it.
//  The channel plays on behind it. Built here so the UIKit player needs no
//  SwiftUI of its own.
//

import SwiftUI

@MainActor
enum LiveGuideOverlay {
    static func make(playing channel: UnifiedChannel,
                     onSelect: @escaping (UnifiedChannel) -> Void,
                     onClose: @escaping () -> Void) -> UIViewController {
        let host = UIHostingController(rootView: GuideLayoutView(
            sourceIdFilter: channel.sourceId,
            initialGroup: LiveGroupOrder.trimmed(channel.groupTitle),
            initialChannelId: channel.id,
            onExit: { _, _ in onClose() },
            overPlayer: true,
            onSelectChannel: onSelect))
        host.view.backgroundColor = .clear
        return host
    }
}
