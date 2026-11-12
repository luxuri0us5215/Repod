import XCTest
@testable import iPodPlayer

final class NetEaseDirectRouteTests: XCTestCase {
    func testCloudsearchBuildsWeapiRequest() throws {
        let request = try XCTUnwrap(try NetEaseDirectRoute.makeRequest(
            path: "/cloudsearch",
            parameters: ["keywords": "周杰伦", "type": "1", "limit": "5", "offset": "0"],
            cookie: "",
            timeout: 10
        ))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "music.163.com")
        XCTAssertEqual(request.url?.path, "/weapi/cloudsearch/pc")
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("params="))
        XCTAssertTrue(body.contains("encSecKey="))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://music.163.com/")
    }

    func testArtistPathCarriesID() throws {
        let request = try XCTUnwrap(try NetEaseDirectRoute.makeRequest(
            path: "/artists",
            parameters: ["id": "6452"],
            cookie: "",
            timeout: 10
        ))
        XCTAssertEqual(request.url?.path, "/weapi/v1/artist/6452")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testSongURLUsesLegacyGET() throws {
        let request = try XCTUnwrap(try NetEaseDirectRoute.makeRequest(
            path: "/song/url",
            parameters: ["ids": "123,456"],
            cookie: "MUSIC_U=abc",
            timeout: 10
        ))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/song/enhance/player/url")
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "ids" }?.value, "[\"123\",\"456\"]")
        XCTAssertEqual(components?.queryItems?.first { $0.name == "br" }?.value, "128000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "MUSIC_U=abc")
    }

    func testLikeBuildsRadioLikeRequest() throws {
        let deviceId = NetEaseDeviceID.generate()
        let request = try XCTUnwrap(try NetEaseDirectRoute.makeRequest(
            path: "/like",
            parameters: ["id": "123", "like": "true"],
            cookie: "MUSIC_U=abc",
            deviceId: deviceId,
            timeout: 10
        ))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/weapi/radio/like")
        let cookie = try XCTUnwrap(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(cookie.contains("MUSIC_U=abc"))
        XCTAssertTrue(cookie.contains("os=pc"))
        XCTAssertTrue(cookie.contains("appver=3.1.17.204416"))
        XCTAssertTrue(cookie.contains("deviceId=\(deviceId)"))
        XCTAssertTrue(cookie.contains("channel=netease"))
    }

    /// 3.1.13: `/weapi/radio/like` answers -460 to a Cookie that carries only the
    /// session bits. Every weapi request now names the desktop client.
    func testIdentityCookieFillsMissingClientFields() {
        let deviceId = NetEaseDeviceID.generate()
        let cookie = NetEaseDirectRoute.identityCookie(
            existing: "MUSIC_U=abc; __csrf=def",
            deviceId: deviceId
        )
        let parsed = Dictionary(uniqueKeysWithValues: NetEaseCookieJar.parse(cookie).map { ($0.name, $0.value) })
        XCTAssertEqual(parsed["MUSIC_U"], "abc")
        XCTAssertEqual(parsed["__csrf"], "def")
        XCTAssertEqual(parsed["os"], "pc")
        XCTAssertEqual(parsed["appver"], "3.1.17.204416")
        XCTAssertEqual(parsed["osver"], "Microsoft-Windows-10-Professional-build-19045-64bit")
        XCTAssertEqual(parsed["channel"], "netease")
        XCTAssertEqual(parsed["deviceId"], deviceId)
        XCTAssertEqual(parsed["__remember_me"], "true")
        XCTAssertEqual(parsed["ntes_kaola_ad"], "1")
        XCTAssertEqual(parsed["WEVNSM"], "1.0.0")
        XCTAssertEqual(parsed["_ntes_nuid"]?.count, 32)
        XCTAssertTrue(parsed["_ntes_nnid"]?.hasPrefix(parsed["_ntes_nuid"]! + ",") ?? false)
        XCTAssertFalse(parsed["WNMCID"]?.isEmpty ?? true)
        // No duplicate names: a repeated Cookie key makes some gateways read the wrong one.
        let names = NetEaseCookieJar.parse(cookie).map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testIdentityCookieKeepsIdentityFromLogin() {
        let cookie = NetEaseDirectRoute.identityCookie(
            existing: "MUSIC_U=abc; os=pc; appver=9.9.9; deviceId=DEADBEEF; _ntes_nuid=feedface",
            deviceId: NetEaseDeviceID.generate()
        )
        let parsed = Dictionary(uniqueKeysWithValues: NetEaseCookieJar.parse(cookie).map { ($0.name, $0.value) })
        XCTAssertEqual(parsed["appver"], "9.9.9")
        XCTAssertEqual(parsed["deviceId"], "DEADBEEF")
        XCTAssertEqual(parsed["_ntes_nuid"], "feedface")
        XCTAssertTrue(parsed["_ntes_nnid"]?.hasPrefix("feedface,") ?? false)
    }

    @MainActor
    func testScrobbleRejectsIncompleteParameters() async {
        let transport = NetEaseDirectTransport(session: URLSession(configuration: .ephemeral))
        do {
            _ = try await transport.send(
                path: "/scrobble",
                parameters: ["id": "123"],
                cookie: "",
                timeout: 5
            )
            XCTFail("Scrobble without a positive time must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("参数不完整"))
        }
    }

    @MainActor
    func testQRCreateIsAnsweredLocally() async throws {
        let transport = NetEaseDirectTransport(session: URLSession(configuration: .ephemeral))
        let response = try await transport.send(
            path: "/login/qr/create",
            parameters: ["key": "abc123"],
            cookie: "",
            timeout: 5
        )
        XCTAssertEqual(response.statusCode, 200)
        let data = response.body?["data"] as? [String: Any]
        let url = try XCTUnwrap(data?["qrurl"] as? String)
        XCTAssertTrue(url.hasPrefix("https://music.163.com/login?codekey=abc123&chainId=v1_"))
        XCTAssertTrue(url.contains("_pc_login_"))
    }

    /// 3.1.12: the old weapi type=1 QR login is refused with 8821 after the scan.
    func testQRLoginUsesPCClientEapi() throws {
        let deviceId = NetEaseDeviceID.generate()
        XCTAssertTrue(NetEaseDeviceID.isValid(deviceId))
        let request = try XCTUnwrap(NetEaseDirectRoute.qrLoginRequest(
            path: "/login/qr/check",
            parameters: ["key": "abc123"],
            cookie: "",
            deviceId: deviceId,
            timeout: 5
        ))
        XCTAssertEqual(request.url?.absoluteString,
                       "https://interfacepc.music.163.com/eapi/login/qrcode/client/login")
        XCTAssertEqual(request.httpMethod, "POST")
        let cookie = try XCTUnwrap(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(cookie.contains("os=pc"))
        XCTAssertTrue(cookie.contains("deviceId=\(deviceId)"))
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.hasPrefix("params="))

        let key = try XCTUnwrap(NetEaseDirectRoute.qrLoginRequest(
            path: "/login/qr/key", parameters: [:], cookie: "", deviceId: deviceId, timeout: 5
        ))
        XCTAssertEqual(key.url?.absoluteString,
                       "https://interfacepc.music.163.com/eapi/login/qrcode/unikey")
        XCTAssertNil(try NetEaseDirectRoute.qrLoginRequest(
            path: "/cloudsearch", parameters: [:], cookie: "", deviceId: deviceId, timeout: 5
        ))
    }

    func testCookieJarAcceptsCookiesScopedToAnotherMusicHost() throws {
        let url = try XCTUnwrap(URL(string: "https://interfacepc.music.163.com/eapi/login/qrcode/client/login"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Set-Cookie": "MUSIC_U=abc; Max-Age=15552000; Domain=music.163.com; Path=/; HTTPOnly, __csrf=def; Max-Age=1296010; Domain=.music.163.com; Path=/"
        ]))
        let updated = try XCTUnwrap(NetEaseCookieJar.update(existing: "", response: response, url: url))
        let parsed = NetEaseCookieJar.parse(updated)
        XCTAssertEqual(parsed.first { $0.name == "MUSIC_U" }?.value, "abc")
        XCTAssertEqual(parsed.first { $0.name == "__csrf" }?.value, "def")
    }

    /// Network probe. It is skipped by default so the suite stays deterministic;
    /// set `REPOD_LIVE_DIRECT=1` in the scheme's test environment to run it.
    /// Full client stack check: the direct transport feeds the same parser and
    /// playback resolver the UI uses. Read-only.
    @MainActor
    func testClientDirectSearchAndPlayback() async throws {
        guard ProcessInfo.processInfo.environment["REPOD_LIVE_DIRECT"] == "1" else {
            throw XCTSkip("Set REPOD_LIVE_DIRECT=1 to run the live direct probe.")
        }
        let client = NetEaseClient(mode: .direct, baseURL: "")
        let page = try await client.search(query: "周杰伦", offset: 0)
        XCTAssertFalse(page.tracks.isEmpty)
        guard let track = page.tracks.first else { return }
        let resolved = try await client.playbackTrack(track)
        XCTAssertNotNil(resolved.streamURL)
    }

    /// Read-only check of the logged-in routes. Uses whatever cookie the app has
    /// already stored; never mutates likes or play counts.
    @MainActor
    func testLiveLoggedInReadOnlyWhenCookieExists() async throws {
        guard ProcessInfo.processInfo.environment["REPOD_LIVE_DIRECT"] == "1" else {
            throw XCTSkip("Set REPOD_LIVE_DIRECT=1 to run the live direct probe.")
        }
        guard let cookie = try? NetEaseCookieKeychain.read(), !cookie.isEmpty else {
            throw XCTSkip("No saved NetEase cookie on this simulator.")
        }
        let transport = NetEaseDirectTransport(session: URLSession(configuration: .ephemeral))
        let status = try await transport.send(
            path: "/login/status",
            parameters: [:],
            cookie: cookie,
            timeout: 15
        )
        let statusCode = (status.body?["code"] as? NSNumber)?.intValue
        XCTAssertEqual(statusCode, 200)
        let profile = status.body?["profile"] as? [String: Any]
        let account = status.body?["account"] as? [String: Any]
        let uid = (profile?["userId"] as? NSNumber)?.stringValue
            ?? (account?["id"] as? NSNumber)?.stringValue
        let userID = try XCTUnwrap(uid)

        let playlists = try await transport.send(
            path: "/user/playlist",
            parameters: ["uid": userID, "limit": "5", "offset": "0"],
            cookie: cookie,
            timeout: 15
        )
        XCTAssertEqual((playlists.body?["code"] as? NSNumber)?.intValue, 200)

        let likes = try await transport.send(
            path: "/likelist",
            parameters: ["uid": userID],
            cookie: cookie,
            timeout: 15
        )
        XCTAssertEqual((likes.body?["code"] as? NSNumber)?.intValue, 200)

        let list = playlists.body?["playlist"] as? [[String: Any]]
        if let first = list?.first, let playlistID = (first["id"] as? NSNumber)?.stringValue {
            let tracks = try await transport.send(
                path: "/playlist/track/all",
                parameters: ["id": playlistID, "limit": "5", "offset": "0"],
                cookie: cookie,
                timeout: 20
            )
            XCTAssertEqual((tracks.body?["code"] as? NSNumber)?.intValue, 200)
            let songs = tracks.body?["songs"] as? [[String: Any]]
            XCTAssertFalse(songs?.isEmpty ?? true)
        }
    }

    @MainActor
    func testLiveAnonymousSearchAndSongURL() async throws {
        guard ProcessInfo.processInfo.environment["REPOD_LIVE_DIRECT"] == "1" else {
            throw XCTSkip("Set REPOD_LIVE_DIRECT=1 to run the live direct probe.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let transport = NetEaseDirectTransport(session: URLSession(configuration: configuration))

        let search = try await transport.send(
            path: "/cloudsearch",
            parameters: ["keywords": "周杰伦", "type": "1", "limit": "5", "offset": "0"],
            cookie: "",
            timeout: 15
        )
        let searchCode = (search.body?["code"] as? NSNumber)?.intValue
        XCTAssertEqual(searchCode, 200)
        let result = search.body?["result"] as? [String: Any]
        let songs = result?["songs"] as? [[String: Any]]
        XCTAssertFalse(songs?.isEmpty ?? true)

        // 2668397359 is the public-domain-friendly track the endpoint probe confirmed
        // returns a real 128 kbps URL without a login.
        let address = try await transport.send(
            path: "/song/url",
            parameters: ["ids": "2668397359"],
            cookie: "",
            timeout: 15
        )
        let addressCode = (address.body?["code"] as? NSNumber)?.intValue
        XCTAssertEqual(addressCode, 200)
        let data = address.body?["data"] as? [[String: Any]]
        let url = data?.first?["url"] as? String
        XCTAssertNotNil(url)

        let qr = try await transport.send(
            path: "/login/qr/key",
            parameters: [:],
            cookie: "",
            timeout: 15
        )
        let unikey = (qr.body?["data"] as? [String: Any])?["unikey"] as? String
        let key = try XCTUnwrap(unikey)
        XCTAssertFalse(key.isEmpty)
        let check = try await transport.send(
            path: "/login/qr/check",
            parameters: ["key": key],
            cookie: "",
            timeout: 15
        )
        let checkCode = (check.body?["code"] as? NSNumber)?.intValue
        XCTAssertTrue([800, 801, 802, 803].contains(checkCode ?? 0))
    }
}
