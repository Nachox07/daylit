import XCTest
@testable import DaylitCore

/// The same cases as windows/tests/UpdateTests.cs.
final class UpdateVersionTests: XCTestCase {
    func testVersionsParseWithOrWithoutAV() {
        XCTAssertEqual(UpdateCheck.parse("1.5.1"), [1, 5, 1])
        XCTAssertEqual(UpdateCheck.parse("v1.5.1"), [1, 5, 1])
        XCTAssertEqual(UpdateCheck.parse(" V2.0 "), [2, 0])
        XCTAssertEqual(UpdateCheck.parse("10"), [10])
    }
    func testTextThatIsNotAVersionDoesNotParse() {
        for s in ["", "v", "1.5-beta", "1..5", "1.5.", "one.two", "1.2.3.4.5", "1.5 beta", "-1.2", "１.２"] {
            XCTAssertNil(UpdateCheck.parse(s), s)
        }
    }
    func testComparisonIsNumericNotAlphabetical() {
        XCTAssertTrue(UpdateCheck.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(UpdateCheck.isNewer("v2.0.0", than: "1.99.99"))
        XCTAssertTrue(UpdateCheck.isNewer("1.5.1", than: "1.5"))
        XCTAssertFalse(UpdateCheck.isNewer("1.9.9", than: "1.10.0"))
    }
    func testTheSameVersionIsNotNewer() {
        XCTAssertFalse(UpdateCheck.isNewer("1.5.1", than: "v1.5.1"))
        XCTAssertFalse(UpdateCheck.isNewer("1.5", than: "1.5.0"))
    }
    func testAnythingThatIsNotAVersionIsNeverNewer() {
        XCTAssertFalse(UpdateCheck.isNewer("nightly", than: "1.0.0"))
        XCTAssertFalse(UpdateCheck.isNewer("2.0.0", than: "garbage"))
    }
    func testLocalBuildsAreDevBuilds() {
        for v in [nil, "", "0.0.0", "0", "dev", "abc"] as [String?] { XCTAssertTrue(UpdateCheck.isDevBuild(v), v ?? "nil") }
        XCTAssertFalse(UpdateCheck.isDevBuild("1.5.1"))
        XCTAssertFalse(UpdateCheck.isDevBuild("0.0.1"))
    }
    func testTheUserAgentCarriesOnlyTheAppAndItsVersion() {
        XCTAssertEqual(UpdateCheck.userAgent(version: "1.5.1"), "Daylit/1.5.1")
        XCTAssertEqual(UpdateCheck.userAgent(version: "0.0.0"), "Daylit/dev")
        XCTAssertEqual(UpdateCheck.userAgent(version: nil), "Daylit/dev")
    }
    func testAnAppInsideTheCaskroomIsAHomebrewInstall() {
        XCTAssertTrue(UpdateCheck.isHomebrew(bundlePath: "/opt/homebrew/Caskroom/daylit/1.5.1/Daylit.app"))
        XCTAssertTrue(UpdateCheck.isHomebrew(bundlePath: "/usr/local/Caskroom/daylit/1.5.1/Daylit.app"))
        XCTAssertFalse(UpdateCheck.isHomebrew(bundlePath: "/Applications/Daylit.app"))
        XCTAssertFalse(UpdateCheck.isHomebrew(bundlePath: "/Users/someone/Applications/Daylit.app"))
    }
}

final class UpdateAvailableTests: XCTestCase {
    func rel(_ tag: String, _ body: String = "", draft: Bool = false, pre: Bool = false) -> UpdateCheck.Release {
        .init(tag: tag, url: "https://github.com/Nachox07/daylit/releases/tag/\(tag)", body: body, draft: draft, prerelease: pre)
    }
    func body(_ items: String...) -> String {
        "## What's Changed\n" + items.map { "* \($0) by @someone in https://github.com/Nachox07/daylit/pull/1" }.joined(separator: "\n")
            + "\n\n\n**Full Changelog**: https://github.com/Nachox07/daylit/compare/v1.0.0...v1.0.1\n"
    }

