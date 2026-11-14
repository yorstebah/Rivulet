// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ForYouSyncTests.swift
//  RivuletTests
//
//  What For You learns from, on every device: Live TV viewings and Xtream
//  places merge rather than overwrite, stay under iCloud's size per value,
//  and keep ids that hold an address on the device; the TMDB key is tried
//  before it is adopted.
//

import XCTest
@testable import Rivulet

final class ForYouSyncTests: XCTestCase {
    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func object<T>(_ value: Any?, as type: T.Type) throws -> T {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(value as? Data)) as? T)
    }

    func test_keysAreSynced() {
        for key in ["liveTVViewings", "xtreamWatchProgress", "xtreamFavorites"] {
            XCTAssertTrue(SyncCatalog.isSynced(key), key)
        }
    }

    func test_watchProgress_mergesByTitle_newestPlaceWins() throws {
        let local: [String: Any] = [
            "x|movie|1": ["position": 100, "watched": false, "updatedAt": 10],
            "x|movie|2": ["position": 50, "watched": false, "updatedAt": 30],
        ]
        let cloud: [String: Any] = [
            "x|movie|1": ["position": 900, "watched": false, "updatedAt": 20],
            "x|movie|2": ["position": 10, "watched": false, "updatedAt": 5],
            "x|movie|3": ["position": 0, "watched": true, "updatedAt": 1],
        ]
        let merged = try object(SyncCatalog.incoming("xtreamWatchProgress", cloud: data(cloud), local: data(local)),
                                as: [String: [String: Any]].self)
        XCTAssertEqual(merged["x|movie|1"]?["position"] as? Int, 900)
        XCTAssertEqual(merged["x|movie|2"]?["position"] as? Int, 50)
        XCTAssertEqual(merged["x|movie|3"]?["watched"] as? Bool, true)
    }

    func test_watchProgress_sendsTheNewest400_underICloudsLimit() throws {
        var many: [String: Any] = [:]
        for index in 0..<1000 {
            many["xtream:abcdef0123456789|movie|\(index)"] = ["position": 1234.5, "duration": 6000.0,
                                                               "watched": false, "updatedAt": Double(index)]
        }
        let sent = try XCTUnwrap(SyncCatalog.outgoing("xtreamWatchProgress", try data(many)) as? Data)
        let kept = try object(sent, as: [String: Any].self)
        XCTAssertEqual(kept.count, 400)
        XCTAssertNotNil(kept["xtream:abcdef0123456789|movie|999"])
        XCTAssertNil(kept["xtream:abcdef0123456789|movie|0"])
        XCTAssertLessThan(sent.count, PreferenceMirror.defaultMaxValueBytes)
    }

    func test_viewings_mergeBothDevices_andKeepAddressedChannelsHome() throws {
        let plex = "plex:plex:http://192.168.1.5:32400:5"
        let local: [[String: Any]] = [
            ["channelId": "xtream:x:1", "at": 10, "labels": []],
            ["channelId": plex, "at": 15, "labels": []],
        ]
        let sent = try object(SyncCatalog.outgoing("liveTVViewings", try data(local)), as: [[String: Any]].self)
        XCTAssertEqual(sent.compactMap { $0["channelId"] as? String }, ["xtream:x:1"])

        let cloud: [[String: Any]] = [["channelId": "xtream:x:1", "at": 10, "labels": []],
                                      ["channelId": "xtream:x:2", "at": 20, "labels": []]]
        let merged = try object(SyncCatalog.incoming("liveTVViewings", cloud: data(cloud), local: data(local)),
                                as: [[String: Any]].self)
        XCTAssertEqual(merged.compactMap { $0["channelId"] as? String }, ["xtream:x:1", plex, "xtream:x:2"])
    }

    func test_viewingsSent_stayUnderICloudsLimit() throws {
        let many: [[String: Any]] = (0..<300).map { index in
            ["channelId": "xtream:xtream:abcdef0123456789:\(index)", "at": Double(index),
             "title": "A programme title of a usual length", "labels": ["football", "premier league"], "genre": "Sports"]
        }
        let sent = try XCTUnwrap(SyncCatalog.outgoing("liveTVViewings", try data(many)) as? Data)
        XCTAssertEqual(try object(sent, as: [Any].self).count, SyncCatalog.syncedViewings)
        XCTAssertLessThan(sent.count, PreferenceMirror.defaultMaxValueBytes)
    }
}

private final class FakeTMDBConfig: URLProtocol {
    nonisolated(unsafe) static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                                              headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class TMDBKeyVerifyTests: XCTestCase {
    func test_aKeyIsTriedBeforeItIsAdopted() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeTMDBConfig.self]
        let session = URLSession(configuration: configuration)
        FakeTMDBConfig.status = 200
        let good = await TMDBLookup.verify("0123456789abcdef0123456789abcdef", session: session)
        XCTAssertEqual(good, true)
        FakeTMDBConfig.status = 401
        let bad = await TMDBLookup.verify("0123456789abcdef0123456789abcdef", session: session)
        XCTAssertEqual(bad, false)
        FakeTMDBConfig.status = 503
        let unsure = await TMDBLookup.verify("0123456789abcdef0123456789abcdef", session: session)
        XCTAssertNil(unsure)
    }
}
