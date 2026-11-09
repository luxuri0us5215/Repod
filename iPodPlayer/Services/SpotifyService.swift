import Combine
import Foundation
@preconcurrency import SpotifyiOS
import UIKit

@MainActor
final class SpotifyService: NSObject, ObservableObject {
    @Published private(set) var isLoggedIn = false
    @Published private(set) var statusMessage = "请在设置中登录 Spotify"
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsedSeconds = 0.0
    @Published private(set) var durationSeconds = 0.0
    @Published private(set) var currentURI: String?
    @Published private(set) var isAuthenticating = false
    private(set) var lastLikeWriteMessage: String?

    var onError: ((String) -> Void)?
    var onTrackChange: ((Track) -> Void)?
    var onEnded: (() -> Void)?

    private let session = URLSession(configuration: .ephemeral)
    private var tokens: Tokens?
    private var sessionManager: SPTSessionManager?
    private var sessionConfiguration: Configuration?
    private var sessionRenewal: CheckedContinuation<String, Error>?
    private var sessionRenewalTimeout: Task<Void, Never>?
    private var automaticTokenRefresh: Task<Void, Never>?
    private var loginPlaybackTrack: Track?
    private var authenticationConfiguration: Configuration?
    private var authenticationGeneration = UUID()
    private var refreshTask: Task<String, Error>?
    private var remote: SPTAppRemote?
    private var remoteConfiguration: Configuration?
    private var pendingTrack: Track?
    private var requestedURI: String?
    private var playbackGeneration = UUID()
    private var knownTracks: [String: Track] = [:]
    private var trackMetadataTask: Task<Void, Never>?
    private var trackMetadataGeneration = UUID()
    private var remoteTrackFallback: Track?
    private var notifiedTrackURI: String?
    private let likedPlaylistIDKey = "spotifyLikedPlaylistID"
    private let likedTracksOverrideKey = "spotifyPlaylistLikedTracks"
    private let unlikedTrackIDsOverrideKey = "spotifyPlaylistUnlikedTrackIDs"
    private var playlistLikedTracks: [String: Track] = [:]
    private var playlistUnlikedTrackIDs = Set<String>()
    private var artistIDByName: [String: String] = [:]
    private var likedTracksCache: LikedPlaylistContents?
    private var cachedPlaylistTrackIDs: [String: Set<String>] = [:]
    private var likedTracksTask: Task<LikedPlaylistContents, Error>?
    private var likedCacheGeneration = UUID()
    /// The real playlist this app writes likes into. It is an ordinary playlist in
    /// the user's account, so 歌单 must not list it twice: 我喜欢的音乐 is its
    /// only entry. Nil until a like (or a liked-list load) resolves it.
    var likedAnchorPlaylistID: String? {
        UserDefaults.standard.string(forKey: likedPlaylistIDKey)
    }
    private var isConnecting = false
    private var isWakingSpotify = false
    private var wakeAttempted = false
    private var userPlaybackRequested = false
    private var connectionMayWake = false
    private var pendingResume = false
    private var resumeRPCReconnectAttempted = false
    private var playRPCReconnectAttempted = false
    private var invalidGrantPlaybackGeneration: UUID?
    private var resumeConnectionTask: Task<Void, Never>?
    private var connectionTimeout: Task<Void, Never>?
    private var stateTimer: Timer?
    private var interpolationTimer: Timer?
    private var lastPlayerState: (uri: String, isPlaying: Bool, position: Double, duration: Double)?
    private var endedEventURI: String?
    private var suppressEndDetection = false

    override init() {
        super.init()
        loadPersistedLikeOverrides()
        do {
            if let data = try TokenKeychain.read() {
                let stored = try JSONDecoder().decode(Tokens.self, from: data)
                if let configuration = try? readConfiguration(), stored.matches(configuration) {
                    tokens = stored
                    isLoggedIn = true
                    ensureSessionManager(configuration)
                    scheduleAutomaticTokenRefresh()
                } else {
                    // Keep saved credentials recoverable if configuration is temporarily unavailable.
                    tokens = nil
                    isLoggedIn = false
                }
            }
        } catch {
            statusMessage = "无法恢复 Spotify 登录，请在设置中重新登录。"
        }
    }

    deinit {
        stateTimer?.invalidate()
        interpolationTimer?.invalidate()
        connectionTimeout?.cancel()
        refreshTask?.cancel()
        resumeConnectionTask?.cancel()
        likedTracksTask?.cancel()
        trackMetadataTask?.cancel()
        automaticTokenRefresh?.cancel()
        sessionRenewalTimeout?.cancel()
        sessionRenewal?.resume(throwing: CancellationError())
    }

    func configurationChanged() {
        let configuration = try? readConfiguration()
        if configuration != sessionConfiguration || (tokens != nil && tokens?.matches(configuration) != true) {
            // Configuration edits must never erase recoverable keychain credentials.
            authenticationGeneration = UUID()
            isAuthenticating = false
            authenticationConfiguration = nil
            loginPlaybackTrack = nil
            disconnect()
            refreshTask?.cancel()
            refreshTask = nil
            automaticTokenRefresh?.cancel()
            sessionRenewalTimeout?.cancel()
            sessionRenewal?.resume(throwing: CancellationError())
            sessionRenewal = nil
            sessionManager?.delegate = nil
            sessionManager = nil
            sessionConfiguration = nil
            remote?.delegate = nil
            remote = nil
            remoteConfiguration = nil
            tokens = nil
            isLoggedIn = false
            likedTracksCache = nil
            playlistLikedTracks = [:]
            playlistUnlikedTrackIDs = []
            cachedPlaylistTrackIDs = [:]
            likedCacheGeneration = UUID()
            likedTracksTask?.cancel()
            likedTracksTask = nil
        }
        if let configuration, tokens == nil,
           let data = try? TokenKeychain.read(),
           let stored = try? JSONDecoder().decode(Tokens.self, from: data), stored.matches(configuration) {
            tokens = stored
            isLoggedIn = true
            loadPersistedLikeOverrides()
            ensureSessionManager(configuration)
            scheduleAutomaticTokenRefresh()
        }
        if !isLoggedIn { statusMessage = "设置已更新，请登录 Spotify" }
    }

    func login(clientID: String, redirectURI: String) {
        beginLogin(clientID: clientID, redirectURI: redirectURI, playbackTrack: nil)
    }

    private func beginLogin(clientID: String, redirectURI: String, playbackTrack: Track?) {
        do {
            let configuration = try validateConfiguration(clientID: clientID, redirectURI: redirectURI)
            if isAuthenticating {
                if authenticationConfiguration == configuration { loginPlaybackTrack = playbackTrack }
                return
            }
            disconnect()
            refreshTask?.cancel()
            refreshTask = nil
            automaticTokenRefresh?.cancel()
            sessionRenewalTimeout?.cancel()
            sessionRenewal?.resume(throwing: CancellationError())
            sessionRenewal = nil
            sessionManager?.delegate = nil
            sessionManager = nil
            sessionConfiguration = nil
            authenticationGeneration = UUID()
            likedTracksTask?.cancel()
            likedTracksTask = nil
            likedTracksCache = nil
            likedCacheGeneration = UUID()
            playlistLikedTracks = [:]
            playlistUnlikedTrackIDs = []
            // Playlist membership belongs to the previous account.
            cachedPlaylistTrackIDs = [:]
            authenticationConfiguration = configuration
            loginPlaybackTrack = playbackTrack
            UserDefaults.standard.set(configuration.clientID, forKey: "spotifyClientID")
            UserDefaults.standard.set(configuration.redirectURI, forKey: "spotifyRedirectURI")
            ensureSessionManager(configuration)
            isAuthenticating = true
            statusMessage = "正在打开 Spotify 登录…"
            // SPTSessionManager uses PKCE without a client secret or token-swap backend.
            let scopes: SPTScope = [.appRemoteControl, .playlistReadPrivate, .playlistReadCollaborative,
                                    .userLibraryRead, .userLibraryModify, .userReadRecentlyPlayed,
                                    .playlistModifyPublic, .playlistModifyPrivate, .userModifyPlaybackState,
                                    .userReadPrivate]
            sessionManager?.initiateSession(with: scopes, options: .default, campaign: nil)
        } catch { report(error) }
    }

    private func ensureSessionManager(_ configuration: Configuration) {
        guard sessionManager == nil || sessionConfiguration != configuration else { return }
        sessionManager?.delegate = nil
        let sdkConfiguration = SPTConfiguration(clientID: configuration.clientID, redirectURL: configuration.redirectURL)
        sdkConfiguration.playURI = ""
        let manager = SPTSessionManager(configuration: sdkConfiguration, delegate: self)
        manager.alwaysShowAuthorizationDialog = false
        if let tokens, tokens.matches(configuration), let archive = tokens.sdkSession {
            manager.session = try? NSKeyedUnarchiver.unarchivedObject(ofClass: SPTSession.self, from: archive)
        }
        sessionManager = manager
        sessionConfiguration = configuration
    }

    func logout() {
        invalidGrantPlaybackGeneration = nil
        authenticationGeneration = UUID()
        authenticationConfiguration = nil
        isAuthenticating = false
        loginPlaybackTrack = nil
        automaticTokenRefresh?.cancel()
        automaticTokenRefresh = nil
        sessionRenewalTimeout?.cancel()
        sessionRenewal?.resume(throwing: CancellationError())
        sessionRenewal = nil
        sessionManager?.delegate = nil
        sessionManager = nil
        sessionConfiguration = nil
        refreshTask?.cancel()
        refreshTask = nil
        isWakingSpotify = false
        disconnect()
        wakeAttempted = false
        remote?.delegate = nil
        remote = nil
        remoteConfiguration = nil
        tokens = nil
        knownTracks = [:]
        remoteTrackFallback = nil
        notifiedTrackURI = nil
        likedCacheGeneration = UUID()
        likedTracksTask?.cancel()
        likedTracksTask = nil
        likedTracksCache = nil
        cachedPlaylistTrackIDs = [:]
        playlistLikedTracks = [:]
        playlistUnlikedTrackIDs = []
        clearPersistedLikeOverrides()
        UserDefaults.standard.removeObject(forKey: likedPlaylistIDKey)
        currentURI = nil
        elapsedSeconds = 0
        durationSeconds = 0
        isLoggedIn = false
        lastLikeWriteMessage = nil
        statusMessage = "请在设置中登录 Spotify"
        do { try TokenKeychain.delete() } catch { report(error) }
    }

