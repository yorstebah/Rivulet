// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TraktTests.swift
//  RivuletTests
//
//  Trakt: the tokens a reply gives, the item each server's playback is sent
//  as, the scrobbles a player's reports turn into, the device sign-in's
//  answers, and a refresh that keeps the rotated token.
//

import XCTest
import os
@testable import Rivulet

private final class FakeTrakt: URLProtocol {
    /// Status and body per "METHOD path"; requests in order with their bodies.
    nonisolated(unsafe) static var replies: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requests: [(line: String, auth: String?, body: [String: Any])] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let line = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        var body: [String: Any] = [:]
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        Self.requests.append((line, request.value(forHTTPHeaderField: "Authorization"), body))
        let (status, text) = Self.replies[line] ?? (404, "")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                              headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Tokens kept in memory, as the Keychain keeps them in the app.
private final class TokenBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<TraktTokens?>(initialState: nil)
    var tokens: TraktTokens? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

@MainActor
final class TraktTests: XCTestCase {
    private var box: TokenBox!

    override func setUp() {
        super.setUp()
        FakeTrakt.replies = [:]
        FakeTrakt.requests = []
        box = TokenBox()
    }

    private func client() -> TraktClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeTrakt.self]
        let box = box!
        return TraktClient(session: URLSession(configuration: configuration), clientID: { "id" }, clientSecret: { "secret" },
                           load: { box.tokens }, save: { box.tokens = $0 })
    }

    private func fresh(_ access: String = "a1", refresh: String = "r1") -> TraktTokens {
        TraktTokens(access: access, refresh: refresh, expiresAt: Date().addingTimeInterval(86400))
    }

    // MARK: - Tokens

    func test_tokens_fromAReply_expireAfterTheirLifetime() throws {
        let tokens = try XCTUnwrap(TraktTokens.from(["access_token": "a", "refresh_token": "r", "expires_in": 86400,
                                                      "created_at": 1_000_000]))
        XCTAssertEqual(tokens.expiresAt, Date(timeIntervalSince1970: 1_086_400))
        XCTAssertTrue(tokens.needsRefresh(now: Date(timeIntervalSince1970: 1_083_000)))
        XCTAssertFalse(tokens.needsRefresh(now: Date(timeIntervalSince1970: 1_000_000)))
        XCTAssertEqual(TraktTokens.decode(tokens.encoded), tokens)
    }

    // MARK: - Items

    private func metadata(_ json: String) -> PlexMetadata {
        try! JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    func test_movie_goesByItsIDs_andNotWithout() async {
        let movie = metadata(#"{"ratingKey":"1","type":"movie","title":"Heat","year":1995,"Guid":[{"id":"imdb://tt0113277"},{"id":"tmdb://949"}]}"#)
        let item = await TraktScrobbleItem.make(for: movie) { [:] }
        XCTAssertEqual(item?.kind, .movie(ids: ["imdb": "tt0113277", "tmdb": "949"]))
        let body = item?.body["movie"] as? [String: any Sendable]
        XCTAssertEqual((body?["ids"] as? [String: any Sendable])?["tmdb"] as? Int, 949)
        XCTAssertEqual(body?["title"] as? String, "Heat")

        let bare = metadata(#"{"ratingKey":"2","type":"movie","title":"Home Video"}"#)
        let none = await TraktScrobbleItem.make(for: bare) { [:] }
        XCTAssertNil(none)
    }

    func test_episode_ownIDsFirst_elseTheShowsWithSeasonAndNumber() async {
        let withIDs = metadata(#"{"ratingKey":"3","type":"episode","parentIndex":1,"index":2,"Guid":[{"id":"tvdb://349232"}]}"#)
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let own = await TraktScrobbleItem.make(for: withIDs) { asked.withLock { $0 += 1 }; return ["tmdb": "1"] }
        XCTAssertEqual(own?.kind, .episode(ids: ["tvdb": "349232"]))
        XCTAssertEqual(asked.withLock { $0 }, 0)

        let xtream = metadata(#"{"ratingKey":"e|70|702","type":"episode","parentIndex":1,"index":2,"grandparentTitle":"The Wire"}"#)
        let byShow = await TraktScrobbleItem.make(for: xtream) { ["TMDB": "1438", "Zap2it": "x"] }
        XCTAssertEqual(byShow?.kind, .showEpisode(showIDs: ["tmdb": "1438"], season: 1, number: 2))
        let body = byShow?.body
        XCTAssertEqual((body?["episode"] as? [String: any Sendable])?["number"] as? Int, 2)
        XCTAssertEqual((body?["show"] as? [String: any Sendable])?["title"] as? String, "The Wire")
    }

    // MARK: - Scrobbles

    private let episode = #"{"ratingKey":"9","type":"episode","duration":1000000,"Guid":[{"id":"tvdb://5"}]}"#

    func test_reports_becomeStartAndStop_onlyOnChanges() async {
        box.tokens = fresh()
        FakeTrakt.replies = ["POST /scrobble/start": (201, "{}"), "POST /scrobble/stop": (201, "{}")]
        let scrobbler = TraktScrobbler(client: client(), isSignedIn: { true }, isOn: { _ in true })
        let item = metadata(episode)
        scrobbler.report(item, server: .jellyfin, state: .playing, at: 100)
        scrobbler.report(item, server: .jellyfin, state: .playing, at: 110)
        scrobbler.report(item, server: .jellyfin, state: .buffering, at: 120)
        scrobbler.report(item, server: .jellyfin, state: .paused, at: 500)
        scrobbler.report(item, server: .jellyfin, state: .paused, at: 500)
        scrobbler.report(item, server: .jellyfin, state: .playing, at: 500)
        scrobbler.report(item, server: .jellyfin, state: .stopped, at: 900)
        await scrobbler.drain()
        XCTAssertEqual(FakeTrakt.requests.map(\.line), ["POST /scrobble/start", "POST /scrobble/stop",
                                                        "POST /scrobble/start", "POST /scrobble/stop"])
        XCTAssertEqual(FakeTrakt.requests.map { $0.body["progress"] as? Double }, [10, 50, 50, 90])
        XCTAssertEqual(FakeTrakt.requests.first?.auth, "Bearer a1")
    }

    func test_nothingIsSent_signedOut_switchedOff_orForATrailer() async {
        box.tokens = fresh()
        let off = TraktScrobbler(client: client(), isSignedIn: { true }, isOn: { $0 != .plex })
        off.report(metadata(episode), server: .plex, state: .playing, at: 100)
        let signedOut = TraktScrobbler(client: client(), isSignedIn: { false }, isOn: { _ in true })
        signedOut.report(metadata(episode), server: .emby, state: .playing, at: 100)
        let trailer = TraktScrobbler(client: client(), isSignedIn: { true }, isOn: { _ in true })
        trailer.report(metadata(#"{"ratingKey":"t","type":"clip","duration":90000}"#), server: .plex, state: .playing, at: 1)
        await off.drain(); await signedOut.drain(); await trailer.drain()
        XCTAssertTrue(FakeTrakt.requests.isEmpty)
    }

    func test_theNextItem_stopsTheOneBefore() async {
        box.tokens = fresh()
        FakeTrakt.replies = ["POST /scrobble/start": (201, "{}"), "POST /scrobble/stop": (201, "{}")]
        let scrobbler = TraktScrobbler(client: client(), isSignedIn: { true }, isOn: { _ in true })
        scrobbler.report(metadata(episode), server: .plex, state: .playing, at: 950)
        let next = #"{"ratingKey":"10","type":"episode","duration":1000000,"Guid":[{"id":"tvdb://6"}]}"#
        scrobbler.report(metadata(next), server: .plex, state: .playing, at: 0)
        await scrobbler.drain()
        XCTAssertEqual(FakeTrakt.requests.map(\.line), ["POST /scrobble/start", "POST /scrobble/stop", "POST /scrobble/start"])
        XCTAssertEqual(FakeTrakt.requests.map { $0.body["progress"] as? Double }, [95, 95, 0])
        let ids = FakeTrakt.requests.map { (($0.body["episode"] as? [String: Any])?["ids"] as? [String: Any])?["tvdb"] as? Int }
        XCTAssertEqual(ids, [5, 5, 6])
    }

    // MARK: - Sign-in and refresh

    func test_devicePoll_readsTraktsAnswers_andSavesTheTokens() async {
        let code = TraktDeviceCode(deviceCode: "d", userCode: "ABCD1234", verificationURL: URL(string: "https://trakt.tv/activate")!,
                                   expiresIn: 600, interval: 5)
        XCTAssertEqual(code.activationURL.absoluteString, "https://trakt.tv/activate/ABCD1234")
        let client = client()
        FakeTrakt.replies["POST /oauth/device/token"] = (400, "")
        let pending = await client.poll(code)
        FakeTrakt.replies["POST /oauth/device/token"] = (429, "")
        let slow = await client.poll(code)
        FakeTrakt.replies["POST /oauth/device/token"] = (418, "")
        let denied = await client.poll(code)
        FakeTrakt.replies["POST /oauth/device/token"] = (200, #"{"access_token":"a","refresh_token":"r","expires_in":86400}"#)
        let done = await client.poll(code)
        XCTAssertEqual(pending, .pending)
        XCTAssertEqual(slow, .slowDown)
        XCTAssertEqual(denied, .failed)
        guard case .signedIn(let tokens) = done else { return XCTFail("not signed in") }
        XCTAssertEqual(box.tokens, tokens)
        XCTAssertEqual(FakeTrakt.requests.last?.body["client_secret"] as? String, "secret")
    }

    func test_anExpiredToken_isRefreshedFirst_andTheRotatedOneKept() async {
        box.tokens = TraktTokens(access: "old", refresh: "r1", expiresAt: Date().addingTimeInterval(60))
        FakeTrakt.replies = [
            "POST /oauth/token": (200, #"{"access_token":"new","refresh_token":"r2","expires_in":86400}"#),
            "GET /users/settings": (200, #"{"user":{"username":"viewer"}}"#),
        ]
        let name = await client().username()
        XCTAssertEqual(name, "viewer")
        XCTAssertEqual(FakeTrakt.requests.map(\.line), ["POST /oauth/token", "GET /users/settings"])
        XCTAssertEqual(FakeTrakt.requests.first?.body["refresh_token"] as? String, "r1")
        XCTAssertEqual(FakeTrakt.requests.last?.auth, "Bearer new")
        XCTAssertEqual(box.tokens?.refresh, "r2")
    }

    func test_aRefusedRefresh_signsOut_butTokensBeingCheckedAreNeverRefreshed() async {
        box.tokens = TraktTokens(access: "old", refresh: "r1", expiresAt: Date().addingTimeInterval(60))
        FakeTrakt.replies = ["POST /oauth/token": (401, #"{"error":"invalid_grant"}"#), "GET /users/settings": (401, "")]
        let checked = await client().username(with: TraktTokens(access: "x", refresh: "y", expiresAt: Date()))
        XCTAssertNil(checked)
        XCTAssertEqual(FakeTrakt.requests.map(\.line), ["GET /users/settings"])
        _ = await client().username()
        XCTAssertNil(box.tokens)
    }

    func test_recommendations_readTheIDs() {
        let titles = TraktClient.titles([
            ["title": "Blackfish", "year": 2013, "ids": ["trakt": 58, "imdb": "tt2545118", "tmdb": 158999]],
            ["show": ["title": "The Wire", "year": 2002, "ids": ["tvdb": 79126]]],
        ])
        XCTAssertEqual(titles, [TraktTitle(title: "Blackfish", year: 2013, tmdb: 158999, imdb: "tt2545118", tvdb: nil),
                                TraktTitle(title: "The Wire", year: 2002, tmdb: nil, imdb: nil, tvdb: 79126)])
    }
}
