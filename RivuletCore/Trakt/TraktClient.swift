// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TraktClient.swift
//  Rivulet
//
//  Trakt's API for one viewer: device sign-in (a short code entered on a
//  phone), tokens that refresh themselves, scrobbles and recommendations.
//  The app's registration (client id and secret) comes from the gitignored
//  `Secrets.swift`; without it Trakt is hidden. Tokens live in the Keychain
//  and ride the encrypted account vault (`TraktAccountSync`), never KVS.
//

import Foundation

/// The app's Trakt registration, from `Secrets`. Empty values hide Trakt everywhere.
nonisolated enum TraktConfig {
    static var clientID: String { Secrets.traktClientID.trimmingCharacters(in: .whitespaces) }
    static var clientSecret: String { Secrets.traktClientSecret.trimmingCharacters(in: .whitespaces) }
    static var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }
}

/// A signed-in viewer's tokens. Trakt rotates the refresh token on every refresh.
nonisolated struct TraktTokens: Codable, Equatable, Sendable {
    var access: String
    var refresh: String
    var expiresAt: Date

    /// Refreshed an hour early, so a request never goes out on a token that expires on the way.
    func needsRefresh(now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) < 3600 }

    static let keychainKey = "traktTokens"

    var encoded: String? { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } }

    static func decode(_ text: String?) -> TraktTokens? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TraktTokens.self, from: data)
    }

    /// From a token reply (`/oauth/token`, `/oauth/device/token`).
    static func from(_ json: [String: Any], now: Date = Date()) -> TraktTokens? {
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else { return nil }
        let lifetime = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init) ?? 86400
        let created = (json["created_at"] as? Double) ?? (json["created_at"] as? Int).map(Double.init)
        let start = created.map { Date(timeIntervalSince1970: $0) } ?? now
        return TraktTokens(access: access, refresh: refresh, expiresAt: start.addingTimeInterval(lifetime))
    }
}

/// A film or show as Trakt names it.
nonisolated struct TraktTitle: Sendable, Equatable {
    let title: String
    let year: Int?
    let tmdb: Int?
    let imdb: String?
    let tvdb: Int?
}

/// The code a viewer enters at Trakt's activation page.
nonisolated struct TraktDeviceCode: Sendable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresIn: TimeInterval
    let interval: TimeInterval

    /// The activation page with the code filled in, for a QR code.
    var activationURL: URL { verificationURL.appending(component: userCode) }
}

