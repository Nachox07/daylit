import XCTest
@testable import DaylitCore

/// A keychain in memory that records each step and can be told to fail one.
final class FakeKeychain: TokenKeychain {
    struct Item { var account: String; var ours: Bool; var token: String }
    var store: [Item] = []
    var steps: [String] = []
    var failAdd = false, failDeleteLegacy = false, failRename = false, failLegacyRead = false, failOwnRead = false

    func items(service: String) -> [TokenItem] { store.map { TokenItem(account: $0.account, ours: $0.ours) } }
    func readOwn(service: String, account: String) -> String? {
        steps.append("readOwn \(account)"); if failOwnRead { return nil }; return store.first { $0.ours && $0.account == account }?.token
    }
    func readLegacy(service: String, account: String) -> String? {
        steps.append("readLegacy \(account)")
        return failLegacyRead ? nil : store.first { !$0.ours && $0.account == account }?.token
    }
    func addOwn(service: String, account: String, token: String) -> Bool {
        steps.append("addOwn \(account)")
        guard !failAdd, !store.contains(where: { $0.account == account }) else { return false }
        store.append(Item(account: account, ours: true, token: token)); return true
    }
    func deleteOwn(service: String, account: String) -> Bool {
        steps.append("deleteOwn \(account)"); store.removeAll { $0.ours && $0.account == account }; return true
    }
    func deleteLegacy(service: String, account: String) -> Bool {
        steps.append("deleteLegacy \(account)")
        guard !failDeleteLegacy else { return false }
        store.removeAll { !$0.ours && $0.account == account }; return true
    }
    func renameOwn(service: String, from: String, to: String) -> Bool {
        steps.append("renameOwn \(from) \(to)")
        guard !failRename, let i = store.firstIndex(where: { $0.ours && $0.account == from }),
              !store.contains(where: { $0.account == to }) else { return false }
        store[i].account = to; return true
    }
}

final class TokenKeychainTests: XCTestCase {
    let s = "daylit-home-assistant"
    func legacy() -> FakeKeychain { let k = FakeKeychain(); k.store = [.init(account: "homeassistant", ours: false, token: "T")]; return k }

    func testTheNewItemIsSavedBeforeTheOldOneIsDeleted() {
        let k = legacy()
        XCTAssertEqual(TokenItems.replace(TokenItem(account: "homeassistant", ours: false), with: "T", service: s, in: k), .replaced)
        XCTAssertEqual(k.steps, ["addOwn homeassistant.daylit", "deleteLegacy homeassistant", "renameOwn homeassistant.daylit homeassistant"])
        XCTAssertEqual(k.store.map(\.account), ["homeassistant"])
        XCTAssertTrue(k.store[0].ours)
    }

    func testAFailedAddLeavesTheOldItemAlone() {
        let k = legacy(); k.failAdd = true
        guard case .keptOld = TokenItems.replace(TokenItem(account: "homeassistant", ours: false), with: "T", service: s, in: k) else { return XCTFail() }
        XCTAssertFalse(k.steps.contains { $0.hasPrefix("deleteLegacy") })
        XCTAssertEqual(k.store.count, 1); XCTAssertFalse(k.store[0].ours)
    }

    func testAnOldItemThatCannotBeDeletedStaysAndTheNewOneIsRemoved() {
        let k = legacy(); k.failDeleteLegacy = true
        guard case .keptOld = TokenItems.replace(TokenItem(account: "homeassistant", ours: false), with: "T", service: s, in: k) else { return XCTFail() }
        XCTAssertEqual(k.steps.last, "deleteOwn homeassistant.daylit")
        XCTAssertEqual(k.store.count, 1); XCTAssertFalse(k.store[0].ours)
    }

    func testAFailedRenameStillLeavesOneAppOnlyItem() {
        let k = legacy(); k.failRename = true
        XCTAssertEqual(TokenItems.replace(TokenItem(account: "homeassistant", ours: false), with: "T", service: s, in: k), .replacedUnderTemporaryAccount)
        XCTAssertEqual(k.store.count, 1); XCTAssertTrue(k.store[0].ours)
        var r = TokenReads()
        XCTAssertEqual(r.read(service: s, in: k) { _ in }, "T")
        XCTAssertEqual(k.steps.last, "readOwn homeassistant.daylit")
    }

