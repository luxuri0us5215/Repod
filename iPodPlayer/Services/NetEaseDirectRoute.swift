import Foundation

/// Translates the app's gateway-style logical paths into direct NetEase requests.
///
/// The gateway was a thin adapter around the same web API the official clients use.
/// Keeping the app's paths unchanged means only one layer has to know that
/// `/cloudsearch` is really `/api/cloudsearch/pc`, and the rest of the client keeps
/// its existing cache keys, paging rules and error handling.
enum NetEaseDirectRoute {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.164 NeteaseMusicDesktop/3.0.18.203152"

    /// A request that can be sent as-is. `nil` means the path needs a multi-step
    /// answer (playlist paging) or is answered locally (QR image URL).
    static func makeRequest(
        path: String,
        parameters: [String: String],
        cookie: String,
        deviceId: String = NetEaseDeviceID.current,
        timeout: TimeInterval
    ) throws -> URLRequest? {
        switch path {
        case "/login/qr/create", "/playlist/track/all":
            return nil
        case "/song/url":
            let ids = idList(parameters["ids"] ?? parameters["id"] ?? "")
            guard !ids.isEmpty, let idsJSON = jsonString(ids) else {
                throw NetEaseTransportError.message("缺少歌曲 ID，无法获取播放地址。")
            }
            return legacySongURLRequest(idsJSON: idsJSON, cookie: cookie, timeout: timeout)
        default:
            let (apiPath, payload) = try apiPathAndPayload(path: path, parameters: parameters)
            guard let request = weapiRequest(
                apiPath: apiPath,
                payload: payload,
                cookie: cookie,
                deviceId: deviceId,
                timeout: timeout
            ) else {
                throw NetEaseTransportError.message("无法构造网易云直连请求。")
            }
            return request
        }
    }

    static func weapiRequest(
        apiPath: String,
        payload: [String: Any],
        cookie: String,
        deviceId: String = NetEaseDeviceID.current,
        timeout: TimeInterval
    ) -> URLRequest? {
        var body = payload
        // 3.1.13: the session cookie alone is not enough any more. See `identityCookie`.
        let wireCookie = identityCookie(existing: cookie, deviceId: deviceId)
        body["csrf_token"] = csrfToken(from: wireCookie)
        guard let encrypted = WeapiCrypto.encrypt(payload: body),
              let url = URL(string: "https://music.163.com/weapi/" + weapiSuffix(apiPath))
        else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Origin")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(wireCookie, forHTTPHeaderField: "Cookie")
        let params = percentEncode(encrypted.params)
        let key = percentEncode(encrypted.encSecKey)
        request.httpBody = Data("params=\(params)&encSecKey=\(key)".utf8)
        return request
    }

    // MARK: Client identity (3.1.13)

