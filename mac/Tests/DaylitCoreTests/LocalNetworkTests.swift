import XCTest
@testable import DaylitCore

final class LocalNetworkTests: XCTestCase {
    func testPrivateAndLinkLocalAddressesAreLocal() {
        for h in ["192.168.1.10", "192.168.0.1", "10.0.0.5", "10.255.1.1", "172.16.0.1", "172.31.255.254", "169.254.3.4",
                  "ha.local", "homeassistant.local.", "HA.LOCAL", "fe80::1", "FE80::abcd:1", "fd12:3456::1", "fc00::1"] {
            XCTAssertTrue(LocalHost.isLocal(h), h)
        }
    }

    func testPublicHostsAndCloudUrlsAreNotLocal() {
        for h in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "11.0.0.1", "192.169.1.1", "ha.example.com", "abcdef.ui.nabu.casa",
                  "example.local.com", "2001:db8::1", "", "192.168.1", "192.168.1.300"] {
            XCTAssertFalse(LocalHost.isLocal(h), h)
        }
    }

    func testHostIsReadFromAUrl() {
        XCTAssertTrue(LocalHost.isLocal(url: "http://192.168.1.5:8123"))
        XCTAssertTrue(LocalHost.isLocal(url: "http://[fe80::1]:8123/"))
        XCTAssertTrue(LocalHost.isLocal(url: "https://ha.local:8123/api"))
        XCTAssertFalse(LocalHost.isLocal(url: "https://example.ui.nabu.casa"))
        XCTAssertFalse(LocalHost.isLocal(url: "not a url"))
        XCTAssertFalse(LocalHost.isLocal(url: nil))
    }

    func testDotlessHomeArpaLanAndMappedIPv6AreLocal() {
        for h in ["homeassistant", "ha.home.arpa", "ha.lan", "HA.LAN", "::ffff:192.168.1.5", "::ffff:10.0.0.1", "[::ffff:172.20.0.1]", "::ffff:c0a8:0105"] {
            XCTAssertTrue(LocalHost.isLocal(h), h)
        }
        XCTAssertTrue(LocalHost.isLocal(url: "http://homeassistant:8123"))
        for h in ["::ffff:8.8.8.8", "::ffff:808:808", "12345", "home.arpa.example.com", "lan"] {
            XCTAssertFalse(LocalHost.isLocal(h), h)
        }
    }

    func testDeniedProbeAlwaysBlocks() {
        XCTAssertTrue(LocalNetworkBlock.isBlocked(errorCode: nil, generalPathSatisfied: false, hostIsLocal: false, probe: .denied))
        XCTAssertTrue(LocalNetworkBlock.isBlocked(errorCode: -1001, generalPathSatisfied: true, hostIsLocal: true, probe: .denied))
    }

    func testOfflineErrorWithAnUnknownProbeOnAWorkingNetworkToALocalHostIsLikelyBlocked() {
        XCTAssertTrue(LocalNetworkBlock.isBlocked(errorCode: -1009, generalPathSatisfied: true, hostIsLocal: true, probe: .unknown))
    }

    func testAProbeThatSaidNotDeniedOverridesTheGuess() {
        XCTAssertFalse(LocalNetworkBlock.isBlocked(errorCode: -1009, generalPathSatisfied: true, hostIsLocal: true, probe: .notDenied))
    }

    func testRealOutagesAreNotBlamedOnMacOS() {
        XCTAssertFalse(LocalNetworkBlock.isBlocked(errorCode: -1009, generalPathSatisfied: false, hostIsLocal: true, probe: .unknown))
        XCTAssertFalse(LocalNetworkBlock.isBlocked(errorCode: -1009, generalPathSatisfied: true, hostIsLocal: false, probe: .unknown))
        XCTAssertFalse(LocalNetworkBlock.isBlocked(errorCode: -1001, generalPathSatisfied: true, hostIsLocal: true, probe: .unknown))
        XCTAssertFalse(LocalNetworkBlock.isBlocked(errorCode: nil, generalPathSatisfied: true, hostIsLocal: true, probe: .unknown))
    }
}
