// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamVODLanguagesTests.swift
//  RivuletTests
//
//  Which of a panel's language copies show: the viewer's languages, each
//  title once in the first of them it has, Multi first by default, then the
//  device's languages, then English; untagged titles always.
//

import XCTest
@testable import Rivulet

final class XtreamVODLanguagesTests: XCTestCase {
    func test_defaults_multiThenTheDevicesLanguagesThenEnglish() {
        XCTAssertEqual(XtreamVODLanguages.defaults(preferredLanguages: ["nl-NL", "en-US"]).origins,
                       ["MULTI", "NL", "BE", "GB", "US", "CA", "AU", "IE", "NZ"])
        XCTAssertEqual(Array(XtreamVODLanguages.defaults(preferredLanguages: ["de-DE"]).origins.prefix(5)),
                       ["MULTI", "DE", "AT", "CH", "GB"])
        XCTAssertEqual(Array(XtreamVODLanguages.defaults(preferredLanguages: ["en-GB"]).origins.prefix(2)), ["MULTI", "GB"])
    }

    func test_eachTitleOnce_inTheFirstLanguageItHas() {
        let languages = XtreamVODLanguages(origins: ["MULTI", "NL", "GB", "US"])
        let titles: [(name: String, year: Int?, tag: String?)] = [
            ("Ted Lasso", 2020, "MULTI / LINGO"),   // 0: Multi wins
            ("Ted Lasso", 2020, "NL"),              // 1
            ("Ted Lasso", 2020, "FR"),              // 2: never
            ("Lost", 2004, "NL"),                   // 3: only Dutch: shown
            ("Lost", 2004, "TR"),                   // 4
            ("Dark", 2017, "USA"),                  // 5: USA reads US
            ("Le Bureau", 2015, "FR"),              // 6: French only: hidden
            ("Untagged", 2020, nil),                // 7: always
            ("Heat", 1995, "UK"),                   // 8: UK reads GB
            ("Heat", 1986, "NL"),                   // 9: another year, another film
        ]
        XCTAssertEqual(languages.shown(titles), [0, 3, 5, 7, 8, 9])
        XCTAssertEqual(XtreamVODLanguages.everything.shown(titles), Array(0..<10))
    }

    func test_available_countsEachLanguage_mostCommonFirst() {
        let found = XtreamVODLanguages.available(["FR", "FR-4K", "NL", "EN", "UK", nil, "PPV"])
        XCTAssertEqual(found.map(\.origin), ["FR", "GB", "NL"])
        XCTAssertEqual(found.map(\.count), [2, 2, 1])
    }

    func test_summary_namesTheLanguages() {
        XCTAssertEqual(XtreamVODLanguages.everything.summary, String(localized: "All Languages"))
        let summary = XtreamVODLanguages(origins: ["MULTI", "NL", "GB", "US", "FR", "DE"]).summary
        XCTAssertTrue(summary.hasSuffix("…"), summary)
        XCTAssertFalse(summary.contains("🇳🇱"))
    }

    func test_countriesReadAsLanguages_andAFocusKeepsOneOfThem() {
        XCTAssertEqual(XtreamVODLanguages.language(of: "BE"), "nl")
        XCTAssertEqual(XtreamVODLanguages.language(of: "US"), "en")
        XCTAssertEqual(XtreamVODLanguages.language(of: "MULTI"), "multi")
        XCTAssertEqual(XtreamVODLanguages.language(of: "EXYU"), "EXYU")
        let mine = XtreamVODLanguages.defaults(preferredLanguages: ["nl-NL"])
        XCTAssertEqual(mine.languages, ["multi", "nl", "en"])
        // "Show: English": only English copies, the viewer's order within English kept.
        let english = mine.focused(on: "en")
        XCTAssertEqual(english.origins, ["GB", "US", "CA", "AU", "IE", "NZ"])
        let titles: [(name: String, year: Int?, tag: String?)] = [("Ted Lasso", 2020, "MULTI"), ("Ted Lasso", 2020, "USA")]
        XCTAssertEqual(english.shown(titles), [1])
        XCTAssertEqual(mine.shown(titles), [0])
        XCTAssertEqual(XtreamVODLanguages.languageCounts([("NL", 5), ("BE", 2), ("US", 4), ("GB", 1), ("FR", 3)]).map(\.language),
                       ["nl", "en", "fr"])
    }

    func test_summary_readsAsLanguages() {
        let summary = XtreamVODLanguages.defaults(preferredLanguages: ["nl-NL"]).summary
        XCTAssertEqual(summary.components(separatedBy: ", ").count, 3, summary)
        XCTAssertTrue(summary.hasPrefix(String(localized: "Multi") + ", "), summary)
    }
}
