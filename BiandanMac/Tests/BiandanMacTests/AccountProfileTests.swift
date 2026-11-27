import XCTest
@testable import BiandanMac

/// 账户昵称和头像：id_token 和华为帐号「获取用户信息」两种来源。
final class AccountProfileTests: XCTestCase {
    func testFromUserInfo() {
        let reply: JSONObject = ["displayName": .string(" 小黄 "), "headPictureURL": .string("https://example.com/a.jpg")]
        XCTAssertEqual(AccountProfile.from(userInfo: reply),
                       AccountProfile(displayName: "小黄", avatarURL: "https://example.com/a.jpg"))
    }

    func testUserInfoWithoutPicture() {
        let reply: JSONObject = ["displayName": .string("小黄"), "headPictureURL": .string("")]
        XCTAssertEqual(AccountProfile.from(userInfo: reply)?.avatarURL, nil)
    }

    func testUserInfoWithoutNameIsIgnored() {
        XCTAssertNil(AccountProfile.from(userInfo: ["error": .string("invalid token")]))
        XCTAssertNil(AccountProfile.from(userInfo: ["displayName": .string("  ")]))
    }

    func testFromIDToken() {
        let payload = Data(#"{"display_name":"小黄","picture":"https://example.com/p.png"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let profile = AccountProfile.from(idToken: "e30." + payload + ".sig")
        XCTAssertEqual(profile, AccountProfile(displayName: "小黄", avatarURL: "https://example.com/p.png"))
    }
}
