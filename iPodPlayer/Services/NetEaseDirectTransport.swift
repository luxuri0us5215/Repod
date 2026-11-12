import Foundation

/// Direct transport: same web endpoints the official clients use, no user-run server.
@MainActor
final class NetEaseDirectTransport: NetEaseTransport {
    let mode: NetEaseConnectionMode = .direct

    private let session: URLSession
    /// The PC-client device id the QR login sends (3.1.12). One per install, so the
    /// key, the code's `chainId` and every check poll name the same device.
    private let deviceId: String

    init(session: URLSession, deviceId: String = NetEaseDeviceID.current) {
        self.session = session
        self.deviceId = deviceId
    }

    func configure(baseURL: String) {}

    func send(
        path: String,
        parameters: [String: String],
        cookie: String,
        timeout: TimeInterval?
    ) async throws -> NetEaseTransportResponse {
        if path == "/login/qr/create" {
            guard let key = parameters["key"], !key.isEmpty else {
                throw NetEaseTransportError.message("缺少二维码密钥。")
            }
            return NetEaseTransportResponse(
                statusCode: 200,
                body: NetEaseDirectRoute.qrCreateBody(key: key, deviceId: deviceId),
                updatedCookie: nil,
                byteCount: 0
            )
        }
        if let request = try NetEaseDirectRoute.qrLoginRequest(
            path: path,
            parameters: parameters,
            cookie: cookie,
            deviceId: deviceId,
            timeout: timeout ?? 25
        ) {
            return try await execute(request, path: path, cookie: cookie)
        }
        if path == "/playlist/track/all" {
            return try await sendPlaylistTracks(
                parameters: parameters,
                cookie: cookie,
                timeout: timeout ?? 25
            )
        }
        if path == "/scrobble" {
            return try await sendScrobble(
                parameters: parameters,
                cookie: cookie,
                timeout: timeout ?? 25
            )
        }
        guard let request = try NetEaseDirectRoute.makeRequest(
            path: path,
            parameters: parameters,
            cookie: cookie,
            deviceId: deviceId,
            timeout: timeout ?? 25
        ) else {
            throw NetEaseTransportError.unsupportedRoute(path)
        }
        return try await execute(request, path: path, cookie: cookie)
    }

    /// The old weapi `/api/feedback/weblog` route is silently dropped by NetEase.
    /// The working combination is clientlog + eapi + a desktop identity in the
    /// cookie, and `startplay` / `play` must be sent as two separate logs: the first
    /// drives 最近播放, the second drives 听歌排行.
    private func sendScrobble(
        parameters: [String: String],
        cookie: String,
        timeout: TimeInterval
    ) async throws -> NetEaseTransportResponse {
        guard let id = parameters["id"], !id.isEmpty,
              let playedSeconds = Int(parameters["time"] ?? ""), playedSeconds > 0 else {
            throw NetEaseTransportError.message("听歌打卡参数不完整。")
        }
        let type = parameters["type"] == "djprogram" ? "djprogram" : "song"
        let sourceID = parameters["sourceid"] ?? ""
        let content = sourceID.isEmpty ? "" : "id=\(sourceID)"

        let startJSON: [String: Any] = [
            "id": id,
            "type": type,
            "mainsite": "1",
            "mainsiteWeb": "1",
            "content": content
        ]
        let playJSON: [String: Any] = [
            "type": type,
            "wifi": 0,
            "download": 0,
            "id": id,
            "time": playedSeconds,
            "end": "playend",
            "source": "list",
            "sourceId": sourceID,
            "mainsite": "1",
            "mainsiteWeb": "1",
            "content": content
        ]
        guard let startLogs = NetEaseDirectRoute.jsonString([
            ["action": "startplay", "json": startJSON]
        ]), let playLogs = NetEaseDirectRoute.jsonString([
            ["action": "play", "json": playJSON]
        ]) else {
            throw NetEaseTransportError.message("无法构造听歌打卡日志。")
        }

        var currentCookie = cookie
        let started = try await sendClientLog(
            logs: startLogs,
            cookie: currentCookie,
            timeout: timeout
        )
        if let updated = started.updatedCookie, !updated.isEmpty {
            currentCookie = updated
        }
        guard started.statusCode == 200 else { return started }

        let ranked = try await sendClientLog(
            logs: playLogs,
            cookie: currentCookie,
            timeout: timeout
        )
        if let updated = ranked.updatedCookie, !updated.isEmpty {
            currentCookie = updated
        }
        guard ranked.statusCode == 200 else { return ranked }

        return NetEaseTransportResponse(
            statusCode: 200,
            body: ["code": 200, "data": "success"],
            updatedCookie: currentCookie == cookie ? nil : currentCookie,
            byteCount: 0
        )
    }

