// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The title line under a poster or square tile, as Apple's App Store and Music
// lockups draw it: one line, secondary at rest, white on focus. It sits below
// the focused frame, so the growing artwork never covers it.

import UIKit

@MainActor
final class PosterTitleLabel: UILabel {
    static let restingColor = UIColor.white.withAlphaComponent(0.6)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        font = .systemFont(ofSize: 24, weight: .medium)
        textColor = Self.restingColor
        textAlignment = .center
        lineBreakMode = .byTruncatingTail
        numberOfLines = 1
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFocused(_ focused: Bool) {
        textColor = focused ? .white : Self.restingColor
    }

    /// Pins the label under a tile whose artwork is centred on `anchor`.
    /// Returns the top constraint, whose constant follows the tile (`topOffset`).
    static func topOffset(for tile: MediaRowMetrics.Tile) -> CGFloat { tile.frame.height / 2 + 6 }
}