    private static func normalizedSearchKey(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    /// Split a collaboration artist string ("A / B", "A、B", "A, B", "A & B", "A feat. B") into individual names.
    static func splitArtistNames(_ artist: String) -> [String] {
        var normalized = artist
        for separator in [" / ", "、", ", ", " & ", " feat. ", " ft. ", " featuring "] {
            normalized = normalized.replacingOccurrences(of: separator, with: "\n")
        }
        return normalized.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func search(query: String, offset: Int) async throws -> SearchPage {
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query),
                                 URLQueryItem(name: "type", value: "track"),
                                 URLQueryItem(name: "market", value: "from_token"),
                                 URLQueryItem(name: "limit", value: "10"),
                                 URLQueryItem(name: "offset", value: String(offset))]
        guard let url = components.url else { throw ServiceError.invalidResponse }
        let data = try await apiData(url: url)
        try Task.checkCancellation()
        let response: SearchResponse
        do { response = try JSONDecoder().decode(SearchResponse.self, from: data) }
        catch { throw ServiceError.invalidResponse }
        let tracks = response.tracks.items.compactMap { $0.track }
        for track in tracks {
            if let uri = track.spotifyURI { knownTracks[uri] = track }
        }
        let normalizedQuery = query.lowercased()
        let ranked = tracks.filter { $0.artist.lowercased().contains(normalizedQuery) }
            + tracks.filter { !$0.artist.lowercased().contains(normalizedQuery) }
        return SearchPage(tracks: ranked, hasMore: response.tracks.items.count == 10,
                          nextOffset: offset + 10)
    }

    private func fetchArtistTopTracks(artistID: String, limit: Int? = nil) async throws -> [Track] {
        guard let encodedID = artistID.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              !encodedID.isEmpty,
              let url = URL(string: "https://api.spotify.com/v1/artists/\(encodedID)/top-tracks?market=from_token") else {
            throw ServiceError.invalidResponse
        }
        let data = try await apiData(url: url)
        try Task.checkCancellation()
        let decoded = try JSONDecoder().decode(ArtistTopTracksResponse.self, from: data)
        let tracks = rememberLibraryTracks(decoded.tracks.compactMap(\.track))
        if let limit { return Array(tracks.prefix(limit)) }
        return tracks
    }

