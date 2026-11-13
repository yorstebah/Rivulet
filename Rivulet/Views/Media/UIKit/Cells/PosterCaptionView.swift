// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The title and year under the focused poster or square tile: hidden at rest,
// shown as focus lands, as tvOS lockups reveal their footer on focus. It sits
// below the focused frame, so the growing artwork never covers it.

import UIKit

@MainActor
final class PosterCaptionView: UIView {
    private let titleLabel = UILabel()
    private let yearLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        alpha = 0
        titleLabel.font = .systemFont(ofSize: 24, weight: .medium)
        titleLabel.textColor = .white
        yearLabel.font = .systemFont(ofSize: 22, weight: .regular)
        yearLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        let stack = UIStackView(arrangedSubviews: [titleLabel, yearLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for label in [titleLabel, yearLabel] {
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.numberOfLines = 1
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String?, year: Int?) {
        titleLabel.text = title
        yearLabel.text = year.map(String.init)
        yearLabel.isHidden = year == nil
    }

    /// Inside a focus animation, so it fades with the poster's growth.
    func setFocused(_ focused: Bool) {
        alpha = focused ? 1 : 0
    }

    /// From the artwork's centre to the caption's top: just under the focused frame.
    static func topOffset(for tile: MediaRowMetrics.Tile) -> CGFloat { tile.frame.height / 2 + 8 }
}
