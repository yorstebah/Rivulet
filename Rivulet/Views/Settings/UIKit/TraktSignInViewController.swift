// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  Trakt sign-in on the popup card, as Plex's: a QR code or Trakt's activation page and a code,
//  then the signed-in name. Renders `TraktAccount.state`; Menu cancels. `onFinish` runs after it closes.

import Combine
import UIKit

final class TraktSignInViewController: UIViewController {

    private let account = TraktAccount.shared
    private let onFinish: () -> Void
    private let stack = UIStackView()
    private var stateObserver: AnyCancellable?
    private var focusTarget: UIView?
    private var isClosing = false

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        let glass = UIVisualEffectView(effect: UIGlassEffect())
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = 38
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        view.addSubview(glass)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)

        let pad = PreviewCarouselGeometry.expandedChromeInset
        NSLayoutConstraint.activate([
            glass.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            glass.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 900),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -pad),
        ])

        let menuTap = UITapGestureRecognizer(target: self, action: #selector(cancel))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuTap)

        stateObserver = account.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.render(state) }
        account.startSignIn()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [focusTarget].compactMap { $0 }
    }

    // MARK: - States

    private func render(_ state: TraktAccount.State) {
        guard !isClosing else { return }
        switch state {
        case .signedOut, .requestingCode:
            showLoading(String(localized: "Connecting to Trakt…"))
        case .waiting(let code):
            showCode(code)
        case .signedIn(let username):
            showConnected(username)
        case .failed(let message):
            showError(message)
        }
    }

    private func showLoading(_ message: String) {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        setContent([spinner, label(message, size: 26, color: .secondaryText)], focus: nil)
    }

    /// A QR code that opens the activation page with the code filled in, or the page and the code.
    private func showCode(_ code: TraktDeviceCode) {
        let scan = UIStackView(arrangedSubviews: [
            qrTile(code.activationURL.absoluteString),
            label(String(localized: "Scan with your phone"), size: 22, color: .secondaryText),
        ])
        scan.axis = .vertical
        scan.alignment = .center
        scan.spacing = 14

        let page = (code.verificationURL.host() ?? "trakt.tv") + code.verificationURL.path()
        let typed = UIStackView(arrangedSubviews: [
            label(String(localized: "or visit"), size: 26, color: .secondaryText),
            label(page, size: 40, weight: .bold),
            label(String(localized: "and enter this code:"), size: 26, color: .secondaryText),
            label(code.userCode, size: 56, weight: .bold, monospaced: true),
        ])
        typed.axis = .vertical
        typed.alignment = .center
        typed.spacing = 4
        typed.setCustomSpacing(20, after: typed.arrangedSubviews[2])

        let ways = UIStackView(arrangedSubviews: [scan, typed])
        ways.axis = .horizontal
        ways.alignment = .center
        ways.spacing = 64
        let waysRow = UIStackView(arrangedSubviews: [ways])
        waysRow.axis = .vertical
        waysRow.alignment = .center

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.startAnimating()
        let waiting = UIStackView(arrangedSubviews: [
            spinner, label(String(localized: "Waiting for you to sign in…"), size: 22, color: .secondaryText),
        ])
        waiting.spacing = 12
        let waitingRow = UIStackView(arrangedSubviews: [waiting])
        waitingRow.axis = .vertical
        waitingRow.alignment = .center

        let cancel = button(String(localized: "Cancel")) { [weak self] in self?.cancel() }
        setContent([waysRow, waitingRow, cancel], focus: cancel)
        stack.setCustomSpacing(36, after: waysRow)
        stack.setCustomSpacing(36, after: waitingRow)
    }

    private func showConnected(_ username: String) {
        var views = [label(String(localized: "Connected to Trakt"), size: 34, weight: .bold)]
        if !username.isEmpty {
            views.append(label(String(localized: "Signed in as \(username)"), size: 24, color: .secondaryText))
        }
        setContent(views, focus: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.close() }
    }

    private func showError(_ message: String) {
        let retry = button(String(localized: "Try Again")) { [weak self] in self?.account.startSignIn() }
        let cancel = button(String(localized: "Cancel")) { [weak self] in self?.cancel() }
        let buttons = UIStackView(arrangedSubviews: [cancel, retry])
        buttons.distribution = .fillEqually
        buttons.spacing = 24
        buttons.heightAnchor.constraint(equalToConstant: 72).isActive = true
        setContent([label(String(localized: "Couldn’t Connect"), size: 34, weight: .bold),
                    label(message, size: 24, color: .secondaryText), buttons], focus: retry)
        stack.setCustomSpacing(36, after: stack.arrangedSubviews[1])
    }

    // MARK: - Actions

    @objc private func cancel() {
        account.cancelSignIn()
        close()
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        dismiss(animated: true) { [onFinish] in onFinish() }
    }

    // MARK: - Building

    private func setContent(_ views: [UIView], focus: UIView?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach(stack.addArrangedSubview)
        focusTarget = focus
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func button(_ title: String, action: @escaping () -> Void) -> PopupPillButton {
        PopupPillButton(title: title, destructive: false, onPress: action)
    }

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular,
                       color: UIColor = .white, monospaced: Bool = false) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    /// Black modules on a white tile, the contrast a phone camera reads from a TV.
    private func qrTile(_ text: String) -> UIView {
        let tile = UIView()
        tile.backgroundColor = .white
        tile.layer.cornerRadius = 16
        tile.layer.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false
        let code = UIImageView(image: QRCodeImage.make(text, side: 200, scale: traitCollection.displayScale))
        code.contentMode = .center
        code.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(code)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 232),
            tile.heightAnchor.constraint(equalToConstant: 232),
            code.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            code.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }
}

private extension UIColor {
    static let secondaryText = UIColor.white.withAlphaComponent(0.7)
}