    func artistTracks(name: String, artistID: String? = nil) async throws -> [Track] {
        var resolvedID = artistID ?? artistIDByName[name]
        if resolvedID == nil {
            var components = URLComponents(string: "https://api.spotify.com/v1/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: name),
                URLQueryItem(name: "type", value: "artist"),
                URLQueryItem(name: "market", value: "from_token"),
                URLQueryItem(name: "limit", value: "5")
            ]
            if let url = components.url,
               let data = try? await apiData(url: url),
               let response = try? JSONDecoder().decode(ArtistOnlySearchResponse.self, from: data) {
                let target = Self.normalizedSearchKey(name)
                let matched = response.artists.items.first { Self.normalizedSearchKey($0.name) == target }
                    ?? response.artists.items.first
                resolvedID = matched?.id
                if let resolvedID { artistIDByName[name] = resolvedID }
            }
        }
        var collected: [Track] = []
        if let id = resolvedID, let top = try? await fetchArtistTopTracks(artistID: id) {
            collected.append(contentsOf: top)
        }
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "artist:\(name)"),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "market", value: "from_token"),
            URLQueryItem(name: "limit", value: "20")
        ]
        if let url = components.url,
           let data = try? await apiData(url: url),
           let response = try? JSONDecoder().decode(SearchResponse.self, from: data) {
            let target = Self.normalizedSearchKey(name)
            let extra = rememberLibraryTracks(response.tracks.items.compactMap(\.track)).filter { track in
                Self.splitArtistNames(track.artist).contains { Self.normalizedSearchKey($0) == target }
            }
            collected.append(contentsOf: extra)
        }
        var seen = Set<String>()
        return collected.filter { seen.insert($0.id).inserted }
    }

    func likedTracks() async throws -> [Track] {
        let contents = try await likedPlaylistContents()
        return contents.tracks
    }

    func isLiked(trackID: String) async throws -> Bool {
        try Task.checkCancellation()
        if playlistUnlikedTrackIDs.contains(trackID) { return false }
        if playlistLikedTracks[trackID] != nil { return true }
        let liked = try await likedTrackIDs([trackID])
        return liked.contains(trackID)
    }

    /// Official Liked Songs keep their order; playlist members and successful writes are liked too.
    func likedTrackIDs(_ trackIDs: [String]) async throws -> Set<String> {
        let contents = try await likedPlaylistContents()
        return contents.trackIDs.intersection(trackIDs.filter(Self.isSpotifyTrackID))
    }

    private func likedPlaylist() async throws -> WebPlaylist {
        guard isLoggedIn else { throw ServiceError.message("请先登录") }
        let generation = authenticationGeneration
        let data = try await apiData(url: URL(string: "https://api.spotify.com/v1/me")!)
        guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
        let user: CurrentUser
        do { user = try JSONDecoder().decode(CurrentUser.self, from: data) }
        catch { throw ServiceError.invalidResponse }
        guard !user.id.isEmpty else { throw ServiceError.invalidResponse }
        let items: [WebPlaylist] = try await libraryItems(path: "/v1/me/playlists")
        try Task.checkCancellation()
        guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
        // The stored ID wins over list order, even when another playlist is added.
        // Validate existence and ownership on every resolution; network errors never re-anchor it.
        if let anchoredID = UserDefaults.standard.string(forKey: likedPlaylistIDKey),
           let anchored = items.first(where: { $0.id == anchoredID && $0.owner?.id == user.id }) {
            return anchored
        }
        UserDefaults.standard.removeObject(forKey: likedPlaylistIDKey)
        guard let playlist = items.first(where: { $0.owner?.id == user.id }) else {
            throw ServiceError.message("Spotify 没有可用于点赞的自建歌单，请先在 Spotify 创建一个属于自己的歌单")
        }
        UserDefaults.standard.set(playlist.id, forKey: likedPlaylistIDKey)
        return playlist
    }

    private func likedPlaylistContents() async throws -> LikedPlaylistContents {
        try Task.checkCancellation()
        guard isLoggedIn else { throw ServiceError.message("请先登录") }
        if let likedTracksCache { return mergedLikedContents(likedTracksCache) }
        let generation = authenticationGeneration
        let cacheGeneration: UUID
        let task: Task<LikedPlaylistContents, Error>
        if let likedTracksTask {
            task = likedTracksTask
            cacheGeneration = likedCacheGeneration
        }
        else {
            cacheGeneration = UUID()
            likedCacheGeneration = cacheGeneration
            task = Task { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.loadLikedPlaylistContents()
            }
            likedTracksTask = task
        }
        do {
            let contents = try await task.value
            guard generation == authenticationGeneration, cacheGeneration == likedCacheGeneration,
                  isLoggedIn else { throw CancellationError() }
            likedTracksCache = contents
            likedTracksTask = nil
            try Task.checkCancellation()
            return mergedLikedContents(contents)
        } catch {
            // An older failing fetch must never clear a newer cache task.
            if generation == authenticationGeneration, cacheGeneration == likedCacheGeneration {
                likedTracksTask = nil
            }
            try Task.checkCancellation()
            guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
            if error is CancellationError { throw error }
            // Official GET was attempted first. Its failure cannot erase successful
            // playlist writes from either the liked list or batched heart membership.
            if !playlistLikedTracks.isEmpty || !playlistUnlikedTrackIDs.isEmpty {
                let snapshot = likedTracksCache ?? LikedPlaylistContents(tracks: [], trackIDs: [])
                return mergedLikedContents(snapshot)
            }
            throw error
        }
    }

    private func loadLikedPlaylistContents() async throws -> LikedPlaylistContents {
        let generation = authenticationGeneration
        // Keep official-GET ordering, but neither source is gated on the other succeeding.
        var tracks: [Track] = []
        var officialError: Error?
        do {
            let items: [LibraryTrackItem] = try await libraryItems(path: "/v1/me/tracks")
            try Task.checkCancellation()
            guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
            tracks = rememberLibraryTracks(items.compactMap(\.track))
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
            officialError = error
            // If the legacy collection endpoint is gone, read the new library
            // contents (same "Liked Songs" collection, different URL).
            do {
                let items: [LibraryTrackItem] = try await libraryItems(
                    path: "/v1/me/library/contents",
                    query: [URLQueryItem(name: "type", value: "track")]
                )
                try Task.checkCancellation()
                guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
                let modern = rememberLibraryTracks(items.compactMap(\.track))
                if !modern.isEmpty { tracks = modern } else { throw error }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
            }
        }
        do {
            let playlist = try await likedPlaylist()
            let playlistItems: [LibraryTrackItem] = try await libraryItems(path: "/v1/playlists/" + playlist.id + "/items")
            try Task.checkCancellation()
            guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
            tracks += rememberLibraryTracks(playlistItems.compactMap(\.track))
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
            // An unavailable playlist must not hide a successful official snapshot.
            if let officialError { throw officialError }
        }
        try Task.checkCancellation()
        guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
        var seen = Set<String>()
        tracks = tracks.filter { seen.insert($0.id).inserted }
        return LikedPlaylistContents(tracks: tracks, trackIDs: Set(tracks.compactMap(\.spotifyTrackID)))
    }

    private func refreshLikedPlaylist() {
        likedCacheGeneration = UUID()
        likedTracksTask?.cancel()
        likedTracksTask = nil
        // Playlist writes do not change the official snapshot. Keep it available offline.
        let generation = authenticationGeneration
        Task { [weak self] in
            guard let self, self.authenticationGeneration == generation, self.isLoggedIn else { return }
            // A successful mutation stays successful if its background refresh is offline.
            _ = try? await self.likedPlaylistContents()
        }
    }

    private func mergedLikedContents(_ contents: LikedPlaylistContents) -> LikedPlaylistContents {
        var seen = Set<String>()
        let additions = playlistLikedTracks.values.sorted { $0.id < $1.id }
        let tracks = (additions + contents.tracks).filter {
            guard let id = $0.spotifyTrackID else { return false }
            return !playlistUnlikedTrackIDs.contains(id) && seen.insert(id).inserted
        }
        return LikedPlaylistContents(tracks: tracks, trackIDs: Set(tracks.compactMap(\.spotifyTrackID)))
    }

    func like(track: Track) async throws {
        try await writeLikedTrack(track, liked: true)
    }

    func unlike(track: Track) async throws {
        try await writeLikedTrack(track, liked: false)
    }

    /// 心形写入走官方「保存到音乐库」：`PUT/DELETE /v1/me/library?uris=spotify:track:…`。
    /// 它写的就是「我喜欢的歌曲」本身，不需要再借一个自建歌单当伪喜欢列表。
    /// 旧账号或旧部署若不认这个接口，先退到 `/v1/me/tracks?ids=…`，最后才用歌单锚点兜底。
    private func writeLikedTrack(_ track: Track, liked: Bool) async throws {
        guard isLoggedIn else { throw ServiceError.message("请先登录") }
        guard let id = track.spotifyTrackID, Self.isSpotifyTrackID(id) else { throw ServiceError.invalidResponse }
        let generation = authenticationGeneration
        lastLikeWriteMessage = nil
        do {
            try await setSavedToLibrary(uri: "spotify:track:" + id, saved: liked)
            guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
            applyLikeWrite(track: track, id: id, liked: liked)
            saveLibraryWriteStyle(.modern)
            // Keep successful writes visible even if the official snapshot is stale or offline.
            refreshLikedPlaylist()
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch ServiceError.loginRequired {
            throw ServiceError.message("请先登录 Spotify 后再点赞")
        } catch ServiceError.http(401) {
            throw ServiceError.message("Spotify 登录已过期，请退出后重新登录再点赞")
        } catch {
            try Task.checkCancellation()
            guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
        }
        // Fallback 1: the legacy 「我喜欢的歌曲」 endpoint, same underlying collection.
        do {
            try await setSavedTrackLegacy(trackID: id, saved: liked)
            guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
            applyLikeWrite(track: track, id: id, liked: liked)
            saveLibraryWriteStyle(.legacy)
            refreshLikedPlaylist()
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch ServiceError.loginRequired {
            throw ServiceError.message("请先登录 Spotify 后再点赞")
        } catch ServiceError.http(401) {
            throw ServiceError.message("Spotify 登录已过期，请退出后重新登录再点赞")
        } catch {
            try Task.checkCancellation()
            guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
        }
        // Fallback 2: older behaviour, a playlist the user owns acts as a stand-in.
        do {
            let playlist = try await likedPlaylist()
            guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
            let url = try playlistItemsURL(playlistID: playlist.id)
            let body: Data
            if liked {
                body = try JSONSerialization.data(withJSONObject: ["uris": ["spotify:track:" + id]])
            } else {
                body = try JSONSerialization.data(withJSONObject: ["items": [["uri": "spotify:track:" + id]]])
            }
            _ = try await apiData(url: url, method: liked ? "POST" : "DELETE", body: body,
                                  expectedStatusCodes: liked ? [201] : [200])
            guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
            applyLikeWrite(track: track, id: id, liked: liked)
            refreshLikedPlaylist()
        } catch ServiceError.loginRequired { throw ServiceError.message("请先登录 Spotify 后再点赞") }
        catch ServiceError.http(401) { throw ServiceError.message("Spotify 登录已过期，请退出后重新登录再点赞") }
        catch ServiceError.http(403) {
            throw ServiceError.message("Spotify 拒绝修改歌单：账号可能缺少 playlist-modify-public / playlist-modify-private 权限，请退出 Spotify 登录后重新登录授权，并确认歌单属于自己")
        } catch ServiceError.http(404) {
            throw ServiceError.message("Spotify 点赞歌单不存在或已删除，请重试以重新选择本人的歌单")
        } catch ServiceError.http(let status) {
            throw ServiceError.message("Spotify 修改点赞歌单失败（HTTP \(status)），请稍后重试")
        }
    }

    private enum LibraryWriteStyle: String {
        case modern
        case legacy
    }

    private var libraryWriteStyleKey: String { "spotifyLibraryWriteStyle" }

    private func saveLibraryWriteStyle(_ style: LibraryWriteStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: libraryWriteStyleKey)
    }

    /// `PUT/DELETE /v1/me/library?uris=spotify:track:…` — 官方「我喜欢的歌曲」。
    private func setSavedToLibrary(uri: String, saved: Bool) async throws {
        guard let encoded = uri.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://api.spotify.com/v1/me/library?uris=" + encoded) else {
            throw ServiceError.invalidResponse
        }
        _ = try await apiData(url: url, method: saved ? "PUT" : "DELETE",
                              expectedStatusCodes: [200, 201, 204])
    }

    /// `PUT/DELETE /v1/me/tracks?ids=…` — 同一份「我喜欢的歌曲」的旧接口。
    private func setSavedTrackLegacy(trackID: String, saved: Bool) async throws {
        guard let url = URL(string: "https://api.spotify.com/v1/me/tracks?ids=" + trackID) else {
            throw ServiceError.invalidResponse
        }
        _ = try await apiData(url: url, method: saved ? "PUT" : "DELETE",
                              expectedStatusCodes: [200, 201, 204])
    }

    /// Keep a successful write visible even when the official snapshot lags behind.
    private func applyLikeWrite(track: Track, id: String, liked: Bool) {
        if liked {
            playlistLikedTracks[id] = track
            playlistUnlikedTrackIDs.remove(id)
        } else {
            playlistLikedTracks[id] = nil
            playlistUnlikedTrackIDs.insert(id)
        }
        savePersistedLikeOverrides()
    }

    private func playlistItemsURL(playlistID: String) throws -> URL {        guard let id = playlistID.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              !id.isEmpty, let url = URL(string: "https://api.spotify.com/v1/playlists/" + id + "/items") else {
            throw ServiceError.invalidResponse
        }
        return url
    }

    private static func isSpotifyTrackID(_ id: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return !id.isEmpty && id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    func recentTracks() async throws -> [Track] {
        let items: [LibraryTrackItem] = try await libraryItems(path: "/v1/me/player/recently-played", paginate: false)
        let tracks = rememberLibraryTracks(items.compactMap(\.track))
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    /// Track IDs in one playlist. Cached for this login so recommendations can exclude them without a second walk.
    func playlistTrackIDs(_ playlist: MusicPlaylist) async throws -> Set<String> {
        if let cached = cachedPlaylistTrackIDs[playlist.id] { return cached }
        guard playlist.source == .spotify,
              let id = playlist.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              !id.isEmpty else { throw ServiceError.invalidResponse }
        let items: [PlaylistItemID] = try await libraryItems(path: "/v1/playlists/" + id + "/items")
        let ids = Set(items.compactMap(\.trackID).filter(Self.isSpotifyTrackID))
        cachedPlaylistTrackIDs[playlist.id] = ids
        return ids
    }

    /// True when this login already walked this playlist, so re-reading it costs no request.
    func hasCachedPlaylistTrackIDs(_ playlist: MusicPlaylist) -> Bool {
        cachedPlaylistTrackIDs[playlist.id] != nil
    }

    /// Songs from albums by artists in the user's recent plays, skipping any ID in `excluding`.
    func tracksOutsidePlaylists(excluding: Set<String>) async throws -> [Track] {
        let artistIDs = try await recentArtistIDs(limit: 4)
        guard !artistIDs.isEmpty else {
            throw ServiceError.message("先听几首歌，推荐会按最近在听的艺人找还没放进歌单的歌。")
        }
        var results: [Track] = []
        var seen = Set<String>()
        for artistID in artistIDs {
            if results.count >= 20 { break }
            let albums = (try? await artistReleaseAlbums(artistID)) ?? []
            for album in albums.prefix(10) {
                if results.count >= 20 { break }
                let tracks = (try? await releaseTracks(album)) ?? []
                for track in tracks {
                    guard let id = track.spotifyTrackID, !excluding.contains(id), seen.insert(id).inserted else { continue }
                    results.append(track)
                    if results.count >= 20 { break }
                }
            }
        }
        guard !results.isEmpty else {
            throw ServiceError.message("最近在听的艺人，歌单里已经有这些歌了。")
        }
        return results.shuffled()
    }

    private func recentArtistIDs(limit: Int) async throws -> [String] {
        guard let url = URL(string: "https://api.spotify.com/v1/me/player/recently-played?limit=50") else {
            throw ServiceError.invalidResponse
        }
        let data = try await apiData(url: url)
        try Task.checkCancellation()
        let page: RecentArtistPage
        do { page = try JSONDecoder().decode(RecentArtistPage.self, from: data) }
        catch { throw ServiceError.invalidResponse }
        var ids: [String] = []
        var seen = Set<String>()
        for item in page.items {
            for artist in item.track.artists ?? [] {
                guard let id = artist.id, Self.isSpotifyTrackID(id), seen.insert(id).inserted else { continue }
                ids.append(id)
                if ids.count == limit { return ids }
            }
        }
        return ids
    }

    private func artistReleaseAlbums(_ artistID: String) async throws -> [ArtistRelease] {
        guard let encodedID = artistID.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              !encodedID.isEmpty,
              let url = URL(string: "https://api.spotify.com/v1/artists/\(encodedID)/albums?limit=10&market=from_token") else {
            throw ServiceError.invalidResponse
        }
        let data = try await apiData(url: url)
        try Task.checkCancellation()
        let page: ArtistReleasePage
        do { page = try JSONDecoder().decode(ArtistReleasePage.self, from: data) }
        catch { throw ServiceError.invalidResponse }
        return page.items.filter { album in
            guard let type = album.albumType else { return true }
            return type == "album" || type == "single"
        }
    }

    private func releaseTracks(_ album: ArtistRelease) async throws -> [Track] {
        guard let encodedID = album.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              !encodedID.isEmpty,
              let url = URL(string: "https://api.spotify.com/v1/albums/\(encodedID)/tracks?limit=50&market=from_token") else {
            throw ServiceError.invalidResponse
        }
        let data = try await apiData(url: url)
        try Task.checkCancellation()
        let page: AlbumTrackPage
        do { page = try JSONDecoder().decode(AlbumTrackPage.self, from: data) }
        catch { throw ServiceError.invalidResponse }
        let artwork = album.artworkURL
        let tracks = page.items.compactMap { item -> Track? in
            guard let id = item.id, Self.isSpotifyTrackID(id), let name = item.name, !name.isEmpty,
                  let uri = item.uri, uri.hasPrefix("spotify:track:"), let duration = item.durationMs else { return nil }
            return Track(id: id, title: name,
                         artist: {
                             let name = (item.artists ?? []).map(\.name).joined(separator: " / ")
                             return name.isEmpty ? "未知艺人" : name
                         }(),
                         album: album.name, duration: duration / 1000, source: .spotify,
                         spotifyURI: uri, artworkURL: artwork)
        }
        return rememberLibraryTracks(tracks)
    }

    func playlists(onProgress: (@MainActor ([MusicPlaylist]) -> Void)? = nil) async throws -> [MusicPlaylist] {
        // Only owned or collaborated playlists are openable in dev mode; followed
        // playlists of other users 403 on /playlists/{id}/items, so hide them here.
        let userID = try await currentUserID()
        let isOpenable: (WebPlaylist) -> Bool = { $0.owner?.id == userID || $0.collaborative == true }
        let items: [WebPlaylist] = try await libraryItems(path: "/v1/me/playlists", onProgress: { items in
            onProgress?(items.filter(isOpenable).map {
                MusicPlaylist(id: $0.id, title: $0.name, trackCount: $0.trackCount, source: .spotify)
            })
        })
        return items.filter(isOpenable).map {
            MusicPlaylist(id: $0.id, title: $0.name, trackCount: $0.trackCount, source: .spotify)
        }
    }

    /// The current Spotify user id, used to tell owned/collaborated playlists from followed ones.
    private func currentUserID() async throws -> String {
        let generation = authenticationGeneration
        let data = try await apiData(url: URL(string: "https://api.spotify.com/v1/me")!)
        try Task.checkCancellation()
        guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
        let user: CurrentUser
        do { user = try JSONDecoder().decode(CurrentUser.self, from: data) }
        catch { throw ServiceError.invalidResponse }
        guard !user.id.isEmpty else { throw ServiceError.invalidResponse }
        return user.id
    }

    /// Recommendations use only playlists owned by this account, without persisting fetched tracks.
    func ownedPlaylists() async throws -> [MusicPlaylist] {
        let generation = authenticationGeneration
        let data = try await apiData(url: URL(string: "https://api.spotify.com/v1/me")!)
        try Task.checkCancellation()
        guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
        let user: CurrentUser
        do { user = try JSONDecoder().decode(CurrentUser.self, from: data) }
        catch { throw ServiceError.invalidResponse }
        guard !user.id.isEmpty else { throw ServiceError.invalidResponse }
        let items: [WebPlaylist] = try await libraryItems(path: "/v1/me/playlists")
        try Task.checkCancellation()
        guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
        return items.filter { $0.owner?.id == user.id }.map {
            MusicPlaylist(id: $0.id, title: $0.name, trackCount: $0.trackCount, source: .spotify)
        }
    }

    func playlistTracks(_ playlist: MusicPlaylist, onProgress: (@MainActor ([Track]) -> Void)? = nil) async throws -> [Track] {
        guard playlist.source == .spotify,
              let id = playlist.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              !id.isEmpty else { throw ServiceError.invalidResponse }
        do {
            let items: [LibraryTrackItem] = try await libraryItems(path: "/v1/playlists/" + id + "/items", onProgress: { items in
                onProgress?(self.rememberLibraryTracks(items.compactMap(\.track)))
            })
            return rememberLibraryTracks(items.compactMap(\.track))
        } catch ServiceError.http(403) {
            throw ServiceError.message("此歌单不是你创建或参与的，Spotify 不开放查看。")
        }
    }

    private func libraryItems<Item: Decodable>(path: String, query: [URLQueryItem] = [], paginate: Bool = true,
                                                onProgress: (@MainActor ([Item]) -> Void)? = nil) async throws -> [Item] {
        guard isLoggedIn else { throw ServiceError.message("请先登录") }
        let generation = authenticationGeneration
        var components = URLComponents(string: "https://api.spotify.com" + path)!
        components.queryItems = query + [URLQueryItem(name: "limit", value: "50")]
        guard let firstURL = components.url else { throw ServiceError.invalidResponse }
        var nextURL: URL? = firstURL
        var items: [Item] = []
        var visited = Set<URL>()
        while let url = nextURL {
            try Task.checkCancellation()
            // A pagination link must never send the user's token to another host.
            guard url.scheme == "https", url.host == "api.spotify.com", visited.insert(url).inserted else {
                throw ServiceError.invalidResponse
            }
            let data: Data
            do { data = try await apiData(url: url) }
            catch ServiceError.loginRequired { throw ServiceError.message("请先登录") }
            try Task.checkCancellation()
            guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
            let page: LibraryPage<Item>
            do { page = try JSONDecoder().decode(LibraryPage<Item>.self, from: data) }
            catch { throw ServiceError.invalidResponse }
            items.append(contentsOf: page.items)
            onProgress?(items)
            nextURL = paginate ? page.next : nil
            if let nextURL, let total = page.total, let limit = page.limit, limit > 0 {
                // The first page is already visible. Fetch two tail pages at a
                // time, publishing each ordered prefix as soon as it is ready.
                let startOffset = (page.offset ?? 0) + limit
                return try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                    var nextOffset = startOffset
                    var expectedOffset = startOffset
                    var pending: [Int: Data] = [:]
                    for _ in 0..<2 where nextOffset < total {
                        let pageOffset = nextOffset
                        let pageURL = try self.libraryPageURL(nextURL, offset: pageOffset)
                        nextOffset += limit
                        group.addTask { @MainActor in
                            (pageOffset, try await self.libraryPageData(pageURL, generation: generation))
                        }
                    }
                    while let (pageOffset, data) = try await group.next() {
                        try Task.checkCancellation()
                        guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
                        pending[pageOffset] = data
                        while let orderedData = pending.removeValue(forKey: expectedOffset) {
                            let orderedPage: LibraryPage<Item>
                            do { orderedPage = try JSONDecoder().decode(LibraryPage<Item>.self, from: orderedData) }
                            catch { throw ServiceError.invalidResponse }
                            items.append(contentsOf: orderedPage.items)
                            onProgress?(items)
                            expectedOffset += limit
                        }
                        if nextOffset < total {
                            let pageOffset = nextOffset
                            let pageURL = try self.libraryPageURL(nextURL, offset: pageOffset)
                            nextOffset += limit
                            group.addTask { @MainActor in
                                (pageOffset, try await self.libraryPageData(pageURL, generation: generation))
                            }
                        }
                    }
                    return items
                }
            }
        }
        return items
    }

    private func libraryPageURL(_ nextURL: URL, offset: Int) throws -> URL {
        guard var components = URLComponents(url: nextURL, resolvingAgainstBaseURL: false) else {
            throw ServiceError.invalidResponse
        }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "offset" }
        query.append(URLQueryItem(name: "offset", value: String(offset)))
        components.queryItems = query
        guard let url = components.url else { throw ServiceError.invalidResponse }
        return url
    }

    private func libraryPageData(_ url: URL, generation: UUID) async throws -> Data {
        try Task.checkCancellation()
        guard url.scheme == "https", url.host == "api.spotify.com" else { throw ServiceError.invalidResponse }
        let data: Data
        do { data = try await apiData(url: url) }
        catch ServiceError.loginRequired { throw ServiceError.message("请先登录") }
        try Task.checkCancellation()
        guard generation == authenticationGeneration, isLoggedIn else { throw CancellationError() }
        return data
    }

    private func rememberLibraryTracks(_ tracks: [Track]) -> [Track] {
        for track in tracks {
            if let uri = track.spotifyURI { knownTracks[uri] = track }
        }
        return tracks
    }

    func play(_ track: Track) async throws {
        try Task.checkCancellation()
        let configuration = try readConfiguration()
        guard let uri = track.spotifyURI, uri.hasPrefix("spotify:track:") else {
            throw ServiceError.message("这首歌曲没有有效的 Spotify 播放地址。")
        }
        guard let spotifyURL = URL(string: "spotify:"), UIApplication.shared.canOpenURL(spotifyURL) else {
            throw ServiceError.message("尚未安装 Spotify。请安装并登录 Spotify 应用，再回来播放。")
        }
        guard isLoggedIn else {
            beginLogin(clientID: configuration.clientID, redirectURI: configuration.redirectURI, playbackTrack: track)
            return
        }
        let generation = UUID()
        playbackGeneration = generation
        invalidGrantPlaybackGeneration = nil
        lastPlayerState = nil
        endedEventURI = nil
        suppressEndDetection = false
        pendingResume = false
        resumeRPCReconnectAttempted = false
        playRPCReconnectAttempted = false
        resumeConnectionTask?.cancel()
        resumeConnectionTask = nil
        connectionTimeout?.cancel()
        userPlaybackRequested = true
        connectionMayWake = false
        wakeAttempted = false
        isWakingSpotify = false
        isConnecting = false
        let token: String
        do { token = try await validAccessToken() }
        catch ServiceError.authorizationExpired {
            guard invalidGrantPlaybackGeneration == generation else { throw CancellationError() }
            invalidGrantPlaybackGeneration = nil
            beginLogin(clientID: configuration.clientID, redirectURI: configuration.redirectURI, playbackTrack: track)
            return
        }
        try Task.checkCancellation()
        guard generation == playbackGeneration else { throw CancellationError() }
        ensureRemote(configuration)
        if track != remoteTrackFallback { knownTracks[uri] = track }
        pendingTrack = track
        requestedURI = uri
        remote?.connectionParameters.accessToken = token
        if remote?.isConnected == true { playPendingTrack() }
        else { connect(allowWake: true) }
    }

    func pause() {
        suppressEndDetection = true
        invalidGrantPlaybackGeneration = nil
        pendingResume = false
        resumeRPCReconnectAttempted = false
        loginPlaybackTrack = nil
        playbackGeneration = UUID()
        resumeConnectionTask?.cancel()
        resumeConnectionTask = nil
        userPlaybackRequested = false
        connectionMayWake = false
        pendingTrack = nil
        requestedURI = nil
        connectionTimeout?.cancel()
        if remote?.isConnected != true {
            isWakingSpotify = false
            isConnecting = false
            return
        }
        guard let player = connectedPlayer() else { return }
        player.pause(commandCallback)
    }

    func resume() {
        guard isLoggedIn else { report(ServiceError.loginRequired); return }
        guard currentURI != nil else {
            report(ServiceError.message("请先搜索并选择一首 Spotify 歌曲。"))
            return
        }
        playbackGeneration = UUID()
        invalidGrantPlaybackGeneration = nil
        resumeConnectionTask?.cancel()
        connectionTimeout?.cancel()
        pendingTrack = nil
        requestedURI = nil
        isConnecting = false
        isWakingSpotify = false
        userPlaybackRequested = true
        connectionMayWake = false
        wakeAttempted = false
        pendingResume = true
        resumeRPCReconnectAttempted = false
        suppressEndDetection = false
        let generation = playbackGeneration
        resumeConnectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = URL(string: "https://api.spotify.com/v1/me/player/play")!
                // Target the active device so resume does not jump to the Spotify app.
                var body: Data? = nil
                if let deviceID = try? await self.activeDeviceID(), !deviceID.isEmpty {
                    body = try? JSONSerialization.data(withJSONObject: ["device_id": deviceID])
                }
                _ = try await self.apiData(url: url, method: "PUT", body: body, expectedStatusCodes: [204])
                guard !Task.isCancelled, generation == self.playbackGeneration,
                      self.isLoggedIn else { return }
                self.resumeConnectionTask = nil
                self.pendingResume = false
                self.userPlaybackRequested = false
                self.isPlaying = true
                if self.remote?.isConnected == true {
                    self.fetchPlayerState()
                } else if let configuration = try? self.readConfiguration(),
                          let token = try? await self.validAccessToken() {
                    self.ensureRemote(configuration)
                    self.remote?.connectionParameters.accessToken = token
                    self.connect(allowWake: false)
                }
            } catch ServiceError.authorizationExpired, ServiceError.loginRequired {
                guard !Task.isCancelled, generation == self.playbackGeneration else { return }
                self.resumeConnectionTask = nil
                self.pendingResume = false
                self.userPlaybackRequested = false
                self.report(ServiceError.authorizationExpired)
            } catch {
                guard !Task.isCancelled, generation == self.playbackGeneration else { return }
                self.resumeConnectionTask = nil
                if let player = self.remote?.isConnected == true ? self.remote?.playerAPI : nil {
                    self.resumeConnectedPlayer(player, generation: generation)
                } else {
                    self.reconnectForResume()
                }
            }
        }
    }

    /// The active playback device id, so Web API resume targets this device.
    private func activeDeviceID() async throws -> String? {
        struct DevicesResponse: Decodable {
            let devices: [Device]
            struct Device: Decodable { let id: String?; let is_active: Bool }
        }
        let data = try await apiData(url: URL(string: "https://api.spotify.com/v1/me/player/devices")!)
        let response = try JSONDecoder().decode(DevicesResponse.self, from: data)
        return response.devices.first(where: { $0.is_active })?.id ?? response.devices.first?.id
    }

    private func resumeConnectedPlayer(_ player: SPTAppRemotePlayerAPI, generation: UUID) {
        let commandRemote = remote
        player.resume { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation,
                      self.remote === commandRemote, self.isLoggedIn else { return }
                if error != nil {
                    guard !self.resumeRPCReconnectAttempted else {
                        self.finishFailedWake()
                        self.report(ServiceError.message("Spotify 未能恢复播放，请再按中心键重试。"))
                        return
                    }
                    self.resumeRPCReconnectAttempted = true
                    // Reconnect before any wake even if the stale connection failed an RPC.
                    self.pendingResume = true
                    self.resetRemoteAfterCommandFailure()
                    self.reconnectForResume()
                } else {
                    self.pendingResume = false
                    self.userPlaybackRequested = false
                    self.fetchPlayerState()
                }
            }
        }
    }

    private func reconnectForResume() {
        guard pendingResume, resumeConnectionTask == nil else { return }
        let generation = playbackGeneration
        resumeConnectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let configuration = try self.readConfiguration()
                let token = try await self.validAccessToken()
                guard !Task.isCancelled, generation == self.playbackGeneration,
                      self.pendingResume, self.isLoggedIn else { return }
                self.ensureRemote(configuration)
                self.remote?.connectionParameters.accessToken = token
                self.resumeConnectionTask = nil
                // Resuming a paused track never wakes authorization. A failed connect is reported instead.
                self.connect(allowWake: false)
            } catch ServiceError.authorizationExpired {
                guard !Task.isCancelled, generation == self.playbackGeneration else { return }
                self.resumeConnectionTask = nil
                self.pendingResume = false
                self.userPlaybackRequested = false
                self.report(ServiceError.authorizationExpired)
            } catch {
                guard !Task.isCancelled, generation == self.playbackGeneration else { return }
                self.resumeConnectionTask = nil
                self.pendingResume = false
                self.userPlaybackRequested = false
                self.report(error)
            }
        }
    }

    func seek(toPosition milliseconds: Int) {
        guard durationSeconds.isFinite, durationSeconds > 0,
              let player = connectedPlayer() else { return }
        let target = min(Int(durationSeconds * 1000), max(0, milliseconds))
        player.seek(toPosition: target, callback: commandCallback)
        elapsedSeconds = Double(target) / 1000
    }

    func next() { connectedPlayer()?.skip(toNext: commandCallback) }
    func previous() { connectedPlayer()?.skip(toPrevious: commandCallback) }

    func handleURL(_ url: URL) {
        if isAuthenticating, let manager = sessionManager, let configuration = authenticationConfiguration,
           Self.matchesRedirect(url, configuration.redirectURL) {
            _ = manager.application(UIApplication.shared, open: url, options: [:])
            return
        }
        guard isWakingSpotify, userPlaybackRequested, let remote, let configuration = remoteConfiguration,
              Self.matchesRedirect(url, configuration.redirectURL) else { return }
        let parameters = remote.authorizationParameters(from: url)
        if parameters?[SPTAppRemoteErrorKey] != nil {
            finishFailedWake()
            report(ServiceError.message("Spotify 应用未授予远程播放权限，请重新登录后再试。"))
            return
        }
        // The wake's App Remote grant may differ from the Web API token; use it for this connection.
        if let accessToken = parameters?[SPTAppRemoteAccessTokenKey], !accessToken.isEmpty {
            remote.connectionParameters.accessToken = accessToken
        }
        isWakingSpotify = false
        isConnecting = false
        connect()
    }

    func handleSceneActive() {
        // Foreground return only renews tokens and reads an existing connection.
        // It must not replace a wake callback's App Remote grant or create a new wake intent.
        guard isLoggedIn else { return }
        let generation = playbackGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let token = try await self.validAccessToken()
                guard generation == self.playbackGeneration, self.isLoggedIn else { return }
                if self.remote?.isConnected == true {
                    self.startStateUpdates()
                } else if self.currentURI != nil, !self.isConnecting, !self.isWakingSpotify,
                          let configuration = try? self.readConfiguration() {
                    self.ensureRemote(configuration)
                    self.remote?.connectionParameters.accessToken = token
                    self.connect(allowWake: false)
                }
            } catch {}
        }
    }

    /// Disconnect only for source changes, logout or best-effort process termination.
    func disconnect() {
        invalidGrantPlaybackGeneration = nil
        pendingResume = false
        userPlaybackRequested = false
        connectionMayWake = false
        resumeConnectionTask?.cancel()
        resumeConnectionTask = nil
        trackMetadataGeneration = UUID()
        trackMetadataTask?.cancel()
        trackMetadataTask = nil
        stopStateTimers()
        lastPlayerState = nil
        endedEventURI = nil
        suppressEndDetection = false
        playbackGeneration = UUID()
        pendingTrack = nil
        requestedURI = nil
        loginPlaybackTrack = nil
        connectionTimeout?.cancel()
        isWakingSpotify = false
        isConnecting = false
        remote?.disconnect()
        isPlaying = false
    }

    private func ensureRemote(_ configuration: Configuration) {
        guard remote == nil || remoteConfiguration != configuration else { return }
        remote?.delegate = nil
        remote?.disconnect()
        ensureSessionManager(configuration)
        let sdkConfiguration = SPTConfiguration(clientID: configuration.clientID, redirectURL: configuration.redirectURL)
        let appRemote = SPTAppRemote(configuration: sdkConfiguration, logLevel: .none)
        appRemote.delegate = self
        remote = appRemote
        remoteConfiguration = configuration
    }

    private func connect(allowWake: Bool = false) {
        guard !isConnecting, remote?.isConnected != true else { return }
        connectionMayWake = allowWake && userPlaybackRequested
        isConnecting = true
        statusMessage = "正在连接 Spotify 应用…"
        remote?.connect()
        scheduleConnectionTimeout(seconds: 4)
    }

    private func wakeSpotify() {
        // Only an explicit new track may use authorizeAndPlayURI. Resume never opens authorization.
        guard userPlaybackRequested, connectionMayWake,
              pendingTrack != nil, let remote, !wakeAttempted else {
            finishFailedWake()
            return
        }
        connectionMayWake = false
        wakeAttempted = true
        isWakingSpotify = true
        isConnecting = false
        statusMessage = "正在唤醒 Spotify…"
        let generation = playbackGeneration
        // Empty URI resumes Spotify's last song. The pending App Remote command selects
        // a new track after connecting; resume never restarts the paused track from zero.
        remote.authorizeAndPlayURI("") { [weak self] installed in
            Task { @MainActor [weak self] in
                guard let self, generation == self.playbackGeneration, self.remote === remote else { return }
                if !installed {
                    self.finishFailedWake()
                    self.report(ServiceError.message("无法打开 Spotify。请安装并登录 Spotify 应用后重试。"))
                }
            }
        }
        scheduleConnectionTimeout(seconds: 25)
    }

    private func finishFailedWake() {
        connectionTimeout?.cancel()
        isConnecting = false
        isWakingSpotify = false
        connectionMayWake = false
        userPlaybackRequested = false
        pendingResume = false
        pendingTrack = nil
        requestedURI = nil
    }

    private func connectionFailed() {
        isConnecting = false
        connectionTimeout?.cancel()
        if connectionMayWake && userPlaybackRequested { wakeSpotify() }
        else {
            let wasResuming = pendingResume
            finishFailedWake()
            if wasResuming {
                report(ServiceError.message("Spotify 尚未连接。请打开 Spotify 后，再按播放重试。"))
            }
        }
    }

    private func scheduleConnectionTimeout(seconds: UInt64) {
        connectionTimeout?.cancel()
        let generation = playbackGeneration
        connectionTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            guard let self, generation == self.playbackGeneration, self.remote?.isConnected != true else { return }
            self.connectionFailed()
        }
    }

    private func resetRemoteAfterCommandFailure() {
        // Replacing the stale transport also revokes its queued delegate callbacks;
        // a retry cannot accidentally observe the old isConnected=true state.
        remote?.delegate = nil
        remote?.disconnect()
        remote = nil
        remoteConfiguration = nil
        isConnecting = false
        connectionTimeout?.cancel()
    }

    private func playPendingTrack() {
        guard let track = pendingTrack, let uri = track.spotifyURI,
              let appRemote = remote, let player = appRemote.playerAPI else { return }
        let generation = playbackGeneration
        player.play(uri) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation, self.remote === appRemote,
                      self.pendingTrack?.spotifyURI == uri, self.isLoggedIn else { return }
                if error != nil {
                    if !self.playRPCReconnectAttempted, self.userPlaybackRequested,
                       let configuration = self.remoteConfiguration,
                       (try? self.readConfiguration()) == configuration {
                        self.playRPCReconnectAttempted = true
                        let token = appRemote.connectionParameters.accessToken
                        self.resetRemoteAfterCommandFailure()
                        self.ensureRemote(configuration)
                        self.remote?.connectionParameters.accessToken = token
                        // Retry connect first; only its failure may perform a user wake.
                        self.connect(allowWake: true)
                    } else {
                        self.pendingTrack = nil
                        self.requestedURI = nil
                        self.userPlaybackRequested = false
                        self.report(ServiceError.message("Spotify 未能播放所选歌曲。请确认会员和歌曲可用，然后重试。"))
                    }
                } else {
                    self.pendingTrack = nil
                    self.userPlaybackRequested = false
                    self.fetchPlayerState()
                }
            }
        }
    }

    private func connectedPlayer() -> SPTAppRemotePlayerAPI? {
        guard isLoggedIn else {
            report(ServiceError.loginRequired)
            return nil
        }
        guard remote?.isConnected == true, let player = remote?.playerAPI else {
            report(ServiceError.message("Spotify 尚未连接，请打开 Spotify 后重新选择歌曲。"))
            return nil
        }
        return player
    }

    private var commandCallback: SPTAppRemoteCallback {
        { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error != nil {
                    self.report(ServiceError.message("Spotify 播放操作失败。请确认会员和歌曲可用，并在 Spotify 中重试。"))
                } else { self.fetchPlayerState() }
            }
        }
    }

    private func startStateUpdates() {
        stateTimer?.invalidate()
        interpolationTimer?.invalidate()
        fetchPlayerState()
        // State changes arrive via the App Remote subscription (playerStateDidChange).
        // Keep only a 10s fallback poll to correct drift; interpolate elapsed time locally.
        stateTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fetchPlayerState() }
        }
        interpolationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying, self.remote?.isConnected == true, self.durationSeconds > 0 else { return }
                self.elapsedSeconds = min(self.elapsedSeconds + 0.25, self.durationSeconds)
            }
        }
    }

    private func stopStateTimers() {
        stateTimer?.invalidate()
        stateTimer = nil
        interpolationTimer?.invalidate()
        interpolationTimer = nil
    }

    private func fetchPlayerState() {
        guard remote?.isConnected == true else { return }
        remote?.playerAPI?.getPlayerState { [weak self] result, error in
            guard error == nil, let state = result as? SPTAppRemotePlayerState else { return }
            Task { @MainActor [weak self] in self?.applyPlayerState(state) }
        }
    }

    private func applyPlayerState(_ state: SPTAppRemotePlayerState) {
        guard isLoggedIn, remote?.isConnected == true else { return }
        let uri = state.track.uri
        if let requestedURI, requestedURI != uri { return }
        requestedURI = nil
        let nextIsPlaying = !state.isPaused
        let nextPosition = max(0, Double(state.playbackPosition) / 1000)
        let nextDuration = Double(state.track.duration) / 1000
        let previousState = lastPlayerState
        let sameURI = previousState?.uri == uri
        let nearEnd = nextDuration > 0 && nextPosition >= max(0, nextDuration - 0.75)
        let previousNearEnd = (previousState?.duration ?? 0) > 0
            && (previousState?.position ?? 0) >= max(0, (previousState?.duration ?? 0) - 2.0)
        let pausedNearEnd = sameURI && previousState?.isPlaying == true && !nextIsPlaying && nearEnd
        let autoAdvancedAfterEnd = !sameURI && previousState?.isPlaying == true && previousNearEnd
        let endedURI = pausedNearEnd ? uri : (previousState?.uri ?? uri)
        let naturalEnd = (pausedNearEnd || autoAdvancedAfterEnd)
            && endedEventURI != endedURI && pendingTrack == nil
            && !pendingResume && !suppressEndDetection
        // Spotify already moved to another track. Adopting it and then advancing skips twice.
        let suppressTrackAdoption = naturalEnd && autoAdvancedAfterEnd
        lastPlayerState = (uri, nextIsPlaying, nextPosition, nextDuration)
        if nextIsPlaying && !autoAdvancedAfterEnd {
            endedEventURI = nil
            suppressEndDetection = false
        }
        isPlaying = nextIsPlaying
        elapsedSeconds = nextPosition
        durationSeconds = nextDuration
        let trackChanged = currentURI != uri
        if trackChanged {
            currentURI = uri
            endedEventURI = nil
            remoteTrackFallback = nil
            trackMetadataGeneration = UUID()
            trackMetadataTask?.cancel()
            trackMetadataTask = nil
        }
        if suppressTrackAdoption {
            // The app's own queue advance replaces this track.
        } else if let track = knownTracks[uri] {
            if trackChanged || notifiedTrackURI != uri {
                notifiedTrackURI = uri
                onTrackChange?(track)
            }
        } else if trackMetadataTask == nil {
            let generation = trackMetadataGeneration
            let authentication = authenticationGeneration
            let playback = playbackGeneration
            let metadataRemote = remote
            let duration = durationSeconds
            trackMetadataTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let track: Track
                let fetched: Bool
                do {
                    let id = String(uri.split(separator: ":").last ?? "")
                    guard uri.hasPrefix("spotify:track:"), !id.isEmpty,
                          let url = URL(string: "https://api.spotify.com/v1/tracks/\(id)") else {
                        throw ServiceError.invalidResponse
                    }
                    let data = try await self.apiData(url: url)
                    try Task.checkCancellation()
                    guard let fullTrack = try JSONDecoder().decode(WebTrack.self, from: data).track else {
                        throw ServiceError.invalidResponse
                    }
                    track = fullTrack
                    fetched = true
                } catch {
                    track = Track(
                        id: String(uri.split(separator: ":").last ?? ""), title: state.track.name,
                        artist: state.track.artist.name, album: state.track.album.name,
                        duration: duration, source: .spotify, spotifyURI: uri,
                        streamURL: nil, artworkURL: nil
                    )
                    fetched = false
                }
                guard !Task.isCancelled, self.trackMetadataGeneration == generation,
                      self.authenticationGeneration == authentication, self.playbackGeneration == playback,
                      self.isLoggedIn, self.remote === metadataRemote, self.remote?.isConnected == true,
                      self.currentURI == uri, self.requestedURI == nil || self.requestedURI == uri else {
                    if self.trackMetadataGeneration == generation { self.trackMetadataTask = nil }
                    return
                }
                // Keep a completed task as the same-URI attempt marker. A new
                // track or connection can try again; one-second state polls cannot.
                self.remoteTrackFallback = fetched ? nil : track
                if fetched { self.knownTracks[uri] = track }
                self.notifiedTrackURI = uri
                self.onTrackChange?(self.knownTracks[uri] ?? track)
            }
        }
        statusMessage = isPlaying ? "Spotify 正在播放" : "Spotify 已暂停"
        if naturalEnd {
            endedEventURI = endedURI
            onEnded?()
        }
    }

    /// Force a token refresh through the normal token flow and return the fresh access token.
    func refreshAccessToken() async throws -> String {
        try await validAccessToken(forceRefresh: true)
    }

    private func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        let configuration = try readConfiguration()
        guard let stored = tokens, stored.matches(configuration) else { throw ServiceError.loginRequired }
        if !forceRefresh, stored.expiresAt.timeIntervalSinceNow > 60 { return stored.accessToken }
        if let refreshTask { return try await refreshTask.value }
        let generation = authenticationGeneration
        let task = Task { @MainActor [weak self] () async throws -> String in
            guard let self else { throw CancellationError() }
            self.ensureSessionManager(configuration)
            if let manager = self.sessionManager, manager.session != nil {
                do {
                    return try await self.renewSDKSession(manager)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // SDK failures never delete credentials. Confirm any invalid_grant at
                    // Spotify's token endpoint before applying the existing logout rule.
                    self.sessionManager?.delegate = nil
                    self.sessionManager = nil
                    self.sessionConfiguration = nil
                }
            }
            let response = try await self.requestTokens([
                "grant_type": "refresh_token", "refresh_token": stored.refreshToken,
                "client_id": configuration.clientID
            ])
            try Task.checkCancellation()
            guard self.authenticationGeneration == generation else { throw CancellationError() }
            try self.persist(response, refreshToken: response.refreshToken ?? stored.refreshToken,
                             configuration: configuration)
            return response.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        do { return try await task.value }
        catch ServiceError.authorizationExpired {
            guard authenticationGeneration == generation else { throw CancellationError() }
            // logout invalidates every active playback task. Carry only the failed
            // intent's identity across it, so a later explicit logout/source switch/
            // play command can revoke the last-resort authorization handoff.
            let failedPlaybackGeneration = playbackGeneration
            logout()
            invalidGrantPlaybackGeneration = failedPlaybackGeneration
            throw ServiceError.authorizationExpired
        }
    }

    private func apiData(url: URL, method: String = "GET", body: Data? = nil,
                         expectedStatusCodes: Set<Int> = [200]) async throws -> Data {
        let generation = authenticationGeneration
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard generation == authenticationGeneration else { throw CancellationError() }
            let token = try await validAccessToken(forceRefresh: attempt > 0)
            guard generation == authenticationGeneration else { throw CancellationError() }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await perform(request)
            guard generation == authenticationGeneration else { throw CancellationError() }
            if response.statusCode == 401, attempt == 0 { continue }
            // Retry once on 429 (respect Retry-After) and 5xx. Never retry 403/400.
            if (response.statusCode == 429 || (500...599).contains(response.statusCode)), attempt == 0 {
                if response.statusCode == 429,
                   let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
                   let seconds = Double(retryAfter), seconds > 0 {
                    try await Task.sleep(nanoseconds: UInt64(min(seconds, 10) * 1_000_000_000))
                } else {
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                continue
            }
            guard expectedStatusCodes.contains(response.statusCode) else { throw ServiceError.http(response.statusCode) }
            return data
        }
        throw ServiceError.loginRequired
    }

    private func requestTokens(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = fields.sorted(by: { $0.key < $1.key }).map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "="
                + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await perform(request)
        if response.statusCode == 400 || response.statusCode == 401 {
            if let failure = try? JSONDecoder().decode(TokenErrorResponse.self, from: data),
               failure.error == "invalid_grant" {
                throw ServiceError.authorizationExpired
            }
            throw ServiceError.http(response.statusCode)
        }
        guard response.statusCode == 200 else { throw ServiceError.http(response.statusCode) }
        guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !tokens.accessToken.isEmpty, tokens.expiresIn > 0 else { throw ServiceError.invalidResponse }
        return tokens
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            var request = request
            request.timeoutInterval = 25
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
            return (data, response)
        } catch is URLError {
            throw ServiceError.message("无法访问 Spotify 服务，请检查网络连接后重试。")
        }
    }

    private func persist(_ response: TokenResponse, refreshToken: String, configuration: Configuration,
                         sdkSession: Data? = nil) throws {
        let updated = Tokens(accessToken: response.accessToken, refreshToken: refreshToken,
                             expiresAt: Date().addingTimeInterval(response.expiresIn),
                             clientID: configuration.clientID, redirectURI: configuration.redirectURI,
                             sdkSession: sdkSession)
        try TokenKeychain.save(JSONEncoder().encode(updated))
        tokens = updated
        isLoggedIn = true
        if !userPlaybackRequested, !isWakingSpotify, !isConnecting {
            remote?.connectionParameters.accessToken = response.accessToken
        }
        scheduleAutomaticTokenRefresh()
    }

    private func persistSDKSession(_ sdkSession: SPTSession, configuration: Configuration) throws {
        let archive = try NSKeyedArchiver.archivedData(withRootObject: sdkSession, requiringSecureCoding: true)
        let response = TokenResponse(accessToken: sdkSession.accessToken, refreshToken: sdkSession.refreshToken,
                                     expiresIn: max(1, sdkSession.expirationDate.timeIntervalSinceNow))
        try persist(response, refreshToken: sdkSession.refreshToken, configuration: configuration, sdkSession: archive)
    }

    private func renewSDKSession(_ manager: SPTSessionManager) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            sessionRenewal = continuation
            sessionRenewalTimeout?.cancel()
            sessionRenewalTimeout = Task { @MainActor [weak self, weak manager] in
                do { try await Task.sleep(nanoseconds: 25_000_000_000) }
                catch { return }
                guard let self, self.sessionManager === manager, let renewal = self.sessionRenewal else { return }
                self.sessionRenewal = nil
                renewal.resume(throwing: ServiceError.message("Spotify 令牌刷新超时，请检查网络。"))
            }
            manager.renewSession()
        }
    }

    private func scheduleAutomaticTokenRefresh(after retryDelay: TimeInterval? = nil) {
        automaticTokenRefresh?.cancel()
        guard let stored = tokens, isLoggedIn else { return }
        let generation = authenticationGeneration
        let delay = retryDelay ?? max(1, stored.expiresAt.timeIntervalSinceNow - 90)
        automaticTokenRefresh = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, generation == self.authenticationGeneration, self.isLoggedIn else { return }
            do { _ = try await self.validAccessToken(forceRefresh: true) }
            catch {
                guard generation == self.authenticationGeneration, self.isLoggedIn else { return }
                // Offline renewal retries silently; token refresh never opens Spotify.
                self.scheduleAutomaticTokenRefresh(after: 60)
            }
        }
    }

    private func readConfiguration() throws -> Configuration {
        try validateConfiguration(
            clientID: UserDefaults.standard.string(forKey: "spotifyClientID") ?? "",
            redirectURI: UserDefaults.standard.string(forKey: "spotifyRedirectURI") ?? "ipodplayer://spotify-login-callback"
        )
    }

    private func validateConfiguration(clientID: String, redirectURI: String) throws -> Configuration {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let redirectURI = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw ServiceError.message("请先在设置中填写 Spotify 开发者应用的客户端标识，再登录。")
        }
        guard let redirect = URL(string: redirectURI), let scheme = redirect.scheme,
              !["http", "https"].contains(scheme.lowercased()), redirect.host != nil,
              redirect.query == nil, redirect.fragment == nil else {
            throw ServiceError.message("请填写已在 Spotify 开发者后台登记的应用回调地址。")
        }
        let registered = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } ?? []
        guard registered.contains(where: { $0.caseInsensitiveCompare(scheme) == .orderedSame }) else {
            throw ServiceError.message("此回调协议尚未在应用中登记。请使用默认回调地址，或先在应用工程中登记对应协议再构建。")
        }
        return Configuration(clientID: clientID, redirectURI: redirectURI)
    }

    private static func matchesRedirect(_ url: URL, _ expected: URL) -> Bool {
        func normalizedPath(_ path: String) -> String {
            // Treat an omitted root path and "/" alike, preserving the root slash.
            if path.isEmpty { return "/" }
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return url.scheme?.lowercased() == expected.scheme?.lowercased()
            && url.host?.lowercased() == expected.host?.lowercased()
            && normalizedPath(url.path) == normalizedPath(expected.path)
    }

    private func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? "Spotify 操作失败，请稍后重试。"
        statusMessage = message
        onError?(message)
    }

    private struct Configuration: Equatable {
        let clientID: String
        let redirectURI: String
        var redirectURL: URL { URL(string: redirectURI)! }
    }

    private struct Tokens: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let clientID: String
        let redirectURI: String
        let sdkSession: Data?
        func matches(_ configuration: Configuration?) -> Bool {
            clientID == configuration?.clientID && redirectURI == configuration?.redirectURI
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
        }
    }

    private struct TokenErrorResponse: Decodable {
        let error: String
    }

    private struct PersistedLikedTrack: Codable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let spotifyURI: String?
        let artworkURL: URL?

        init(_ track: Track) {
            id = track.id
            title = track.title
            artist = track.artist
            album = track.album
            duration = track.duration
            spotifyURI = track.spotifyURI
            artworkURL = track.artworkURL
        }

        var track: Track {
            Track(id: id, title: title, artist: artist, album: album, duration: duration,
                  source: .spotify, spotifyURI: spotifyURI, streamURL: nil, artworkURL: artworkURL)
        }
    }

    private func loadPersistedLikeOverrides() {
        let defaults = UserDefaults.standard
        if let unliked = defaults.stringArray(forKey: unlikedTrackIDsOverrideKey) {
            playlistUnlikedTrackIDs = Set(unliked.filter(Self.isSpotifyTrackID))
        }
        if let data = defaults.data(forKey: likedTracksOverrideKey),
           let saved = try? JSONDecoder().decode([String: PersistedLikedTrack].self, from: data) {
            playlistLikedTracks = saved.reduce(into: [:]) { result, pair in
                guard Self.isSpotifyTrackID(pair.key), !playlistUnlikedTrackIDs.contains(pair.key) else { return }
                result[pair.key] = pair.value.track
            }
        }
    }

    private func savePersistedLikeOverrides() {
        let defaults = UserDefaults.standard
        defaults.set(Array(playlistUnlikedTrackIDs).sorted(), forKey: unlikedTrackIDsOverrideKey)
        let encoded = playlistLikedTracks.mapValues(PersistedLikedTrack.init)
        if let data = try? JSONEncoder().encode(encoded) {
            defaults.set(data, forKey: likedTracksOverrideKey)
        }
    }

    private func clearPersistedLikeOverrides() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: likedTracksOverrideKey)
        defaults.removeObject(forKey: unlikedTrackIDsOverrideKey)
    }

    private struct SearchResponse: Decodable {
        let tracks: Page
        struct Page: Decodable { let items: [WebTrack] }
    }

    private struct ArtistOnlySearchResponse: Decodable {
        let artists: ArtistPage
        struct ArtistPage: Decodable { let items: [WebArtist] }
    }

    private struct ArtistTopTracksResponse: Decodable {
        let tracks: [WebTrack]
    }

    private struct WebArtist: Decodable {
        let id: String
        let name: String
    }

    private struct LibraryPage<Item: Decodable>: Decodable {
        let items: [Item]
        let next: URL?
        let total: Int?
        let limit: Int?
        let offset: Int?
    }

    private struct LibraryTrackItem: Decodable {
        let webTrack: WebTrack?
        let webItem: WebTrack?
        let isLocal: Bool?
        enum CodingKeys: String, CodingKey {
            case webTrack = "track", webItem = "item", isLocal = "is_local"
        }
        var track: Track? { isLocal == true ? nil : (webItem ?? webTrack)?.track }
    }

    private struct WebPlaylist: Decodable {
        let id: String
        let name: String
        let tracks: TrackCount?
        /// Playlist list responses now report the count here instead of `tracks`.
        let items: TrackCount?
        let owner: Owner?
        let collaborative: Bool?
        struct Owner: Decodable { let id: String }
        struct TrackCount: Decodable { let total: Int }
        var trackCount: Int? { items?.total ?? tracks?.total }
    }

    private struct PlaylistItemID: Decodable {
        let track: Box?
        let item: Box?
        struct Box: Decodable { let id: String? }
        var trackID: String? { item?.id ?? track?.id }
    }

    private struct RecentArtistPage: Decodable {
        struct Item: Decodable {
            struct Track: Decodable {
                struct Artist: Decodable { let id: String? }
                let artists: [Artist]?
            }
            let track: Track
        }
        let items: [Item]
    }

    private struct ArtistRelease: Decodable {
        let id: String
        let name: String
        let albumType: String?
        let images: [WebTrack.Artwork]?
        enum CodingKeys: String, CodingKey {
            case id, name, images
            case albumType = "album_type"
        }
        var artworkURL: URL? {
            let images = images ?? []
            let adequate = images.filter { ($0.width ?? 0) >= 300 }
            return adequate.min { ($0.width ?? 0) < ($1.width ?? 0) }?.url
                ?? images.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url
        }
    }

    private struct ArtistReleasePage: Decodable {
        let items: [ArtistRelease]
    }

    private struct AlbumTrackPage: Decodable {
        struct Item: Decodable {
            let id: String?
            let name: String?
            let uri: String?
            let durationMs: Double?
            let artists: [Artist]?
            enum CodingKeys: String, CodingKey {
                case id, name, uri, artists, durationMs = "duration_ms"
            }
            struct Artist: Decodable { let name: String }
        }
        let items: [Item]
    }

    private struct CurrentUser: Decodable {
        let id: String
    }

    private struct LikedPlaylistContents {
        let tracks: [Track]
        let trackIDs: Set<String>
    }

    private struct WebTrack: Decodable {
        let id: String?
        let name: String?
        let uri: String?
        let durationMs: Double?
        let artists: [Artist]?
        let album: Album?
        let type: String?
        let isLocal: Bool?
        let isPlayable: Bool?
        enum CodingKeys: String, CodingKey {
            case id, name, uri, artists, album, type, durationMs = "duration_ms"
            case isLocal = "is_local", isPlayable = "is_playable"
        }
        struct Artist: Decodable { let name: String }
        struct Album: Decodable {
            let name: String
            let images: [Artwork]

            var artworkURL: URL? {
                // At the current cover size, 300px avoids downloading the
                // usual 640px image for every album in the strip.
                let adequate = images.filter { ($0.width ?? 0) >= 300 }
                return adequate.min { ($0.width ?? 0) < ($1.width ?? 0) }?.url
                    ?? images.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url
            }
        }
        struct Artwork: Decodable {
            let url: URL
            let width: Int?
        }
        var track: Track? {
            guard let id, !id.isEmpty, let uri, uri.hasPrefix("spotify:track:"),
                  let name, let durationMs, let artists, let album,
                  type == nil || type == "track", isLocal != true, isPlayable != false else { return nil }
            return Track(id: id, title: name, artist: artists.map(\.name).joined(separator: "、"),
                         album: album.name, duration: durationMs / 1000, source: .spotify,
                         spotifyURI: uri, streamURL: nil, artworkURL: album.artworkURL)
        }
    }

    private enum ServiceError: LocalizedError {
        case message(String), loginRequired, authorizationExpired, invalidResponse, http(Int)
        var errorDescription: String? {
            switch self {
            case .message(let message): return message
            case .loginRequired: return "请先前往设置登录 Spotify，再搜索或播放。"
            case .authorizationExpired: return "Spotify 授权已失效，请检查客户端标识与回调地址后重新登录。"
            case .invalidResponse: return "Spotify 返回了无法读取的数据，请稍后重试。"
            case .http(401): return "Spotify 登录已过期，请前往设置重新登录。"
            case .http(403): return "Spotify 拒绝访问。请确认开发者应用已允许此账号，且会员与歌曲可用。"
            case .http(429): return "Spotify 请求过于频繁，请稍后重试。"
            case .http: return "Spotify 服务暂时不可用，请稍后重试。"
            }
        }
    }
}