    /// Fills the desktop-client identity into a weapi request's Cookie.
    ///
    /// NetEase answers `-460 检测到您的网络环境存在风险` to a write whose Cookie carries
    /// only the session bits (MUSIC_U / __csrf / NMTID): the request looks like it came
    /// from no known client. The maintained reference server
    /// (`NeteaseCloudMusicApiEnhanced`, `util/request.js` → `processCookieObject`) puts
    /// these fields into *every* request's Cookie for exactly this reason, and the 2021
    /// fix for the same -460 on `/api/radio/like` (`commit d1907ae5`, issue #1151) set
    /// `cookie.os` / `cookie.appver` on the like route.
    ///
    /// Measured on one IP, a minute apart, anonymous `POST /weapi/radio/like`:
    /// - identity Cookie → `{"code":301}` — accepted, merely not logged in
    /// - NMTID only      → `{"code":-460}` — refused as risky
    /// - NMTID only + desktop UA → still `-460`
    /// so the identity Cookie is the deciding factor, not the user agent.
    ///
    /// Values already in the stored cookie win, so a login that hands back its own
    /// `os` / `appver` / `deviceId` is not overwritten.
    static func identityCookie(
        existing cookie: String,
        deviceId: String,
        now: Date = Date()
    ) -> String {
        var pairs: [(name: String, value: String)] = []
        for pair in NetEaseCookieJar.parse(cookie) {
            guard !pair.value.isEmpty,
                  !pairs.contains(where: { $0.name == pair.name })
            else { continue }
            pairs.append(pair)
        }

        func kept(_ name: String) -> String? {
            pairs.first { $0.name == name }?.value
        }

        let millis = Int(now.timeIntervalSince1970 * 1_000)
        let nuid = kept("_ntes_nuid") ?? randomHex(32)
        let fillers: [(String, String)] = [
            ("__remember_me", "true"),
            ("ntes_kaola_ad", "1"),
            ("_ntes_nuid", nuid),
            ("_ntes_nnid", kept("_ntes_nnid") ?? "\(nuid),\(millis)"),
            ("WNMCID", kept("WNMCID") ?? wnmcid),
            ("WEVNSM", kept("WEVNSM") ?? "1.0.0"),
            ("osver", kept("osver") ?? pcClient["osver"]!),
            ("deviceId", kept("deviceId") ?? deviceId),
            ("os", kept("os") ?? pcClient["os"]!),
            ("channel", kept("channel") ?? pcClient["channel"]!),
            ("appver", kept("appver") ?? pcClient["appver"]!)
        ]
        for (name, value) in fillers where kept(name) == nil {
            pairs.append((name, value))
        }
        return pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// `WNMCID` in the reference server: six random lowercase letters, the millis it
    /// was minted, then `.01.0`. One per process there, so one per launch here.
    private static let wnmcid: String = {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let prefix = String((0..<6).map { _ in letters.randomElement()! })
        return "\(prefix).\(Int(Date().timeIntervalSince1970 * 1_000)).01.0"
    }()

    private static func randomHex(_ length: Int) -> String {
        let digits = Array("0123456789abcdef")
        return String((0..<length).map { _ in digits.randomElement()! })
    }

    static func legacySongURLRequest(idsJSON: String, cookie: String, timeout: TimeInterval) -> URLRequest? {
        var components = URLComponents(string: "https://music.163.com/api/song/enhance/player/url")
        components?.queryItems = [
            URLQueryItem(name: "ids", value: idsJSON),
            URLQueryItem(name: "br", value: "128000")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    /// The app asks for a QR *image URL*, which the gateway used to compose without
    /// forwarding anything. Direct mode can answer it locally.
    ///
    /// 3.1.12: the code carries a `chainId` naming the same device id the PC-client
    /// key and check requests send, so the scan confirmation is tied to one client.
    static func qrCreateBody(key: String, deviceId: String? = nil) -> [String: Any] {
        var url = "https://music.163.com/login?codekey=\(key)"
        if let deviceId, !deviceId.isEmpty {
            url += "&chainId=" + qrChainID(deviceId: deviceId)
        }
        return [
            "code": 200,
            "data": [
                "qrurl": url
            ]
        ]
    }

    static func qrChainID(deviceId: String, now: Date = Date()) -> String {
        "v1_\(deviceId)_pc_login_\(Int(now.timeIntervalSince1970 * 1_000))"
    }

    // MARK: QR login as the PC client (3.1.12)
    //
    // NetEase now refuses the old web QR login (weapi `/login/qrcode/...`, type=1)
    // at the confirmation step: the phone shows 「请切换其他登录方式或升级新版本再试」
    // and the check returns 8821. The maintained NeteaseCloudMusicApiEnhanced
    // (4.41.1, `login_qr_key` / `login_qr_check`) logs in as the Windows client:
    // eapi on interfacepc.music.163.com, type=3, and the client identity both in
    // the Cookie header and in the encrypted `header`. This is the same request.

    static let pcClient: [String: String] = [
        "os": "pc",
        "appver": "3.1.17.204416",
        "osver": "Microsoft-Windows-10-Professional-build-19045-64bit",
        "channel": "netease"
    ]
    /// The user agent NeteaseCloudMusicApiEnhanced sends with its eapi requests.
    static let eapiUserAgent = "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"

    /// `/login/qr/key` and `/login/qr/check` as PC-client eapi requests.
    static func qrLoginRequest(
        path: String,
        parameters: [String: String],
        cookie: String,
        deviceId: String,
        timeout: TimeInterval
    ) throws -> URLRequest? {
        switch path {
        case "/login/qr/key":
            return pcEapiRequest(apiPath: "/api/login/qrcode/unikey",
                                 payload: ["type": 3],
                                 cookie: cookie, deviceId: deviceId, timeout: timeout)
        case "/login/qr/check":
            guard let key = parameters["key"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else {
                throw NetEaseTransportError.message("缺少二维码密钥。")
            }
            return pcEapiRequest(apiPath: "/api/login/qrcode/client/login",
                                 payload: ["key": key, "type": 3],
                                 cookie: cookie, deviceId: deviceId, timeout: timeout)
        default:
            return nil
        }
    }

    static func pcEapiRequest(
        apiPath: String,
        payload: [String: Any],
        cookie: String,
        deviceId: String,
        timeout: TimeInterval,
        now: Date = Date()
    ) -> URLRequest? {
        let existing = NetEaseCookieJar.parse(cookie)
        func saved(_ name: String) -> String? {
            existing.first { $0.name == name }?.value
        }
        let millis = Int(now.timeIntervalSince1970 * 1_000)
        var header: [String: String] = [
            "osver": pcClient["osver"]!,
            "deviceId": deviceId,
            "os": pcClient["os"]!,
            "appver": pcClient["appver"]!,
            "versioncode": "140",
            "mobilename": "",
            "buildver": String(millis / 1_000),
            "resolution": "1920x1080",
            "__csrf": csrfToken(from: cookie),
            "channel": pcClient["channel"]!,
            "requestId": "\(millis)_\(String(format: "%04d", Int.random(in: 0..<1_000)))"
        ]
        if let musicU = saved("MUSIC_U"), !musicU.isEmpty { header["MUSIC_U"] = musicU }
        if let musicA = saved("MUSIC_A"), !musicA.isEmpty { header["MUSIC_A"] = musicA }

        var body = payload
        body["header"] = header
        body["e_r"] = false
        guard let params = EapiCrypto.encrypt(apiPath: apiPath, payload: body),
              let url = URL(string: "https://interfacepc.music.163.com/eapi/" + weapiSuffix(apiPath))
        else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(eapiUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(header
            .sorted { $0.key < $1.key }
            .map { "\(cookieEncode($0.key))=\(cookieEncode($0.value))" }
            .joined(separator: "; "), forHTTPHeaderField: "Cookie")
        request.httpBody = Data("params=\(params)".utf8)
        return request
    }

    /// `encodeURIComponent`, which is what the reference implementation uses for
    /// the header cookie.
    private static func cookieEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Upstream login answers put the fresh cookie in `Set-Cookie`, while the app's
    /// `checkQRLogin` reads `body.cookie`. The adapter keeps that contract.
    static func qrKeyBody(from body: [String: Any]) -> [String: Any] {
        guard let unikey = body["unikey"] as? String, !unikey.isEmpty else {
            return body
        }
        return ["code": 200, "data": ["unikey": unikey]]
    }

    static func qrCheckBody(from body: [String: Any], updatedCookie: String?) -> [String: Any] {
        var shaped = body
        let code = (body["code"] as? NSNumber)?.intValue
        if code == 803, let updatedCookie, !updatedCookie.isEmpty {
            shaped["cookie"] = updatedCookie
        }
        return shaped
    }

    private static func apiPathAndPayload(
        path: String,
        parameters: [String: String]
    ) throws -> (String, [String: Any]) {
        func value(_ key: String, default fallback: String? = nil) throws -> String {
            if let raw = parameters[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                return raw
            }
            if let fallback { return fallback }
            throw NetEaseTransportError.message("直连接口缺少参数（\(key)）。")
        }

        switch path {
        case "/cloudsearch":
            return ("/api/cloudsearch/pc", [
                "s": try value("keywords"),
                "type": try value("type", default: "1"),
                "limit": try value("limit", default: "30"),
                "offset": try value("offset", default: "0"),
                "total": true
            ])
        case "/search":
            return ("/api/search/get/web", [
                "s": try value("keywords"),
                "type": try value("type", default: "1"),
                "limit": try value("limit", default: "30"),
                "offset": try value("offset", default: "0")
            ])
        case "/artists":
            return ("/api/v1/artist/\(try value("id"))", [:])
        case "/artist/songs":
            return ("/api/v1/artist/songs", [
                "id": try value("id"),
                "order": try value("order", default: "hot"),
                "limit": try value("limit", default: "50"),
                "offset": try value("offset", default: "0")
            ])
        case "/song/detail":
            let ids = idList(try value("ids"))
            guard !ids.isEmpty, let idsJSON = jsonString(ids),
                  let cJSON = jsonString(ids.map { ["id": $0] }) else {
                throw NetEaseTransportError.message("歌曲 ID 无效。")
            }
            return ("/api/v3/song/detail", ["ids": idsJSON, "c": cJSON])
        case "/album":
            return ("/api/v1/album/\(try value("id"))", [:])
        case "/song/url/v1":
            let ids = idList(parameters["ids"] ?? parameters["id"] ?? "")
            guard !ids.isEmpty, let idsJSON = jsonString(ids) else {
                throw NetEaseTransportError.message("歌曲 ID 无效。")
            }
            return ("/api/song/enhance/player/url/v1", [
                "ids": idsJSON,
                "level": try value("level", default: "standard"),
                "encodeType": "flac"
            ])
        case "/login/status":
            return ("/api/w/nuser/account/get", [:])
        case "/user/account":
            return ("/api/nuser/account/get", [:])
        case "/user/level":
            return ("/api/user/level", [:])
        case "/likelist":
            return ("/api/song/like/get", ["uid": try value("uid")])
        case "/like":
            return ("/api/radio/like", [
                "trackId": try value("id"),
                "like": (parameters["like"] ?? "true") == "true",
                "alg": "itembased",
                "time": "3"
            ])
        case "/user/playlist":
            return ("/api/user/playlist", [
                "uid": try value("uid"),
                "limit": try value("limit", default: "100"),
                "offset": try value("offset", default: "0")
            ])
        case "/playlist/detail":
            return ("/api/v6/playlist/detail", [
                "id": try value("id"),
                "n": "1000",
                "s": "0"
            ])
        case "/recommend/songs":
            return ("/api/v1/discovery/recommend/songs", [:])
        case "/personal_fm":
            return ("/api/v1/radio/get", [:])
        case "/dj/sublist":
            return ("/api/djradio/get/subed", [
                "limit": try value("limit", default: "30"),
                "offset": try value("offset", default: "0"),
                "total": true
            ])
        case "/dj/program":
            return ("/api/dj/program/byradio", [
                "radioId": try value("radioId"),
                "limit": try value("limit", default: "30"),
                "offset": try value("offset", default: "0"),
                "asc": false
            ])
        case "/login/qr/key":
            return ("/api/login/qrcode/unikey", ["type": "1"])
        case "/login/qr/check":
            return ("/api/login/qrcode/client/login", [
                "key": try value("key"),
                "type": "1"
            ])
        case "/logout":
            return ("/api/logout", [:])
        default:
            throw NetEaseTransportError.unsupportedRoute(path)
        }
    }

    static func idList(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return array.compactMap { item in
                if let text = item as? String, !text.isEmpty { return text }
                if let number = item as? NSNumber { return number.stringValue }
                return nil
            }
        }
        return trimmed.split(separator: ",").compactMap { part in
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    static func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    static func csrfToken(from cookie: String) -> String {
        NetEaseCookieJar.parse(cookie).first { $0.name == "__csrf" }?.value ?? ""
    }

    private static func weapiSuffix(_ apiPath: String) -> String {
        apiPath.hasPrefix("/api/") ? String(apiPath.dropFirst(5)) : apiPath
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}
