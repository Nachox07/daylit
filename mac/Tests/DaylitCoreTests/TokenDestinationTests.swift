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

    func testNothingRememberedRemembersTheCurrentOneWithoutAsking() {
        XCTAssertEqual(TokenDestinationRule.decide(current: d("http://ha.example.local"), remembered: nil), .remember)
    }

    func testTheRememberedDestinationIsSent() {
        XCTAssertEqual(TokenDestinationRule.decide(current: d("http://ha.example.local/"), remembered: d("http://HA.example.local")), .send)
    }

    func testAChangedAddressOrTokenNameAsksFirst() {
        let was = d("http://ha.example.local:8123")
        XCTAssertEqual(TokenDestinationRule.decide(current: d("https://evil.example.com"), remembered: was), .ask)
        XCTAssertEqual(TokenDestinationRule.decide(current: d("http://ha.example.local:8123", "other"), remembered: was), .ask)
    }

    func testNoValidAddressSendsNothing() {
        XCTAssertEqual(TokenDestinationRule.decide(current: nil, remembered: nil), .hold)
        XCTAssertEqual(TokenDestinationRule.decide(current: nil, remembered: d("http://ha.example.local")), .hold)
    }

    func testEditingTheURLInSettingsKeepsTheRememberedTokenName() {
        let now = d("http://new.example.local", "changed-in-the-file")
        let r = TokenDestinationRule.afterURLEdit(current: now, remembered: d("http://old.example.local"))
        XCTAssertEqual(r, d("http://new.example.local"))
        // So a token name changed in the file is still asked about.
        XCTAssertEqual(TokenDestinationRule.decide(current: now, remembered: r), .ask)
        // With nothing remembered the file's name is taken as it is.
        XCTAssertEqual(TokenDestinationRule.afterURLEdit(current: now, remembered: nil), now)
    }

    func testTheQuestionNamesTheNewHostOrTheNewTokenName() {
        let was = d("http://ha.example.local")
        XCTAssertEqual(TokenDestinationRule.question(current: d("https://other.example.local:8123/x"), remembered: was),
                       "Home Assistant address changed to other.example.local. Send the token there?")
        XCTAssertTrue(TokenDestinationRule.question(current: d("http://ha.example.local", "spare"), remembered: was).contains("“spare”"))
    }

    func testTheLogLineNamesTheHostAndNeverAToken() {
        let line = TokenDestinationRule.heldLine(current: d("https://other.example.local"))
        XCTAssertTrue(line.contains("other.example.local"))
        XCTAssertTrue(line.contains("not sending the token"))
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
