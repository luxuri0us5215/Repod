import Foundation
import UIKit

struct NetEaseQRLogin {
    let key: String
    let url: String
}

enum NetEaseQRStatus {
    case waiting, scanned, expired, authorized
}

/// Adapter for a user-configured NeteaseCloudMusicApi server, never a public default server.
/// Authentication cookies persist independently of address edits until explicit logout or an authentication failure.
@MainActor
final class NetEaseClient {
    private var baseURL: String
    private var session: URLSession
    private var cookie = ""
    private var generation = UUID()
    private var isLoggingOut = false
    private var likedPlaylistTracksCache: [Track]?
    private var likedTrackIDsCache: Set<String>?
    /// The membership set `likedPlaylistTracksCache` was built from. When a later
    /// `/likelist` returns the same ids, the cached metadata is still exact and the
    /// expensive playlist page walk can be skipped.
    private var likedMemberIDs: Set<String>?
    private var playlistLikedTracks: [String: Track] = [:]
    private var playlistUnlikedTrackIDs = Set<String>()
    /// Song-address requests increment this so library paging waits instead of occupying the same server.
    private var playbackPriorityDepth = 0
    private(set) var userID: String?

    /// Read-only endpoints whose answer only changes when the library is edited.
    /// `/user/playlist` walks up to 100 rows per page and a playlist page up to 200
    /// songs, so a repeat open is the difference between instant and a round trip.
    /// A playlist page is large, but the cache is bounded by bytes now, not entries,
    /// so it is kept and stops being the biggest source of repeat page walks.
    private static let responseCacheLifetime: [String: TimeInterval] = [
        "/user/playlist": 300,
        "/playlist/track/all": 300,
        "/playlist/detail": 300,
        "/song/detail": 600,
        "/album": 900
    ]
    private struct CachedResponse {
        let body: [String: Any]
        let expiresAt: Date
        /// Raw JSON size. The parsed Foundation tree is several times larger than the
        /// bytes that arrived, so bounding the input is the conservative measure.
        let byteCount: Int
    }
    private var responseCache: [String: CachedResponse] = [:]
    private var responseCacheOrder: [String] = []
    private var responseCacheBytes = 0
    private static let responseCacheByteLimit = 4 * 1_024 * 1_024

    /// Song addresses resolved ahead of time, keyed by track id. One entry per song:
    /// the prefetch starts a single request while the previous song plays, and the
    /// track change then spends no round trip at all. An entry is removed the moment
    /// playback consumes it, so a replay resolves a fresh address instead of one the
    /// server may already have dropped.
    private var playbackURLCache: [String: ResolvedPlaybackURL] = [:]
    /// Address lookups already travelling, so a repeated trigger and a track change
    /// both wait for the same request instead of starting another.
    private var playbackPrefetchTasks: [String: Task<ResolvedPlaybackURL?, Never>] = [:]
    /// A song refused with -460 is left alone for a while; asking again straight away
    /// is what turns one refusal into a burst. Kept short (3 minutes) because a refusal
    /// is about the caller, not this song: measured against a flagged egress IP, the
    /// answer flips between refused and served at the same few-second spacing, so a
    /// long per-song block mostly just guarantees a cold address on the next switch.
    private var riskControlBlockedUntil: [String: Date] = [:]
    private static let riskControlCooldown: TimeInterval = 180
    /// Speculative work stands down after a refusal — but only briefly. A two-minute
    /// mute used to mean every switch inside that window paid a full cold round trip,
    /// which is exactly the "every skip is slow" report. The window is short, and any
    /// successful answer clears the mute immediately (see `request`), so prefetching
    /// comes back on its own.
    private static let riskControlQuietDuration: TimeInterval = 25
    /// Set when the service refuses anything with -460. A refusal is about the caller,
    /// not the song, so every speculative request stands down for a while instead of
    /// probing the same rate window song after song.
    private var riskControlQuietUntil: Date?
    private var memoryNotifications: [NSObjectProtocol] = []

    private func cacheKey(_ path: String, _ parameters: [String: String]) -> String {
        // The sorted parameters already identify the question.
        path + "?" + parameters.sorted { $0.key < $1.key }
            .map { $0.key + "=" + $0.value }.joined(separator: "&")
    }

    private func cachedResponse(path: String, parameters: [String: String]) -> [String: Any]? {
        guard Self.responseCacheLifetime[path] != nil else { return nil }
        let key = cacheKey(path, parameters)
        guard let entry = responseCache[key] else { return nil }
        guard entry.expiresAt > Date() else {
            responseCache[key] = nil
            responseCacheOrder.removeAll { $0 == key }
            return nil
        }
        return entry.body
    }

    private func storeResponse(_ body: [String: Any], path: String, parameters: [String: String],
                               byteCount: Int) {
        guard let lifetime = Self.responseCacheLifetime[path] else { return }
        let key = cacheKey(path, parameters)
        if let replaced = responseCache[key] { responseCacheBytes -= replaced.byteCount }
        responseCache[key] = CachedResponse(body: body,
                                            expiresAt: Date().addingTimeInterval(lifetime),
                                            byteCount: byteCount)
        responseCacheOrder.removeAll { $0 == key }
        responseCacheOrder.append(key)
        responseCacheBytes += byteCount
        // Byte-bounded rather than count-bounded: forty-eight entries of small metadata
        // are cheap, while a handful of large pages are what actually fills memory.
        while responseCacheBytes > Self.responseCacheByteLimit, let oldest = responseCacheOrder.first {
            responseCacheOrder.removeFirst()
            if let removed = responseCache.removeValue(forKey: oldest) {
                responseCacheBytes -= removed.byteCount
            }
        }
    }

    /// Likes, playlist edits and re-logins change these answers.
    func invalidateResponseCache() {
        responseCache = [:]
        responseCacheOrder = []
        responseCacheBytes = 0
    }

    /// A song address belongs to the server that issued it, and a prefetch made under
    /// the previous credentials must not be handed to a track change after an address
    /// edit or a re-login.
    private func invalidatePlaybackURLCache() {
        playbackURLCache = [:]
        playbackPrefetchTasks = [:]
        riskControlBlockedUntil = [:]
        riskControlQuietUntil = nil
    }