actor TraktClient {
    enum Kind: String, Sendable { case movies, shows }

    enum PollResult: Equatable, Sendable {
        case pending
        case slowDown
        case signedIn(TraktTokens)
        /// The code expired, was denied or used: start again.
        case failed
    }

    static let shared = TraktClient()

    static let host = URL(string: "https://api.trakt.tv")!

    private let session: URLSession
    private let clientID: @Sendable () -> String
    private let clientSecret: @Sendable () -> String
    /// Reads and writes the tokens (the Keychain in the app); `save(nil)` forgets them.
    private let load: @Sendable () async -> TraktTokens?
    private let save: @Sendable (TraktTokens?) async -> Void
    private var refreshing: Task<TraktTokens?, Never>?
    private var recommendationCache: [Kind: (at: Date, titles: [TraktTitle])] = [:]

    init(session: URLSession = .shared,
         clientID: @escaping @Sendable () -> String = { TraktConfig.clientID },
         clientSecret: @escaping @Sendable () -> String = { TraktConfig.clientSecret },
         load: @escaping @Sendable () async -> TraktTokens? = {
             await MainActor.run { TraktTokens.decode(KeychainHelper.get(TraktTokens.keychainKey)) }
         },
         save: @escaping @Sendable (TraktTokens?) async -> Void = { tokens in
             await MainActor.run { TraktAccount.shared.store(tokens) }
         }) {
        self.session = session
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.load = load
        self.save = save
    }

    // MARK: - Sign-in

    func deviceCode() async -> TraktDeviceCode? {
        guard let (status, json) = await send("oauth/device/code", body: ["client_id": clientID()], token: nil),
              status == 200, let json = json as? [String: Any],
              let device = json["device_code"] as? String, let user = json["user_code"] as? String,
              let page = (json["verification_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return TraktDeviceCode(deviceCode: device, userCode: user, verificationURL: page,
                               expiresIn: Self.number(json["expires_in"]) ?? 600,
                               interval: max(Self.number(json["interval"]) ?? 5, 1))
    }

    /// One poll of a device code. A `signedIn` result is already saved.
    func poll(_ code: TraktDeviceCode) async -> PollResult {
        let body = ["code": code.deviceCode, "client_id": clientID(), "client_secret": clientSecret()]
        guard let (status, json) = await send("oauth/device/token", body: body, token: nil) else { return .pending }
        switch status {
        case 200:
            guard let tokens = (json as? [String: Any]).flatMap({ TraktTokens.from($0) }) else { return .failed }
            await save(tokens)
            return .signedIn(tokens)
        case 400: return .pending
        case 429: return .slowDown
        default: return .failed
        }
    }

    /// Ends this app's access to the account. Best effort.
    func revoke(_ tokens: TraktTokens) async {
        _ = await send("oauth/revoke", body: ["token": tokens.access, "client_id": clientID(),
                                              "client_secret": clientSecret()], token: nil)
    }

    /// The viewer's Trakt username: nil when the tokens don't work, empty when Trakt can't be asked.
    func username(with tokens: TraktTokens? = nil) async -> String? {
        guard let (status, json) = await authorized("users/settings", tokens: tokens) else { return "" }
        guard status == 200 else { return nil }
        let user = (json as? [String: Any])?["user"] as? [String: Any]
        return (user?["username"] as? String) ?? ""
    }

    // MARK: - Scrobble

    enum ScrobbleAction: String, Sendable { case start, stop }

    /// Sends one scrobble; `body` is the movie or episode objects. True when Trakt took it
    /// (a 409, "just scrobbled", counts: it already has the play).
    @discardableResult
    func scrobble(_ action: ScrobbleAction, body: [String: any Sendable], progress: Double) async -> Bool {
        var payload = body
        payload["progress"] = (progress * 100).rounded() / 100
        guard let (status, _) = await authorized("scrobble/\(action.rawValue)", method: "POST", body: payload) else { return false }
        return status == 201 || status == 409
    }

    // MARK: - Recommendations

    /// The viewer's personal picks, best first, kept for six hours. Empty when signed out.
    func recommendations(_ kind: Kind, limit: Int = 50, now: Date = Date()) async -> [TraktTitle] {
        if let cached = recommendationCache[kind], now.timeIntervalSince(cached.at) < 6 * 3600 { return cached.titles }
        let query = [URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "ignore_collected", value: "true")]
        guard let (status, json) = await authorized("recommendations/\(kind.rawValue)", query: query),
              status == 200, let list = json as? [[String: Any]] else { return [] }
        let titles = Self.titles(list)
        recommendationCache[kind] = (now, titles)
        return titles
    }

    static func titles(_ list: [[String: Any]]) -> [TraktTitle] {
        list.compactMap { entry in
            // Recommendations are bare objects; history and lists wrap them under "movie" or "show".
            let object = (entry["movie"] as? [String: Any]) ?? (entry["show"] as? [String: Any]) ?? entry
            guard let title = object["title"] as? String else { return nil }
            let ids = object["ids"] as? [String: Any] ?? [:]
            return TraktTitle(title: title, year: object["year"] as? Int, tmdb: ids["tmdb"] as? Int,
                              imdb: ids["imdb"] as? String, tvdb: ids["tvdb"] as? Int)
        }
    }

    // MARK: - Requests

    /// A request with the viewer's stored token, refreshed first when due and once more after a 401.
    /// Tokens passed in (a vault entry being checked) are only tried, never refreshed: Trakt rotates
    /// the refresh token, so a refresh whose result is not kept would sign the viewer out.
    /// nil when signed out or Trakt can't be reached.
    private func authorized(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                            body: [String: any Sendable]? = nil, tokens given: TraktTokens? = nil) async -> (Int, Any?)? {
        if let given { return await send(path, method: method, query: query, body: body, token: given.access) }
        guard var tokens = await load() else { return nil }
        if tokens.needsRefresh(), let fresh = await refreshed(from: tokens) { tokens = fresh }
        guard let first = await send(path, method: method, query: query, body: body, token: tokens.access) else { return nil }
        guard first.0 == 401, let fresh = await refreshed(from: tokens) else { return first }
        return await send(path, method: method, query: query, body: body, token: fresh.access)
    }

    /// New tokens for old ones, one refresh at a time. Another device may have refreshed first (the
    /// vault then holds the newer pair), so a refused refresh tries what is stored before giving up.
    private func refreshed(from tokens: TraktTokens) async -> TraktTokens? {
        if let running = refreshing { return await running.value }
        let task = Task { () -> TraktTokens? in
            let body = ["refresh_token": tokens.refresh, "client_id": clientID(), "client_secret": clientSecret(),
                        "redirect_uri": "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token"]
            guard let (status, json) = await send("oauth/token", body: body, token: nil) else { return nil }
            if status == 200, let fresh = (json as? [String: Any]).flatMap({ TraktTokens.from($0) }) {
                await save(fresh)
                return fresh
            }
            guard status == 401 || status == 400 else { return nil }
            if let stored = await load(), stored != tokens { return stored }
            await save(nil)
            return nil
        }
        refreshing = task
        let result = await task.value
        refreshing = nil
        return result
    }

    private func send(_ path: String, method: String = "POST", query: [URLQueryItem] = [],
                      body: [String: any Sendable]?, token: String?) async -> (Int, Any?)? {
        var components = URLComponents(url: Self.host.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil && method == "POST" ? "GET" : method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID(), forHTTPHeaderField: "trakt-api-key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        return (status, data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data))
    }

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Rivulet/\(version)"
    }()

    private static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
    }
}
