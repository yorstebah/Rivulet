// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBKeySync.swift
//  Rivulet
//
//  The viewer's TMDB key on every device. It is a credential, so it rides the
//  encrypted CloudKit vault with the server sign-ins, never the key-value
//  store. Every Settings field sets it here, so a change or a removal reaches
//  the other devices; a key that arrives is tried against TMDB first.
//

import Foundation

@MainActor
enum TMDBKeyStore {
    /// The vault's entry id: one key for the viewer, whichever source uses it.
    static let syncID = "tmdb"

    static var current: String? {
        KeychainHelper.get(TMDBLookup.keychainKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Saves a key, or with an empty one removes it, here and on the viewer's other devices.
    static func set(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (current ?? "") else { return }
        if trimmed.isEmpty {
            _ = KeychainHelper.delete(TMDBLookup.keychainKey)
            CloudSync.shared.signedOut(accountID: syncID, identity: nil, scope: .everywhere)
        } else {
            _ = KeychainHelper.set(trimmed, forKey: TMDBLookup.keychainKey)
            CloudSync.shared.accountsChanged()
        }
    }
}

extension SyncedAccountKind {
    static var tmdb: SyncedAccountKind {
        SyncedAccountKind(
            kind: "tmdb", updatesInPlace: true,
            export: {
                guard let key = TMDBKeyStore.current else { return [] }
                return [AccountExport(id: TMDBKeyStore.syncID, kind: "tmdb", identity: nil, body: Data(key.utf8))]
            },
            adopt: { entry in
                guard let body = entry.body, let key = String(data: body, encoding: .utf8), !key.isEmpty else {
                    return .refused
                }
                switch await TMDBLookup.verify(key) {
                case true?:
                    _ = KeychainHelper.set(key, forKey: TMDBLookup.keychainKey)
                    return .adopted
                case false?: return .refused
                case nil: return .unavailable
                }
            },
            remove: { _ in _ = KeychainHelper.delete(TMDBLookup.keychainKey) })
    }
}

extension TMDBLookup {
    /// Whether TMDB accepts a key: true or false, nil when it could not be asked (offline).
    nonisolated static func verify(_ key: String, session: URLSession = .shared) async -> Bool? {
        var components = URLComponents(string: "https://api.themoviedb.org/3/configuration")!
        let isToken = key.count > 40
        if !isToken { components.queryItems = [URLQueryItem(name: "api_key", value: key)] }
        guard let url = components.url else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if isToken { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (_, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if status == 200 { return true }
        return status == 401 || status == 403 ? false : nil
    }
}