    private func sendClientLog(
        logs: String,
        cookie: String,
        timeout: TimeInterval
    ) async throws -> NetEaseTransportResponse {
        let identity: [String: String] = [
            "os": "osx",
            "appver": "3.1.10.5100",
            "osver": "15.5",
            "channel": "netease"
        ]
        let header: [String: String] = [
            "osver": identity["osver"]!,
            // 3.1.13: the same device that logged in and that every weapi call now
            // presents, so the play log cannot look like a third client.
            "deviceId": deviceId,
            "os": identity["os"]!,
            "appver": identity["appver"]!,
            "versioncode": "140",
            "mobilename": "",
            "buildver": String(Int(Date().timeIntervalSince1970)),
            "resolution": "1920x1080",
            "__csrf": NetEaseDirectRoute.csrfToken(from: cookie),
            "channel": identity["channel"]!,
            "requestId": "\(Int(Date().timeIntervalSince1970 * 1_000))_\(String(format: "%04d", Int.random(in: 0..<10_000)))"
        ]
        guard let params = EapiCrypto.encrypt(
            apiPath: "/api/feedback/weblog",
            payload: ["logs": logs, "header": header, "e_r": false]
        ), let url = URL(string: "https://clientlog.music.163.com/eapi/feedback/weblog") else {
            throw NetEaseTransportError.message("无法构造听歌打卡请求。")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(NetEaseDirectRoute.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        var cookieWithIdentity = NetEaseCookieJar.parse(cookie)
        for (name, value) in identity {
            if let index = cookieWithIdentity.firstIndex(where: { $0.name == name }) {
                cookieWithIdentity[index].value = value
            } else {
                cookieWithIdentity.append((name, value))
            }
        }
        request.setValue(
            cookieWithIdentity.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
            forHTTPHeaderField: "Cookie"
        )
        request.httpBody = Data("params=\(params)".utf8)
        return try await execute(request, path: "/scrobble", cookie: cookie)
    }

    private func execute(
        _ request: URLRequest,
        path: String,
        cookie: String
    ) async throws -> NetEaseTransportResponse {
        let (data, response) = try await NetEaseHTTP.sendWithRetry(session: session, request: request)
        guard let http = response as? HTTPURLResponse, let url = request.url else {
            throw NetEaseTransportError.invalidResponse
        }
        let updatedCookie = NetEaseCookieJar.update(existing: cookie, response: http, url: url)
        var body = await NetEaseJSON.parse(data)
        if path == "/login/qr/key", let parsed = body {
            body = NetEaseDirectRoute.qrKeyBody(from: parsed)
        }
        if path == "/login/qr/check", let parsed = body {
            body = NetEaseDirectRoute.qrCheckBody(from: parsed, updatedCookie: updatedCookie)
        }
        return NetEaseTransportResponse(
            statusCode: http.statusCode,
            body: body,
            updatedCookie: updatedCookie,
            byteCount: data.count
        )
    }

    /// The gateway used to reassemble a playlist page before handing it to the app.
    /// Direct mode must do the same: `/api/v6/playlist/detail` returns the first
    /// `tracks` window plus the full `trackIds`, and pages beyond that window need
    /// `/api/v3/song/detail` batches.
    private func sendPlaylistTracks(
        parameters: [String: String],
        cookie: String,
        timeout: TimeInterval
    ) async throws -> NetEaseTransportResponse {
        guard let playlistID = parameters["id"], !playlistID.isEmpty else {
            throw NetEaseTransportError.message("缺少歌单 ID。")
        }
        let limit = max(1, Int(parameters["limit"] ?? "200") ?? 200)
        let offset = max(0, Int(parameters["offset"] ?? "0") ?? 0)
        var currentCookie = cookie

        guard let detailRequest = NetEaseDirectRoute.weapiRequest(
            apiPath: "/api/v6/playlist/detail",
            payload: ["id": playlistID, "n": 1000, "s": 0],
            cookie: currentCookie,
            deviceId: deviceId,
            timeout: timeout
        ) else {
            throw NetEaseTransportError.message("无法构造歌单请求。")
        }
        let detail = try await execute(detailRequest, path: "/playlist/detail", cookie: currentCookie)
        if let updated = detail.updatedCookie, !updated.isEmpty {
            currentCookie = updated
        }
        guard detail.statusCode == 200, var body = detail.body,
              let playlist = body["playlist"] as? [String: Any] else {
            return detail
        }

        var tracks = playlist["tracks"] as? [[String: Any]] ?? []
        let trackIDs = playlist["trackIds"] as? [[String: Any]] ?? []
        let orderedIDs = trackIDs.compactMap { identifier($0["id"]) }
        let total = (playlist["trackCount"] as? NSNumber)?.intValue
            ?? (playlist["trackCount"] as? Int)
            ?? orderedIDs.count
        let needed = min(orderedIDs.count, offset + limit)

        if tracks.count < needed {
            let missing = Array(orderedIDs.dropFirst(tracks.count).prefix(needed - tracks.count))
            var index = 0
            while index < missing.count {
                let batch = Array(missing[index..<min(index + 500, missing.count)])
                guard let idsJSON = NetEaseDirectRoute.jsonString(batch),
                      let cJSON = NetEaseDirectRoute.jsonString(batch.map { ["id": $0] }),
                      let request = NetEaseDirectRoute.weapiRequest(
                        apiPath: "/api/v3/song/detail",
                        payload: ["ids": idsJSON, "c": cJSON],
                        cookie: currentCookie,
                        deviceId: deviceId,
                        timeout: timeout
                      ) else {
                    throw NetEaseTransportError.message("无法补全歌单歌曲。")
                }
                let result = try await execute(request, path: "/song/detail", cookie: currentCookie)
                if let updated = result.updatedCookie, !updated.isEmpty {
                    currentCookie = updated
                }
                tracks += (result.body?["songs"] as? [[String: Any]]) ?? []
                index += 500
            }
        }

        var byID: [String: [String: Any]] = [:]
        for track in tracks {
            if let id = identifier(track["id"]) {
                byID[id] = track
            }
        }
        let ordered = orderedIDs.compactMap { byID[$0] }
        let page = ordered.isEmpty
            ? Array(tracks.dropFirst(offset).prefix(limit))
            : Array(ordered.dropFirst(offset).prefix(limit))

        body["code"] = 200
        body["songs"] = page
        body["trackCount"] = total
        body["more"] = offset + page.count < total
        let byteCount = (try? JSONSerialization.data(withJSONObject: page)).map(\.count) ?? 0
        return NetEaseTransportResponse(
            statusCode: 200,
            body: body,
            updatedCookie: currentCookie == cookie ? nil : currentCookie,
            byteCount: byteCount
        )
    }

    private func identifier(_ value: Any?) -> String? {
        if let number = value as? NSNumber, number.int64Value > 0 {
            return number.stringValue
        }
        if let text = value as? String, !text.isEmpty {
            return text
        }
        return nil
    }
}

/// The device id the PC-client QR login presents: 52 upper-case hex digits, the
/// shape NeteaseCloudMusicApiEnhanced generates. Kept for the life of the install
/// so NetEase sees one device logging in, not a new one per code.
enum NetEaseDeviceID {
    private static let key = "neteasePCDeviceID"

    static var current: String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: key), isValid(saved) { return saved }
        let made = generate()
        defaults.set(made, forKey: key)
        return made
    }

    static func generate() -> String {
        let digits = Array("0123456789ABCDEF")
        return String((0..<52).map { _ in digits[Int.random(in: 0..<digits.count)] })
    }

    static func isValid(_ value: String) -> Bool {
        value.count == 52 && value.allSatisfy { $0.isHexDigit && !$0.isLowercase }
    }
}
