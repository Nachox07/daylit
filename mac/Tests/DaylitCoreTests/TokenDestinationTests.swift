import XCTest
@testable import DaylitCore

final class TokenDestinationTests: XCTestCase {
    func d(_ url: String, _ name: String? = nil) -> TokenDestination { TokenDestination(url: url, tokenName: name)! }

    func testAddressesThatDifferOnlyInSpellingAreTheSame() {
        XCTAssertEqual(d("http://HA.example.local:8123/"), d("http://ha.example.local:8123"))
        XCTAssertEqual(d("http://ha.example.local"), d("http://ha.example.local:80"))
        XCTAssertEqual(d("https://ha.example.local"), d("https://ha.example.local:443/"))
        XCTAssertEqual(d(" https://ha.example.local/?x=1#y "), d("https://ha.example.local"))
        XCTAssertEqual(d("HTTPS://ha.example.local/ha//"), d("https://ha.example.local/ha"))
    }

    func testSchemeHostPortAndPathEachMakeADifferentAddress() {
        let base = d("http://ha.example.local:8123")
        for other in ["https://ha.example.local:8123", "http://other.example.local:8123", "http://ha.example.local:8124",
                      "http://ha.example.local:8123/ha"] {
            XCTAssertNotEqual(base, d(other), other)
        }
    }

    func testTheTokenNameIsPartOfTheDestinationAndDefaults() {
        XCTAssertEqual(d("http://ha.example.local").tokenName, "daylit-home-assistant")
        XCTAssertEqual(d("http://ha.example.local", " "), d("http://ha.example.local"))
        XCTAssertNotEqual(d("http://ha.example.local", "other"), d("http://ha.example.local"))
    }

    func testAnAddressThatIsNotHttpWithAHostHasNoDestination() {
        for u in ["", "ha.example.local:8123", "ftp://ha.example.local", "http://", "not a url"] {
            XCTAssertNil(TokenDestination(url: u, tokenName: nil), u)
        }
        XCTAssertNil(TokenDestination(url: nil, tokenName: nil))
    }

    func testIPv6HostsKeepTheirBrackets() {
        XCTAssertEqual(d("http://[fd00::5]:8123").url, "http://[fd00::5]:8123")
        XCTAssertEqual(d("http://[fd00::5]:8123").host, "fd00::5")
    }

    func decide(_ current: TokenDestination?, _ remembered: TokenDestination?, stored: Bool = true) -> TokenDestinationRule.Decision {
        TokenDestinationRule.decide(current: current, remembered: remembered) { stored }
    }

    func testAStoredTokenWithNoApprovedAddressAsksFirst() {
        XCTAssertEqual(decide(d("http://ha.example.local"), nil, stored: true), .ask)
        XCTAssertFalse(TokenDestinationRule.allows(.ask))
    }

    func testFirstSetupWithNoTokenNeitherAsksNorRemembers() {
        XCTAssertEqual(decide(d("http://ha.example.local"), nil, stored: false), .noToken)
        XCTAssertFalse(TokenDestinationRule.allows(.noToken), "a token that appears later is still asked about")
        XCTAssertTrue(TokenDestinationRule.allows(.send))
    }

    func testTheKeychainIsOnlyCheckedWhenNothingIsRemembered() {
        var asked = 0
        _ = TokenDestinationRule.decide(current: d("http://ha.example.local"), remembered: d("http://ha.example.local")) { asked += 1; return true }
        _ = TokenDestinationRule.decide(current: nil, remembered: nil) { asked += 1; return true }
        XCTAssertEqual(asked, 0)
    }

    func testTheShownAddressDropsOnlyTheDefaultPort() {
        XCTAssertEqual(d("https://HA.example.local/ha/").shown, "https://ha.example.local/ha")
        XCTAssertEqual(d("http://ha.example.local").shown, "http://ha.example.local")
        XCTAssertEqual(d("http://ha.example.local:8123").shown, "http://ha.example.local:8123")
        XCTAssertEqual(d("https://ha.example.local:80").shown, "https://ha.example.local:80")
        XCTAssertEqual(d("http://[fd00::5]").shown, "http://[fd00::5]")
    }

    func testTheRememberedDestinationIsSent() {
        XCTAssertEqual(decide(d("http://ha.example.local/"), d("http://HA.example.local")), .send)
    }

    func testAChangedAddressOrTokenNameAsksFirst() {
        let was = d("http://ha.example.local:8123")
        XCTAssertEqual(decide(d("https://other.example.com"), was), .ask)
        XCTAssertEqual(decide(d("http://ha.example.local:8123", "other"), was), .ask)
    }

    func testNoValidAddressSendsNothing() {
        XCTAssertEqual(decide(nil, nil), .hold)
        XCTAssertEqual(decide(nil, d("http://ha.example.local")), .hold)
    }

    func testEditingTheURLInSettingsKeepsTheRememberedTokenName() {
        let now = d("http://new.example.local", "changed-in-the-file")
        let r = TokenDestinationRule.afterURLEdit(current: now, remembered: d("http://old.example.local"))
        XCTAssertEqual(r, d("http://new.example.local"))
        // So a token name changed in the file is still asked about.
        XCTAssertEqual(decide(now, r), .ask)
        // With nothing remembered the file's name is taken as it is.
        XCTAssertEqual(TokenDestinationRule.afterURLEdit(current: now, remembered: nil), now)
    }

    func testTheQuestionNamesTheWholeNewAddressOrTheNewTokenName() {
        let was = d("http://ha.example.local")
        XCTAssertEqual(TokenDestinationRule.question(current: d("https://other.example.local:8123/x"), remembered: was),
                       "Home Assistant address changed to https://other.example.local:8123/x. Send the token there?")
        XCTAssertTrue(TokenDestinationRule.question(current: d("http://ha.example.local", "spare"), remembered: was).contains("“spare”"))
    }

    func testTheFirstQuestionAsksWhetherToSendTheTokenAtAll() {
        XCTAssertEqual(TokenDestinationRule.question(current: d("https://ha.example.local"), remembered: nil),
                       "Send this Mac’s Home Assistant token to https://ha.example.local?")
    }

    func testTheLogLineNamesTheHostAndNeverAToken() {
        for was in [d("http://ha.example.local"), nil] {
            let line = TokenDestinationRule.heldLine(current: d("https://other.example.local"), remembered: was)
            XCTAssertTrue(line.contains("other.example.local"))
            XCTAssertTrue(line.contains("not sending the token"))
        }
    }

    func testNotNowHidesTheQuestionForAnHourForThatDestinationOnly() {
        let cur = d("https://other.example.local")
        XCTAssertTrue(TokenDestinationRule.showQuestion(current: cur, dismissed: nil, dismissedAt: nil, now: 1000))
        XCTAssertFalse(TokenDestinationRule.showQuestion(current: cur, dismissed: cur, dismissedAt: 1000, now: 1000 + 3599))
        XCTAssertTrue(TokenDestinationRule.showQuestion(current: cur, dismissed: cur, dismissedAt: 1000, now: 1000 + 3600))
        XCTAssertTrue(TokenDestinationRule.showQuestion(current: d("https://third.example.local"), dismissed: cur, dismissedAt: 1000, now: 1001))
        XCTAssertTrue(TokenDestinationRule.showQuestion(current: cur, dismissed: cur, dismissedAt: 1000, now: 500), "clock moved back")
    }
}
