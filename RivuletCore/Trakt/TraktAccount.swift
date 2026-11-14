// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TraktAccount.swift
//  Rivulet
//
//  The viewer's Trakt sign-in: the device-code flow every app's Settings
//  shows, the tokens in the Keychain, and the vault entry that signs the
//  viewer's other devices in too. Refreshed tokens go back to the vault, as
//  Trakt rotates the refresh token and the other devices need the new one.
//

import Combine
import Foundation

@MainActor
final class TraktAccount: ObservableObject {
    enum State: Equatable {
        case signedOut
        case requestingCode
        /// Waiting for the viewer to enter `code` at its page.
        case waiting(TraktDeviceCode)
        case signedIn(username: String)
        case failed(String)
    }

    static let shared = TraktAccount()
    /// The vault's entry id: one Trakt account per viewer.
    static let syncID = "trakt"

    @Published private(set) var state: State
    private var signIn: Task<Void, Never>?

    var isSignedIn: Bool { tokens != nil }
    var tokens: TraktTokens? { TraktTokens.decode(KeychainHelper.get(TraktTokens.keychainKey)) }
    /// The name shown in Settings, kept so it shows without asking Trakt.
    private static let usernameKey = "traktUsername"

    private init() {
        state = TraktTokens.decode(KeychainHelper.get(TraktTokens.keychainKey)) == nil
            ? .signedOut : .signedIn(username: UserDefaults.standard.string(forKey: Self.usernameKey) ?? "")
    }

    /// Saves (or with nil forgets) the tokens here, and tells the vault.
    func store(_ new: TraktTokens?) {
        let old = tokens
        guard new != old else { return }
        if let new, let text = new.encoded {
            _ = KeychainHelper.set(text, forKey: TraktTokens.keychainKey)
            if old == nil { state = .signedIn(username: UserDefaults.standard.string(forKey: Self.usernameKey) ?? "") }
            CloudSync.shared.accountsChanged()
        } else {
            // Trakt refused the tokens: this device is signed out; the others find out on their own.
            _ = KeychainHelper.delete(TraktTokens.keychainKey)
            UserDefaults.standard.removeObject(forKey: Self.usernameKey)
            state = .signedOut
        }
    }

    // MARK: - Sign in and out

    /// Shows a code, then waits for the viewer to enter it, until it expires.
    func startSignIn(client: TraktClient = .shared) {
        signIn?.cancel()
        state = .requestingCode
        signIn = Task { [weak self] in
            guard let code = await client.deviceCode() else {
                self?.state = .failed(String(localized: "Couldn’t reach Trakt. Check your connection and try again."))
                return
            }
            guard !Task.isCancelled else { return }
            self?.state = .waiting(code)
            var interval = code.interval
            let deadline = Date().addingTimeInterval(code.expiresIn)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                switch await client.poll(code) {
                case .pending: continue
                case .slowDown: interval += 1
                case .signedIn(let tokens):
                    await self?.finishSignIn(tokens, client: client)
                    return
                case .failed:
                    self?.state = .failed(String(localized: "The code was not accepted. Try again."))
                    return
                }
            }
            if !Task.isCancelled { self?.state = .failed(String(localized: "The code expired. Try again.")) }
        }
    }

    private func finishSignIn(_ tokens: TraktTokens, client: TraktClient) async {
        let name = await client.username(with: tokens) ?? ""
        UserDefaults.standard.set(name, forKey: Self.usernameKey)
        state = .signedIn(username: name)
    }

    func cancelSignIn() {
        signIn?.cancel()
        signIn = nil
        if case .signedIn = state { return }
        state = tokens == nil ? .signedOut : .signedIn(username: UserDefaults.standard.string(forKey: Self.usernameKey) ?? "")
    }

    /// Signs out here, or everywhere (revoking the app's access on Trakt).
    func signOut(scope: SignOutScope, client: TraktClient = .shared) {
        let old = tokens
        _ = KeychainHelper.delete(TraktTokens.keychainKey)
        UserDefaults.standard.removeObject(forKey: Self.usernameKey)
        state = .signedOut
        CloudSync.shared.signedOut(accountID: Self.syncID, identity: nil, scope: scope)
        if case .everywhere = scope, let old { Task { await client.revoke(old) } }
    }

    /// The username again, for a device that was signed in through iCloud.
    func refreshUsername(client: TraktClient = .shared) {
        guard isSignedIn else { return }
        Task { [weak self] in
            guard let name = await client.username(), !name.isEmpty else { return }
            UserDefaults.standard.set(name, forKey: Self.usernameKey)
            if self?.isSignedIn == true { self?.state = .signedIn(username: name) }
        }
    }

    fileprivate func adopted() {
        state = .signedIn(username: UserDefaults.standard.string(forKey: Self.usernameKey) ?? "")
        refreshUsername()
    }

    fileprivate func removedBySync() {
        _ = KeychainHelper.delete(TraktTokens.keychainKey)
        UserDefaults.standard.removeObject(forKey: Self.usernameKey)
        state = .signedOut
    }
}