    func testDaylitsOwnItemIsPickedWhenTwoExist() {
        XCTAssertEqual(TokenItems.pick([TokenItem(account: "a", ours: false), TokenItem(account: "a.daylit", ours: true)]),
                       TokenItem(account: "a.daylit", ours: true))
        XCTAssertEqual(TokenItems.pick([TokenItem(account: "a", ours: false)]), TokenItem(account: "a", ours: false))
        XCTAssertNil(TokenItems.pick([]))
    }

    func testAnOldItemLeftBesideOursIsDeletedOnceAndOursIsRead() {
        let k = FakeKeychain()
        k.store = [.init(account: "homeassistant", ours: false, token: "OLD"), .init(account: "homeassistant.daylit", ours: true, token: "T")]
        var r = TokenReads()
        XCTAssertEqual(r.read(service: s, in: k) { _ in }, "T")
        XCTAssertEqual(k.store.count, 1); XCTAssertTrue(k.store[0].ours)
        XCTAssertFalse(k.steps.contains { $0.hasPrefix("readLegacy") })
    }

    func testAnOldItemBesideAnUnreadableOneOfOursIsKeptAndStillGivesTheToken() {
        let k = FakeKeychain(); k.failOwnRead = true
        k.store = [.init(account: "homeassistant", ours: false, token: "T"), .init(account: "homeassistant.daylit", ours: true, token: "X")]
        var r = TokenReads()
        XCTAssertEqual(r.read(service: s, in: k) { _ in }, "T")
        XCTAssertTrue(k.store.contains { !$0.ours && $0.token == "T" })
    }

    func testAMovedTokenIsReadInProcessAfterwards() {
        let k = legacy()
        var r = TokenReads(), lines: [String] = []
        XCTAssertEqual(r.read(service: s, in: k) { lines.append($0) }, "T")
        XCTAssertEqual(lines, [TokenReads.movedLine])
        k.steps = []
        XCTAssertEqual(r.read(service: s, in: k) { lines.append($0) }, "T")
        XCTAssertEqual(k.steps, ["readOwn homeassistant"])
    }

    func testAFailedMoveIsTriedOnceAndTheTokenIsKeptForTheSession() {
        let k = legacy(); k.failDeleteLegacy = true
        var r = TokenReads(), lines: [String] = []
        XCTAssertEqual(r.read(service: s, in: k) { lines.append($0) }, "T")
        k.steps = []
        for _ in 0..<3 { XCTAssertEqual(r.read(service: s, in: k) { lines.append($0) }, "T") }
        XCTAssertEqual(k.steps, [], "no more keychain or /usr/bin/security calls this launch")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("old keychain item"))
    }

    func testARefusedOldReadIsNotRetriedThisLaunch() {
        let k = legacy(); k.failLegacyRead = true
        var r = TokenReads(), lines: [String] = []
        XCTAssertNil(r.read(service: s, in: k) { lines.append($0) })
        XCTAssertNil(r.read(service: s, in: k) { lines.append($0) })
        XCTAssertEqual(k.steps.filter { $0.hasPrefix("readLegacy") }.count, 1)
        XCTAssertEqual(lines.count, 1)
    }

    func testASavedTokenEndsWhatTheLaunchKnew() {
        let k = legacy(); k.failDeleteLegacy = true
        var r = TokenReads()
        _ = r.read(service: s, in: k) { _ in }
        k.store = [.init(account: "homeassistant", ours: true, token: "NEW")]
        r.saved(service: s)
        XCTAssertEqual(r.read(service: s, in: k) { _ in }, "NEW")
    }

    func testNoItemReadsNothing() {
        var r = TokenReads()
        XCTAssertNil(r.read(service: s, in: FakeKeychain()) { _ in })
    }
}