    enum ClientError: LocalizedError {
        case message(String)
        case loginRequired
        /// NetEase judged the caller risky and refused with -460. Kept apart from a
        /// plain message so playback can stop after this one refusal: retrying the
        /// legacy route and the same song again only enlarges the burst that caused it.
        case riskControl
        /// The request never produced a complete answer: DNS, connect, TLS, or a
        /// connection that died mid-body. Kept apart from `.message` because it is not
        /// an answer about the song — a second endpoint would only dial the same dead
        /// connection again — and because it is the one failure worth a quiet retry.
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .message(let message): return message
            case .loginRequired: return "请先登录"
            case .riskControl:
                // Playback and the lists recover from this on their own, silently, so
                // this text is only a fallback for a path that has no recovery.
                return "网易云暂时限流，正在后台自动重试。"
            case .transport(let message): return message
            }
        }
    }

    init(baseURL: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        session = Self.makeSession()
        cookie = (try? NetEaseCookieKeychain.read()) ?? ""
        observeMemoryPressure()
    }

    deinit {
        for token in memoryNotifications { NotificationCenter.default.removeObserver(token) }
    }

    /// Parsed responses and prefetched addresses are rebuildable, so under memory
    /// pressure they are the first thing to give up. A background player that the
    /// system kills for memory looks exactly like a playback interruption.
    private func observeMemoryPressure() {
        let center = NotificationCenter.default
        for name in [UIApplication.didReceiveMemoryWarningNotification,
                     UIApplication.didEnterBackgroundNotification] {
            memoryNotifications.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.invalidateTransientCaches() }
            })
        }
    }

    private func invalidateTransientCaches() {
        invalidateResponseCache()
        playbackURLCache = [:]
        riskControlBlockedUntil = [:]
    }

    func restoreSession() async throws -> String? {
        guard !cookie.isEmpty else { return nil }
        return try await loginStatus()
    }

    func configure(_ baseURL: String) {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != self.baseURL else { return }
        self.baseURL = value
        session.invalidateAndCancel()
        session = Self.makeSession()
        generation = UUID()
        userID = nil
        likedPlaylistTracksCache = nil
        likedTrackIDsCache = nil
        likedMemberIDs = nil
        playlistLikedTracks = [:]
        playlistUnlikedTrackIDs = []
        isLoggingOut = false
        invalidateResponseCache()
        invalidatePlaybackURLCache()
    }

    func resetSession() {
        session.invalidateAndCancel()
        session = Self.makeSession()
        clearAuthentication()
    }

    private func clearAuthentication() {
        cookie = ""
        userID = nil
        isLoggingOut = false
        generation = UUID()
        invalidateResponseCache()
        invalidatePlaybackURLCache()
        likedPlaylistTracksCache = nil
        likedTrackIDsCache = nil
        likedMemberIDs = nil
        playlistLikedTracks = [:]
        playlistUnlikedTrackIDs = []
        try? NetEaseCookieKeychain.delete()
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 25
        return URLSession(configuration: configuration)
    }

    private var artistIDByName: [String: String] = [:]

    func search(query: String, offset: Int) async throws -> SearchPage {
        let parameters = ["keywords": query, "type": "1", "limit": "30", "offset": String(offset)]
        // `/cloudsearch` returns the same rows as `/search` but keeps the album
        // object's `picUrl`; the legacy route drops every cover and only leaves
        // `picId`, so search results had no artwork at all. Older servers without
        // the route fall back to `/search` rather than breaking search entirely.
        let body: [String: Any]
        do {
            body = try await request("/cloudsearch", parameters: parameters)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let cloudError = error
            do {
                body = try await request("/search", parameters: parameters)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw cloudError
            }
        }
        let result = body["result"] as? [String: Any]
        let songs = result?["songs"] as? [[String: Any]] ?? []
        let songCount = (result?["songCount"] as? NSNumber)?.intValue ?? 0
        return SearchPage(tracks: songs.compactMap(Self.track),
                          hasMore: (offset == 0 ? max(30, songs.count) : offset + songs.count) < songCount,
                          nextOffset: offset + 30)
    }

    private static func normalizedSearchKey(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    func artistTracks(name: String, artistID: String? = nil,
                      onProgress: (@MainActor ([Track]) -> Void)? = nil) async throws -> [Track] {
        var resolvedID = artistID ?? artistIDByName[name]
        if resolvedID == nil {
            let body = try await request("/search", parameters: ["keywords": name, "type": "100", "limit": "5"])
            let result = body["result"] as? [String: Any]
            let artists = result?["artists"] as? [[String: Any]] ?? []
            let normalizedTarget = Self.normalizedSearchKey(name)
            let matched = artists.first {
                guard let candidate = $0["name"] as? String else { return false }
                return Self.normalizedSearchKey(candidate) == normalizedTarget
            } ?? artists.first
            resolvedID = Self.identifier(matched?["id"])
            if let resolvedID { artistIDByName[name] = resolvedID }
        }
        guard let id = resolvedID else { return [] }
        // Hot songs are one request. Show them before paging the full catalogue,
        // which on the current NetEase API can stall long enough to look frozen.
        var hotTracks: [Track] = []
        do {
            let hotBody = try await request("/artists", parameters: ["id": id])
            hotTracks = Self.uniqueTracks((hotBody["hotSongs"] as? [[String: Any]] ?? []).compactMap(Self.track))
            if !hotTracks.isEmpty { onProgress?(hotTracks) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            hotTracks = []
        }
        try Task.checkCancellation()
        var allTracks: [Track] = []
        var seen = Set<String>()
        var offset = 0
        let pageSize = 50
        let maxPages = 10
        for _ in 0..<maxPages {
            try Task.checkCancellation()
            let songsBody: [String: Any]
            do {
                songsBody = try await request("/artist/songs", parameters: ["id": id, "order": "hot",
                                                                             "limit": String(pageSize), "offset": String(offset)])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !allTracks.isEmpty { return allTracks }
                if !hotTracks.isEmpty { return hotTracks }
                throw error
            }
            let pageTracks = (songsBody["songs"] as? [[String: Any]] ?? []).compactMap(Self.track)
            let fresh = pageTracks.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { break }
            allTracks.append(contentsOf: fresh)
            onProgress?(allTracks)
            if pageTracks.count < pageSize { break }
            offset += pageSize
        }
        if !allTracks.isEmpty { return allTracks }
        if !hotTracks.isEmpty { return hotTracks }
        return []
    }

    func albumIdentifier(forTrackID trackID: String) async throws -> String {
        let detail = try await request("/song/detail", parameters: ["ids": trackID])
        let song = (detail["songs"] as? [[String: Any]])?.first
        let metadata = (song?["al"] ?? song?["album"]) as? [String: Any]
        guard let id = Self.identifier(metadata?["id"]) else {
            throw ClientError.message("专辑加载失败，请稍后重试。")
        }
        return id
    }

    func albumTracks(id albumID: String, name: String) async throws -> [Track] {
        let body = try await request("/album", parameters: ["id": albumID])
        let songs = body["songs"] as? [[String: Any]] ?? []
        // `/album` often ships the cover only on the album object, not on each song.
        let albumInfo = body["album"] as? [String: Any] ?? [:]
        let albumArtwork = Self.artworkURL(from: albumInfo)
        let tracks = Self.uniqueTracks(songs.compactMap { item -> Track? in
            guard let track = Self.track(item) else { return nil }
            return Track(id: track.id, title: track.title, artist: track.artist, album: name,
                         duration: track.duration, source: .netease,
                         artworkURL: track.artworkURL ?? albumArtwork,
                         albumID: track.albumID ?? albumID)
        })
        guard !tracks.isEmpty else { throw ClientError.message("专辑加载失败，请稍后重试。") }
        return tracks
    }

    func playbackTrack(_ track: Track) async throws -> Track {
        guard track.source == .netease else { throw ClientError.message("请选择网易云歌曲。") }
        playbackPriorityDepth += 1
        defer { playbackPriorityDepth -= 1 }
        let url: URL
        if let prefetched = await takePrefetchedURL(for: track) {
            url = prefetched
        } else {
            url = try await resolvePlaybackURL(for: track).url
        }
        var playable = track
        playable.streamURL = url
        return playable
    }

    /// Consumes an address resolved ahead of time, if there is one. The entry is
    /// removed either way: an address is used once, so replaying a song resolves a
    /// fresh one instead of one the server may already have dropped.
    private func takePrefetchedURL(for track: Track) async -> URL? {
        let id = track.id
        if let cached = playbackURLCache.removeValue(forKey: id) {
            if cached.expiresAt > Date() { return cached.url }
        }
        // The next song can be selected while its prefetch is still travelling. Waiting
        // for that one request is still one request, instead of a second one racing it.
        if let inFlight = playbackPrefetchTasks[id] {
            _ = await inFlight.value
            if let cached = playbackURLCache.removeValue(forKey: id), cached.expiresAt > Date() {
                return cached.url
            }
        }
        return nil
    }

    /// The address resolved for a song, without consuming it. `takePrefetchedURL`
    /// still spends it exactly once; this is for warming the CDN connection the
    /// address points at, which is where the silence before the next song goes.
    func prefetchedPlaybackURL(forTrackID id: String) async -> URL? {
        if let cached = playbackURLCache[id], cached.expiresAt > Date() { return cached.url }
        if let inFlight = playbackPrefetchTasks[id] {
            _ = await inFlight.value
            if let cached = playbackURLCache[id], cached.expiresAt > Date() { return cached.url }
        }
        return nil
    }

    /// Resolves the next song's address while the current one is still playing. A
    /// failure here is discarded on purpose: the track change asks again through the
    /// normal path, where an error is expected to be shown and counted.
    func prefetchPlaybackTrack(_ track: Track) async {
        guard track.source == .netease else { return }
        // Speculative work is the first thing to give up when the service has already
        // said it is refusing this caller.
        if let quietUntil = riskControlQuietUntil, quietUntil > Date() { return }
        let id = track.id
        if let cached = playbackURLCache[id], cached.expiresAt > Date() { return }
        if let blockedUntil = riskControlBlockedUntil[id], blockedUntil > Date() { return }
        guard playbackPrefetchTasks[id] == nil else { return }
        pruneExpiredPlaybackURLs()
        let task = Task { [weak self] () -> ResolvedPlaybackURL? in
            guard let self else { return nil }
            // Only a request that produced no answer at all is retried. A dropped
            // connection costs nothing to repeat while this song is still playing, and
            // giving up would push a whole cold round trip onto the next skip.
            //
            // A -460 is deliberately *not* retried here. Measurement against a gated
            // caller showed that repeating a refused request escalates the verdict from
            // -460 (risk) to -462 (a verification challenge), so a retry does not just
            // fail again — it makes the next switch more likely to be refused too. The
            // primary route is chosen to not be refused at all (see
            // `resolvePlaybackURL`), which is what actually removes this from the path.
            for attempt in 0..<2 {
                do {
                    let resolved = try await self.resolvePlaybackURL(for: track)
                    guard !Task.isCancelled else { return nil }
                    self.playbackURLCache[id] = resolved
                    return resolved
                } catch is CancellationError {
                    // A track change or an address edit cancelled it; nothing to keep.
                    return nil
                } catch let error as ClientError {
                    if case .riskControl = error {
                        self.riskControlBlockedUntil[id] = Date()
                            .addingTimeInterval(Self.riskControlCooldown)
                        self.riskControlQuietUntil = Date()
                            .addingTimeInterval(Self.riskControlQuietDuration)
                        return nil
                    }
                    guard case .transport = error, attempt == 0 else { return nil }
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return nil }
                    guard !Task.isCancelled else { return nil }
                } catch {
                    // No address, a preview clip, a dead server: the track change decides.
                    return nil
                }
            }
            return nil
        }
        playbackPrefetchTasks[id] = task
        _ = await task.value
        playbackPrefetchTasks[id] = nil
    }

    /// Skipping tracks leaves an unused entry behind; the cache only has to be small,
    /// never complete.
    private func pruneExpiredPlaybackURLs() {
        let now = Date()
        playbackURLCache = playbackURLCache.filter { $0.value.expiresAt > now }
        riskControlBlockedUntil = riskControlBlockedUntil.filter { $0.value > now }
    }

    private struct ResolvedPlaybackURL: Sendable {
        let url: URL
        let expiresAt: Date
    }

    /// Songs are resolved through the legacy `/song/url` route first, podcasts through
    /// the program route. Measured against a datacenter IP (the deployment these numbers
    /// came from), the two routes differ enormously for the *same* song:
    ///
    ///     /song/url?br=128000          12 / 12 served
    ///     /song/url/v1?level=standard   2 / 12 served (ten -460, and one -462 请完成验证)
    ///
    /// Nothing is lost by preferring the legacy route: this player only ever asks for
    /// 128 kbps (`level=standard` and `br=128000` are the same bitrate), so the address
    /// it gets back is the same audio it was getting when v1 happened to answer.
    ///
    /// v1 stays as a fallback only for an answer that names a problem with the song —
    /// a null address, a copyright gap — never for a refusal. A refusal is about the
    /// caller, and asking the stricter route after it produced `-462 请完成验证操作`
    /// in measurement: the second request does not just fail, it makes the next ones
    /// more likely to fail.
    private func resolvePlaybackURL(for track: Track) async throws -> ResolvedPlaybackURL {
        if track.isPodcastEpisode {
            do {
                return try await playbackURL(track, path: "/song/url", parameters: ["br": "128000"])
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ClientError {
                // An episode's `mainSong` resolves on the legacy route and frequently
                // answers null on v1, so v1 is only worth a try after a plain failure.
                if case .riskControl = error { throw error }
                if case .transport = error { throw error }
                let programError = error
                do {
                    return try await playbackURL(track, path: "/song/url/v1",
                                                 parameters: ["level": "standard"])
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw programError
                }
            } catch {
                throw error
            }
        }
        do {
            return try await playbackURL(track, path: "/song/url",
                                         parameters: ["br": "128000"])
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClientError {
            if case .riskControl = error { throw error }
            if case .transport = error { throw error }
            let legacyError = error
            do {
                return try await playbackURL(track, path: "/song/url/v1",
                                             parameters: ["level": "standard"])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw legacyError
            }
        } catch {
            throw error
        }
    }

    /// An address is a tiny answer to a question the player is blocked on, so it gets a
    /// much shorter ceiling than a playlist page: the 25s blanket timeout meant a
    /// half-dead connection kept the next song silent for that long before the fallback
    /// even began, and the fallback is another request with the same ceiling.
    private static let playbackAddressTimeout: TimeInterval = 8

    private func playbackURL(_ track: Track, path: String,
                             parameters: [String: String]) async throws -> ResolvedPlaybackURL {
        var query = parameters
        query["id"] = track.id
        let body = try await request(path, parameters: query, timeout: Self.playbackAddressTimeout)
        guard let item = (body["data"] as? [[String: Any]])?.first,
              let rawURL = item["url"] as? String,
              let url = Self.mediaURL(rawURL) else {
            throw ClientError.message("这首歌没有可播放地址。会员歌曲请先在设置中扫码登录；也可能受版权或地区限制。")
        }
        if let trial = item["freeTrialInfo"], !(trial is NSNull) {
            throw ClientError.message("服务只返回了试听片段。请在设置中扫码登录会员账号后重试，或选择有完整播放权限的歌曲。")
        }
        return ResolvedPlaybackURL(url: url, expiresAt: Self.playbackURLExpiry(item: item))
    }

    /// `expi` arrives as a lifetime in seconds, but older server builds have answered
    /// with an absolute time. Both are accepted and clamped: an address kept far past
    /// its lifetime fails the way a dead link does, one dropped too soon costs a
    /// round trip that the normal path pays anyway.
    private static func playbackURLExpiry(item: [String: Any]) -> Date {
        let now = Date()
        guard let value = (item["expi"] as? NSNumber)?.doubleValue, value.isFinite, value > 0 else {
            return now.addingTimeInterval(600)
        }
        let seconds: Double
        if value > 1_000_000_000_000 {
            seconds = value / 1_000 - now.timeIntervalSince1970
        } else if value > 1_000_000_000 {
            seconds = value - now.timeIntervalSince1970
        } else {
            seconds = value
        }
        return now.addingTimeInterval(min(3_600, max(60, seconds)))
    }

    func loginStatus() async throws -> String {
        // account/get often comes back 200 with an empty profile now. A still-valid
        // cookie must survive that, so try the other account endpoints before failing.
        for path in ["/login/status", "/user/account", "/user/level"] {
            try Task.checkCancellation()
            if let status = try await profileStatus(path) { return status }
        }
        throw ClientError.loginRequired
    }

    /// Reads a user id without discarding the saved cookie. Only an explicit 301 from a real library call does that.
    private func profileStatus(_ path: String) async throws -> String? {
        let body: [String: Any]
        do {
            body = try await request(path, preservesLogin: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClientError {
            if case .loginRequired = error { return nil }
            if path == "/login/status" { throw error }
            return nil
        } catch {
            throw error
        }
        let data = body["data"] as? [String: Any] ?? body
        if (data["code"] as? NSNumber)?.intValue == 301 { return nil }
        let profile = data["profile"] as? [String: Any]
        let account = data["account"] as? [String: Any]
        guard let id = Self.identifier(profile?["userId"]) ?? Self.identifier(account?["id"]) ?? Self.identifier(data["userId"]) else {
            return nil
        }
        userID = id
        let nickname = profile?["nickname"] as? String ?? account?["userName"] as? String
        return nickname.map { "已登录：\($0)" } ?? "已登录"
    }

    /// The liked list written by the last successful walk answers the same question a
    /// cold-launch walk would: what metadata belongs to these ids. Handing it over
    /// means the next launch can spend one `/likelist` instead of walking every page.
    func seedLikedTracks(_ tracks: [Track]) {
        guard likedPlaylistTracksCache == nil else { return }
        let snapshot = tracks.filter { $0.source == .netease }
        guard !snapshot.isEmpty else { return }
        likedPlaylistTracksCache = snapshot
        // `likedMemberIDs` stays nil on purpose: the membership check still has to run,
        // because the disk copy may be older than the account's current likes.
    }

    func likedTracks() async throws -> [Track] {
        let requestGeneration = generation
        let uid = try await requireUserID()
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        // `/likelist` is one small request and carries the authoritative membership
        // set. Reading it first means an unchanged list costs one request instead of
        // a full playlist page walk, which is what made this screen slow every time.
        var memberIDs: [String]?
        do {
            let body = try await request("/likelist", parameters: ["uid": uid], requiresLogin: true)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            var seenIDs = Set<String>()
            memberIDs = (body["ids"] as? [Any] ?? []).compactMap { Self.identifier($0) }
                .filter { seenIDs.insert($0).inserted }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            // Without membership the playlist fallback below still decides.
        }
        if let memberIDs, let cached = likedPlaylistTracksCache,
           likedMemberIDs == Set(memberIDs) {
            return mergedLikedTracks(cached)
        }
        var tracks = likedPlaylistTracksCache ?? []
        var hasPlaylist = likedPlaylistTracksCache != nil
        if !hasPlaylist {
            do {
                tracks = try await loadLikedPlaylistTracks(refresh: true)
                hasPlaylist = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard generation == requestGeneration else { throw CancellationError() }
            }
        }
        // A snapshot seeded from the last walk is metadata, and `/likelist` above is the
        // membership: the playlist no longer has to be walked again just to hear that.
        var ids = memberIDs ?? []
        var hasMembership = memberIDs != nil
        if memberIDs == nil {
            do {
                let body = try await request("/likelist", parameters: ["uid": uid], requiresLogin: true)
                try Task.checkCancellation()
                guard generation == requestGeneration else { throw CancellationError() }
                var seenIDs = Set<String>()
                ids = (body["ids"] as? [Any] ?? []).compactMap { Self.identifier($0) }
                    .filter { seenIDs.insert($0).inserted }
                hasMembership = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard generation == requestGeneration else { throw CancellationError() }
                // A secondary-source failure cannot erase known playlist members.
                if !hasPlaylist && playlistLikedTracks.isEmpty && playlistUnlikedTrackIDs.isEmpty { throw error }
            }
        }
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        // Playlist members are liked by definition. Keep their order, then fill missing likes.
        tracks = Self.uniqueTracks(tracks)
        if hasMembership {
            // A seeded snapshot is only metadata. Membership is what decides which rows
            // still belong, or an unlike made in the NetEase app would survive here.
            let current = Set(ids)
            tracks = tracks.filter { current.contains($0.id) }
        }
        let playlistIDs = Set(tracks.map(\.id))
        let missingIDs = ids.filter { !playlistIDs.contains($0) && !playlistUnlikedTrackIDs.contains($0) }
        let limit = 200
        for offset in stride(from: 0, to: missingIDs.count, by: limit) {
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            let batch = missingIDs[offset..<min(offset + limit, missingIDs.count)]
            do {
                let detail = try await request("/song/detail", parameters: ["ids": batch.joined(separator: ",")], requiresLogin: true)
                try Task.checkCancellation()
                guard generation == requestGeneration else { throw CancellationError() }
                let songs = (detail["songs"] as? [[String: Any]] ?? []).compactMap(Self.track)
                let byID = Dictionary(Self.uniqueTracks(songs).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                tracks.append(contentsOf: batch.compactMap { byID[$0] })
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard generation == requestGeneration else { throw CancellationError() }
                if !hasPlaylist && playlistLikedTracks.isEmpty { throw error }
            }
        }
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        // The fast path needs both the membership set and the metadata it belongs to,
        // so it is armed only when this call actually reconciled the two.
        if hasMembership, likedPlaylistTracksCache != nil, !tracks.isEmpty {
            // `tracks` is already the reconciled list (membership-filtered plus any
            // freshly fetched rows), so it is exactly what the next launch should seed.
            likedPlaylistTracksCache = tracks
            likedMemberIDs = Set(ids)
            // The membership set just arrived on the wire, so remember it as the
            // authoritative answer. Otherwise the first press of play after entering
            // 歌曲 asked `/likelist` again — one full request landing on the same
            // small server at the exact moment the stream address was needed.
            var membership = Set(ids)
            membership.formUnion(playlistLikedTracks.keys)
            membership.subtract(playlistUnlikedTrackIDs)
            likedTrackIDsCache = membership
        }
        return mergedLikedTracks(tracks)
    }

    /// Playlist members keep their order; local like/unlike overrides applied last.
    private func mergedLikedTracks(_ tracks: [Track]) -> [Track] {
        let additions = playlistLikedTracks.values.sorted { $0.id < $1.id }
        return Self.uniqueTracks(tracks + additions).filter { !playlistUnlikedTrackIDs.contains($0.id) }
    }

    func likedTrackIDs(_ trackIDs: [String]) async throws -> Set<String> {
        guard !trackIDs.isEmpty else { return [] }
        if let likedTrackIDsCache { return likedTrackIDsCache.intersection(trackIDs) }
        let requestGeneration = generation
        let uid = try await requireUserID()
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        // `/likelist` is one small request and is the authoritative membership set.
        // The playlist walk is only used when it is already cached: starting one here
        // made "is this heart red?" block on thousands of song details, which stalled
        // every list that opened before the liked list itself was loaded.
        var ids = Set<String>()
        do {
            let body = try await request("/likelist", parameters: ["uid": uid], requiresLogin: true)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            ids.formUnion((body["ids"] as? [Any] ?? []).compactMap { Self.identifier($0) })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            // Fall back only to membership we already hold; never start a walk here.
            if let cached = likedPlaylistTracksCache {
                ids.formUnion(cached.map(\.id))
            } else if !playlistLikedTracks.isEmpty || !playlistUnlikedTrackIDs.isEmpty {
                ids.formUnion(likedMemberIDs ?? [])
            } else {
                throw error
            }
        }
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        ids.formUnion(playlistLikedTracks.keys)
        ids.subtract(playlistUnlikedTrackIDs)
        likedTrackIDsCache = ids
        return ids.intersection(trackIDs)
    }

    /// Likes can change in the NetEase app while this one sits in the
    /// background, so the cached membership set is dropped on the way back in.
    func invalidateLikedMembershipCache() {
        likedTrackIDsCache = nil
    }

    private func loadLikedPlaylistTracks(refresh: Bool) async throws -> [Track] {
        if !refresh, let likedPlaylistTracksCache { return likedPlaylistTracksCache }
        let requestGeneration = generation
        let playlist = try await likedPlaylist()
        let tracks = try await playlistTracks(playlist)
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        likedPlaylistTracksCache = tracks
        return tracks
    }

    func like(track: Track) async throws {
        guard track.source == .netease, Self.identifier(track.id) != nil else {
            throw ClientError.message("请选择网易云歌曲。")
        }
        let requestGeneration = generation
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        let body = try await request("/like", parameters: ["id": track.id, "like": "true"])
        guard generation == requestGeneration else { throw CancellationError() }
        guard (body["code"] as? NSNumber)?.intValue == 200 else {
            throw ClientError.message("加入「我喜欢的音乐」歌单失败，请稍后重试。")
        }
        playlistLikedTracks[track.id] = track
        playlistUnlikedTrackIDs.remove(track.id)
        likedTrackIDsCache?.insert(track.id)
        likedMemberIDs?.insert(track.id)
        // The liked playlist's own row changed; a cached playlist listing is stale.
        invalidateResponseCache()
    }

    func unlike(track: Track) async throws {
        guard track.source == .netease, Self.identifier(track.id) != nil else {
            throw ClientError.message("请选择网易云歌曲。")
        }
        let requestGeneration = generation
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        let body = try await request("/like", parameters: ["id": track.id, "like": "false"])
        guard generation == requestGeneration else { throw CancellationError() }
        guard (body["code"] as? NSNumber)?.intValue == 200 else {
            throw ClientError.message("移出「我喜欢的音乐」歌单失败，请稍后重试。")
        }
        playlistLikedTracks[track.id] = nil
        playlistUnlikedTrackIDs.insert(track.id)
        likedTrackIDsCache?.remove(track.id)
        likedMemberIDs?.remove(track.id)
        invalidateResponseCache()
    }

    func scrobble(track: Track, playedSeconds: Int, sourceID: String?) async throws {
        guard track.source == .netease else {
            throw ClientError.message("请选择网易云歌曲。")
        }
        // A podcast is a `djprogram` named by its program id. Reporting the episode's song
        // id as a `song` play credits whichever catalogue song that asset belongs to.
        let reportType = track.isPodcastEpisode ? "djprogram" : "song"
        let reportID = track.isPodcastEpisode ? track.podcastProgramID : track.id
        // An episode restored from a snapshot written before the program id was kept cannot
        // be named correctly, so it is left unreported instead of being credited elsewhere.
        guard let reportID, Self.identifier(reportID) != nil else {
            throw ClientError.message("该播客单集缺少节目标识，已跳过听歌打卡。")
        }
        guard userID != nil, !cookie.isEmpty, !isLoggingOut, playedSeconds >= 10 else { return }
        // Search, charts and recommendations have no playlist origin; the album, or the show
        // for an episode, is the only truthful source those plays have.
        var parameters = ["id": reportID, "time": String(playedSeconds), "type": reportType]
        if let resolvedSourceID = sourceID ?? track.albumID ?? track.podcastRadioID {
            parameters["sourceid"] = resolvedSourceID
        }
        let body = try await request("/scrobble", parameters: parameters)
        guard (body["code"] as? NSNumber)?.intValue == 200 else {
            throw ClientError.message("听歌打卡失败。")
        }
    }

    private func likedPlaylist() async throws -> MusicPlaylist {
        let requestGeneration = generation
        let uid = try await requireUserID()
        var seen = Set<String>()
        var namedFallback: MusicPlaylist?
        var offset = 0
        let limit = 100
        while true {
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            let body = try await request("/user/playlist", parameters: ["uid": uid, "limit": String(limit), "offset": String(offset)], requiresLogin: true)
            guard generation == requestGeneration else { throw CancellationError() }
            let items = body["playlist"] as? [[String: Any]] ?? []
            var newItems = 0
            for item in items {
                guard let id = Self.identifier(item["id"]), seen.insert(id).inserted else { continue }
                newItems += 1
                let creator = item["creator"] as? [String: Any]
                guard Self.identifier(creator?["userId"]) == uid else { continue }
                let playlist = MusicPlaylist(id: id, title: "我喜欢的音乐", trackCount: (item["trackCount"] as? NSNumber)?.intValue, source: .netease, isLiked: true)
                if (item["specialType"] as? NSNumber)?.intValue == 5 { return playlist }
                if namedFallback == nil, item["name"] as? String == "我喜欢的音乐" { namedFallback = playlist }
            }
            guard newItems > 0, (body["more"] as? Bool ?? (items.count == limit)) else { break }
            offset += items.count
        }
        if let namedFallback { return namedFallback }
        throw ClientError.message("未找到「我喜欢的音乐」歌单，请在网易云 App 里确认。")
    }

    func recentTracks() async throws -> [Track] {
        let uid = try await requireUserID()
        let body = try await request("/record/recent/song", parameters: ["uid": uid, "type": "0", "limit": "100"], requiresLogin: true)
        let data = body["data"] as? [String: Any] ?? [:]
        let items = data["list"] as? [[String: Any]] ?? []
        return Self.uniqueTracks(items.compactMap { item in
            let song = (item["data"] ?? item["song"]) as? [String: Any] ?? item
            return Self.track(song)
        })
    }

    func dailyRecommendations() async throws -> [Track] {
        let requestGeneration = generation
        guard !cookie.isEmpty else { throw ClientError.loginRequired }
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        let body = try await request("/recommend/songs", requiresLogin: true)
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        let data = body["data"] as? [String: Any] ?? [:]
        return (data["dailySongs"] as? [[String: Any]] ?? []).compactMap(Self.track)
    }

    func personalFM() async throws -> [Track] {
        let requestGeneration = generation
        guard !cookie.isEmpty else { throw ClientError.loginRequired }
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        let body = try await request("/personal_fm", requiresLogin: true)
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        return (body["data"] as? [[String: Any]] ?? []).compactMap(Self.track)
    }

    /// The shows the user follows. NetEase calls these 电台 (DJ radios); on an iPod
    /// they are simply the podcast subscriptions behind the Podcasts menu.
    func podcastShows() async throws -> [PodcastShow] {
        let requestGeneration = generation
        guard !cookie.isEmpty else { throw ClientError.loginRequired }
        var shows: [PodcastShow] = []
        var seen = Set<String>()
        var offset = 0
        let limit = 100
        while true {
            let body = try await request("/dj/sublist",
                                         parameters: ["limit": String(limit), "offset": String(offset)],
                                         requiresLogin: true)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            let items = body["djRadios"] as? [[String: Any]] ?? []
            let page = items.compactMap { item -> PodcastShow? in
                guard let id = Self.identifier(item["id"]), let name = item["name"] as? String,
                      seen.insert(id).inserted else { return nil }
                let owner = item["dj"] as? [String: Any] ?? [:]
                return PodcastShow(id: id, title: name,
                                   author: owner["nickname"] as? String ?? "",
                                   episodeCount: (item["programCount"] as? NSNumber)?.intValue,
                                   artworkURL: Self.artworkURL(from: item),
                                   source: .netease)
            }
            shows.append(contentsOf: page)
            guard !page.isEmpty, items.count == limit else { break }
            offset += items.count
        }
        return shows
    }

    /// Newest episode first, which is the order a podcast list is read in.
    ///
    /// The walk is deliberately forgiving. NetEase answers a deep page of a long show
    /// with HTTP 406 for the next few tries, while its neighbours answer normally; the
    /// old code turned one refused page into a fatal error and dropped the 500 episodes
    /// that had already arrived, which made every large show look unplayable. A page is
    /// retried, then stepped over, and the pages that did arrive are published as they
    /// come so the list is usable before the walk ends.
    func podcastEpisodes(showID: String, onProgress: (@MainActor ([Track]) -> Void)? = nil) async throws -> [Track] {
        let requestGeneration = generation
        guard !cookie.isEmpty else { throw ClientError.loginRequired }
        var episodes: [Track] = []
        var seen = Set<String>()
        var offset = 0
        let limit = 100
        var refusalsInARow = 0
        while true {
            let body: [String: Any]
            do {
                body = try await podcastProgramPage(showID: showID, offset: offset, limit: limit)
                refusalsInARow = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ClientError {
                // A dropped login is about the account, not this page.
                if case .loginRequired = error { throw error }
                // A -460 is about the caller, not this show. Paging on would ask the
                // same window up to ten more times, so keep what arrived and stop.
                if case .riskControl = error {
                    if episodes.isEmpty { throw error }
                    break
                }
                refusalsInARow += 1
                // Nothing arrived: the screen needs the error, not an empty list.
                if episodes.isEmpty, refusalsInARow >= 2 { throw error }
                // The service has stopped answering this show; the pages already
                // collected are still the list the user asked for.
                if refusalsInARow >= 3 { break }
                offset += limit
                continue
            } catch {
                refusalsInARow += 1
                if episodes.isEmpty { throw error }
                if refusalsInARow >= 3 { break }
                offset += limit
                continue
            }
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            let items = body["programs"] as? [[String: Any]] ?? []
            let page = items.compactMap { Self.episode($0) }
                .filter { seen.insert($0.id).inserted }
            episodes.append(contentsOf: page)
            onProgress?(episodes)
            let more = body["more"] as? Bool ?? (items.count == limit)
            guard !page.isEmpty, more else { break }
            offset += items.count
            // Deep pages are refused when they are asked for back to back; a gap
            // between them is what keeps a thousand-episode show walkable.
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return episodes
    }

    /// One page of a show, with a short backoff retry. A single 406 or 5xx is a
    /// refusable-by-design answer that often succeeds on the second ask.
    private func podcastProgramPage(showID: String, offset: Int, limit: Int) async throws -> [String: Any] {
        let parameters = ["rid": showID, "limit": String(limit),
                          "offset": String(offset), "asc": "false"]
        do {
            return try await request("/dj/program", parameters: parameters, requiresLogin: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClientError {
            if case .loginRequired = error { throw error }
            // A risk refusal is not the deep-page 406 this retry exists for: asking
            // again 0.7s later is another request in the same window.
            if case .riskControl = error { throw error }
            try await Task.sleep(nanoseconds: 700_000_000)
            return try await request("/dj/program", parameters: parameters, requiresLogin: true)
        }
    }

    /// A program's audio is its `mainSong`; the program id itself has no stream.
    private static func episode(_ item: [String: Any]) -> Track? {
        guard let title = item["name"] as? String else { return nil }
        let radio = item["radio"] as? [String: Any] ?? [:]
        let song = item["mainSong"] as? [String: Any] ?? [:]
        // Older responses carry only `mainTrackId`; both name the same asset.
        guard let songID = identifier(song["id"]) ?? identifier(item["mainTrackId"]) else { return nil }
        let show = radio["name"] as? String ?? "播客"
        // The list keeps the length on the program, not always on `mainSong`.
        let milliseconds = song["dt"] as? NSNumber ?? song["duration"] as? NSNumber
            ?? item["duration"] as? NSNumber
        // The cover belongs to the show, not to the underlying song.
        var artworkItem: [String: Any] = [:]
        if let pic = radio["picUrl"] as? String { artworkItem["picUrl"] = pic }
        else if let pic = item["coverUrl"] as? String { artworkItem["picUrl"] = pic }
        return Track(id: songID, title: title, artist: show, album: show,
                     duration: (milliseconds?.doubleValue ?? 0) / 1_000,
                     source: .netease, spotifyURI: nil, streamURL: nil,
                     artworkURL: artworkURL(from: artworkItem), isPodcastEpisode: true,
                     podcastProgramID: identifier(item["id"]) ?? identifier(item["programId"]),
                     podcastRadioID: identifier(radio["id"]))
    }

    func playlists(onProgress: (@MainActor ([MusicPlaylist]) -> Void)? = nil) async throws -> [MusicPlaylist] {
        let requestGeneration = generation
        let uid = try await requireUserID()
        var playlists: [MusicPlaylist] = []
        var seen = Set<String>()
        var offset = 0
        let limit = 100
        while true {
            let body = try await request("/user/playlist", parameters: ["uid": uid, "limit": String(limit), "offset": String(offset)], requiresLogin: true)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            let items = body["playlist"] as? [[String: Any]] ?? []
            let page = items.compactMap { item -> MusicPlaylist? in
                guard let id = Self.identifier(item["id"]), let title = item["name"] as? String,
                      seen.insert(id).inserted else { return nil }
                // 我喜欢的音乐 is not a tag the list can infer from its name alone:
                // the account may rename it, while `specialType` stays 5.
                let isLiked = (item["specialType"] as? NSNumber)?.intValue == 5
                    || title == "我喜欢的音乐"
                return MusicPlaylist(id: id, title: title,
                                     trackCount: (item["trackCount"] as? NSNumber)?.intValue,
                                     source: .netease, isLiked: isLiked)
            }
            playlists.append(contentsOf: page)
            onProgress?(playlists)
            guard !page.isEmpty, (body["more"] as? Bool ?? (items.count == limit)) else { break }
            offset += items.count
        }
        return playlists
    }

    func playlistTracks(_ playlist: MusicPlaylist, onProgress: (@MainActor ([Track]) -> Void)? = nil,
                        yieldsToPlayback: Bool = false) async throws -> [Track] {
        guard playlist.source == .netease else { throw ClientError.message("请选择网易云歌单。") }
        let requestGeneration = generation
        _ = try await requireUserID()
        var tracks: [Track] = []
        var seen = Set<String>()
        var offset = 0
        let limit = 200
        // Publish page zero before starting the bounded parallel tail. Consume
        // completed pages in offset order to keep the original order and dedup.
        // Background indexing stays on the sequential path so it can wait for a song address.
        if let count = playlist.trackCount, !yieldsToPlayback {
            let first = try await playlistTrackPage(playlist.id, offset: 0, limit: limit)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            tracks = first.tracks.filter { seen.insert($0.id).inserted }
            onProgress?(tracks)
            guard first.itemCount > 0, !tracks.isEmpty, limit < count else { return tracks }
            return try await withThrowingTaskGroup(of: (Int, [Track], Int).self) { group in
                var nextOffset = limit
                var expectedOffset = limit
                var pending: [Int: ([Track], Int)] = [:]
                for _ in 0..<2 where nextOffset < count {
                    let pageOffset = nextOffset
                    nextOffset += limit
                    group.addTask { @MainActor in
                        let page = try await self.playlistTrackPage(playlist.id, offset: pageOffset, limit: limit)
                        return (pageOffset, page.tracks, page.itemCount)
                    }
                }
                while let (pageOffset, pageTracks, itemCount) = try await group.next() {
                    try Task.checkCancellation()
                    guard generation == requestGeneration else { throw CancellationError() }
                    pending[pageOffset] = (pageTracks, itemCount)
                    while let (orderedTracks, rawCount) = pending.removeValue(forKey: expectedOffset) {
                        let page = orderedTracks.filter { seen.insert($0.id).inserted }
                        guard rawCount > 0, !page.isEmpty else {
                            group.cancelAll()
                            return tracks
                        }
                        tracks.append(contentsOf: page)
                        onProgress?(tracks)
                        expectedOffset += limit
                    }
                    if nextOffset < count {
                        let pageOffset = nextOffset
                        nextOffset += limit
                        group.addTask { @MainActor in
                            let page = try await self.playlistTrackPage(playlist.id, offset: pageOffset, limit: limit)
                            return (pageOffset, page.tracks, page.itemCount)
                        }
                    }
                }
                return tracks
            }
        }
        while true {
            let body = try await request("/playlist/track/all", parameters: ["id": playlist.id, "limit": String(limit), "offset": String(offset)], requiresLogin: true)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            let items = body["songs"] as? [[String: Any]] ?? []
            let page = items.compactMap(Self.track).filter { seen.insert($0.id).inserted }
            tracks.append(contentsOf: page)
            onProgress?(tracks)
            guard !items.isEmpty, !page.isEmpty else { break }
            offset += limit
            if let count = playlist.trackCount {
                guard offset < count else { break }
            } else {
                guard items.count == limit, !page.isEmpty else { break }
            }
        }
        return tracks
    }

    private func playlistTrackPage(_ playlistID: String, offset: Int, limit: Int) async throws -> (tracks: [Track], itemCount: Int) {
        let body = try await request("/playlist/track/all", parameters: ["id": playlistID, "limit": String(limit), "offset": String(offset)], requiresLogin: true)
        let items = body["songs"] as? [[String: Any]] ?? []
        return (items.compactMap(Self.track), items.count)
    }

    /// Library paging polls until the current song-address request has finished.
    private func waitUntilPlaybackHasPriority() async throws {
        while playbackPriorityDepth > 0 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func requireUserID() async throws -> String {
        if let userID, !cookie.isEmpty { return userID }
        guard !cookie.isEmpty else { throw ClientError.loginRequired }
        _ = try await loginStatus()
        guard let userID else { throw ClientError.loginRequired }
        return userID
    }

    func createQRLogin() async throws -> NetEaseQRLogin {
        // Finish clearing a pending logout before starting another QR flow.
        if isLoggingOut { resetSession() }
        let keyBody = try await request("/login/qr/key")
        guard let keyData = keyBody["data"] as? [String: Any],
              let key = keyData["unikey"] as? String, !key.isEmpty else {
            throw ClientError.message("服务未返回二维码密钥，请检查服务版本后重试。")
        }
        let createBody = try await request("/login/qr/create", parameters: ["key": key])
        guard let data = createBody["data"] as? [String: Any],
              let url = data["qrurl"] as? String, Self.mediaURL(url) != nil else {
            throw ClientError.message("服务未返回二维码地址，请稍后重试。")
        }
        return NetEaseQRLogin(key: key, url: url)
    }

    func checkQRLogin(key: String) async throws -> NetEaseQRStatus {
        let requestGeneration = generation
        let body = try await request("/login/qr/check", parameters: ["key": key])
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        switch (body["code"] as? NSNumber)?.intValue {
        case 800: return .expired
        case 801: return .waiting
        case 802: return .scanned
        case 803:
            guard let value = body["cookie"] as? String, !value.isEmpty else {
                throw ClientError.message("扫码已确认，但服务未返回登录凭据。请检查服务版本并重新扫码。")
            }
            do { try NetEaseCookieKeychain.save(value, baseURL: baseURL) }
            catch {
                clearAuthentication()
                throw error
            }
            cookie = value
            userID = nil
            // Earlier status/library responses belong to the previous credentials.
            generation = UUID()
            likedPlaylistTracksCache = nil
            playlistLikedTracks = [:]
            playlistUnlikedTrackIDs = []
            return .authorized
        default: throw ClientError.message("无法识别扫码状态，请重新生成二维码。")
        }
    }

    func logout() async throws {
        let requestGeneration = generation
        isLoggingOut = true
        defer { if generation == requestGeneration { resetSession() } }
        _ = try await request("/logout")
    }

    private func request(_ path: String, parameters: [String: String] = [:], requiresLogin: Bool = false,
                         preservesLogin: Bool = false,
                         timeout: TimeInterval? = nil) async throws -> [String: Any] {
        guard !baseURL.isEmpty else {
            throw ClientError.message("请先到“设置 → 网易云设置”填写自己的服务地址。")
        }
        // Entering the same playlist or the playlists screen again is a repeat of a
        // question whose answer has not changed. Serving it from memory removes the
        // whole round trip instead of merely making it faster.
        if let cached = cachedResponse(path: path, parameters: parameters) { return cached }
        guard var components = URLComponents(string: baseURL),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw ClientError.message("服务地址无效，请填写完整的网页服务地址，不要包含账号、密码或查询参数。")
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = (components.path.isEmpty ? "" : "/" + components.path) + path
        components.queryItems = parameters.sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        } + [URLQueryItem(name: "timestamp", value: String(Int(Date().timeIntervalSince1970 * 1_000)))]
        guard let url = components.url else { throw ClientError.message("服务地址无效。") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        // The API server only forwards a `cookie` form field to NetEase. A Cookie header
        // is ignored, and URLSession drops it, so those GETs came back 301 and wiped a valid login.
        if !cookie.isEmpty {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = [URLQueryItem(name: "cookie", value: cookie)]
            request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        }
        let requestGeneration = generation
        do {
            // Library calls wait out an in-flight song address. They share one small server,
            // and a playback URL stuck behind playlist pages is what makes a tap feel failed.
            // Both address routes are the priority side of that rule, including the legacy
            // one podcasts resolve through.
            if path != "/song/url/v1", path != "/song/url" {
                try await waitUntilPlaybackHasPriority()
            }
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            let (data, response) = try await sendWithRetry(request, timeout: timeout)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            // A -460 is a short rate window about the caller, not a verdict on this song.
            // It is reported once and the player recovers on its own: retrying inside
            // this function would put a second request into the window that refuses it.
            guard let response = response as? HTTPURLResponse else {
                throw ClientError.message("网易云服务请求失败，请检查服务运行状态和网络连接。")
            }
            if !(200...299).contains(response.statusCode),
                let body = try? await Self.parseObject(data),
                (body["code"] as? NSNumber)?.intValue == -460 {
                noteRiskRefusal()
                throw ClientError.riskControl
            }
            if [301, 401, 403].contains(response.statusCode), requiresLogin || path == "/login/status" || preservesLogin {
                if !preservesLogin { clearAuthentication() }
                throw ClientError.loginRequired
            }
            guard (200...299).contains(response.statusCode) else {
                throw ClientError.message("网易云服务请求失败，请检查服务运行状态和网络连接。")
            }
            let parsed = try await Self.parseObject(data)
            // Parsing suspends: a logout or address change meanwhile makes this answer stale.
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            guard let body = parsed else {
                throw ClientError.message("服务返回格式无效，请确认地址指向兼容的网易云接口服务。")
            }
            let code = (body["code"] as? NSNumber)?.intValue ?? 200
            guard code == 200 || (path == "/login/qr/check" && (800...803).contains(code)) else {
                if code == -460 {
                    noteRiskRefusal()
                    throw ClientError.riskControl
                }
                if code == 301 {
                    if !preservesLogin { clearAuthentication() }
                    if requiresLogin || preservesLogin || path == "/login/status" { throw ClientError.loginRequired }
                    throw ClientError.message("网易云登录已失效，请在设置中重新扫码登录。")
                }
                throw ClientError.message("网易云接口返回错误（\(code)），请检查登录、版权和服务版本。")
            }
            storeResponse(body, path: path, parameters: parameters, byteCount: data.count)
            // One served answer is the only evidence available that the window has
            // lifted, so lift it here rather than waiting out the whole mute: the next
            // switch can be prefetched again.
            riskControlQuietUntil = nil
            return body
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where Self.isTransportFailure(error) {
            // Named apart from the generic message so playback can retry quietly
            // instead of treating it as "this song has no address".
            throw ClientError.transport(Self.transportMessage)
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.message("无法连接网易云服务。请确认手机可以访问服务地址、网络已连通并允许局域网访问。")
        }
    }

    private static let transportMessage = "与网易云服务的连接中断，请检查网络后重试。"

    /// Failures where the request never got a complete answer, so nothing was learned
    /// about the song. A refused -460 or a plain HTTP error is an answer, not this.
    private static func isTransportFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// The subset worth re-sending at once. A timeout is excluded on purpose: it means
    /// the server is slow, and a second attempt would only double the silence the
    /// listener is already sitting in.
    private static func isWorthRetrying(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// One extra attempt for a request that died in transit.
    ///
    /// Every authenticated NetEase call is a POST, and URLSession only re-sends a GET
    /// by itself — so a server restarting, or a carrier middlebox resetting a plain
    /// HTTP reply halfway through (the `5129/0 bytes … -1005` case), used to cost the
    /// caller the entire round trip on top of the wait it had already served. The
    /// broken socket is evicted from the pool by the failure itself, so the retry
    /// dials fresh rather than reusing it. A refusal that did come back as an answer
    /// never reaches this path, so this cannot turn a -460 into a burst.
    private func sendWithRetry(_ urlRequest: URLRequest, timeout: TimeInterval?,
                               attempts: Int = 2) async throws -> (Data, URLResponse) {
        var urlRequest = urlRequest
        if let timeout { urlRequest.timeoutInterval = timeout }
        var lastError: URLError?
        for attempt in 1...max(1, attempts) {
            do {
                return try await session.data(for: urlRequest)
            } catch let error as URLError where Self.isWorthRetrying(error) {
                lastError = error
                guard attempt < attempts else { break }
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    /// A refusal is about this caller, so every speculative lookup stands down for the
    /// same window the per-song block uses. Playback still asks when the user asks, but
    /// the prefetch stays quiet instead of turning one refusal into a probe per song.
    private func noteRiskRefusal() {
        riskControlQuietUntil = Date().addingTimeInterval(Self.riskControlQuietDuration)
    }

    /// A freshly parsed tree that nothing mutates afterwards, carried back from the parsing thread.
    private struct ParsedObject: @unchecked Sendable {
        let value: [String: Any]?
    }

    /// A 200-song playlist page is several hundred kilobytes of JSON. Parsing it on
    /// the main actor held the UI for every page of every playlist walk.
    private static func parseObject(_ data: Data) async throws -> [String: Any]? {
        try await Task.detached(priority: Task.currentPriority) {
            ParsedObject(value: try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }.value.value
    }

    private static func identifier(_ value: Any?) -> String? {
        if let number = value as? NSNumber, number.int64Value > 0 { return number.stringValue }
        if let text = value as? String, let number = UInt64(text), number > 0 { return text }
        return nil
    }

    private static func uniqueTracks(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    private static func track(_ item: [String: Any]) -> Track? {
        guard let identifier = item["id"] as? NSNumber, let title = item["name"] as? String else { return nil }
        let artists = (item["ar"] ?? item["artists"]) as? [[String: Any]] ?? []
        let artist = artists.compactMap { $0["name"] as? String }.joined(separator: " / ")
        let album = (item["al"] ?? item["album"]) as? [String: Any] ?? [:]
        let duration = ((item["dt"] ?? item["duration"]) as? NSNumber)?.doubleValue ?? 0
        return Track(id: identifier.stringValue, title: title,
                     artist: artist.isEmpty ? "未知艺人" : artist,
                     album: album["name"] as? String ?? "未知专辑", duration: duration / 1_000,
                     source: .netease, spotifyURI: nil, streamURL: nil,
                     artworkURL: artworkURL(from: item),
                     albumID: Self.identifier(album["id"]))
    }

    /// Every list endpoint spells the cover differently: playlist and search rows
    /// use `al.picUrl`, some detail/recent responses leave it empty and only keep
    /// `album.picUrl` or a top-level `picUrl`. Missing any of them showed the
    /// placeholder on Now Playing for those songs.
    private static func artworkURL(from item: [String: Any]?) -> URL? {
        guard let item else { return nil }
        let album = (item["al"] ?? item["album"]) as? [String: Any] ?? [:]
        let candidates = [album["picUrl"], item["picUrl"], album["picUrlStr"], album["coverUrl"]]
        for candidate in candidates {
            if let text = candidate as? String,
               let url = artworkURL(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return url }
        }
        return nil
    }

    /// Now Playing can hold a row that arrived without a cover (older endpoints,
    /// restored snapshots). `/song/detail` is the authoritative source for it.
    func artworkURL(forTrackID trackID: String) async -> URL? {
        guard Self.identifier(trackID) != nil else { return nil }
        let requestGeneration = generation
        do {
            let body = try await request("/song/detail", parameters: ["ids": trackID])
            try Task.checkCancellation()
            guard generation == requestGeneration else { return nil }
            return Self.artworkURL(from: (body["songs"] as? [[String: Any]])?.first)
        } catch {
            return nil
        }
    }

    private static func artworkURL(_ value: String) -> URL? {
        guard let url = mediaURL(value),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "param" }
        query.append(URLQueryItem(name: "param", value: "300y300"))
        components.queryItems = query
        return components.url
    }

    private static func mediaURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}