extension SpotifyService: SPTSessionManagerDelegate {
    nonisolated func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
        Task { @MainActor [weak self] in
            guard let self, self.sessionManager === manager, self.isAuthenticating,
                  let configuration = self.authenticationConfiguration,
                  (try? self.readConfiguration()) == configuration else { return }
            do {
                try self.persistSDKSession(session, configuration: configuration)
                self.isAuthenticating = false
                self.authenticationConfiguration = nil
                self.statusMessage = "已登录 Spotify"
                let track = self.loginPlaybackTrack
                self.loginPlaybackTrack = nil
                if let track { try await self.play(track) }
            } catch { self.report(error) }
        }
    }

    nonisolated func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        Task { @MainActor [weak self] in
            guard let self, self.sessionManager === manager, let configuration = self.sessionConfiguration,
                  (try? self.readConfiguration()) == configuration else { return }
            let renewal = self.sessionRenewal
            self.sessionRenewal = nil
            self.sessionRenewalTimeout?.cancel()
            do {
                try self.persistSDKSession(session, configuration: configuration)
                renewal?.resume(returning: session.accessToken)
            } catch { renewal?.resume(throwing: error) }
        }
    }

    nonisolated func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.sessionManager === manager else { return }
            if let renewal = self.sessionRenewal {
                self.sessionRenewal = nil
                self.sessionRenewalTimeout?.cancel()
                renewal.resume(throwing: error)
                return
            }
            guard self.isAuthenticating else { return }
            self.isAuthenticating = false
            self.authenticationConfiguration = nil
            self.loginPlaybackTrack = nil
            self.scheduleAutomaticTokenRefresh()
            self.report(ServiceError.message("Spotify 登录未完成，请重试。"))
        }
    }
}