/// Which servers report what the viewer watches to Trakt. On for every server unless turned off:
/// a server with its own Trakt plugin would otherwise count each play twice.
nonisolated enum TraktScrobbleSettings {
    static let kinds: [MediaProviderKind] = [.plex, .jellyfin, .emby, .xtream]

    static func key(_ kind: MediaProviderKind) -> String { "traktScrobble_\(kind.rawValue)" }

    static func isOn(_ kind: MediaProviderKind, defaults: UserDefaults = .standard) -> Bool {
        guard kinds.contains(kind) else { return false }
        return defaults.object(forKey: key(kind)) as? Bool ?? true
    }

    static func set(_ on: Bool, for kind: MediaProviderKind, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key(kind))
    }

    /// The kinds of server set up on this device, the ones a scrobble can come from.
    @MainActor static var setUpKinds: [MediaProviderKind] {
        let present = Set(MediaProviderRegistry.shared.providers.values.map(\.kind))
        return kinds.filter { kind in
            kind == .plex ? PlexAuthManager.shared.isAuthenticated || present.contains(.plex) : present.contains(kind)
        }
    }

    /// A server kind's name in Settings (brand names, not translated).
    static func name(_ kind: MediaProviderKind) -> String {
        switch kind {
        case .plex: "Plex"
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        case .xtream: "Xtream Codes"
        default: kind.rawValue
        }
    }
}

extension SyncedAccountKind {
    static var trakt: SyncedAccountKind {
        SyncedAccountKind(
            kind: "trakt", updatesInPlace: true,
            export: {
                guard let text = TraktAccount.shared.tokens?.encoded else { return [] }
                return [AccountExport(id: TraktAccount.syncID, kind: "trakt", identity: nil, body: Data(text.utf8))]
            },
            adopt: { entry in
                guard let body = entry.body, let text = String(data: body, encoding: .utf8),
                      let tokens = TraktTokens.decode(text) else { return .refused }
                guard TraktConfig.isConfigured else { return .unavailable }
                // A pair about to expire can't be tried without refreshing it, which is this
                // device's first real request's job: kept as it is.
                if tokens.needsRefresh() {
                    _ = KeychainHelper.set(text, forKey: TraktTokens.keychainKey)
                    TraktAccount.shared.adopted()
                    return .adopted
                }
                // Tried before it is kept: a token another device has since refreshed away is refused.
                switch await TraktClient.shared.username(with: tokens) {
                case nil: return .refused
                case "": return .unavailable
                case let name?:
                    _ = KeychainHelper.set(text, forKey: TraktTokens.keychainKey)
                    UserDefaults.standard.set(name, forKey: "traktUsername")
                    TraktAccount.shared.adopted()
                    return .adopted
                }
            },
            remove: { _ in TraktAccount.shared.removedBySync() })
    }
}
