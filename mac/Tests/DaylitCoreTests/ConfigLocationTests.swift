import XCTest
@testable import DaylitCore

/// A made-up home folder per test: no real iCloud, no real config.
final class ConfigLocationTests: XCTestCase {
    var home: URL!
    let fm = FileManager.default
    let sun = Data(#"{ "source": "sun", "location": { "latitude": 51.48, "longitude": 0.0 } }"#.utf8)
    let off = Data(#"{ "source": "off" }"#.utf8)

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("daylit-home-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    func loc(_ env: [String: String] = [:]) -> ConfigLocation { ConfigLocation(home: home, environment: env) }
    func turnOnICloudDrive() throws { try fm.createDirectory(at: loc().iCloudDrive, withIntermediateDirectories: true) }
    func put(_ d: Data, _ u: URL) throws {
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: u)
    }
    func read(_ u: URL) -> Data? { try? Data(contentsOf: u) }

    func testThePathsAreUnderTheHomeFolder() {
        XCTAssertEqual(loc().local.path, home.path + "/.config/daylit/config.json")
        XCTAssertEqual(loc().iCloud.path, home.path + "/Library/Mobile Documents/com~apple~CloudDocs/Daylit/config.json")
        XCTAssertEqual(loc().backup.path, home.path + "/.config/daylit/config.local-backup.json")
    }

    func testWithoutICloudDriveTheSwitchIsBlockedAndTheLocalFileIsUsed() {
        XCTAssertFalse(loc().iCloudAvailable)
        XCTAssertNotNil(loc().iCloudBlocked)
        XCTAssertEqual(loc().path(useICloud: true), loc().local)
        XCTAssertThrowsError(try loc().moveToICloud()) { XCTAssertEqual($0 as? ConfigLocation.MoveError, .noICloudDrive) }
    }

    func testWithICloudDriveTheSwitchPicksTheFile() throws {
        try turnOnICloudDrive()
        XCTAssertNil(loc().iCloudBlocked)
        XCTAssertEqual(loc().path(useICloud: true), loc().iCloud)
        XCTAssertEqual(loc().path(useICloud: false), loc().local)
    }

    func testDaylitConfigWinsAndBlocksTheSwitch() throws {
        try turnOnICloudDrive()
        let l = loc(["DAYLIT_CONFIG": "/somewhere/else.json"])
        XCTAssertEqual(l.path(useICloud: true).path, "/somewhere/else.json")
        XCTAssertNotNil(l.iCloudBlocked)
        XCTAssertThrowsError(try l.moveToICloud())
        XCTAssertThrowsError(try l.moveToLocal())
    }

    func testAnEmptyDaylitConfigIsIgnored() {
        XCTAssertEqual(loc(["DAYLIT_CONFIG": ""]).path(useICloud: false), loc().local)
    }

    func testTheFirstMacCopiesItsFileToICloud() throws {
        try turnOnICloudDrive()
        try put(sun, loc().local)
        XCTAssertEqual(try loc().moveToICloud(), .copiedLocal)
        XCTAssertEqual(read(loc().iCloud), sun)
        XCTAssertEqual(read(loc().local), sun, "the local file stays")
        XCTAssertFalse(fm.fileExists(atPath: loc().backup.path))
    }

    func testWithNoFileAnywhereNothingIsCreated() throws {
        try turnOnICloudDrive()
        XCTAssertEqual(try loc().moveToICloud(), .empty)
        XCTAssertEqual(ConfigLocation.state(of: loc().iCloud), .missing)
    }

    func testTheSecondMacAdoptsTheICloudCopyAndBacksUpItsOwn() throws {
        try turnOnICloudDrive()
        try put(sun, loc().iCloud)
        try put(off, loc().local)
        XCTAssertEqual(try loc().moveToICloud(), .adopted(backedUp: true, downloading: false))
        XCTAssertEqual(read(loc().iCloud), sun, "the iCloud copy is not overwritten")
        XCTAssertEqual(read(loc().backup), off)
    }

    func testTheSameFileNeedsNoBackup() throws {
        try turnOnICloudDrive()
        try put(sun, loc().iCloud)
        try put(sun, loc().local)
        XCTAssertEqual(try loc().moveToICloud(), .adopted(backedUp: false, downloading: false))
        XCTAssertFalse(fm.fileExists(atPath: loc().backup.path))
    }

    func testAnEvictedICloudCopyIsAdoptedAndTheLocalFileKept() throws {
        try turnOnICloudDrive()
        try put(Data(), ConfigLocation.placeholder(for: loc().iCloud))
        try put(off, loc().local)
        XCTAssertEqual(ConfigLocation.state(of: loc().iCloud), .evicted)
        XCTAssertEqual(try loc().moveToICloud(), .adopted(backedUp: true, downloading: true))
        XCTAssertEqual(read(loc().backup), off)
        XCTAssertEqual(ConfigLocation.state(of: loc().iCloud), .evicted, "the placeholder is not replaced")
    }

    func testThePlaceholderNameIsICloudDrives() {
        XCTAssertEqual(ConfigLocation.placeholder(for: URL(fileURLWithPath: "/a/Daylit/config.json")).path, "/a/Daylit/.config.json.icloud")
    }

    func testTurningOffCopiesTheICloudFileBackAndLeavesIt() throws {
        try turnOnICloudDrive()
        try put(sun, loc().iCloud)
        try put(off, loc().local)
        XCTAssertEqual(try loc().moveToLocal(), .copiedBack)
        XCTAssertEqual(read(loc().local), sun)
        XCTAssertEqual(read(loc().iCloud), sun, "the other Macs keep theirs")
    }

    func testTurningOffCreatesTheLocalFolder() throws {
        try turnOnICloudDrive()
        try put(sun, loc().iCloud)
        XCTAssertEqual(try loc().moveToLocal(), .copiedBack)
        XCTAssertEqual(read(loc().local), sun)
    }

    func testTurningOffWithNoICloudFileKeepsTheLocalOne() throws {
        try turnOnICloudDrive()
        try put(off, loc().local)
        XCTAssertEqual(try loc().moveToLocal(), .nothingThere)
        XCTAssertEqual(read(loc().local), off)
    }

    func testTurningOffWaitsForAnEvictedCopy() throws {
        try turnOnICloudDrive()
        try put(Data(), ConfigLocation.placeholder(for: loc().iCloud))
        try put(off, loc().local)
        XCTAssertThrowsError(try loc().moveToLocal()) { XCTAssertEqual($0 as? ConfigLocation.MoveError, .notDownloaded) }
        XCTAssertEqual(read(loc().local), off)
    }

    func testTheStampChangesWhenTheFileIsReplacedAtomically() throws {
        let u = loc().local
        XCTAssertEqual(ConfigLocation.stamp(of: u).state, .missing)
        try put(sun, u)
        let before = ConfigLocation.stamp(of: u)
        XCTAssertEqual(before.state, .present)
        // Same size and modification time: only the inode tells them apart, as when iCloud renames a new copy in.
        let tmp = u.deletingLastPathComponent().appendingPathComponent("new.json")
        try sun.write(to: tmp)
        try fm.setAttributes([.modificationDate: before.modified!], ofItemAtPath: tmp.path)
        _ = try fm.replaceItemAt(u, withItemAt: tmp)
        XCTAssertNotEqual(ConfigLocation.stamp(of: u), before)
        XCTAssertEqual(ConfigLocation.stamp(of: u), ConfigLocation.stamp(of: u))
    }

    func testTheStampSeesEviction() throws {
        let u = loc().iCloud
        try put(Data(), ConfigLocation.placeholder(for: u))
        XCTAssertEqual(ConfigLocation.stamp(of: u).state, .evicted)
    }

    // MARK: reloading

    func testABrokenFileKeepsTheLastGoodConfig() throws {
        let u = loc().iCloud
        try put(sun, u)
        let first = Config.reload(from: u, lastGood: nil)
        XCTAssertEqual(first.config.source, "sun"); XCTAssertNil(first.problem); XCTAssertFalse(first.kept)
        try put(Data(#"{ "source": "#.utf8), u)
        let r = Config.reload(from: u, lastGood: first.config)
        XCTAssertTrue(r.kept)
        XCTAssertEqual(r.config.source, "sun")
        XCTAssertTrue(r.problem?.hasPrefix("config.json is not valid") == true, r.problem ?? "")
    }

    func testABrokenFileWithNothingBeforeGivesTheDefaults() throws {
        try put(Data("[".utf8), loc().local)
        let r = Config.reload(from: loc().local, lastGood: nil)
        XCTAssertFalse(r.kept); XCTAssertNil(r.config.source); XCTAssertNotNil(r.problem)
    }

    func testAnEvictedFileKeepsTheLastGoodConfig() throws {
        let u = loc().iCloud
        try put(Data(), ConfigLocation.placeholder(for: u))
        var last = Config(); last.source = "sun"
        let r = Config.reload(from: u, lastGood: last)
        XCTAssertTrue(r.kept); XCTAssertEqual(r.config.source, "sun"); XCTAssertNotNil(r.problem)
    }

    func testAValidButWrongFileIsUsedSafelyNotKeptAside() throws {
        try put(Data(#"{ "source": "sun", "homeAssistant": { "url": "file:///x" } }"#.utf8), loc().local)
        var last = Config(); last.source = "off"
        let r = Config.reload(from: loc().local, lastGood: last)
        XCTAssertFalse(r.kept, "validation problems follow load: safe parts only")
        XCTAssertNil(r.config.homeAssistant)
        XCTAssertNotNil(r.problem)
    }

    func testADeletedFileMeansNoConfig() {
        var last = Config(); last.source = "sun"
        let r = Config.reload(from: loc().local, lastGood: last)
        XCTAssertFalse(r.kept); XCTAssertNil(r.config.source); XCTAssertNil(r.problem)
    }
}

final class DataForPatchTests: XCTestCase {
    func testMissingEvictedAndPresent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daylit-patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("config.json")
        XCTAssertNil(try ConfigLocation.dataForPatch(at: f))
        try Data().write(to: ConfigLocation.placeholder(for: f))
        XCTAssertThrowsError(try ConfigLocation.dataForPatch(at: f)) { XCTAssertEqual($0 as? ConfigLocation.ReadError, .downloading) }
        try Data("{}".utf8).write(to: f)
        XCTAssertEqual(try ConfigLocation.dataForPatch(at: f), Data("{}".utf8))
        try FileManager.default.removeItem(at: f)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: false)   // exists but cannot be read as a file
        XCTAssertThrowsError(try ConfigLocation.dataForPatch(at: f)) {
            if case ConfigLocation.ReadError.unreadable = $0 {} else { XCTFail("expected unreadable, got \($0)") }
        }
    }
}

final class OpenedTests: XCTestCase {
    func testWhatTheWindowSawAndWhenItChanged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daylit-opened-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("config.json")
        XCTAssertEqual(ConfigLocation.open(at: f), .file(nil))
        try Data().write(to: ConfigLocation.placeholder(for: f))
        let evicted = ConfigLocation.open(at: f)
        XCTAssertEqual(evicted, .blocked("config.json is still downloading from iCloud Drive"))
        XCTAssertEqual(evicted.blockedReason, "config.json is still downloading from iCloud Drive")
        XCTAssertNil(evicted.data)
        try Data("{}".utf8).write(to: f)   // the download finished
        XCTAssertNotEqual(ConfigLocation.open(at: f), evicted)
        XCTAssertEqual(ConfigLocation.open(at: f).data, Data("{}".utf8))
        try FileManager.default.removeItem(at: f)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: false)
        let bad = ConfigLocation.open(at: f)
        XCTAssertTrue(bad.blockedReason?.hasPrefix("config.json could not be read (") == true)
    }
}
