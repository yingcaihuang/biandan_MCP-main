import Foundation
import XCTest
@testable import BiandanMac

final class RenewalTests: XCTestCase {
    private func base64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testJWTExpiry() {
        let token = base64url(#"{"alg":"none"}"#) + "." + base64url(#"{"sub":"x","exp":1800000000}"#) + ".sig"
        XCTAssertEqual(RenewalStatus.jwtExpiry(token), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(RenewalStatus.jwtExpiry("opaque-refresh-token"))
        XCTAssertNil(RenewalStatus.jwtExpiry("a.b"))
        XCTAssertNil(RenewalStatus.jwtExpiry(nil))
        let noExp = base64url("{}") + "." + base64url(#"{"sub":"x"}"#) + ".sig"
        XCTAssertNil(RenewalStatus.jwtExpiry(noExp))
    }

    func testLegacyCredentialDecodesWithoutIssuedAt() throws {
        let legacy = #"{"refresh_token":"abc","device_grant":"def"}"#
        let credential = try JSONDecoder().decode(StoredCredential.self, from: Data(legacy.utf8))
        XCTAssertEqual(credential.refreshToken, "abc")
        XCTAssertNil(credential.refreshIssuedAt)
        var updated = credential
        updated.refreshIssuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let round = try JSONDecoder().decode(StoredCredential.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(round, updated)
    }

    func testReloginUsesEarlierLimit() {
        let issued = date("2026-11-20T14:45:02Z")
        var status = RenewalStatus(refreshIssuedAt: issued)
        XCTAssertEqual(status.reloginLimit?.limit, .refreshEstimate)
        XCTAssertEqual(status.reloginBy, issued.addingTimeInterval(180 * 86_400))
        XCTAssertEqual(status.daysUntilRelogin(now: issued, calendar: shanghai), 180)

        status.deviceGrantExpiry = date("2027-01-01T00:00:00Z")
        XCTAssertEqual(status.reloginLimit?.limit, .deviceGrant)
        status.deviceGrantExpiry = date("2028-01-01T00:00:00Z")
        XCTAssertEqual(status.reloginLimit?.limit, .refreshEstimate)

        XCTAssertNil(RenewalStatus().reloginLimit)
        XCTAssertNil(RenewalStatus().daysUntilRelogin(now: issued))
    }

    func testNextRenewalText() {
        let now = date("2026-11-20T14:00:00Z")
        XCTAssertEqual(RenewalText.nextRenewal(nil, now: now), "下次访问云端时续期")
        let soon = RenewalStatus(nextRenewalAt: now.addingTimeInterval(29.5 * 60))
        XCTAssertTrue(RenewalText.nextRenewal(soon, now: now).hasPrefix("约 30 分钟后（"))
        XCTAssertEqual(RenewalText.nextRenewalShort(soon, now: now), "30 分钟后")
        let later = RenewalStatus(nextRenewalAt: now.addingTimeInterval(65 * 60))
        XCTAssertEqual(RenewalText.nextRenewalShort(later, now: now), "1 小时 5 分后")
        let past = RenewalStatus(nextRenewalAt: now.addingTimeInterval(-10))
        XCTAssertEqual(RenewalText.nextRenewal(past, now: now), "下次访问云端时续期")
    }

    func testReloginTexts() {
        XCTAssertEqual(RenewalText.reloginValue(days: nil), "通常 180 天")
        XCTAssertEqual(RenewalText.reloginValue(days: 179), "179 天后")
        XCTAssertEqual(RenewalText.reloginValue(days: 0), "今天")
        XCTAssertEqual(RenewalText.reloginValue(days: -3), "已到期")
        XCTAssertEqual(RenewalText.cardStatus(days: 179).text, "自动续期 · 剩 179 天")
        XCTAssertEqual(RenewalText.cardStatus(days: 10).text, "剩 10 天需重新登录")
        XCTAssertEqual(RenewalText.cardStatus(days: 0).text, "需要重新登录")
        XCTAssertNil(RenewalText.tint(days: 30))
        XCTAssertNotNil(RenewalText.tint(days: 14))
    }
}