    func testANewerReleaseIsAvailableWithItsPageAndVersion() {
        let a = UpdateCheck.available(running: "1.5.0", releases: [rel("v1.5.1", body("Fix the slider")), rel("v1.5.0")])
        XCTAssertEqual(a?.version, "1.5.1")
        XCTAssertEqual(a?.url, "https://github.com/Nachox07/daylit/releases/tag/v1.5.1")
        XCTAssertEqual(a?.changes, ["Fix the slider"])
    }
    func testWhenTheRunningVersionIsTheLatestNothingIsAvailable() {
        XCTAssertNil(UpdateCheck.available(running: "1.5.1", releases: [rel("v1.5.1", body("A")), rel("v1.5.0", body("B"))]))
    }
    func testANewerRunningVersionSeesNothing() {
        XCTAssertNil(UpdateCheck.available(running: "2.0.0", releases: [rel("v1.5.1")]))
    }
    func testDevBuildsNeverSeeAnUpdate() {
        XCTAssertNil(UpdateCheck.available(running: "0.0.0", releases: [rel("v9.0.0")]))
        XCTAssertNil(UpdateCheck.available(running: nil, releases: [rel("v9.0.0")]))
    }
    func testDraftsPrereleasesAndOddTagsAreSkipped() {
        let a = UpdateCheck.available(running: "1.0.0", releases: [rel("v3.0.0", draft: true), rel("v2.0.0", pre: true),
                                                                   rel("nightly"), rel("v1.1.0", body("Real"))])
        XCTAssertEqual(a?.version, "1.1.0")
        XCTAssertEqual(a?.changes, ["Real"])
    }
    func testSkippingVersionsCollectsEveryNewerReleaseNewestFirst() {
        let list = [rel("v1.4.0", body("Old")), rel("v1.6.0", body("Six a", "Six b")), rel("v1.5.0", body("Five")), rel("v1.3.0", body("Older"))]
        let a = UpdateCheck.available(running: "1.4.0", releases: list)
        XCTAssertEqual(a?.version, "1.6.0")
        XCTAssertEqual(a?.changes, ["Six a", "Six b", "Five"])
    }
    func testAReleaseWithoutAChangesSectionAddsNothing() {
        let a = UpdateCheck.available(running: "1.0.0", releases: [rel("v1.2.0", body("Two")), rel("v1.1.0", "Bug fixes.\n\n## Install\nUnzip it.")])
        XCTAssertEqual(a?.changes, ["Two"])
    }
}

final class UpdateNotesTests: XCTestCase {
    let generated = """
    ## What's Changed
    * Mac: ask for Accessibility once, then wait quietly by @Nachox07 in https://github.com/Nachox07/daylit/pull/70
    * Settings: Instant updates switch for push (both apps) by @Nachox07 in https://github.com/Nachox07/daylit/pull/71


    **Full Changelog**: https://github.com/Nachox07/daylit/compare/v1.5.0...v1.5.1

    ## Install
    * Download the zip
    """

