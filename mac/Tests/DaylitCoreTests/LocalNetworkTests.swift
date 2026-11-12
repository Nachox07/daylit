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
                  "local", "example.local.com", "2001:db8::1", "", "192.168.1", "192.168.1.300"] {
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

    func testExplicitDenialAlwaysBlocks() {
        XCTAssertTrue(LocalNetworkBlock.isBlocked(errorCode: nil, generalPathSatisfied: false, hostIsLocal: false, deniedReported: true))
        XCTAssertTrue(LocalNetworkBlock.isBlocked(errorCode: -1001, generalPathSatisfied: true, hostIsLocal: true, deniedReported: true))
    }

    func testOfflineErrorOnAWorkingNetworkToALocalHostIsLikelyBlocked() {
        XCTAssertTrue(LocalNetworkBlock.isBlocked(errorCode: -1009, generalPathSatisfied: true, hostIsLocal: true, deniedReported: false))
    }

    func testRealOutagesAreNotBlamedOnMacOS() {
        XCTAssertFalse(LocalNetworkBlock.isBlocked(errorCode: -1009, generalPathSatisfied: false, hostIsLocal: true, deniedReported: false))
        XCTAssertFalse(LocalNetworkBlock.isBlocked(errorCode: -1009, generalPathSatisfied: true, hostIsLocal: false, deniedReported: false))
        XCTAssertFalse(LocalNetworkBlock.isBlocked(errorCode: -1001, generalPathSatisfied: true, hostIsLocal: true, deniedReported: false))
        XCTAssertFalse(LocalNetworkBlock.isBlocked(errorCode: nil, generalPathSatisfied: true, hostIsLocal: true, deniedReported: false))
    }
}