extension SpotifyService: SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor [weak self] in
            guard let self, self.remote === appRemote else { return }
            self.resumeConnectionTask?.cancel()
            self.resumeConnectionTask = nil
            self.isConnecting = false
            self.isWakingSpotify = false
            self.connectionMayWake = false
            self.connectionTimeout?.cancel()
            appRemote.playerAPI?.delegate = self
            appRemote.playerAPI?.subscribe(toPlayerState: self.commandCallback)
            // This app owns the queue. Spotify shuffle or repeat would advance once, then the app would advance again.
            appRemote.playerAPI?.setShuffle(false, callback: nil)
            appRemote.playerAPI?.setRepeatMode(.off, callback: nil)
            self.statusMessage = "Spotify 已连接"
            self.startStateUpdates()
            if self.pendingResume {
                self.pendingResume = false
                if let player = appRemote.playerAPI {
                    self.resumeConnectedPlayer(player, generation: self.playbackGeneration)
                }
            } else {
                self.playPendingTrack()
            }
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.remote === appRemote, !self.isWakingSpotify else { return }
            self.connectionFailed()
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.remote === appRemote else { return }
            self.trackMetadataGeneration = UUID()
            self.trackMetadataTask?.cancel()
            self.trackMetadataTask = nil
            self.stopStateTimers()
            self.lastPlayerState = nil
            self.isConnecting = false
            self.isPlaying = false
            // Spotify suspends after a pause. Disconnection only changes iPod state;
            // it never reconnects or opens authorization without another user action.
            if !self.isWakingSpotify, !self.userPlaybackRequested {
                self.requestedURI = nil
                self.pendingTrack = nil
            }
        }
    }

    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        Task { @MainActor [weak self] in self?.applyPlayerState(playerState) }
    }
}