    func testTheBulletsUnderWhatsChangedAreTheChangesWithoutTheirAttribution() {
        XCTAssertEqual(UpdateCheck.changes(body: generated), [
            "Mac: ask for Accessibility once, then wait quietly",
            "Settings: Instant updates switch for push (both apps)",
        ])
    }
    func testWindowsLineEndingsReadTheSame() {
        XCTAssertEqual(UpdateCheck.changes(body: generated.replacingOccurrences(of: "\n", with: "\r\n")).count, 2)
    }
    func testABodyWithoutTheSectionHasNoChanges() {
        XCTAssertEqual(UpdateCheck.changes(body: ""), [])
        XCTAssertEqual(UpdateCheck.changes(body: "Bug fixes.\n* Not under the heading\n## Install\n* Unzip"), [])
    }
    func testTheListEndsAtTheNextHeading() {
        XCTAssertEqual(UpdateCheck.changes(body: "## What's Changed\n* One\n## New Contributors\n* @x made their first contribution"), ["One"])
    }
    func testBulletsWithoutAnAttributionAreKeptAsTheyAre() {
        XCTAssertEqual(UpdateCheck.changes(body: "## What's Changed\n* Faster start\n* Written by hand"), ["Faster start", "Written by hand"])
    }
    func testSeveralAuthorsAreDroppedToo() {
        XCTAssertEqual(UpdateCheck.changes(body: "## What's Changed\n* Shared work by @a and @b in https://github.com/x/y/pull/2"), ["Shared work"])
    }
    func testMalformedTextGivesNoChangesOrOnlyTheBulletsThatAreThere() {
        XCTAssertEqual(UpdateCheck.changes(body: "## What's Changed"), [])
        XCTAssertEqual(UpdateCheck.changes(body: "## What's Changed\n\n\n"), [])
        XCTAssertEqual(UpdateCheck.changes(body: "## What's Changed\n*\n* \n*No space\n* Real"), [])
        XCTAssertEqual(UpdateCheck.changes(body: "##What's changed\n* by @x in https://e.com/1\n* Kept"), ["Kept"])
        XCTAssertEqual(UpdateCheck.changes(body: "\u{0}<script>## What's Changed\n* A"), [])
    }
    func testAVeryLongChangeIsShortened() {
        let c = UpdateCheck.changes(body: "## What's Changed\n* " + String(repeating: "x", count: 500))
        XCTAssertEqual(c.first?.count, 200)
        XCTAssertEqual(c.first?.last, "…")
    }
    func testThePanelShowsEightChangesAndCountsTheRest() {
        let all = (1...11).map { "Change \($0)" }
        let s = UpdateCheck.shown(all)
        XCTAssertEqual(s.items, Array(all.prefix(8)))
        XCTAssertEqual(s.more, 3)
        XCTAssertEqual(UpdateCheck.shown(["One"]).more, 0)
    }
    func testGitHubsAnswerIsReadIntoReleases() throws {
        let json = #"""
        [ { "tag_name": "v1.5.1", "html_url": "https://github.com/Nachox07/daylit/releases/tag/v1.5.1", "draft": false, "prerelease": false, "body": "## What's Changed\n* A" },
          { "tag_name": "v1.6.0-rc1", "html_url": "https://github.com/Nachox07/daylit/releases/tag/v1.6.0-rc1", "prerelease": true, "body": null },
          { "tag_name": "v9.9.9", "html_url": "javascript:alert(1)" },
          { "name": "no tag" } ]
        """#
        let r = try XCTUnwrap(UpdateCheck.releases(json: Data(json.utf8)))
        XCTAssertEqual(r.map(\.tag), ["v1.5.1", "v1.6.0-rc1"])
        XCTAssertEqual(r[1].body, "")
        XCTAssertTrue(r[1].prerelease)
        XCTAssertNil(UpdateCheck.releases(json: Data(#"{"message": "API rate limit exceeded"}"#.utf8)))
        XCTAssertNil(UpdateCheck.releases(json: Data("not json".utf8)))
    }
}

final class UpdateLineTests: XCTestCase {
    let a = UpdateCheck.Available(version: "1.6.0", url: "https://github.com/Nachox07/daylit/releases/tag/v1.6.0", changes: [])

    func testANewVersionShowsTheLine() {
        XCTAssertTrue(UpdateCheck.showLine(a, dismissed: nil, checkUpdates: true, manual: false))
    }
    func testNothingAvailableShowsNothingEvenWhenAsked() {
        XCTAssertFalse(UpdateCheck.showLine(nil, dismissed: nil, checkUpdates: true, manual: true))
    }
    func testNotNowHidesThatVersion() {
        XCTAssertFalse(UpdateCheck.showLine(a, dismissed: "1.6.0", checkUpdates: true, manual: false))
    }
    func testANewerVersionThanTheOnePutOffShowsAgain() {
        XCTAssertTrue(UpdateCheck.showLine(a, dismissed: "1.5.1", checkUpdates: true, manual: false))
    }
    func testWithChecksOffTheLineStaysHidden() {
        XCTAssertFalse(UpdateCheck.showLine(a, dismissed: nil, checkUpdates: false, manual: false))
    }
    func testCheckingFromTheMenuShowsItEvenWhenOffOrPutOff() {
        XCTAssertTrue(UpdateCheck.showLine(a, dismissed: "1.6.0", checkUpdates: false, manual: true))
    }
}

final class UpdateSettingsEditTests: XCTestCase {
    func root(_ e: SettingsEdit, _ original: String?) throws -> [String: Any] {
        let out = try ConfigPatch.apply(e, to: original.map { Data($0.utf8) })
        return try JSONSerialization.jsonObject(with: out) as! [String: Any]
    }
    func edit(_ on: Bool?, editable: Bool = true) -> SettingsEdit {
        var e = SettingsEdit(source: "off")
        e.checkUpdatesEditable = editable; e.checkUpdates = on
        return e
    }

    func testTurningChecksOffWritesFalseAndKeepsTheRest() throws {
        let r = try root(edit(false), #"{ "futureKey": 1 }"#)
        XCTAssertEqual(r["checkUpdates"] as? Bool, false)
        XCTAssertEqual(r["futureKey"] as? Int, 1)
    }
    func testTurningChecksOnRemovesTheKey() throws {
        XCTAssertNil(try root(edit(true), #"{ "checkUpdates": false }"#)["checkUpdates"])
        XCTAssertNil(try root(edit(nil), nil)["checkUpdates"])
    }
    func testTheKeyIsKeptWhenTheWindowDoesNotShowTheSwitch() throws {
        XCTAssertEqual(try root(edit(nil, editable: false), #"{ "checkUpdates": false }"#)["checkUpdates"] as? Bool, false)
    }
    func testASavedOffReadsBackAsOffAndMissingAsDefault() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try ConfigPatch.apply(edit(false), to: nil).write(to: u)
        XCTAssertEqual(Config.load(from: u).0.checkUpdates, false)
        try ConfigPatch.apply(edit(true), to: nil).write(to: u)
        XCTAssertNil(Config.load(from: u).0.checkUpdates)
    }
    func testABrokenConfigStillKeepsChecksOff() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(#"{ "checkUpdates": false, "location": { "latitude": 200, "longitude": 0 } }"#.utf8).write(to: u)
        let (c, err) = Config.load(from: u)
        XCTAssertNotNil(err)
        XCTAssertEqual(c.checkUpdates, false)
    }
}
