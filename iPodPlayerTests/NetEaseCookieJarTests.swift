import XCTest
@testable import iPodPlayer

final class NetEaseCookieJarTests: XCTestCase {
    func testParseKeepsEqualsInsideValues() {
        let parsed = NetEaseCookieJar.parse("MUSIC_U=abc==; __csrf=def; os=pc")
        XCTAssertEqual(parsed.map(\.name), ["MUSIC_U", "__csrf", "os"])
        XCTAssertEqual(parsed.first?.value, "abc==")
    }

    func testUpdateMergesJoinedSetCookieHeader() throws {
        let url = try XCTUnwrap(URL(string: "https://music.163.com"))
        let header = "MUSIC_U=new; Path=/; Domain=.music.163.com; Expires=Wed, 21 Oct 2027 07:28:00 GMT, "
            + "__csrf=token; Path=/; Domain=.music.163.com"
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Set-Cookie": header]
        ))
        let updated = try XCTUnwrap(NetEaseCookieJar.update(
            existing: "MUSIC_U=old; os=pc",
            response: response,
            url: url
        ))
        let parsed = NetEaseCookieJar.parse(updated)
        XCTAssertEqual(parsed.first { $0.name == "MUSIC_U" }?.value, "new")
        XCTAssertEqual(parsed.first { $0.name == "__csrf" }?.value, "token")
        XCTAssertEqual(parsed.first { $0.name == "os" }?.value, "pc")
    }

    func testUpdateDeletesExpiredCookie() throws {
        let url = try XCTUnwrap(URL(string: "https://music.163.com"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Set-Cookie": "MUSIC_U=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"]
        ))
        let updated = try XCTUnwrap(NetEaseCookieJar.update(
            existing: "MUSIC_U=old; os=pc",
            response: response,
            url: url
        ))
        XCTAssertNil(NetEaseCookieJar.parse(updated).first { $0.name == "MUSIC_U" })
        XCTAssertEqual(NetEaseCookieJar.parse(updated).first { $0.name == "os" }?.value, "pc")
    }
}
