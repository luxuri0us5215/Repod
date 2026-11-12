import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import MediaPlayer
import Observation
import UIKit

/// A visual confirmation, emitted only after the optimistic toggle succeeds.
struct LikeAnimationEvent: Equatable {
    let id = UUID()
    let trackID: String
    let isLiked: Bool
}

enum TrackTransitionDirection: Equatable {
    case forward, backward
}

/// Observed per property: a view repaints only for the state its body read,
/// instead of for every change anywhere in the player. Stored state no body can
/// reach stays `@ObservationIgnored`, and so do caches filled in while a body
/// runs, since writing tracked state there would invalidate that same body.
@MainActor
@Observable
final class PlayerViewModel {
    private(set) var navigation = [NavigationFrame(screen: .home, selectedIndex: 0)]
    private(set) var selectedSource: AudioSource
    private(set) var isPlaying = false {
        didSet { syncNowPlayingInfo() }
    }
    /// Progress lives in its own observable object: at 4 Hz it would otherwise
    /// invalidate every list screen that observes this view model.
    let clock = PlaybackClock()
    var elapsedSeconds: Double {
        get { clock.elapsedSeconds }
        set {
            clock.setElapsed(newValue)
            syncNowPlayingInfo()
        }
    }
    var durationSeconds: Double {
        get { clock.durationSeconds }
        set {
            clock.setDuration(newValue)
            syncNowPlayingInfo()
        }
    }
    private(set) var playbackMode = PlayerViewModel.restoredPlaybackMode()
    private(set) var language = AppLanguage.current
    private(set) var currentTrack: Track? {
        didSet {
            guard !isRestoringPlayback else { return }
            if currentTrack?.id != oldValue?.id || currentTrack?.source != oldValue?.source {
                lastWheelSeek = nil
            }
            if currentTrack?.spotifyTrackID != oldValue?.spotifyTrackID
                || currentTrack?.source != oldValue?.source
                || (currentTrack?.source == .netease && currentTrack?.id != oldValue?.id), let currentTrack {
                refreshLikedState(for: [currentTrack])
            }
            if let currentTrack, currentTrack.source == .netease, currentTrack.artworkURL == nil {
                fillMissingNetEaseArtwork(for: currentTrack)
            }
            syncNowPlayingInfo()
            savePlaybackState()
        }
    }
    private(set) var likedSpotifyTrackIDs = Set<String>()
    private(set) var likedNetEaseTrackIDs = Set<String>()
    private(set) var likeStatus: String?
    private(set) var wheelStatus: String?
    private(set) var volumeLevel: Float = 0
    private(set) var isVolumeBarVisible = false
    private(set) var likeAnimation: LikeAnimationEvent?
    private(set) var trackTransitionDirection: TrackTransitionDirection = .forward
    private(set) var searchResults: [Track] = [] {
        didSet { searchResultsVersion &+= 1 }
    }
    var searchQuery = ""
    private(set) var searchFocusRequest = 0
    private(set) var isSearching = false
    private(set) var searchHasMore = false
    private(set) var searchNextOffset = 0
    private(set) var isLoadingMoreSearch = false
    private(set) var searchLoadMoreFailed = false
    private(set) var searchNotice: SearchNotice?
    /// Identity of the rendered result list; it changes only when a new result set replaces the old one.
    private(set) var searchListID = UUID()
    private(set) var libraryTracks: [AppScreen: [Track]] = [:] {
        didSet { libraryTracksVersion &+= 1 }
    }
    private(set) var sourcePlaylists: [MusicPlaylist] = []
    /// Podcast subscriptions behind the Podcasts menu. Their episodes are tracks.
    private(set) var podcastShows: [PodcastShow] = []
    /// 电台 is NetEase's Personal FM: an endless stream that refills itself, and
    /// the only place the app hands you music you have not picked.
    private(set) var radioTracks: [Track] = [] {
        didSet { radioTracksVersion &+= 1 }
    }
    private(set) var isRadioMode = false
    private(set) var isRadioLoading = false
    private(set) var radioLoadingError: String?
    private var browseMessages: [AppScreen: String] = [:]
    private var browseLoadingScreen: AppScreen?
    /// When each list screen last finished a successful fetch this session. The
    /// playlist row cache makes a re-entry show rows immediately, but without this
    /// the same pages were walked again on every visit.
    @ObservationIgnored private var libraryRefreshedAt: [AppScreen: Date] = [:]
    /// Matching the server response cache: within this window the answer is the
    /// one the screen already holds, so an open costs no round trip at all.
    private static let listRefreshWindow: TimeInterval = 300

    var alertMessage: String? {
        didSet {
            if let message = alertMessage {
                let localized = L10n.error(message)
                if localized != message { alertMessage = localized }
            }
        }
    }
    private(set) var neteaseLoginStatus = "尚未登录；会员歌曲需要扫码登录"
    private(set) var neteaseMode: NetEaseConnectionMode = .direct
    private(set) var neteaseQRImage: UIImage?
    private(set) var isNetEaseLoggingIn = false {
        didSet {
            guard oldValue != isNetEaseLoggingIn, currentScreen == .neteaseSettings,
                  selectedIndex >= 3 else { return }
            // Preserve Logout's identity; a disappearing Cancel returns to the QR row.
            navigation[navigation.count - 1].selectedIndex += isNetEaseLoggingIn ? 1 : -1
        }
    }
    private(set) var isSpotifyLoggedIn = false
    private(set) var spotifyStatus = "请在设置中登录 Spotify"

    /// Login truth lives in the clients, but a client property is not observable.
    /// Each read also touches the status string that does repaint, so a row that
    /// shows login state updates the moment the session changes.
    func isSignedIn(_ source: AudioSource) -> Bool {
        switch source {
        case .netease:
            _ = neteaseLoginStatus
            return netease.userID != nil
        case .spotify:
            return isSpotifyLoggedIn
        }
    }

    /// What the centre button will do on the highlighted 音源 row.
    var sourceHint: String? {
        guard AudioSource.allCases.indices.contains(selectedIndex) else { return nil }
        return AudioSource.allCases[selectedIndex] == selectedSource ? "按中键配置" : "按中键切换音源"
    }
    let settingsActions = PassthroughSubject<SettingsAction, Never>()

    private let netease: NetEaseClient
    private let spotify = SpotifyService()
    private let localLibrary = LocalLibraryStore()
    private let likedSongsCache = LikedSongsCache()
    private let screenListCache = ScreenListCache.shared
    private let playbackStateStore = PlaybackStateStore.shared
    /// Last known 我喜欢的音乐 per source, so the screen opens instantly instead of
    /// waiting for a full playlist walk every time it is entered.
    /// The liked list per source. It is also the app's library: 歌曲, 歌手 and
    /// 专辑 are all derived from it, so there is one collection to keep coherent.
    private var cachedLikedSongs: [AudioSource: [Track]] = [:]
    @ObservationIgnored private var likedPrewarmTask: Task<Void, Never>?
    /// The playlists / podcasts walks started by the boot screen. Cancelled
    /// whenever the library is reset so a late answer cannot repopulate a list
    /// after a logout or account switch.
    @ObservationIgnored private var libraryScreensPrewarmTask: Task<Void, Never>?
    /// Debounces the off-main rebuild of the browsing index after a library write.
    @ObservationIgnored private var browsingIndexPrewarmTask: Task<Void, Never>?
    /// The generation `browsingIndexPrewarmTask` was started for. Reads of a stale
    /// index happen several times per frame, so the schedule has to be idempotent:
    /// restarting it on every read would keep resetting the delay below and the
    /// rebuild would never run.
    @ObservationIgnored private var browsingIndexPrewarmGeneration: UUID?
    /// The liked rows of the active source, filtered by source, so the browsing
    /// index can be built off it without touching the dictionary on every frame.
    private var localLibraryTracks: [Track] = [] {
        didSet {
            libraryGeneration = UUID()
            scheduleBrowsingIndexPrewarm()
        }
    }
    /// Tracked although only caches compare it: a cache hit never touches the
    /// library itself, so this is the only read that ties a body to it.
    private var libraryGeneration = UUID()
    @ObservationIgnored private var cachedBrowsingIndex: BrowsingIndex?
    private let streamingPlayer = StreamingPlayer()
    let volumeController = VolumeController()
    @ObservationIgnored private var nowPlayingArtworkKey: String?
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    @ObservationIgnored private var nowPlayingArtworkTask: Task<Void, Never>?
    @ObservationIgnored private var netEaseArtworkFillTask: Task<Void, Never>?
    @ObservationIgnored private var netEaseArtworkAttempted = Set<String>()
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    private var queue: [Track] = [] {
        didSet {
            queueVersion &+= 1
            savePlaybackState()
            syncNowPlayingInfo()
        }
    }
    /// Cheap change stamps for caches that used to rebuild a key by joining every
    /// track id on each body evaluation. Tracked like `libraryGeneration`.
    private var queueVersion = 0
    private var searchResultsVersion = 0
    private var libraryTracksVersion = 0
    private var radioTracksVersion = 0
    @ObservationIgnored private var queueIndex: Int?
    @ObservationIgnored private var requestedTrackID: String?
    @ObservationIgnored private var preservesPlayingDuringTrackChange = false
    @ObservationIgnored private var playbackCommandPending = false
    /// Seconds of the current play already sent to NetEase. A pause reports what has
    /// been heard, so a track abandoned mid-way is still counted; only the remaining
    /// seconds are sent afterwards, which keeps a resumed song from being counted twice.
    @ObservationIgnored private var reportedPlaySeconds = 0
    @ObservationIgnored private var playbackSourceID: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchResultsQuery = ""
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var radioRefillTask: Task<Void, Never>?
    @ObservationIgnored private var radioGeneration = UUID()
    @ObservationIgnored private var qrTask: Task<Void, Never>?
    @ObservationIgnored private var neteaseStatusTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored private var browseGeneration = UUID()
    @ObservationIgnored private var playbackGeneration = UUID()
    @ObservationIgnored private var qrGeneration = UUID()
    @ObservationIgnored private var configuredNetEaseURL: String
    @ObservationIgnored private var configuredNetEaseMode: NetEaseConnectionMode
    @ObservationIgnored private var likeGeneration = UUID()
    @ObservationIgnored private var likedCheckTokens: [String: UUID] = [:]
    @ObservationIgnored private var pendingLikeToggles = Set<String>()
    @ObservationIgnored private var likedSongsNeedsRefresh = false
    @ObservationIgnored private var likedSongChanges: [String: Bool] = [:]
    @ObservationIgnored private var wheelStatusTask: Task<Void, Never>?
    @ObservationIgnored private var wheelStatusGeneration = UUID()
    @ObservationIgnored private var volumeBarTask: Task<Void, Never>?
    @ObservationIgnored private var volumeBarGeneration = UUID()
    @ObservationIgnored private var lastWheelSeek: (source: AudioSource, trackID: String, timestamp: TimeInterval)?
    private var completeAlbums: [String: [Track]] = [:]
    @ObservationIgnored private var queueBaseTracks: [Track] = []
    /// Set while late artwork is written back into the queue. Persisting then would
    /// re-encode the whole snapshot for a field the relaunch re-resolves anyway.
    @ObservationIgnored private var isApplyingArtworkResolution = false
    /// Tracks persisted on each side of the playing one. Larger than any realistic
    /// album queue, small enough that a snapshot decodes quickly on the way back in.
    private static let snapshotTrackLimit = 400
    /// One shared ephemeral session for album JSON, instead of a new session per call.
    private static let sharedAlbumSession = URLSession(configuration: .ephemeral)

    /// Lightweight position-only record, written every 5s while playing without re-encoding the queue.
    private typealias PlaybackProgress = PlaybackStateStore.PlaybackProgress

    /// The decoded contents of both persisted records, produced off the main actor.
    private typealias RestoredPlayback = PlaybackStateStore.Restored

    /// Fingerprint of the last fully-saved queue/index/track, so the 5s progress save can skip re-encoding.
    @ObservationIgnored private var lastSavedQueueFingerprint: String?
    /// The trailing debounce of the snapshot write, and the values it will write.
    @ObservationIgnored private var playbackSaveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSnapshot: PlaybackSnapshot?
    @ObservationIgnored private var pendingProgress: PlaybackProgress?
    @ObservationIgnored private var isRestoringPlayback = false
    /// Guards against a second boot task applying the saved queue twice.
    @ObservationIgnored private var isPlaybackRestoreFinished = false
    @ObservationIgnored private var restoredPlaybackNeedsStart = false
    @ObservationIgnored private var lastPlaybackSaveTime: TimeInterval = 0
    @ObservationIgnored private var pendingPlaybackSeek: (source: AudioSource, trackID: String, seconds: Double)?
    @ObservationIgnored private var pendingSpotifySeekConfirmed = false
    @ObservationIgnored private var consecutiveNetEaseFailures = 0
    @ObservationIgnored private var lastHandledNetEaseFailure: UUID?
    @ObservationIgnored private var lastRetriedNetEaseTrackID: String?
    /// The silent recovery of a -460 while a song is being started. A refusal is a
    /// short window about the caller, so nothing about it reaches the screen: the
    /// position is kept, the song is asked for again after a pause, and no pause,
    /// skip or alert is shown. Cleared as soon as audio is playing, the user acts,
    /// or the window has clearly not lifted.
    @ObservationIgnored private var silentRiskRetryTask: Task<Void, Never>?
    @ObservationIgnored private var silentRiskRetryAttempt = 0
    /// Retries of a screen whose read was refused, capped so a closed window cannot turn
    /// into an endless poll. Reset when the screen is loaded again.
    @ObservationIgnored private var silentScreenRetryAttempts: [AppScreen: Int] = [:]
    /// Quiet re-probes of the login status after a refusal; the cookie is never cleared
    /// by one, so a refusal must not read as a logout.
    @ObservationIgnored private var neteaseRiskStatusRetries = 0
    /// The song whose next-track address has already been requested. One per song:
    /// the player publishes progress four times a second, and a prefetch keyed on the
    /// progress value would ask again on every tick.
    @ObservationIgnored private var prefetchedUpcomingTrackID: String?
    @ObservationIgnored private var playbackPrefetchTask: Task<Void, Never>?
    /// Media addresses whose CDN host has already been opened for the next song, so a
    /// repeated trigger does not re-open the same connection.
    @ObservationIgnored private var warmedMediaAddresses = Set<String>()
    @ObservationIgnored private var sourcePlaybackStates: [AudioSource: SourcePlaybackState] = [:]
    @ObservationIgnored private var likedChecksInFlight: [String: UUID] = [:]
    @ObservationIgnored private var remoteCommandHandlers: [(command: MPRemoteCommand, token: Any)] = []

    enum QueueAdvanceReason {
        case manual, naturalEnd, playbackFailure
    }

    private struct SourcePlaybackState {
        var queue: [Track]
        var queueBaseTracks: [Track]
        var queueIndex: Int?
        var currentTrack: Track?
        var elapsedSeconds: Double
        var durationSeconds: Double
        var playbackSourceID: String?
        var searchQuery: String
        var searchResults: [Track]
        var searchResultsQuery: String
        var searchHasMore: Bool
        var searchNextOffset: Int
    }

    private typealias PersistedTrack = PlaybackStateStore.PersistedTrack

    private typealias PlaybackSnapshot = PlaybackStateStore.PlaybackSnapshot

    init() {
        L10n.install()
        selectedSource = AudioSource(rawValue: UserDefaults.standard.string(forKey: "selectedSource") ?? "") ?? .netease
        let address = UserDefaults.standard.string(forKey: "neteaseBaseURL") ?? ""
        let storedMode = UserDefaults.standard.string(forKey: "neteaseConnectionMode")
        let mode = NetEaseConnectionMode.resolved(storedRaw: storedMode, address: address)
        neteaseMode = mode
        configuredNetEaseMode = mode
        configuredNetEaseURL = address
        UserDefaults.standard.set(mode.rawValue, forKey: "neteaseConnectionMode")
        netease = NetEaseClient(mode: mode, baseURL: address)
        localLibrary.onSaveFailure = { [weak self] in
            self?.alertMessage = "本地曲库保存失败，请检查设备存储空间。"
        }
        likedSongsCache.onSaveFailure = { [weak self] in
            self?.alertMessage = "我喜欢的音乐缓存写入失败，不影响播放。"
        }
        observePlayers()
        configureRemoteCommands()
        // The saved queue is decoded on a background thread inside the boot task;
        // only the empty state is published here.
        syncNowPlayingInfo()
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.flushPlaybackState() }
            .store(in: &subscriptions)
        restoreNetEaseLogin()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-repod-open-netease-settings") {
            DispatchQueue.main.async { [weak self] in
                self?.open(.neteaseSettings)
            }
        }
        #endif
    }

    /// False while the saved library index is still being read. The boot screen
    /// covers the UI until this flips, so the first frame is never blocked by a
    /// multi-megabyte JSON decode.
    private(set) var isLibraryReady = false

    /// Reads the library index off the main actor and publishes the result.
    /// Called once from the boot screen's task; the guard makes re-entry harmless.
    func loadLibraryIndex() async {
        guard !isLibraryReady else { return }
        // Starting the out-of-process keyboard is the one cost that used to land
        // on the user's first tap of the search field. Doing it now puts that
        // cost behind the boot screen instead.
        KeyboardWarmup.warmUpIfNeeded()
        let started = Date()
        var failure: String?
        // The disk reads are independent. Awaiting them one after another made
        // every launch pay their sum, which is exactly the wait the boot screen shows.
        async let likedLoad: Void = likedSongsCache.load()
        async let listLoad: Void = screenListCache.load()
        // The saved queue is decoded here, not in `init`, so it never delays the
        // first frame; the player applies it before the boot screen lifts.
        async let playbackLoad: Void = restorePlaybackStateInBackground()
        do { try await localLibrary.load() }
        catch {
            // A cancelled boot still drops the cover; the app is going away anyway.
            if !(error is CancellationError) { failure = "无法读取本地曲库，请检查设备存储空间。" }
        }
        // The restore follows the saved track's source, and the browsing index is
        // built for whichever source is active, so let it land before starting.
        await playbackLoad
        // The liked list is the library, so the index cannot be built until it has
        // been read. Its disk read is already in flight.
        await likedLoad
        for source in AudioSource.allCases {
            if let cached = likedSongsCache.tracks(for: source, account: accountTag(for: source)) {
                cachedLikedSongs[source] = cached
            }
        }
        // The disk copy holds the same metadata a cold-launch walk would fetch. Seeding
        // it means the boot read costs one `/likelist` instead of a playlist page walk,
        // which matters most on a device that is relaunched every time a build is run.
        if let likedSnapshot = cachedLikedSongs[.netease] {
            netease.seedLikedTracks(likedSnapshot)
        }
        refreshLikedLibrary()
        // The sort only needs the library, so it runs alongside the remaining reads.
        async let indexPrewarm: Void = prewarmBrowsingIndex()
        // The most expensive network read of a session starts here instead of once
        // the player is visible: its first request goes out while the boot screen
        // still covers the UI, and 歌曲 opens with rows either way.
        prewarmLikedSongs()
        // 歌单 and 播客 are network walks too. They run behind the liked list
        // so the one small server is never asked for two walks at once.
        prewarmLibraryScreens()
        _ = await (listLoad, indexPrewarm)
        // The restored cover is wanted by Now Playing's first frame and by the lock
        // screen's first sync. Starting the downloads and the ImageIO decodes now
        // (without waiting) means both find them in the cache instead of a
        // placeholder, and the same goes for the covers the first screens show.
        prewarmArtworkForFirstScreens()
        // The playlists screen is the way into everything else, and its list has
        // not changed most launches. Restoring it means it opens with rows.
        restoreCachedPlaylists()
        // The first frame is already on screen. Hold the boot screen briefly so a
        // tiny library does not flash black for a single frame.
        let remaining = 0.3 - Date().timeIntervalSince(started)
        if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        // A cold haptic engine takes a moment to build and start, and the first
        // thing a user does is drag the wheel. Warming it here means the first
        // tick is a tick instead of an impact-generator fallback.
        HapticEngine.shared.prepare()
        isLibraryReady = true
        if let failure { alertMessage = failure }
        // The library read may have dropped records a previous version wrote. That
        // rewrite is a multi-megabyte encode and is not needed by the first frame,
        // so it runs after the cover lifts rather than competing with it.
        localLibrary.writeDeferredCleanup()
        #if DEBUG
        applyScreenshotFixtureIfRequested()
        #endif
    }

    #if DEBUG
    /// Screenshot aid for appearance reviews: `SIMCTL_CHILD_REPOD_SCREEN_OVERRIDE=nowPlaying`
    /// opens Now Playing with a fixture track and a locally served cover, so the screen can be
    /// inspected without driving the click wheel (simctl has no touch input). Debug builds only.
    #if DEBUG
    /// Albums injected for Cover Flow screenshots: the simulator has no library to browse.
    private var coverFlowFixtureAlbums: [CoverFlowAlbum]?
    #endif

    func applyScreenshotFixtureIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let requested = env["REPOD_SCREEN_OVERRIDE"], !requested.isEmpty else { return }
        func fixture(_ key: String, _ fallback: String) -> String {
            guard let value = env[key], !value.isEmpty else { return fallback }
            return value
        }
        let home = NavigationFrame(screen: .home, selectedIndex: 0)
        switch requested {
        case "nowPlaying":
            isRestoringPlayback = true
            if env["REPOD_FIXTURE_TRACK"] == "empty" {
                currentTrack = nil
            } else {
                currentTrack = Track(
                    id: "screenshot-now-playing",
                    title: fixture("REPOD_FIXTURE_TITLE", "Midnight City"),
                    artist: fixture("REPOD_FIXTURE_ARTIST", "M83"),
                    album: fixture("REPOD_FIXTURE_ALBUM", "Hurry Up, We're Dreaming"),
                    duration: 244,
                    source: .netease,
                    artworkURL: URL(string: fixture("REPOD_FIXTURE_COVER", "http://127.0.0.1:8765/cover.png"))
                )
            }
            isRestoringPlayback = false
            durationSeconds = 244
            elapsedSeconds = 96
            isPlaying = currentTrack != nil
            if env["REPOD_FIXTURE_LIKED"] == "1", let track = currentTrack {
                likedNetEaseTrackIDs.insert(track.id)
            }
            if env["REPOD_FIXTURE_VOLUME"] == "1" {
                volumeLevel = 0.42
                isVolumeBarVisible = true
            }
            navigation = [home, NavigationFrame(screen: .nowPlaying, selectedIndex: 0)]
        case "settings":
            navigation = [home, NavigationFrame(screen: .settings, selectedIndex: 0)]
        case "appearance":
            navigation = [home,
                          NavigationFrame(screen: .settings, selectedIndex: 0),
                          NavigationFrame(screen: .appearance, selectedIndex: 0)]
        case "sources":
            navigation = [home,
                          NavigationFrame(screen: .settings, selectedIndex: 0),
                          NavigationFrame(screen: .sources, selectedIndex: 0)]
        case "coverflow":
            let titles = ["Hurry Up, We're Dreaming", "Random Access Memories", "Kind of Blue",
                          "The Dark Side of the Moon", "In Rainbows"]
            let artists = ["M83", "Daft Punk", "Miles Davis", "Pink Floyd", "Radiohead"]
            coverFlowFixtureAlbums = titles.enumerated().map { index, title in
                let track = Track(id: "fixture-album-\(index)-track", title: title,
                                  artist: artists[index], album: title, duration: 240,
                                  source: .netease,
                                  artworkURL: URL(string: "http://127.0.0.1:8765/cover\(index + 1).png"))
                return CoverFlowAlbum(id: "fixture-album-\(index)", title: title,
                                      artist: artists[index], artworkURL: track.artworkURL,
                                      tracks: [track])
            }
            // The fixture bypasses the cache path that bumps the identity, so the
            // cover view would never reconcile to the middle copy of the loop.
            coverFlowIdentity &+= 1
            navigation = [home, NavigationFrame(screen: .albums, selectedIndex: 0)]
        case "music":
            navigation = [home, NavigationFrame(screen: .music, selectedIndex: 0)]
        case "languages":
            navigation = [home,
                          NavigationFrame(screen: .settings, selectedIndex: 0),
                          NavigationFrame(screen: .languages, selectedIndex: 0)]
        case "list":
            let screen = AppScreen.podcastEpisodes(id: "fixture-show", name: "产品笔记")
            let titles = ["第一集 · 把 iPod 装进手机", "第二集 · 转盘的手感", "第三集 · 液态玻璃",
                          "第四集 · 封面流动", "第五集 · 主题的边界", "第六集 · 从 2.0 到 3.0"]
            libraryTracks[screen] = titles.enumerated().map { index, title in
                Track(id: "fixture-episode-\(index)", title: title, artist: "Repod 电台",
                      album: "05 \(index + 1) 期", duration: 1_500 + Double(index) * 60,
                      source: .netease)
            }
            navigation = [home,
                          NavigationFrame(screen: .music, selectedIndex: 0),
                          NavigationFrame(screen: screen, selectedIndex: 0)]
        default:
            return
        }
    }
    #endif

    private func restoreCachedPlaylists() {
        var restored: [MusicPlaylist] = []
        for source in AudioSource.allCases {
            guard let cached = screenListCache.playlists(for: source, account: accountTag(for: source)) else { continue }
            restored.append(contentsOf: cached)
        }
        guard !restored.isEmpty else { return }
        sourcePlaylists = restored
        browseMessages[.playlists] = nil
    }

    /// Builds songs/artists/albums off the main actor, so the first 歌曲/歌手/专辑
    /// screen after launch or a source switch opens against a ready index.
    private func prewarmBrowsingIndex() async {
        let generation = libraryGeneration
        let source = selectedSource
        let tracks = localLibraryTracks
        let index = await Task.detached(priority: .userInitiated) {
            Self.buildBrowsingIndex(tracks, source: source, generation: generation)
        }.value
        guard libraryGeneration == generation, selectedSource == source else { return }
        cachedBrowsingIndex = index
    }

    /// Captures the current state and schedules the write. A track change reaches this
    /// four times (the assignment, the explicit save, the resolved metadata copy and
    /// the first playing callback), so the write is trailing-debounced by one second
    /// and encoded off the main actor.
    private func savePlaybackState() {
        guard let snapshot = makePlaybackSnapshot() else { return }
        let progress = currentPlaybackProgress()
        schedulePlaybackSave(snapshot: snapshot, progress: progress)
    }

    /// Restoring is asynchronous, so there is a window where the player has no current
    /// track yet. Writing during it would delete the snapshot that is about to be
    /// restored (a background transition during the boot screen used to be impossible
    /// because the restore ran in `init`).
    private func makePlaybackSnapshot() -> PlaybackSnapshot? {
        guard isPlaybackRestoreFinished, !isRestoringPlayback, !isApplyingArtworkResolution else {
            return nil
        }
        guard let currentTrack else {
            // Nothing is playing: an old snapshot would resume a session that ended.
            discardPendingPlaybackSave()
            if lastSavedQueueFingerprint != nil { playbackStateStore.removeAll() }
            lastSavedQueueFingerprint = nil
            return nil
        }
        guard elapsedSeconds.isFinite, elapsedSeconds >= 0 else { return nil }
        // Locate the playing track in the live queue and leave that array alone. The
        // queue is often a whole library (歌曲 has one row per liked song), and
        // overwriting one element of a copy allocated and retained 20,000 tracks just
        // to persist 400 of them — four times per start, which is why a song from
        // 歌曲 took visibly longer to begin than one from a 200-row playlist.
        let position: Int
        if let existing = queueIndex, queue.indices.contains(existing),
           queue[existing].id == currentTrack.id, queue[existing].source == currentTrack.source {
            position = existing
        } else if let existing = queue.firstIndex(where: {
            $0.id == currentTrack.id && $0.source == currentTrack.source
        }) {
            position = existing
        } else {
            position = queue.count
        }
        // A queue can be a whole library. Persisting all of it puts megabytes into a
        // record that is rewritten at every track change. Persist a window around the
        // playing track instead: the live queue is untouched, so previous/next still
        // reach everything this session, and a relaunch resumes in place. Only the
        // window is copied, so the cost no longer scales with the list size.
        let limit = Self.snapshotTrackLimit
        let start = max(0, min(position - limit / 2, queue.count - limit))
        let end = min(queue.count, start + limit)
        var savedWindow = queue[start..<end].map { PersistedTrack($0) }
        let windowIndex: Int
        if position < queue.count {
            windowIndex = position - start
            savedWindow[windowIndex] = PersistedTrack(currentTrack)
        } else {
            // Nothing in the queue names this song (a restored window, a rebuilt
            // queue): keep it as the last row of the persisted window.
            savedWindow.append(PersistedTrack(currentTrack))
            if savedWindow.count > limit { savedWindow.removeFirst() }
            windowIndex = savedWindow.count - 1
        }
        var baseTracks: [Track]?
        if playbackMode == .shuffle {
            var base = queueBaseTracks
            if base.count > limit,
               let baseIndex = base.firstIndex(where: { $0.id == currentTrack.id && $0.source == currentTrack.source }) {
                let start = min(max(0, baseIndex - limit / 2), base.count - limit)
                base = Array(base[start..<start + limit])
            }
            baseTracks = base
        }
        // Fingerprinted exactly the way `savePlaybackProgress` hashes it, including
        // the `queueIndex ?? queue.count` fallback: when the queue position was not
        // known the two used to derive different indexes and every 5s tick re-encoded
        // the whole snapshot instead of writing the small progress record.
        lastSavedQueueFingerprint = queueFingerprint(queue: queue, index: queueIndex ?? queue.count,
                                                    track: currentTrack)
        lastPlaybackSaveTime = ProcessInfo.processInfo.systemUptime
        return PlaybackSnapshot(version: 1, currentTrack: PersistedTrack(currentTrack),
                                queue: savedWindow, queueIndex: windowIndex,
                                elapsedSeconds: elapsedSeconds, wasPlaying: isPlaying,
                                queueBaseTracks: baseTracks?.map(PersistedTrack.init))
    }

    private func currentPlaybackProgress() -> PlaybackProgress? {
        guard let currentTrack, elapsedSeconds.isFinite, elapsedSeconds >= 0 else { return nil }
        return PlaybackProgress(trackID: currentTrack.id, source: currentTrack.source.rawValue,
                                elapsedSeconds: elapsedSeconds, reportedPlaySeconds: reportedPlaySeconds)
    }

    private func schedulePlaybackSave(snapshot: PlaybackSnapshot?, progress: PlaybackProgress?) {
        if let snapshot { pendingSnapshot = snapshot }
        if let progress { pendingProgress = progress }
        playbackSaveTask?.cancel()
        playbackSaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1_000)) } catch { return }
            guard let self else { return }
            await self.writePendingPlaybackState()
        }
    }

    private func writePendingPlaybackState() async {
        let snapshot = pendingSnapshot
        let progress = pendingProgress
        pendingSnapshot = nil
        pendingProgress = nil
        playbackSaveTask = nil
        if let snapshot {
            await playbackStateStore.save(snapshot, progress: progress)
        } else if let progress {
            await playbackStateStore.saveProgress(progress)
        }
    }

    private func discardPendingPlaybackSave() {
        playbackSaveTask?.cancel()
        playbackSaveTask = nil
        pendingSnapshot = nil
        pendingProgress = nil
    }

    /// The background transition is the last moment this process is guaranteed to run:
    /// a debounced write would still be sleeping when the app is suspended.
    private func flushPlaybackState() {
        discardPendingPlaybackSave()
        guard let snapshot = makePlaybackSnapshot() else { return }
        playbackStateStore.flush(snapshot, progress: currentPlaybackProgress())
    }

    private func queueFingerprint(queue: [Track], index: Int, track: Track) -> String {
        // Constant time. The live queue can hold a whole library, and this runs
        // on every five-second progress tick as well as on every save.
        let first = queue.first.map { $0.source.rawValue + ":" + $0.id } ?? ""
        let last = queue.last.map { $0.source.rawValue + ":" + $0.id } ?? ""
        return "\(queue.count)|\(index)|\(track.source.rawValue):\(track.id)|\(first)|\(last)"
    }

    private func savePlaybackProgressRecord() {
        guard let progress = currentPlaybackProgress() else { return }
        schedulePlaybackSave(snapshot: nil, progress: progress)
    }

    private func savePlaybackProgress() {
        guard isPlaying, ProcessInfo.processInfo.systemUptime - lastPlaybackSaveTime >= 5 else { return }
        // Only re-encode the whole queue when it actually changed; otherwise just save the position.
        guard let currentTrack else { return }
        let fingerprint = queueFingerprint(queue: queue, index: queueIndex ?? queue.count, track: currentTrack)
        if fingerprint == lastSavedQueueFingerprint {
            savePlaybackProgressRecord()
            lastPlaybackSaveTime = ProcessInfo.processInfo.systemUptime
        } else {
            savePlaybackState()
        }
    }

    /// Fetches the next song's address (and both neighbours' covers) once the current
    /// song is far enough along. A track change then spends neither an API round trip
    /// nor a cold CDN connection.
    ///
    /// The trigger is three seconds, not the previous 30: the address belongs to the
    /// next song either way, and asking earlier means a skip within the first three
    /// seconds of a song makes no request at all, while every switch after that has
    /// both the address and the CDN host already warm.
    ///
    /// It is still one request per song, not a cursor-driven window: the earlier
    /// prefetcher asked for several songs at a time and the burst is what provoked
    /// NetEase's -460. An address that fails here is dropped in silence and the track
    /// change asks again through the normal path, where errors are shown and counted.
    private func prefetchUpcomingIfNeeded(elapsed: Double, duration: Double) {
        guard isPlaying, consecutiveNetEaseFailures == 0, silentRiskRetryTask == nil,
              !restoredPlaybackNeedsStart, !playbackCommandPending,
              // 单曲循环 replays the item in place, so there is nothing to fetch.
              playbackMode != .repeatOne,
              let track = currentTrack, track.source == .netease,
              elapsed.isFinite, elapsed > 0 else { return }
        let trigger = duration.isFinite && duration > 0 ? min(3, duration * 0.25) : 3
        guard elapsed >= trigger else { return }
        guard prefetchedUpcomingTrackID != track.id else { return }
        // Marked once per song, and only after the queue position is known: a queue the
        // player cannot place (a restored window, a station that has not refilled) must
        // not spend this song's only attempt.
        guard let index = queueIndex.flatMap({
            queue.indices.contains($0) && queue[$0].id == track.id ? $0 : nil
        }) else { return }
        prefetchedUpcomingTrackID = track.id
        // An empty queue and a station whose next page has not arrived answer nil here,
        // and nothing is requested.
        let next = Self.nextQueueIndex(current: index, count: queue.count, direction: 1).map { queue[$0] }
        let previous = Self.nextQueueIndex(current: index, count: queue.count, direction: -1).map { queue[$0] }
        if let next, next.source == .netease, next.id != track.id {
            playbackPrefetchTask?.cancel()
            playbackPrefetchTask = Task { [weak self, netease] in
                await netease.prefetchPlaybackTrack(next)
                guard let self, !Task.isCancelled else { return }
                // The address alone was never the wait: AVPlayer still had to open a
                // cold connection to whatever CDN host that song lives on, which in
                // 歌曲 means a different host almost every time (the list is ordered by
                // title, not by album). Asking the asset for its header here leaves
                // the host resolved and connected before the switch.
                guard let address = await netease.prefetchedPlaybackURL(forTrackID: next.id) else { return }
                let key = address.absoluteString
                if self.warmedMediaAddresses.count > 32 { self.warmedMediaAddresses.removeAll() }
                guard self.warmedMediaAddresses.insert(key).inserted else { return }
                await StreamingPlayer.warm(url: address)
            }
        }
        let covers = [next, previous].compactMap { $0?.artworkURL }
        guard !covers.isEmpty else { return }
        // Covers come from a CDN, not the API server: no risk window, and each one is
        // a few dozen kilobytes.
        Task { await CachedImageLoader.shared.prefetch(covers) }
    }

    /// The saved queue is up to ~900 KB of JSON. Decoding it inside `init` ran on
    /// the main thread before the first frame, which is the one stretch of launch
    /// where every millisecond is still the system's launch image. The boot screen
    /// already covers the player, so the decode moves there and only the apply
    /// (array assignment, no parsing) stays on the main actor.
    private func restorePlaybackStateInBackground() async {
        guard !isPlaybackRestoreFinished else { return }
        let restored = await playbackStateStore.load()
        isPlaybackRestoreFinished = true
        // The decode is already done and applying it costs no parsing, so it is
        // applied even if the boot task was cancelled: skipping it would leave the
        // player with no restored queue until the app is relaunched.
        applyRestoredPlayback(restored)
        syncNowPlayingInfo()
    }

    private func applyRestoredPlayback(_ restored: RestoredPlayback) {
        guard let snapshot = restored.snapshot,
              snapshot.version == 1, snapshot.elapsedSeconds.isFinite, snapshot.elapsedSeconds >= 0,
              let savedTrack = snapshot.currentTrack.track else { return }
        let restoredQueue = snapshot.queue.compactMap(\.track)
        guard restoredQueue.count == snapshot.queue.count, restoredQueue.indices.contains(snapshot.queueIndex),
              restoredQueue[snapshot.queueIndex] == savedTrack else { return }
        isRestoringPlayback = true
        defer { isRestoringPlayback = false }
        queue = restoredQueue
        queueIndex = snapshot.queueIndex
        if let savedBase = snapshot.queueBaseTracks {
            let restoredBase = savedBase.compactMap(\.track)
            if restoredBase.count == savedBase.count {
                queueBaseTracks = restoredBase
            }
        }
        currentTrack = restoredQueue[snapshot.queueIndex]
        // Prefer the lightweight 5s progress record when it belongs to the same track.
        var restoredElapsed = snapshot.elapsedSeconds
        if let progress = restored.progress,
           progress.trackID == savedTrack.id, progress.source == savedTrack.source.rawValue,
           progress.elapsedSeconds.isFinite, progress.elapsedSeconds >= 0 {
            restoredElapsed = progress.elapsedSeconds
            // The seconds already sent to NetEase must survive the relaunch, or the resume
            // below reports them a second time as the start of a new play.
            reportedPlaySeconds = min(Int(restoredElapsed), max(0, progress.reportedPlaySeconds ?? 0))
        }
        elapsedSeconds = savedTrack.duration > 0 ? min(restoredElapsed, savedTrack.duration) : restoredElapsed
        durationSeconds = savedTrack.duration
        selectedSource = savedTrack.source
        isPlaying = false
        restoredPlaybackNeedsStart = true
        if savedTrack.source == .netease, savedTrack.artworkURL == nil {
            // The didSet above is suppressed while restoring, so ask here.
            fillMissingNetEaseArtwork(for: savedTrack)
        }
    }

    /// Some list rows arrive without a cover (endpoint omitting `al.picUrl`, an older
    /// restored snapshot, or a cached catalogue row). Resolve it once per track so
    /// Now Playing and Cover Flow show real art instead of the placeholder note.
    private func fillMissingNetEaseArtwork(for track: Track) {
        // The player republishes the track when its stream URL resolves, and that
        // copy is built from the metadata playback started with. A cover resolved in
        // the meantime therefore has to be inherited here, not fetched again — the
        // set below would otherwise refuse the retry and leave the note on screen.
        if let known = knownArtwork(for: track) {
            applyNetEaseArtwork(known, for: track)
            return
        }
        // One request per song per session; a resolved playback copy re-publishes the
        // same track without art and must not refetch it.
        guard netEaseArtworkAttempted.insert(track.id).inserted else { return }
        netEaseArtworkFillTask?.cancel()
        netEaseArtworkFillTask = Task { [weak self] in
            // Song URLs and art share the same server and the same risk control.
            // Let playback resolve its stream first; a cover a moment later is fine.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            guard let artwork = await self.netease.artworkURL(forTrackID: track.id) else {
                // A failed lookup must not poison this song for the rest of the
                // session: the next time it plays it may well resolve.
                if !Task.isCancelled { self.netEaseArtworkAttempted.remove(track.id) }
                return
            }
            guard !Task.isCancelled else { return }
            self.applyNetEaseArtwork(artwork, for: track)
        }
    }

    /// A cover already known for this song, from the playing copy or from any list
    /// that carries it. Used before asking the server, and when the player
    /// republishes a track built from older metadata.
    private func knownArtwork(for track: Track) -> URL? {
        if let current = currentTrack, current.source == track.source, current.id == track.id,
           let artwork = current.artworkURL { return artwork }
        if let entry = queue.first(where: { $0.source == track.source && $0.id == track.id }),
           let artwork = entry.artworkURL { return artwork }
        if let entry = queueBaseTracks.first(where: { $0.source == track.source && $0.id == track.id }),
           let artwork = entry.artworkURL { return artwork }
        return nil
    }

    private func applyNetEaseArtwork(_ artwork: URL, for track: Track) {
        // Resolving art must not look like a playback change to persistence: a full
        // snapshot re-encode while the cover appears made the screen hitch. The art
        // is re-resolved on the next launch anyway.
        isApplyingArtworkResolution = true
        defer { isApplyingArtworkResolution = false }
        if var current = currentTrack, current.source == .netease,
           current.id == track.id, current.artworkURL == nil {
            current.artworkURL = artwork
            // Reassigning publishes the resolved art to Now Playing, the lock screen
            // and Cover Flow; the identity checks above keep it to one pass.
            currentTrack = current
        }
        // Copy, edit, assign once: writing elements in place re-published the whole
        // queue for every matching row.
        if queue.contains(where: { $0.source == .netease && $0.id == track.id && $0.artworkURL == nil }) {
            var updated = queue
            for index in updated.indices where updated[index].source == .netease
                && updated[index].id == track.id && updated[index].artworkURL == nil {
                updated[index].artworkURL = artwork
            }
            queue = updated
        }
        if queueBaseTracks.contains(where: { $0.source == .netease && $0.id == track.id && $0.artworkURL == nil }) {
            var updated = queueBaseTracks
            for index in updated.indices where updated[index].source == .netease
                && updated[index].id == track.id && updated[index].artworkURL == nil {
                updated[index].artworkURL = artwork
            }
            queueBaseTracks = updated
        }
    }

    private func applyPendingPlaybackSeek(duration: Double) {
        guard let pending = pendingPlaybackSeek, duration.isFinite, duration > 0,
              currentTrack?.source == pending.source, currentTrack?.id == pending.trackID else { return }
        if pending.source == .spotify && !pendingSpotifySeekConfirmed { return }
        // @Published emits before the player's property is assigned. Wait for
        // both the published duration and the seek API's stored duration.
        let playerDuration = pending.source == .netease ? streamingPlayer.durationSeconds : spotify.durationSeconds
        guard playerDuration.isFinite, playerDuration > 0 else { return }
        pendingPlaybackSeek = nil
        let position = min(pending.seconds, min(duration, playerDuration))
        if pending.source == .netease { streamingPlayer.seek(to: position) }
        else { spotify.seek(toPosition: Int(position * 1000)) }
        elapsedSeconds = position
        savePlaybackState()
    }

    deinit {
        for handler in remoteCommandHandlers { handler.command.removeTarget(handler.token) }
        searchTask?.cancel()
        browseTask?.cancel()
        playbackTask?.cancel()
        playbackPrefetchTask?.cancel()
        playbackSaveTask?.cancel()
        qrTask?.cancel()
        neteaseStatusTask?.cancel()
        wheelStatusTask?.cancel()
        volumeBarTask?.cancel()
        nowPlayingArtworkTask?.cancel()
        netEaseArtworkFillTask?.cancel()
        likedPrewarmTask?.cancel()
    }

    var currentScreen: AppScreen { navigation.last?.screen ?? .home }
    var selectedIndex: Int {
        let raw = navigation.last?.selectedIndex ?? 0
        // Clamp to the current screen's valid range so a row always highlights,
        // even if the list shrank after the index was set (e.g. async playlist load).
        let count: Int
        switch currentScreen {
        case .sources: count = AudioSource.allCases.count
        case .search: count = searchRowCount
        default: count = currentScreen.isTrackList ? browseTracks.count : menuEntries.count
        }
        let minIndex = currentScreen == .search ? -1 : 0
        guard count > 0 else { return minIndex }
        return min(max(raw, minIndex), count - 1)
    }

    /// Songs, then the retry row after a failed page load.
    private var searchRowCount: Int {
        searchResults.count + (searchLoadMoreFailed ? 1 : 0)
    }

    private var defaultSearchSelection: Int {
        searchResults.isEmpty ? -1 : 0
    }

    private var searchFrameIndex: Int? {
        navigation.lastIndex { $0.screen == .search }
    }

    private var searchRequirementScreen: AppScreen? {
        switch selectedSource {
        case .spotify:
            return isSpotifyLoggedIn ? nil : .spotifySettings
        case .netease:
            // Read the stored fields directly: Settings applies them to the client only on disappear.
            let address = UserDefaults.standard.string(forKey: "neteaseBaseURL") ?? ""
            let storedMode = UserDefaults.standard.string(forKey: "neteaseConnectionMode")
            let mode = NetEaseConnectionMode.resolved(storedRaw: storedMode, address: address)
            guard mode == .gateway else { return nil }
            return address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .neteaseSettings : nil
        }
    }

    private var hasSearchRows: Bool { !searchResults.isEmpty }

    /// Whether this screen's refresh is still running. Kept separate from
    /// `isLoadingLibrary` because `browseTracks` reads it while deciding what to
    /// return, so it must not depend on `browseTracks` itself.
    private var isLibraryRefreshInFlight: Bool { browseLoadingScreen == currentScreen }

    /// True only when the screen has nothing to show yet. A refresh running behind
    /// cached rows is invisible: the list already has content, and reporting it as
    /// a load made every re-entry look like a reload.
    var isLoadingLibrary: Bool {
        guard isLibraryRefreshInFlight else { return false }
        return !hasBrowsableRows
    }

    /// Content already available to draw, without going through `browseTracks`.
    private var hasBrowsableRows: Bool {
        switch currentScreen {
        case .playlists: return !sourcePlaylists.isEmpty
        case .podcasts: return !podcastShows.isEmpty
        case .songs: return !songs.isEmpty
        case .dailyRecommendations: return !dailyRecommendationTracks.isEmpty
        case .radio: return !radioTracks.isEmpty
        case .podcastEpisodes: return !(libraryTracks[currentScreen] ?? []).isEmpty
        case .artistTracks(_, let artist):
            if let tracks = libraryTracks[currentScreen], !tracks.isEmpty { return true }
            return !localTracks(byArtist: artist).isEmpty
        case .albumTracks(let albumID, let album, let artist):
            if let tracks = libraryTracks[currentScreen], !tracks.isEmpty { return true }
            return completeAlbums[albumKey(album, source: selectedSource, id: albumID, artist: artist)] != nil
        default: return !(libraryTracks[currentScreen] ?? []).isEmpty
        }
    }

    // Playlist metadata persists; the queue and latest search join this index only in memory.
    private var browsingCandidates: [Track] {
        var seen = Set<String>()
        return (localLibraryTracks + queue + searchResults).filter { $0.source == selectedSource }.filter {
            seen.insert($0.source.rawValue + ":" + ($0.spotifyTrackID ?? $0.id)).inserted
        }
    }

    private var localBrowsingTracks: [Track] { browsingIndex().local }

    var dailyRecommendationTracks: [Track] { libraryTracks[.dailyRecommendations] ?? [] }

    /// 歌单 is a plain iPod list: names only, alphabetical, no covers and no
    /// owner. Spotify's like anchor is an ordinary playlist that the app writes
    /// into, so it is not listed as a second copy of the liked collection.
    private var browsePlaylists: [MusicPlaylist] {
        let systemID = selectedSource == .spotify ? spotify.likedAnchorPlaylistID : nil
        var seen = Set<String>()
        return sourcePlaylists
            .filter { $0.source == selectedSource && $0.id != systemID && seen.insert($0.id).inserted }
            .sorted {
                // 我喜欢的音乐 is the one playlist the account did not create and
                // cannot lose, so it stays above the alphabetical rest.
                if $0.isLiked != $1.isLiked { return $0.isLiked }
                let order = Self.compareAlphabetically($0.title, $1.title)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    /// Alphabetical order for every list in the app: letters first, then
    /// numbers, then punctuation and symbols. Plain `localizedStandardCompare`
    /// ranks "#", "《" and digits above "A", so a single symbol-leading title
    /// pushes the whole alphabet a page down the list.
    private nonisolated static func compareAlphabetically(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsBucket = alphabetBucket(lhs)
        let rhsBucket = alphabetBucket(rhs)
        if lhsBucket != rhsBucket { return lhsBucket < rhsBucket ? .orderedAscending : .orderedDescending }
        return lhs.localizedStandardCompare(rhs)
    }

    /// Bucket of the leading non-space character: 0 letters (CJK included),
    /// 1 digits, 2 everything else. An empty name sits with the symbols.
    private nonisolated static func alphabetBucket(_ name: String) -> Int {
        guard let first = name.first(where: { !$0.isWhitespace }) else { return 2 }
        if first.isLetter { return 0 }
        if first.isNumber { return 1 }
        return 2
    }

    private var songs: [Track] { browsingIndex().songs }

    var browseTracks: [Track] {
        switch currentScreen {
        case .dailyRecommendations: return selectedSource == .netease ? dailyRecommendationTracks : []
        case .radio: return selectedSource == .netease ? radioTracks : []
        case .songs: return songs
        case .podcastEpisodes: return libraryTracks[currentScreen] ?? []
        case .artistTracks(_, let artist):
            if let tracks = libraryTracks[currentScreen], !tracks.isEmpty {
                return tracks
            }
            let localMatches = localTracks(byArtist: artist)
            if !localMatches.isEmpty { return localMatches }
            if isLibraryRefreshInFlight { return [] }
            return browsingCandidates.filter { trackHasArtist($0, artist: artist) || $0.artist.localizedCaseInsensitiveContains(artist) }
        case .albumTracks(let albumID, let album, let artist):
            if let tracks = libraryTracks[currentScreen] ?? completeAlbums[albumKey(album, source: selectedSource, id: albumID, artist: artist)] {
                return tracks
            }
            if isLibraryRefreshInFlight { return [] }
            return browsingCandidates.filter { $0.album == album && (artist == nil || $0.artist == artist) }
        default: return libraryTracks[currentScreen] ?? []
        }
    }

    private var artistNames: [String] { browsingIndex().artists }

    private struct LibraryAlbum: Hashable {
        let name: String
        let artist: String
    }

    /// Same album title by different artists stays as separate rows.
    private var libraryAlbums: [LibraryAlbum] { browsingIndex().albums }

    /// Everything derived from the local library, built once per library or source
    /// change. Wheel steps and playback updates then read cached arrays instead of
    /// re-sorting up to 20,000 tracks on every screen pass.
    private struct BrowsingIndex {
        var generation: UUID
        let source: AudioSource
        let local: [Track]
        let songs: [Track]
        let artists: [String]
        let albums: [LibraryAlbum]
        /// Positions in `local` per credited artist, in library order.
        let artistTrackIndices: [String: [Int]]
    }

    private func browsingIndex() -> BrowsingIndex {
        if let cached = cachedBrowsingIndex,
           cached.generation == libraryGeneration, cached.source == selectedSource {
            return cached
        }
        // This runs inside SwiftUI bodies. Sorting the whole library here put a
        // multi-second pass on the main thread while a screen was being laid out, and
        // the watchdog killed the app when that pass collided with a termination. The
        // previous snapshot of the same source is good enough until the rebuild below
        // lands; only a cold start with nothing cached still builds inline.
        if let stale = cachedBrowsingIndex, stale.source == selectedSource {
            scheduleBrowsingIndexPrewarm()
            return stale
        }
        let index = Self.buildBrowsingIndex(localLibraryTracks, source: selectedSource,
                                            generation: libraryGeneration)
        cachedBrowsingIndex = index
        return index
    }

    /// Collapses the burst of library writes that a refresh or a heart press produces
    /// into one sort, off the main actor. Without this, the stale snapshot handed out
    /// above would be the last thing the menu ever saw.
    ///
    /// Keyed on the generation rather than on "is a task running": a stale read from a
    /// SwiftUI body must not restart the delay, or a redraw faster than the delay would
    /// postpone the rebuild forever and leave the menu on the old snapshot.
    private func scheduleBrowsingIndexPrewarm() {
        let generation = libraryGeneration
        guard browsingIndexPrewarmGeneration != generation else { return }
        browsingIndexPrewarmGeneration = generation
        browsingIndexPrewarmTask?.cancel()
        browsingIndexPrewarmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            await self.prewarmBrowsingIndex()
        }
    }

    /// A logout or an account switch replaces the whole library. The old snapshot is
    /// the previous account's music and must not be served while the rebuild runs.
    private func discardBrowsingIndex() {
        browsingIndexPrewarmTask?.cancel()
        browsingIndexPrewarmTask = nil
        browsingIndexPrewarmGeneration = nil
        cachedBrowsingIndex = nil
    }

    /// Pure: `nonisolated` so the boot screen can build the first index off the
    /// main actor while the library is still the only thing loaded.
    private nonisolated static func buildBrowsingIndex(_ library: [Track], source: AudioSource,
                                                       generation: UUID) -> BrowsingIndex {
        var seen = Set<String>()
        let local = library.filter { $0.source == source }.filter {
            seen.insert($0.source.rawValue + ":" + ($0.spotifyTrackID ?? $0.id)).inserted
        }
        // Precompute the sort key and its bucket once per track instead of twice
        // per comparison.
        let keyed = local.map { track -> (track: Track, key: String, bucket: Int) in
            let key = songSortKey(track.title)
            return (track, key, alphabetBucket(key))
        }
        let songs = keyed.sorted {
            if $0.bucket != $1.bucket { return $0.bucket < $1.bucket }
            let order = $0.key.localizedStandardCompare($1.key)
            if order != .orderedSame { return order == .orderedAscending }
            let titleOrder = $0.track.title.localizedStandardCompare($1.track.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.track.id < $1.track.id
        }.map(\.track)
        var artistTrackIndices: [String: [Int]] = [:]
        for (position, track) in local.enumerated() {
            var credited = Set<String>()
            for name in splitArtistNames(track.artist) where credited.insert(name).inserted {
                artistTrackIndices[name, default: []].append(position)
            }
        }
        let artists = artistTrackIndices.keys
            .sorted { compareAlphabetically($0, $1) == .orderedAscending }
        var seenAlbums = Set<String>()
        var albums: [LibraryAlbum] = []
        for track in local {
            let name = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = track.artist + "\u{1F}" + name
            guard seenAlbums.insert(key).inserted else { continue }
            albums.append(LibraryAlbum(name: name, artist: track.artist))
        }
        albums.sort {
            let nameOrder = compareAlphabetically($0.name, $1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return compareAlphabetically($0.artist, $1.artist) == .orderedAscending
        }
        return BrowsingIndex(generation: generation, source: source,
                             local: local, songs: songs, artists: artists, albums: albums,
                             artistTrackIndices: artistTrackIndices)
    }

    /// Drops a leading "The / A / An" plus its whitespace. A regex here ran once per
    /// track on every index build, which is most of a 20k-song rebuild.
    private nonisolated static func songSortKey(_ title: String) -> String {
        for article in ["the", "an", "a"] {
            guard let range = title.range(of: article, options: [.anchored, .caseInsensitive]) else { continue }
            let rest = title[range.upperBound...]
            let words = rest.drop(while: \.isWhitespace)
            if words.startIndex != rest.startIndex { return String(words) }
        }
        return title
    }

    /// Local songs crediting `artist`, looked up in the index instead of splitting
    /// every track's artist field again on the main actor.
    private func localTracks(byArtist artist: String) -> [Track] {
        let index = browsingIndex()
        return index.artistTrackIndices[artist]?.map { index.local[$0] } ?? []
    }

    var browseStateMessage: String? {
        // Radio says what it is doing: it is fetching music rather than loading a
        // list the user already chose.
        if currentScreen == .radio, isRadioLoading, radioTracks.isEmpty {
            return "正在为你挑选新歌…"
        }
        if isLoadingLibrary && (currentScreen == .playlists ? sourcePlaylists.isEmpty
                                : currentScreen == .podcasts ? podcastShows.isEmpty
                                : browseTracks.isEmpty) {
            return currentScreen == .podcasts ? "正在载入播客…" : "正在载入…"
        }
        if let message = browseMessages[currentScreen] { return message }
        switch currentScreen {
        case .songs where songs.isEmpty:
            return "暂无歌曲。播放时按住中键即可把歌曲加入这里。"
        case .artists where artistNames.isEmpty,
             .albums where libraryAlbums.isEmpty:
            return "暂无歌曲。播放时按住中键即可把歌曲加入这里。"
        case .artists, .albums, .artistTracks, .albumTracks: return nil
        case .playlists: return sourcePlaylists.isEmpty ? "暂无歌单" : nil
        case .podcasts:
            return podcastShows.isEmpty ? "请先在网易云音乐中订阅播客。" : nil
        case .podcastEpisodes:
            return browseTracks.isEmpty ? "该播客近期没有节目。" : nil
        case .radio:
            if let radioLoadingError { return radioLoadingError }
            return radioTracks.isEmpty ? "暂无歌曲" : nil
        default: return currentScreen.isTrackList && browseTracks.isEmpty ? "暂无歌曲" : nil
        }
    }

    @ObservationIgnored private var cachedCoverFlowAlbums: [CoverFlowAlbum]?
    @ObservationIgnored private var cachedCoverFlowKey: String?
    /// Changes whenever the cover IDs do, so the view can react to a new set
    /// without copying and comparing up to 2,000 IDs on every pass.
    @ObservationIgnored private(set) var coverFlowIdentity = 0
    /// A whole-library Songs page can hold tens of thousands of rows. Per-song
    /// entries are what the view mirrors while browsing, but past this size the
    /// looping slot copies become too expensive and album covers are used instead.
    private static let coverFlowSongEntryLimit = 2_000

    var coverFlowAlbums: [CoverFlowAlbum] {
        #if DEBUG
        if let coverFlowFixtureAlbums { return coverFlowFixtureAlbums }
        #endif
        let pageMode = currentScreen.isTrackList
        let searchMode = currentScreen == .search
        // Cache stamps only: reading browseTracks here would filter and sort the
        // library on every body pass, cached answer or not.
        let key = selectedSource.rawValue + "|" + (pageMode ? "page:" + coverFlowScreenIdentity
                                                         : (searchMode ? "search" : "queue"))
            + "|" + String(libraryTracksVersion)
            + "|" + String(radioTracksVersion)
            + "|" + libraryGeneration.uuidString
            + "|" + String(queueVersion) + "|" + String(searchResultsVersion)
            + "|" + (currentTrack?.id ?? "")
            + "|" + (currentTrack?.artworkURL?.absoluteString ?? "")
        if key == cachedCoverFlowKey, let cached = cachedCoverFlowAlbums { return cached }

        let pageTracks = pageMode ? browseTracks : []
        // An empty page is still loading; the queue keeps the flow from blanking.
        var tracks: [Track]
        if !pageTracks.isEmpty { tracks = pageTracks }
        else if searchMode { tracks = searchResults }
        else { tracks = queue }
        if let currentTrack, currentTrack.source == selectedSource {
            if let index = tracks.firstIndex(where: { $0.source == currentTrack.source && $0.id == currentTrack.id }) {
                // Preserve the page's order, but use resolved real art.
                tracks[index].artworkURL = currentTrack.artworkURL ?? tracks[index].artworkURL
            } else if !pageMode && !searchMode {
                tracks.append(currentTrack)
            }
        }
        // One cover per row: a recommendation list with several songs from the
        // same album must still be browsable song by song.
        let albums: [CoverFlowAlbum]
        if tracks.count > Self.coverFlowSongEntryLimit {
            albums = CoverFlowAlbum.albums(from: tracks, source: selectedSource)
        } else {
            albums = CoverFlowAlbum.songs(from: tracks, source: selectedSource)
        }
        if !(cachedCoverFlowAlbums?.elementsEqual(albums, by: { $0.id == $1.id }) ?? false) {
            coverFlowIdentity &+= 1
        }
        cachedCoverFlowAlbums = albums
        cachedCoverFlowKey = key
        return albums
    }

    /// Stable identity for the browsed page, so switching pages always misses the cache.
    private var coverFlowScreenIdentity: String {
        switch currentScreen {
        case .playlistTracks(let playlist):
            return "playlist|" + playlist.source.rawValue + "|" + playlist.id
        case .artistTracks(let id, let name):
            return "artist|" + (id ?? "") + "|" + name
        case .albumTracks(let id, let name, let artist):
            return "album|" + (id ?? "") + "|" + name + "|" + (artist ?? "")
        default:
            return String(describing: currentScreen)
        }
    }

    func isCurrentCoverFlowAlbum(_ album: CoverFlowAlbum) -> Bool {
        guard let currentTrack, currentTrack.source == selectedSource else { return false }
        return album.contains(currentTrack)
    }

    func playCoverFlowAlbum(_ album: CoverFlowAlbum) {
        // Resolve against live source data so a stale view cannot start an old source.
        guard let available = coverFlowAlbums.first(where: { $0.id == album.id }) else { return }
        if isCurrentCoverFlowAlbum(available) {
            togglePlayPause()
            return
        }
        guard let firstTrack = available.tracks.first else { return }
        // Playing from a browsed page starts that page, so the rest of the
        // visible list becomes the queue exactly as a row tap would.
        if currentScreen.isTrackList,
           let index = browseTracks.firstIndex(where: { $0.source == firstTrack.source && $0.id == firstTrack.id }) {
            playBrowseTrack(at: index)
            return
        }
        if currentScreen == .search,
           let index = searchResults.firstIndex(where: { $0.source == firstTrack.source && $0.id == firstTrack.id }) {
            playSearchResult(at: index)
            return
        }
        if let index = queue.firstIndex(where: { $0.source == firstTrack.source && $0.id == firstTrack.id }) {
            startPlayback(queue[index], at: index)
        } else {
            preparePlaybackQueue(available.tracks, startingWith: firstTrack)
        }
    }

    var progress: Double {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
        return min(max(elapsedSeconds / durationSeconds, 0), 1)
    }

    var emptyStateMessage: String? {
        if currentScreen.loadsLibrary || currentScreen == .songs || currentScreen == .artists || currentScreen == .albums {
            return browseStateMessage
        }
        if currentScreen == .search, !hasSearchRows {
            if isSearching { return "正在搜索…" }
            switch searchRequirementScreen {
            case .spotifySettings: return "请先前往“设置”登录 Spotify，再搜索或播放歌曲。"
            case .neteaseSettings: return "请先到“设置 → 网易云设置”填写自己的服务地址。"
            default: break
            }
            switch searchNotice {
            case .noResults: return "没有找到歌曲，请尝试其他歌名或艺人。"
            case .failed(let message): return message
            case nil: return "输入歌名或艺人，搜索当前音源"
            }
        }
        if currentScreen == .nowPlaying && currentTrack == nil {
            // 电台 opens here before its first song exists; say what the station is
            // doing instead of claiming nothing is playing.
            if isRadioLoading { return "正在为你挑选新歌…" }
            if let radioLoadingError { return radioLoadingError }
            return "还没有播放歌曲"
        }
        return nil
    }

    /// Building the artist or album menu maps the whole catalogue into rows, and
    /// the wheel reads it twice per step (count, then the visible list). The rows
    /// only depend on the library, source and language, so the built array is kept
    /// until one of those changes instead of being rebuilt on every frame.
    @ObservationIgnored private var cachedMenuEntries: [MenuEntry] = []
    @ObservationIgnored private var cachedMenuKey: String?

    private func memoizedMenuEntries(_ key: String, build: () -> [MenuEntry]) -> [MenuEntry] {
        if key == cachedMenuKey { return cachedMenuEntries }
        let entries = build()
        cachedMenuKey = key
        cachedMenuEntries = entries
        return entries
    }

    var menuEntries: [MenuEntry] {
        switch currentScreen {
        case .home:
            // iPod Classic's root order: Music, then Podcasts, then Settings.
            // 播客 is a NetEase-only library (its DJ endpoints have no Spotify
            // counterpart), so on Spotify the row is not drawn at all rather than
            // sitting there as a dead entry.
            var entries: [MenuEntry] = [MenuEntry("音乐", action: .open(.music))]
            if selectedSource == .netease {
                entries.append(MenuEntry("播客", action: .open(.podcasts)))
            }
            entries.append(MenuEntry("设置", action: .open(.settings)))
            // One row instead of two switches: 随机播放 / 单曲循环 / 列表循环
            // cannot contradict each other, so the row's subtitle is the whole
            // answer to "what will happen when this song ends".
            entries.append(MenuEntry("播放模式", detail: playbackMode.displayName, action: .playbackMode))
            // An iPod only lists Now Playing once a song is loaded into it.
            if currentTrack != nil {
                entries.append(MenuEntry("正在播放", action: .open(.nowPlaying)))
            }
            return entries
        case .music:
            // An iPod's Songs entry *is* the library: on this app that is the
            // liked collection, so there is no second 我喜欢的音乐 row.
            var entries = [
                MenuEntry("搜索", action: .open(.search)),
                MenuEntry("歌曲", action: .open(.songs)),
                MenuEntry("歌单", action: .open(.playlists))
            ]
            if selectedSource == .netease {
                entries.append(MenuEntry("每日推荐", action: .open(.dailyRecommendations)))
                entries.append(MenuEntry("电台", action: .open(.radio)))
            }
            return entries + [
                MenuEntry("歌手", action: .open(.artists)),
                MenuEntry("专辑", action: .open(.albums))
            ]
        case .settings:
            // Configuring a source now lives inside 音源. Shuffle and repeat are
            // not settings rows: they live on the root menu, where they can be
            // reached in one press instead of two.
            return [
                MenuEntry("音源", detail: selectedSource.displayName, action: .open(.sources)),
                MenuEntry("外观", action: .open(.appearance)),
                MenuEntry("语言", action: .open(.languages))
            ]
        case .languages:
            return AppLanguage.allCases.map {
                MenuEntry($0.nativeName, id: $0.rawValue, marked: $0 == language,
                          translates: false, action: .language($0))
            }
        case .appearance:
            let followsSystem = UserDefaults.standard.object(forKey: "appearanceFollowSystem") as? Bool ?? true
            let customAccent = UserDefaults.standard.bool(forKey: "useCustomAccent")
            return [MenuEntry("跟随系统", switchValue: followsSystem, action: .setting(.followSystem))]
                + AppThemePreset.allCases.map { MenuEntry($0.rawValue, action: .setting(.theme($0))) }
                + [
                    MenuEntry("使用自定强调色", switchValue: customAccent, action: .setting(.customAccentEnabled)),
                    MenuEntry("自定强调色", action: .setting(.customAccentColor)),
                    // 3.1, appended after the existing rows so their order is untouched.
                    MenuEntry("沉浸式播放页",
                              switchValue: UserDefaults.standard.bool(forKey: "immersiveNowPlaying"),
                              action: .setting(.immersiveNowPlaying))
                ]
        case .neteaseSettings:
            var entries = [
                MenuEntry("连接方式",
                          detail: neteaseMode == .direct ? "直连官方接口" : "自建网关",
                          action: .setting(.neteaseMode))
            ]
            if neteaseMode == .gateway {
                entries.append(MenuEntry("网易云服务地址", action: .setting(.neteaseAddress)))
            }
            entries.append(contentsOf: [
                MenuEntry("保存并检查登录", action: .setting(.saveNetEase)),
                MenuEntry(isNetEaseLoggingIn ? "重新生成二维码" : "生成登录二维码",
                          id: "neteaseQR", action: .setting(.generateNetEaseQR))
            ])
            if isNetEaseLoggingIn {
                entries.append(MenuEntry("取消", action: .setting(.cancelNetEaseQR)))
            }
            entries.append(MenuEntry("退出网易云登录", action: .setting(.logoutNetEase)))
            return entries
        case .spotifySettings:
            return [
                MenuEntry("Spotify 客户端标识", action: .setting(.spotifyClientID)),
                MenuEntry("回调地址", action: .setting(.spotifyRedirectURI)),
                MenuEntry(isSpotifyLoggedIn ? "退出 Spotify 登录" : "登录 Spotify",
                          id: "spotifyLogin", action: .setting(isSpotifyLoggedIn ? .logoutSpotify : .loginSpotify))
            ]
        case .podcasts:
            // Show names are the user's subscriptions, so they are never translated.
            let key = "podcasts|" + selectedSource.rawValue + "|" + podcastShows.map {
                $0.id + "\u{1F}" + $0.title
            }.joined(separator: "\u{1E}")
            return memoizedMenuEntries(key) {
                podcastShows.map { show in
                    MenuEntry(show.title, id: show.id,
                              detail: show.episodeCount.map { L10n.text("\($0) 集") },
                              translates: false,
                              action: .open(.podcastEpisodes(id: show.id, name: show.title)))
                }
            }
        case .playlists:
            let visible = browsePlaylists
            // The row text is the user's own; only the count is a locale template,
            // so the language is part of the identity.
            let key = "playlists|" + language.rawValue + "|" + visible.map {
                $0.id + "\u{1F}" + $0.title + "\u{1F}" + ($0.trackCount.map(String.init) ?? "-")
                    + "\u{1F}" + ($0.isLiked ? "1" : "0")
            }.joined(separator: "\u{1E}")
            return memoizedMenuEntries(key) {
                visible.map { playlist in
                    MenuEntry(playlist.title, id: playlist.id,
                              detail: playlist.trackCount.map { L10n.text("\($0) 首") },
                              translates: false, action: .open(.playlistTracks(playlist)))
                }
            }
        case .artists:
            let key = "artists|" + language.rawValue + "|" + selectedSource.rawValue
                + "|" + libraryGeneration.uuidString
            return memoizedMenuEntries(key) {
                artistNames.map {
                    MenuEntry($0, translates: false, action: .open(.artistTracks(id: nil, name: $0)))
                }
            }
        case .albums:
            let key = "albums|" + language.rawValue + "|" + selectedSource.rawValue
                + "|" + libraryGeneration.uuidString
            return memoizedMenuEntries(key) {
                libraryAlbums.map { album in
                    MenuEntry(album.name, id: album.artist + "\u{1F}" + album.name,
                              detail: album.artist.isEmpty ? nil : album.artist,
                              translates: false,
                              action: .open(.albumTracks(id: nil, name: album.name, artist: album.artist)))
                }
            }
        default: return []
        }
    }

    @discardableResult
    func moveSelection(by direction: Int) -> Bool {
        let count: Int
        let minIndex: Int
        switch currentScreen {
        case .sources: count = AudioSource.allCases.count; minIndex = 0
        case .search: count = searchRowCount; minIndex = -1
        default: count = currentScreen.isTrackList ? browseTracks.count : menuEntries.count; minIndex = 0
        }
        // Search includes the input box as row -1, so the wheel can return to it.
        let totalRows = currentScreen == .search ? count + 1 : count
        guard totalRows > 1, direction != 0 else { return false }
        defer {
            let totalSearchCount = searchResults.count
            if currentScreen == .search, selectedIndex >= max(0, totalSearchCount - 5),
               searchHasMore, !isLoadingMoreSearch, !isSearching {
                loadMoreSearchResults()
            }
        }
        let next = min(max(selectedIndex + (direction > 0 ? 1 : -1), minIndex), count - 1)
        guard next != selectedIndex else { return false }
        navigation[navigation.count - 1].selectedIndex = next
        return true
    }

    func selectMenuEntry(at index: Int) {
        guard menuEntries.indices.contains(index) else { return }
        navigation[navigation.count - 1].selectedIndex = index
        confirmSelection()
    }

    func confirmSelection() {
        switch currentScreen {
        case .nowPlaying: togglePlayPause()
        case .sources:
            guard AudioSource.allCases.indices.contains(selectedIndex) else { return }
            // The list only switches sources; the highlighted source opens its own
            // configuration, so choosing and configuring never share one press.
            let source = AudioSource.allCases[selectedIndex]
            if source == selectedSource { open(source.settingsScreen) }
            else { selectSource(source) }
        case .search:
            if selectedIndex == -1 {
                if !hasSearchRows, let screen = searchRequirementScreen {
                    open(screen)
                } else if !hasSearchRows, case .failed = searchNotice {
                    performSearch()
                } else {
                    searchFocusRequest += 1
                }
            } else if searchResults.indices.contains(selectedIndex) {
                playSearchResult(at: selectedIndex)
            } else {
                retryLoadMoreSearchResults()
            }
        case .dailyRecommendations, .radio, .songs, .podcastEpisodes,
             .playlistTracks, .artistTracks, .albumTracks:
            playBrowseTrack(at: selectedIndex)
        default:
            guard menuEntries.indices.contains(selectedIndex) else { return }
            switch menuEntries[selectedIndex].action {
            case .open(let screen): open(screen)
            case .setting(let action): settingsActions.send(action)
            case .playbackMode:
                cyclePlaybackMode()
            case .language(let choice):
                AppLanguage.select(choice)
                language = choice
            }
        }
    }

    func open(_ screen: AppScreen) {
        guard screen != currentScreen else { return }
        // 每日推荐, 电台 and the DJ-backed podcast screens exist on NetEase only.
        // Their menu rows are hidden on Spotify, so this is only a guard.
        guard !screen.requiresNetEase || selectedSource == .netease else { return }
        likeStatus = nil
        // One publish for the whole transition: appending and then editing the frame
        // made SwiftUI diff the entire screen two or three times before it drew.
        let initialSelection: Int
        switch screen {
        case .search:
            // The input row owns the selection because the keyboard is raised with
            // this push. Opening on a stale result row instead would move the
            // selection once focus arrives, which publishes a second time.
            initialSelection = -1
            isSearchKeyboardRequested = true
        case .languages: initialSelection = AppLanguage.allCases.firstIndex(of: language) ?? 0
        // 音源 opens on the active source: centre then configures it instead of
        // silently switching to whichever source happens to be first.
        case .sources: initialSelection = AudioSource.allCases.firstIndex(of: selectedSource) ?? 0
        default: initialSelection = 0
        }
        navigation.append(NavigationFrame(screen: screen, selectedIndex: initialSelection))
        // 电台 is a frequency, not a list to choose from: its row press lands on Now
        // Playing immediately. The queue list is still pushed underneath, so MENU
        // returns to the station while it plays and refills.
        if screen == .radio {
            navigation.append(NavigationFrame(screen: .nowPlaying, selectedIndex: 0))
        }
        if screen.loadsLibrary { loadLibrary(screen) }
        else if screen.isTrackList { refreshLikedStateAfterLayout(for: browseTracks) }
        else if screen == .search { refreshLikedStateAfterLayout(for: searchResults) }
        else if screen == .nowPlaying, let currentTrack { refreshLikedState(for: [currentTrack]) }
    }

    /// Heart checks are network work plus a membership set the size of the list.
    /// Queueing them after the navigation update lets the new screen draw its first
    /// frame first; doing it inline made opening a list wait on its own setup.
    private func refreshLikedStateAfterLayout(for tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let snapshot = tracks
        Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.refreshLikedState(for: snapshot)
        }
    }

    func goBack() {
        guard navigation.count > 1 else { return }
        // Search results are one level below their input row, not a page to leave:
        // MENU steps back into the field and raises the keyboard so a new query can
        // be typed straight away. The next MENU press leaves Search as usual.
        if currentScreen == .search, selectedIndex >= 0 {
            navigation[navigation.count - 1].selectedIndex = -1
            searchFocusRequest += 1
            return
        }
        if currentScreen == .neteaseSettings { cancelNetEaseQRLogin() }
        // 电台 is a frequency, not a list. Its queue page sits under Now Playing only
        // so the station keeps its rows; MENU must return to where the station was
        // started instead of dropping the user into that generated list.
        if currentScreen == .nowPlaying, navigation.count >= 3,
           navigation[navigation.count - 2].screen == .radio {
            navigation.removeLast(2)
            likeStatus = nil
            return
        }
        // Leaving 电台 does not stop the station: the radio queue keeps playing and
        // refilling until something else starts a queue (see startPlayback).
        if currentScreen.loadsLibrary { cancelLibraryLoad() }
        navigation.removeLast()
        likeStatus = nil
        if currentScreen == .songs && likedSongsNeedsRefresh { loadLibrary(.songs) }
        else if currentScreen.isTrackList { refreshLikedState(for: browseTracks) }
        else if currentScreen == .search { refreshLikedState(for: searchResults) }
    }

    /// Long-press MENU: drop every pushed screen in one publish and land on the
    /// root. The same clean-up as `goBack` runs once, because none of the screens
    /// being skipped will get their own farewell.
    func goHome() {
        guard navigation.count > 1 else { return }
        // A pending keyboard request would raise the field on a screen that is
        // already gone; Search dismisses itself when it leaves the hierarchy.
        isSearchKeyboardRequested = false
        if currentScreen == .neteaseSettings { cancelNetEaseQRLogin() }
        if currentScreen.loadsLibrary { cancelLibraryLoad() }
        navigation.removeSubrange(1..<navigation.count)
        likeStatus = nil
    }

    func selectSource(_ source: AudioSource) {
        if selectedSource != source {
            reportCurrentNetEasePlay()
            sourcePlaybackStates[selectedSource] = SourcePlaybackState(
                queue: queue, queueBaseTracks: queueBaseTracks, queueIndex: queueIndex,
                currentTrack: currentTrack, elapsedSeconds: elapsedSeconds,
                durationSeconds: durationSeconds, playbackSourceID: playbackSourceID,
                searchQuery: searchQuery, searchResults: searchResults,
                searchResultsQuery: searchResultsQuery,
                searchHasMore: searchHasMore, searchNextOffset: searchNextOffset
            )
            cancelPendingPlayback()
            searchTask?.cancel()
            searchGeneration = UUID()
            isSearching = false
            isLoadingMoreSearch = false
            consecutiveNetEaseFailures = 0
            lastHandledNetEaseFailure = nil
            streamingPlayer.stop()
            if currentTrack?.source == .spotify { spotify.pause() }
            spotify.disconnect()
            let restored = sourcePlaybackStates[source]
            isRestoringPlayback = true
            selectedSource = source
            resetLikedState()
            resetLibrary()
            searchQuery = restored?.searchQuery ?? ""
            searchResults = restored?.searchResults ?? []
            searchResultsQuery = restored?.searchResultsQuery ?? ""
            searchHasMore = restored?.searchHasMore ?? false
            searchNextOffset = restored?.searchNextOffset ?? 0
            searchLoadMoreFailed = false
            searchNotice = nil
            searchListID = UUID()
            queue = restored?.queue ?? []
            queueBaseTracks = restored?.queueBaseTracks ?? []
            queueIndex = restored?.queueIndex
            requestedTrackID = nil
            currentTrack = restored?.currentTrack
            elapsedSeconds = restored?.elapsedSeconds ?? 0
            durationSeconds = restored?.durationSeconds ?? 0
            playbackSourceID = restored?.playbackSourceID
            isPlaying = false
            restoredPlaybackNeedsStart = currentTrack != nil
            pendingPlaybackSeek = nil
            pendingSpotifySeekConfirmed = false
            isRestoringPlayback = false
            if currentScreen == .search, !searchResults.isEmpty {
                refreshLikedState(for: searchResults)
            }
            UserDefaults.standard.set(source.rawValue, forKey: "selectedSource")
            syncNowPlayingInfo()
            // 歌曲/歌手/专辑 describe the new source's liked list, so the index is
            // rebuilt from that list rather than reused.
            refreshLikedLibrary()
            Task { [weak self] in await self?.prewarmBrowsingIndex() }
        }
        if currentScreen == .sources {
            navigation[navigation.count - 1].selectedIndex = AudioSource.allCases.firstIndex(of: source) ?? 0
        }
        // NetEase-only screens cannot render on Spotify; drop back to the root
        // instead of leaving an empty list behind.
        if source != .netease, currentScreen.requiresNetEase, navigation.count > 1 {
            navigation.removeSubrange(1..<navigation.count)
        }
    }

    func performSearch() {
        searchTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        isSearching = false
        searchHasMore = false
        searchNextOffset = 0
        isLoadingMoreSearch = false
        searchLoadMoreFailed = false
        searchNotice = nil
        searchResultsQuery = ""
        searchResults = []
        searchListID = UUID()
        if let frameIndex = searchFrameIndex { navigation[frameIndex].selectedIndex = -1 }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // A missing login or service address is already shown in place of the results.
        guard !query.isEmpty, searchRequirementScreen == nil else { return }
        let source = selectedSource
        isSearching = true
        searchResultsQuery = query
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page: SearchPage
                if source == .netease { page = try await self.netease.search(query: query, offset: 0) }
                else { page = try await self.spotify.search(query: query, offset: 0) }
                guard !Task.isCancelled, self.searchGeneration == generation, self.selectedSource == source else { return }
                self.searchResults = page.tracks
                self.searchHasMore = page.hasMore
                self.searchNextOffset = page.nextOffset
                self.isSearching = false
                if page.tracks.isEmpty { self.searchNotice = .noResults }
                // MENU may have left Search while this was loading; only Search's own frame moves.
                if let frameIndex = self.searchFrameIndex {
                    self.navigation[frameIndex].selectedIndex = self.defaultSearchSelection
                }
                self.refreshLikedState(for: page.tracks)
            } catch {
                guard !Task.isCancelled, self.searchGeneration == generation, self.selectedSource == source else { return }
                self.isSearching = false
                self.searchNotice = .failed(L10n.error(error.localizedDescription))
            }
        }
    }

    func clearSearch() {
        searchQuery = ""
        performSearch()
    }

    func selectSearchInput() {
        guard currentScreen == .search else { return }
        // Focusing the field during the keyboard presentation publishes again and
        // repaints the whole screen; when the input row is already selected this is
        // a no-op that only cost frames.
        guard navigation[navigation.count - 1].selectedIndex != -1 else { return }
        navigation[navigation.count - 1].selectedIndex = -1
    }

    /// Search raises its keyboard on the way in, but only for the transition out
    /// of the menu. The boot-screen warmup makes that presentation cheap; coming
    /// back from Now Playing instead returns to the result rows, which the
    /// keyboard would otherwise cover.
    @ObservationIgnored private var isSearchKeyboardRequested = false

    /// The view's single chance to react to the request: an entry that needs a
    /// login or answers a failure belongs to the list, not to the keyboard.
    func consumeSearchKeyboardRequest() -> Bool {
        guard isSearchKeyboardRequested else { return false }
        isSearchKeyboardRequested = false
        guard currentScreen == .search, searchRequirementScreen == nil else { return false }
        if case .failed = searchNotice { return false }
        return true
    }

    func retryLoadMoreSearchResults() {
        guard searchLoadMoreFailed else { return }
        searchLoadMoreFailed = false
        loadMoreSearchResults()
    }

    /// Automatic paging stops after a failure; only the retry row resumes it.
    func loadMoreSearchResults() {
        let query = searchResultsQuery
        guard searchHasMore, !isLoadingMoreSearch, !isSearching, !searchLoadMoreFailed, !query.isEmpty else { return }
        searchTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        let source = selectedSource
        let offset = searchNextOffset
        isLoadingMoreSearch = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page: SearchPage
                if source == .netease { page = try await self.netease.search(query: query, offset: offset) }
                else { page = try await self.spotify.search(query: query, offset: offset) }
                guard !Task.isCancelled, self.searchGeneration == generation, self.selectedSource == source else { return }
                var seen = Set(self.searchResults.map(\.id))
                let appendedTracks = page.tracks.filter { seen.insert($0.id).inserted }
                self.searchResults.append(contentsOf: appendedTracks)
                self.searchHasMore = page.hasMore
                self.searchNextOffset = page.nextOffset
                self.refreshLikedState(for: appendedTracks)
                self.isLoadingMoreSearch = false
            } catch {
                guard !Task.isCancelled, self.searchGeneration == generation, self.selectedSource == source else { return }
                self.isLoadingMoreSearch = false
                self.searchLoadMoreFailed = true
            }
        }
    }

    func playSearchResult(at index: Int) {
        guard searchResults.indices.contains(index) else { return }
        navigation[navigation.count - 1].selectedIndex = index
        let track = searchResults[index]
        preparePlaybackQueue(searchResults, startingWith: track, at: index)
        open(.nowPlaying)
    }

    func playBrowseTrack(at index: Int) {
        if currentScreen == .radio {
            playRadio(at: index)
            return
        }
        let tracks = browseTracks
        guard tracks.indices.contains(index), tracks[index].source == selectedSource else { return }
        navigation[navigation.count - 1].selectedIndex = index
        let track = tracks[index]
        let sourceID: String?
        if case .playlistTracks(let playlist) = currentScreen, playlist.source == track.source {
            sourceID = playlist.id
        } else {
            sourceID = nil
        }
        preparePlaybackQueue(tracks, startingWith: track, at: index, sourceID: sourceID)
        open(.nowPlaying)
    }

    /// Picking a row in 电台 jumps within the station's own queue. That queue is
    /// append-only and refilled, so it is never reshuffled or rebuilt.
    func playRadio(at index: Int) {
        guard selectedSource == .netease, radioTracks.indices.contains(index) else { return }
        navigation[navigation.count - 1].selectedIndex = index
        cancelPendingPlayback()
        queueBaseTracks = radioTracks
        queue = radioTracks
        startRadioMode()
        startPlayback(radioTracks[index], at: index, radio: true)
        open(.nowPlaying)
    }

    /// Starts the station: the radio queue becomes the playback queue and keeps
    /// growing in the background as playback approaches its end.
    private func startRadio(_ tracks: [Track]) {
        var seen = Set<String>()
        let usable = tracks.filter { $0.source == .netease && seen.insert($0.id).inserted }
        radioTracks = usable
        guard selectedSource == .netease, let first = usable.first else { return }
        cancelPendingPlayback()
        queueBaseTracks = usable
        queue = usable
        startRadioMode()
        startPlayback(first, at: 0, radio: true)
    }

    private func startRadioMode() {
        radioGeneration = UUID()
        radioRefillTask?.cancel()
        radioRefillTask = nil
        isRadioMode = true
    }

    private func initialRadioBatch() async -> Result<[Track], Error> {
        do { return .success(try await netease.personalFM()) }
        catch { return .failure(error) }
    }

    private func stopRadio() {
        isRadioMode = false
        radioGeneration = UUID()
        radioRefillTask?.cancel()
        radioRefillTask = nil
    }

    /// Tops the station up while the user is still a few tracks away from its end.
    /// A refill never interrupts playback or shows any loading or error UI.
    private func refillRadioIfNeeded() {
        guard isRadioMode, selectedSource == .netease, radioRefillTask == nil,
              let index = queueIndex, queue.indices.contains(index),
              queue.count - index <= 5 else { return }
        let generation = radioGeneration
        radioRefillTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.radioGeneration == generation { self.radioRefillTask = nil }
            }
            do {
                for _ in 0..<3 {
                    guard !Task.isCancelled, self.radioGeneration == generation,
                          self.isRadioMode, self.selectedSource == .netease,
                          let index = self.queueIndex, self.queue.indices.contains(index) else { return }
                    if self.queue.count - index >= 8 { break }
                    let batch = try await self.netease.personalFM()
                    guard !Task.isCancelled, self.radioGeneration == generation,
                          self.isRadioMode, self.selectedSource == .netease else { return }
                    var seen = Set(self.queue.map(\.id))
                    let additions = batch.filter { $0.source == .netease && seen.insert($0.id).inserted }
                    if additions.isEmpty { break }
                    self.queue.append(contentsOf: additions)
                    // 电台's list is the queue itself, so it grows with the station.
                    self.radioTracks = self.queue
                    self.refreshLikedState(for: additions)
                }
            } catch {
                // A station that cannot refill simply ends; nothing is reported.
            }
        }
    }

    private func cyclePlaybackMode() {
        setPlaybackMode(playbackMode.next)
    }

    /// The single writer for the mode setting. Every surface that reports it — the
    /// two header glyphs, the root menu's 播放模式 row, the queue builder and the
    /// advance rules — reads `playbackMode`, so one assignment keeps them agreeing.
    private func setPlaybackMode(_ mode: PlaybackMode) {
        guard mode != playbackMode else { return }
        playbackMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.playbackModeKey)
        // The station owns an append-only queue and its own refill thresholds.
        guard !isRadioMode, let currentTrack else { return }
        var tracks = queueBaseTracks.isEmpty ? queue : queueBaseTracks
        // A relaunched session may hold only a window of a huge base list; keep the
        // playing track in it so previous/next can still find it.
        if !tracks.contains(where: { $0.id == currentTrack.id && $0.source == currentTrack.source }) {
            tracks.insert(currentTrack, at: 0)
        }
        // Rebuild in place: leaving 随机播放 restores the list order the base
        // tracks were saved in, and entering it reshuffles everything but the
        // playing track. Audio is not restarted either way.
        preparePlaybackQueue(tracks, startingWith: currentTrack, startAudio: false)
    }

    private static let playbackModeKey = "playbackMode"

    /// Reads the one mode setting, migrating the two switches it replaced:
    /// 单曲循环 is more specific than 随机播放, and every other combination becomes
    /// the new default of 列表循环.
    private static func restoredPlaybackMode() -> PlaybackMode {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: playbackModeKey),
           let mode = PlaybackMode(rawValue: raw) {
            return mode
        }
        let legacy = defaults.string(forKey: "repeatMode")
        if legacy == "one" { return .repeatOne }
        if let shuffle = defaults.string(forKey: "shuffleMode"), shuffle != "off" { return .shuffle }
        return .repeatAll
    }

    private func preparePlaybackQueue(_ tracks: [Track], startingWith track: Track,
                                      at selectedIndex: Int? = nil, sourceID: String? = nil, startAudio: Bool = true) {
        if startAudio {
            consecutiveNetEaseFailures = 0
            lastHandledNetEaseFailure = nil
            cancelPendingPlayback()
            stopRadio()
        }
        let mode = playbackMode
        let selectedPosition = selectedIndex.flatMap { tracks.indices.contains($0) ? $0 : nil }
            ?? tracks.firstIndex { $0.id == track.id && $0.source == track.source }
        queueBaseTracks = tracks
        // 列表循环 and 单曲循环 both play the list in its own order; only 随机播放
        // reshuffles. The playing track stays first so shuffle starts where the
        // user tapped instead of somewhere else in the list.
        if mode == .shuffle {
            // One copy of the list, then a removal and a shuffle in place. The
            // filter/map/shuffled chain built three arrays the size of the library
            // for a single song started from 歌曲.
            var rest = tracks
            if let selectedPosition, rest.indices.contains(selectedPosition) {
                rest.remove(at: selectedPosition)
            } else if let match = rest.firstIndex(where: { $0.id == track.id && $0.source == track.source }) {
                rest.remove(at: match)
            }
            rest.shuffle()
            queue = [track] + rest
            queueIndex = 0
        } else {
            queue = tracks
            queueIndex = selectedPosition
        }
        if startAudio { startPlayback(track, at: queueIndex, sourceID: sourceID) }
        else { savePlaybackState() }
    }

    /// Split a collaboration artist string ("A / B", "A、B", "A, B", "A & B", "A feat. B") into individual names.
    /// Pure, so the boot screen can group artists off the main actor.
    nonisolated static func splitArtistNames(_ artist: String) -> [String] {
        var normalized = artist
        for separator in [" / ", "、", ", ", " & ", " feat. ", " ft. ", " featuring "] {
            normalized = normalized.replacingOccurrences(of: separator, with: "\n")
        }
        return normalized.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// True when the track's artist field lists `artist` as one of its (possibly collaborating) artists.
    private func trackHasArtist(_ track: Track, artist: String) -> Bool {
        Self.splitArtistNames(track.artist).contains(artist)
    }

    private func albumKey(_ album: String, source: AudioSource, id: String? = nil, artist: String? = nil) -> String {
        if let id, !id.isEmpty { return source.rawValue + ":album-id:" + id }
        if let artist, !artist.isEmpty { return source.rawValue + ":album:" + artist + ":" + album }
        return source.rawValue + ":album:" + album
    }

    /// Album metadata stays in memory; only loadLibrary's playlist branch calls rememberTracks.
    private func fullAlbumTracks(_ album: String, source: AudioSource, seed: Track? = nil, albumID: String? = nil,
                                 artist: String? = nil) async throws -> [Track] {
        let directAlbumID = albumID
        let resolvedSeed = seed ?? browsingCandidates.first(where: {
            $0.album == album && $0.source == source && (artist == nil || $0.artist == artist)
        })
        let key = albumKey(album, source: source, id: albumID, artist: artist ?? resolvedSeed?.artist)
        if let cached = completeAlbums[key] { return cached }
        guard resolvedSeed != nil || directAlbumID != nil else {
            throw NetEaseClient.ClientError.message("专辑加载失败，请稍后重试。")
        }
        let tracks: [Track]
        if source == .netease {
            let resolvedAlbumID: String
            if let directAlbumID {
                resolvedAlbumID = directAlbumID
            } else if let resolvedSeed {
                resolvedAlbumID = try await netease.albumIdentifier(forTrackID: resolvedSeed.id)
            } else {
                throw NetEaseClient.ClientError.message("专辑加载失败，请稍后重试。")
            }
            tracks = try await netease.albumTracks(id: resolvedAlbumID, name: album)
        } else {
            let seedForToken = resolvedSeed ?? searchResults.first(where: { $0.source == .spotify }) ?? Track(id: "0", title: album, artist: "", album: album, duration: 0, source: .spotify, spotifyURI: "spotify:track:0")
            let token = try await spotifyAlbumToken(seed: seedForToken)
            let albumID: String
            var artwork: URL? = resolvedSeed?.artworkURL
            if let directAlbumID {
                albumID = directAlbumID
            } else if let trackID = resolvedSeed?.spotifyTrackID {
                let detail = try await albumJSON(path: "/v1/tracks/" + trackID, source: source, token: token)
                guard let metadata = detail["album"] as? [String: Any], let id = metadata["id"] as? String else {
                    throw NetEaseClient.ClientError.message("专辑加载失败，请稍后重试。")
                }
                let images = metadata["images"] as? [[String: Any]] ?? []
                artwork = (images.first?["url"] as? String).flatMap(URL.init(string:)) ?? resolvedSeed?.artworkURL
                albumID = id
            } else {
                throw NetEaseClient.ClientError.message("专辑加载失败，请稍后重试。")
            }
            var pageURL: URL? = URL(string: "https://api.spotify.com/v1/albums/\(albumID)/tracks?limit=50")
            var collected: [Track] = []
            var visited = Set<URL>()
            while let url = pageURL {
                guard url.scheme == "https", url.host == "api.spotify.com", visited.insert(url).inserted else {
                    throw NetEaseClient.ClientError.message("专辑加载失败，请稍后重试。")
                }
                let page = try await albumJSON(path: url.path, source: source, token: token, pageURL: url)
                guard let items = page["items"] as? [[String: Any]] else { throw NetEaseClient.ClientError.message("专辑加载失败，请稍后重试。") }
                for item in items {
                    guard let id = item["id"] as? String, let title = item["name"] as? String,
                          let duration = item["duration_ms"] as? NSNumber,
                          let uri = item["uri"] as? String else { throw NetEaseClient.ClientError.message("专辑加载失败，请稍后重试。") }
                    let artists = item["artists"] as? [[String: Any]] ?? []
                    collected.append(Track(id: id, title: title,
                        artist: artists.compactMap { $0["name"] as? String }.joined(separator: " / "),
                        album: album, duration: duration.doubleValue / 1000, source: source,
                        spotifyURI: uri, artworkURL: artwork))
                }
                pageURL = (page["next"] as? String).flatMap(URL.init(string:))
            }
            tracks = collected
        }
        try Task.checkCancellation()
        guard source == selectedSource, !tracks.isEmpty else {
            throw NetEaseClient.ClientError.message("专辑加载失败，请稍后重试。")
        }
        completeAlbums[key] = tracks
        return tracks
    }

    private struct AlbumCredentials: Decodable {
        let accessToken: String
        let expiresAt: Date
        let clientID: String
        let redirectURI: String
    }

    private func spotifyAlbumToken(seed: Track) async throws -> String {
        func credentials() throws -> AlbumCredentials {
            guard spotify.isLoggedIn, let data = try TokenKeychain.read() else { throw NetEaseClient.ClientError.message("请在设置中登录 Spotify") }
            let saved = try JSONDecoder().decode(AlbumCredentials.self, from: data)
            guard saved.clientID == (UserDefaults.standard.string(forKey: "spotifyClientID") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                  saved.redirectURI == (UserDefaults.standard.string(forKey: "spotifyRedirectURI") ?? "ipodplayer://spotify-login-callback").trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw NetEaseClient.ClientError.message("请在设置中登录 Spotify")
            }
            return saved
        }
        var saved = try credentials()
        if saved.expiresAt.timeIntervalSinceNow <= 60 {
            // Refresh through the token flow instead of a fake search.
            _ = try await spotify.refreshAccessToken()
            saved = try credentials()
        }
        return saved.accessToken
    }

    private func albumJSON(path: String, parameters: [String: String] = [:], source: AudioSource,
                           token: String? = nil, pageURL: URL? = nil) async throws -> [String: Any] {
        let address = configuredNetEaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: source == .netease ? address : "https://api.spotify.com"),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw NetEaseClient.ClientError.message("服务地址无效。")
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = (components.path.isEmpty ? "" : "/" + components.path) + path
        if !parameters.isEmpty { components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = pageURL ?? components.url else { throw NetEaseClient.ClientError.message("专辑加载失败，请稍后重试。") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        if source == .netease {
            if let cookie = try NetEaseCookieKeychain.read(), !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        } else if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await Self.sharedAlbumSession.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetEaseClient.ClientError.message("专辑加载失败，请稍后重试。")
        }
        if let code = body["code"] as? Int, code != 200 {
            throw NetEaseClient.ClientError.message("专辑加载失败，请稍后重试。")
        }
        return body
    }

    private func loadLibrary(_ screen: AppScreen) {
        cancelLibraryLoad()
        // Once a screen loads these rows itself, a boot-screen walk that finishes
        // later must not publish pages on top of the fresher answer (or the other
        // way round). The screen owns the list from here.
        if screen == .playlists || screen == .podcasts {
            libraryScreensPrewarmTask?.cancel()
        }
        let generation = browseGeneration
        let source = selectedSource
        browseMessages[screen] = nil
        if screen == .radio {
            // Every visit starts a new station; the previous queue is not resumed.
            radioTracks = []
            isRadioLoading = true
            radioLoadingError = nil
        }
        // A list whose answer cannot have changed yet keeps the rows it already
        // holds. Re-walking the same pages made every re-entry look like a reload.
        if isFreshEnough(screen), let existing = libraryTracks[screen], !existing.isEmpty {
            refreshLikedState(for: existing)
            return
        }
        // The previous list stays on screen while its refresh runs; it is replaced
        // page by page, like 歌单.
        if case .playlistTracks(let playlist) = screen, playlist.source == source {
            libraryTracks[screen] = localLibrary.tracks(in: playlist)
            refreshLikedState(for: libraryTracks[screen] ?? [])
        } else if case .artistTracks(_, let artist) = screen {
            let localMatches = localTracks(byArtist: artist)
            libraryTracks[screen] = localMatches.isEmpty ? nil : localMatches
            if !localMatches.isEmpty { refreshLikedState(for: localMatches) }
        } else if let cached = cachedScreenList(for: screen, source: source) {
            // Daily recommendations are the same list for a whole day. Open with
            // the stored copy and let the refresh replace it.
            libraryTracks[screen] = cached
            refreshLikedStateAfterLayout(for: cached)
        } else if let existing = libraryTracks[screen], !existing.isEmpty {
            // A list opened earlier this session stays on screen while its refresh
            // runs. Clearing it here is what made 每日推荐 blank out and re-download
            // on every visit: the file copy is skipped once the session holds one.
            refreshLikedStateAfterLayout(for: existing)
        } else {
            libraryTracks[screen] = nil
        }
        // A toggle after this refresh starts must still invalidate its older snapshot.
        if screen == .songs { likedSongsNeedsRefresh = false }
        browseLoadingScreen = screen
        browseTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tracks: [Track]
                switch screen {
                case .dailyRecommendations:
                    guard source == .netease else { throw CancellationError() }
                    tracks = try await self.netease.dailyRecommendations()
                case .radio:
                    guard source == .netease else { throw CancellationError() }
                    // Two independent batches give the station a usable runway
                    // instead of one song and a refill request per track.
                    async let firstBatch = self.initialRadioBatch()
                    async let secondBatch = self.initialRadioBatch()
                    let batches = await (firstBatch, secondBatch)
                    switch batches {
                    case (.success(let first), .success(let second)):
                        tracks = first + second
                    case (.success(let batch), .failure(_)), (.failure(_), .success(let batch)):
                        tracks = batch
                    case (.failure(let error), .failure(_)):
                        throw error
                    }
                case .songs:
                    if source == .netease { tracks = try await self.freshNetEaseLikedTracks() }
                    else { tracks = try await self.spotify.likedTracks() }
                case .playlists:
                    let playlists: [MusicPlaylist]
                    let cachedPlaylists = self.sourcePlaylists
                    let publishPlaylists: @MainActor ([MusicPlaylist]) -> Void = { partial in
                        guard !Task.isCancelled, self.browseGeneration == generation,
                              self.selectedSource == source else { return }
                        let fresh = partial.filter { $0.source == source }
                        let ids = Set(fresh.map(\.id))
                        self.sourcePlaylists = fresh + cachedPlaylists.filter { $0.source == source && !ids.contains($0.id) }
                    }
                    if source == .netease { playlists = try await self.netease.playlists(onProgress: publishPlaylists) }
                    else { playlists = try await self.spotify.playlists(onProgress: publishPlaylists) }
                    guard !Task.isCancelled, self.browseGeneration == generation,
                          self.selectedSource == source else { return }
                    self.sourcePlaylists = playlists.filter { $0.source == source }
                    self.screenListCache.store(playlists: self.sourcePlaylists, for: source,
                                               account: self.accountTag(for: source))
                    self.pruneLocalIndex(self.sourcePlaylists, source: source)
                    self.browseLoadingScreen = nil
                    return
                case .podcasts:
                    guard source == .netease else {
                        throw NetEaseClient.ClientError.message("播客只支持网易云音源，请先在设置 → 音源中切换。")
                    }
                    self.podcastShows = try await self.netease.podcastShows()
                    self.browseLoadingScreen = nil
                    return
                case .podcastEpisodes(let showID, _):
                    guard source == .netease else { throw CancellationError() }
                    // A long show is walked page by page, and a deep page can be
                    // refused. Publishing each page as it lands means the list opens
                    // on the newest episodes instead of staying empty until the end.
                    let cachedEpisodes = self.libraryTracks[screen] ?? []
                    let publishEpisodes: @MainActor ([Track]) -> Void = { partial in
                        guard !Task.isCancelled, self.browseGeneration == generation,
                              self.selectedSource == source else { return }
                        let fresh = partial.filter { $0.source == source }
                        let ids = Set(fresh.map(\.id))
                        self.libraryTracks[screen] = fresh + cachedEpisodes.filter { !ids.contains($0.id) }
                    }
                    tracks = try await self.netease.podcastEpisodes(showID: showID,
                                                                   onProgress: publishEpisodes)
                case .playlistTracks(let playlist):
                    guard playlist.source == source else { throw CancellationError() }
                    let cachedTracks = self.libraryTracks[screen] ?? []
                    let publishTracks: @MainActor ([Track]) -> Void = { partial in
                        guard !Task.isCancelled, self.browseGeneration == generation,
                              self.selectedSource == source else { return }
                        let fresh = partial.filter { $0.source == source }
                        let ids = Set(fresh.map(\.id))
                        // Keep cached rows visible until the complete refresh can
                        // replace the snapshot, including rows beyond page one.
                        self.libraryTracks[screen] = fresh + cachedTracks.filter { !ids.contains($0.id) }
                        self.refreshLikedState(for: fresh)
                    }
                    if source == .netease { tracks = try await self.netease.playlistTracks(playlist, onProgress: publishTracks) }
                    else { tracks = try await self.spotify.playlistTracks(playlist, onProgress: publishTracks) }
                case .artistTracks(let screenArtistID, let artist):
                    let artistID = screenArtistID
                    let localMatches = self.localTracks(byArtist: artist)
                    let publishArtist: @MainActor ([Track]) -> Void = { remote in
                        guard !Task.isCancelled, self.browseGeneration == generation,
                              self.selectedSource == source else { return }
                        let combined = self.artistTracksInSourceOrder(remote: remote, local: localMatches, source: source)
                        guard !combined.isEmpty else { return }
                        self.libraryTracks[screen] = combined
                        self.refreshLikedState(for: combined)
                    }
                    let remoteTracks: [Track]
                    if source == .netease {
                        remoteTracks = try await self.netease.artistTracks(name: artist, artistID: artistID, onProgress: publishArtist)
                    } else {
                        remoteTracks = try await self.spotify.artistTracks(name: artist, artistID: artistID)
                    }
                    let combined = self.artistTracksInSourceOrder(remote: remoteTracks, local: localMatches, source: source)
                    tracks = combined.isEmpty ? self.browsingCandidates.filter { self.trackHasArtist($0, artist: artist) } : combined
                case .albumTracks(let albumID, let album, let artist):
                    tracks = try await self.fullAlbumTracks(album, source: source, albumID: albumID, artist: artist)
                default: return
                }
                guard !Task.isCancelled, self.browseGeneration == generation,
                      self.selectedSource == source else { return }
                if screen == .songs && self.likedSongsNeedsRefresh {
                    self.loadLibrary(.songs)
                    return
                }
                if screen == .songs, source == .netease {
                    let ids = Set(tracks.map(\.id))
                    self.likedSongChanges = self.likedSongChanges.filter { ids.contains($0.key) != $0.value }
                }
                if case .playlistTracks(let playlist) = screen, playlist.source == source {
                    self.rememberTracks(tracks.filter { $0.source == source }, playlist: playlist)
                }
                let sourceTracks = tracks.filter { $0.source == source }
                if screen == .songs {
                    // 歌曲 is the liked list itself; publishing it also rebuilds the
                    // artist and album rows derived from it.
                    self.storeLikedSongs(sourceTracks, source: source)
                } else if screen == .radio {
                    // The list is the station's queue, so publishing it is also what
                    // starts the music: 电台 is entered to hear something new.
                    self.isRadioLoading = false
                    // MENU during loading has already left the station; starting a
                    // queue then would hijack whatever the user picked next.
                    if self.navigation.contains(where: { $0.screen == .radio }) {
                        self.startRadio(sourceTracks)
                    } else {
                        self.radioTracks = sourceTracks
                    }
                } else {
                    self.libraryTracks[screen] = sourceTracks
                    // This answer is now the screen's contents; a re-entry inside its
                    // window reuses it instead of asking the server again.
                    self.libraryRefreshedAt[screen] = Date()
                }
                // Store the screens whose next open should already have rows.
                switch screen {
                case .dailyRecommendations:
                    self.screenListCache.store(sourceTracks, for: screen,
                                               source: source, account: self.accountTag(for: source))
                case .playlists:
                    break
                default:
                    break
                }
                let published = screen == .radio ? self.radioTracks : (self.libraryTracks[screen] ?? [])
                if screen == .songs {
                    // These rows are liked by definition; confirming them would cost a
                    // membership query this screen does not need.
                    self.markLikedRows(sourceTracks, source: source)
                } else {
                    self.refreshLikedState(for: published)
                }
                // A cached row may already have opened Now Playing; finish the refresh
                // for its retained frame without changing the playback queue or stack.
                if let frameIndex = self.navigation.lastIndex(where: { $0.screen == screen }) {
                    let count = screen == .songs || screen == .radio ? published.count
                        : (self.libraryTracks[screen]?.count ?? 0)
                    self.navigation[frameIndex].selectedIndex = min(self.navigation[frameIndex].selectedIndex,
                                                                  max(0, count - 1))
                }
                self.browseLoadingScreen = nil
                // The read went through: a later refusal on this screen may retry again.
                self.silentScreenRetryAttempts[screen] = nil
            } catch {
                guard !Task.isCancelled, self.browseGeneration == generation,
                      self.selectedSource == source else { return }
                if case .artistTracks(_, let artist) = screen {
                    let fallback = self.browsingCandidates.filter { $0.source == source && self.trackHasArtist($0, artist: artist) }
                    self.libraryTracks[screen] = fallback
                    if fallback.isEmpty, !Self.isRiskRefusal(error) {
                        self.browseMessages[screen] = L10n.error(error.localizedDescription)
                    }
                } else {
                    // A refused read is a short window about the caller. The rows the
                    // screen already has stay on it, and the same read is asked for
                    // again quietly instead of showing an error nobody can act on.
                    if !Self.isRiskRefusal(error) {
                        self.browseMessages[screen] = L10n.error(error.localizedDescription)
                    }
                    if case .albumTracks(_, let album, let artist) = screen {
                        self.libraryTracks[screen] = self.browsingCandidates.filter {
                            $0.source == source && $0.album == album && (artist == nil || $0.artist == artist)
                        }
                    }
                }
                if Self.isRiskRefusal(error) { self.scheduleSilentRiskReload(screen, source: source) }
                self.browseLoadingScreen = nil
                if screen == .radio {
                    self.isRadioLoading = false
                    if !Self.isRiskRefusal(error) {
                        self.radioLoadingError = L10n.error(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// A -460 is a window, not a verdict on the account: the same read succeeds once it
    /// lifts. Callers use this to stay quiet instead of surfacing an error.
    private static func isRiskRefusal(_ error: Error) -> Bool {
        if case NetEaseClient.ClientError.riskControl = error { return true }
        return false
    }

    /// Asks for the same screen again after the window, twice at most. The screen keeps
    /// whatever rows it already had, so the only visible effect is the list filling in.
    private func scheduleSilentRiskReload(_ screen: AppScreen, source: AudioSource) {
        let attempt = (silentScreenRetryAttempts[screen] ?? 0)
        guard attempt < 2 else { return }
        silentScreenRetryAttempts[screen] = attempt + 1
        let generation = browseGeneration
        let delay: TimeInterval = attempt == 0 ? 6 : 15
        Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, !Task.isCancelled,
                  self.browseGeneration == generation,
                  self.selectedSource == source,
                  self.currentScreen == screen else { return }
            self.loadLibrary(screen)
        }
    }

    private func cancelLibraryLoad() {
        if browseLoadingScreen == .radio { isRadioLoading = false }
        browseTask?.cancel()
        browseTask = nil
        browseGeneration = UUID()
        browseLoadingScreen = nil
    }

    private func freshNetEaseLikedTracks() async throws -> [Track] {
        let changes = likedSongChanges
        var tracks = try await netease.likedTracks()
        let ids = Set(tracks.map(\.id))
        if changes.contains(where: { ids.contains($0.key) != $0.value }) {
            try await Task.sleep(for: .milliseconds(400))
            try Task.checkCancellation()
            tracks = try await netease.likedTracks()
        }
        return tracks
    }

    private func resetLibrary(clearingCaches: Bool = false) {
        // A boot-screen walk that lands after this would restore the rows that
        // this reset is removing.
        libraryScreensPrewarmTask?.cancel()
        completeAlbums = [:]
        queueBaseTracks = []
        cancelLibraryLoad()
        stopRadio()
        radioTracks = []
        isRadioLoading = false
        radioLoadingError = nil
        podcastShows = []
        libraryTracks = [:]
        libraryRefreshedAt = [:]
        sourcePlaylists = []
        browseMessages = [:]
        // Rows are gone, so the index derived from them is too. Keeping it would
        // serve the previous account's artists and albums while the next one loads.
        discardBrowsingIndex()
        // Another account's rows must never be shown from the disk cache. A plain
        // source switch keeps it: those lists belong to the other source anyway.
        if clearingCaches { screenListCache.removeAll() }
    }

    private func rememberTracks(_ tracks: [Track], playlist: MusicPlaylist) {
        // This only caches rows so a playlist reopens with content. The library
        // index is built from the liked list, never from playlist membership.
        localLibrary.remember(tracks, playlist: playlist)
    }

    /// How long a stored screen list is worth showing before its refresh. Daily
    /// recommendations only change at midnight.
    private func cachedScreenList(for screen: AppScreen, source: AudioSource) -> [Track]? {
        let maxAge: TimeInterval
        switch screen {
        // Elapsed time since midnight, so a copy written yesterday is rejected as
        // soon as the day changes instead of surviving another full day.
        case .dailyRecommendations: maxAge = Self.secondsSinceStartOfDay()
        default: return nil
        }
        // A screen that already holds this session's result is newer than any file.
        if let existing = libraryTracks[screen], !existing.isEmpty { return nil }
        return screenListCache.tracks(for: screen, source: source,
                                      account: accountTag(for: source), maxAge: maxAge)
    }

    /// True while a screen's rows are still the answer the server would give, so a
    /// re-entry can use them without a request. Screens that produce a fresh answer
    /// every visit (radio) and screens whose rows are partial (artist/album) are not
    /// listed: their fetch is what completes them.
    private func isFreshEnough(_ screen: AppScreen) -> Bool {
        guard let refreshedAt = libraryRefreshedAt[screen] else { return false }
        switch screen {
        case .dailyRecommendations:
            // The list changes at midnight and nowhere else.
            return Calendar.current.isDate(refreshedAt, inSameDayAs: Date())
        case .playlistTracks, .podcastEpisodes:
            return Date().timeIntervalSince(refreshedAt) < Self.listRefreshWindow
        default:
            return false
        }
    }

    private static func secondsSinceStartOfDay() -> TimeInterval {
        max(60, Date().timeIntervalSince(Calendar.current.startOfDay(for: Date())))
    }

    /// Account marker for the on-disk liked list. NetEase exposes a user id only
    /// after login; a nil marker accepts and rewrites the entry.
    private func accountTag(for source: AudioSource) -> String? {
        switch source {
        case .netease: return netease.userID
        case .spotify: return UserDefaults.standard.string(forKey: "spotifyClientID")
        }
    }

    private func rememberLikedSongs(_ tracks: [Track], source: AudioSource) {
        // A refresh that came back empty is far more likely to be a transient
        // failure than a library the user emptied; the cache keeps its rows.
        guard !tracks.isEmpty else { return }
        storeLikedSongs(tracks, source: source)
    }

    /// Writes the liked list to memory and disk. Unlike `rememberLikedSongs` this
    /// accepts an empty result, because a completed 歌曲 refresh is authoritative.
    private func storeLikedSongs(_ tracks: [Track], source: AudioSource) {
        let filtered = tracks.filter { $0.source == source }
        cachedLikedSongs[source] = filtered
        if filtered.isEmpty {
            likedSongsCache.remove(source)
        } else {
            likedSongsCache.store(filtered, for: source, account: accountTag(for: source))
        }
        refreshLikedLibrary()
    }

    /// Publishes the active source's liked rows as the library the browsing index
    /// is built from. 歌曲/歌手/专辑 therefore all describe the liked collection,
    /// exactly like an iPod's own library.
    private func refreshLikedLibrary() {
        let source = selectedSource
        localLibraryTracks = (cachedLikedSongs[source] ?? []).filter { $0.source == source }
    }

    /// Applies one successful heart press locally so the song joins 歌曲 (and its
    /// artist/album rows) immediately, without waiting for the next list refresh.
    private func applyLikedChange(track: Track, isLiked: Bool) {
        let source = track.source
        let key = { (candidate: Track) in candidate.source.rawValue + ":" + (candidate.spotifyTrackID ?? candidate.id) }
        var liked = cachedLikedSongs[source] ?? []
        liked.removeAll { key($0) == key(track) }
        if isLiked { liked.insert(track, at: 0) }
        storeLikedSongs(liked, source: source)
    }

    /// The liked list used to be re-read from the server on every visit, which on
    /// NetEase meant a full playlist walk. The boot screen now warms it once so the
    /// first visit already has rows, and later visits only need a membership check.
    private func prewarmLikedSongs() {
        guard likedPrewarmTask == nil else { return }
        let source = selectedSource
        likedPrewarmTask = Task { [weak self] in
            guard let self else { return }
            defer { self.likedPrewarmTask = nil }
            if source == .netease, let status = self.neteaseStatusTask {
                // Waiting for the restored session avoids a guaranteed loginRequired.
                await status.value
            }
            guard !Task.isCancelled else { return }
            do {
                let tracks: [Track]
                if source == .netease { tracks = try await self.netease.likedTracks() }
                else { tracks = try await self.spotify.likedTracks() }
                guard !Task.isCancelled, !tracks.isEmpty else { return }
                self.rememberLikedSongs(tracks, source: source)
            } catch {
                // The first visit retries through the normal path and its error UI.
            }
        }
    }

    /// Starts the network walks for the two lists that sit one screen away from
    /// the root: 歌单 and 播客. Both open with their own refresh anyway, so
    /// starting them here does not make launch longer — it only moves the wait
    /// behind the boot screen and leaves the rows ready when the list is opened.
    private func prewarmLibraryScreens() {
        guard libraryScreensPrewarmTask == nil else { return }
        libraryScreensPrewarmTask = Task { [weak self] in
            guard let self else { return }
            defer { self.libraryScreensPrewarmTask = nil }
            // One small server: the liked list goes first, because 歌曲 is the
            // list a session is most likely to open, and two walks at once made
            // both look stalled.
            if let liked = self.likedPrewarmTask { await liked.value }
            guard !Task.isCancelled else { return }
            await self.prewarmPlaylists()
            guard !Task.isCancelled else { return }
            await self.prewarmPodcastShows()
        }
    }

    /// The same walk 歌单 performs on first open, with no screen state to
    /// drive. Partial pages are published so a large library fills in the same
    /// way it does when the screen itself is loading it.
    private func prewarmPlaylists() async {
        let source = selectedSource
        let account = accountTag(for: source)
        let cached = sourcePlaylists
        let publish: @MainActor ([MusicPlaylist]) -> Void = { [weak self] partial in
            guard let self, !Task.isCancelled, self.selectedSource == source,
                  self.accountTag(for: source) == account,
                  // The screen's own load owns the list while it is running.
                  self.browseLoadingScreen != .playlists else { return }
            let fresh = partial.filter { $0.source == source }
            let ids = Set(fresh.map(\.id))
            self.sourcePlaylists = fresh + cached.filter { $0.source == source && !ids.contains($0.id) }
        }
        do {
            let playlists: [MusicPlaylist]
            if source == .netease { playlists = try await netease.playlists(onProgress: publish) }
            else { playlists = try await spotify.playlists(onProgress: publish) }
            guard !Task.isCancelled, selectedSource == source,
                  accountTag(for: source) == account,
                  browseLoadingScreen != .playlists else { return }
            sourcePlaylists = playlists.filter { $0.source == source }
            screenListCache.store(playlists: sourcePlaylists, for: source, account: account)
            pruneLocalIndex(sourcePlaylists, source: source)
        } catch {
            // Not logged in yet, or the server is down: opening the screen
            // retries through the normal path and shows the error there.
        }
    }

    /// 播客 has no disk cache, so this is the only thing that keeps its first
    /// open from being a spinner.
    private func prewarmPodcastShows() async {
        guard selectedSource == .netease else { return }
        let account = accountTag(for: .netease)
        do {
            let shows = try await netease.podcastShows()
            guard !Task.isCancelled, selectedSource == .netease,
                  accountTag(for: .netease) == account,
                  browseLoadingScreen != .podcasts else { return }
            podcastShows = shows
        } catch {
            // The screen's own load reports the failure.
        }
    }

    /// The first artwork this session will draw: the restored cover in Now
    /// Playing, the covers of the next queue entries Cover Flow pages through,
    /// and the top of 歌曲. Each one used to be fetched the first time its row
    /// appeared, which is exactly when a wheel step is supposed to feel instant.
    private func prewarmArtworkForFirstScreens() {
        var urls: [URL] = []
        if let artworkURL = currentTrack?.artworkURL { urls.append(artworkURL) }
        urls.append(contentsOf: queue.prefix(6).compactMap(\.artworkURL))
        urls.append(contentsOf: songs.prefix(6).compactMap(\.artworkURL))
        guard !urls.isEmpty else { return }
        // Downloads and decodes run off the main actor inside the loader; only
        // the finished images are handed back, so this never delays the lift.
        Task { await CachedImageLoader.shared.prefetch(urls) }
    }

    /// A complete playlist list proves which playlists still exist, so cached rows
    /// of deleted or unfollowed playlists can go. It never touches 歌曲, which is
    /// the liked list and therefore unaffected by playlist membership.
    private func pruneLocalIndex(_ playlists: [MusicPlaylist], source: AudioSource) {
        let ids = Set(playlists.filter { $0.source == source }.map(\.id))
        localLibrary.retainPlaylists(ids, source: source)
    }

    /// Logout must not leave the previous account's library behind.
    private func clearLocalIndex(_ source: AudioSource) {
        localLibrary.removeSource(source)
        cachedLikedSongs[source] = nil
        localLibraryTracks = []
        discardBrowsingIndex()
    }

    /// Remote catalogue order first, then local songs that the source did not return.
    private func artistTracksInSourceOrder(remote: [Track], local: [Track], source: AudioSource) -> [Track] {
        var seen = Set<String>()
        func accept(_ track: Track) -> Bool {
            track.source == source && seen.insert(track.spotifyTrackID ?? track.id).inserted
        }
        return remote.filter(accept) + local.filter(accept)
    }

    func trackLikeID(for track: Track) -> String? {
        // A podcast episode's id names DJ audio, not a song, so it has no heart.
        if track.isPodcastEpisode { return nil }
        if track.source == .netease { return track.id.isEmpty ? nil : track.id }
        return track.spotifyTrackID
    }

    func isLiked(_ track: Track) -> Bool {
        guard let id = trackLikeID(for: track) else { return false }
        return track.source == .netease ? likedNetEaseTrackIDs.contains(id) : likedSpotifyTrackIDs.contains(id)
    }

    private func setLiked(_ liked: Bool, trackID: String, source: AudioSource) {
        if source == .netease {
            if liked { likedNetEaseTrackIDs.insert(trackID) }
            else { likedNetEaseTrackIDs.remove(trackID) }
        } else {
            if liked { likedSpotifyTrackIDs.insert(trackID) }
            else { likedSpotifyTrackIDs.remove(trackID) }
        }
    }

    private var likeTargetTrack: Track? {
        if currentScreen == .nowPlaying { return currentTrack }
        if currentScreen == .search {
            return searchResults.indices.contains(selectedIndex) ? searchResults[selectedIndex] : nil
        }
        if currentScreen.isTrackList {
            let tracks = browseTracks
            return tracks.indices.contains(selectedIndex) ? tracks[selectedIndex] : nil
        }
        return nil
    }

    var canToggleTrackLike: Bool { likeTargetTrack.flatMap { trackLikeID(for: $0) } != nil }

    /// Every row in 我喜欢的音乐 is liked by definition, so the screen marks its
    /// hearts directly instead of spending a membership query (and, on NetEase, a
    /// waiting playlist walk) just to confirm what the list already proves.
    private func markLikedRows(_ tracks: [Track], source: AudioSource) {
        let ids = Set(tracks.filter { $0.source == source }.compactMap { trackLikeID(for: $0) })
        guard !ids.isEmpty else { return }
        let pending = ids.filter { !pendingLikeToggles.contains(source.rawValue + ":" + $0) }
        applyLikedBatch(gained: Set(pending), lost: [], source: source)
    }

    private func refreshLikedState(for tracks: [Track]) {
        let source = selectedSource
        let candidates = Set(tracks.filter { $0.source == source }.compactMap { trackLikeID(for: $0) })
            .filter { !pendingLikeToggles.contains(source.rawValue + ":" + $0) }
        let ids = candidates.filter { likedChecksInFlight[source.rawValue + ":" + $0] == nil }
        guard !ids.isEmpty else { return }
        let generation = likeGeneration
        let checkToken = UUID()
        for id in ids {
            let key = source.rawValue + ":" + id
            likedCheckTokens[key] = checkToken
            likedChecksInFlight[key] = checkToken
        }
        // A recheck keeps the last confirmed hearts on screen; unknown and failed checks
        // stay grey and never alert.
        Task { [weak self] in
            guard let self else { return }
            defer {
                for id in ids {
                    let key = source.rawValue + ":" + id
                    if self.likedChecksInFlight[key] == checkToken { self.likedChecksInFlight[key] = nil }
                }
            }
            do {
                let liked: Set<String>
                // Membership only: sorting the whole id set here cost a pass over
                // thousands of strings on the main actor for nothing.
                if source == .netease { liked = try await self.netease.likedTrackIDs(Array(ids)) }
                else { liked = try await self.spotify.likedTrackIDs(Array(ids)) }
                guard self.likeGeneration == generation else { return }
                var gained = Set<String>()
                var lost = Set<String>()
                for id in ids {
                    let key = source.rawValue + ":" + id
                    guard self.likedCheckTokens[key] == checkToken, !self.pendingLikeToggles.contains(key) else { continue }
                    if liked.contains(id) { gained.insert(id) } else { lost.insert(id) }
                    self.likedCheckTokens[key] = nil
                }
                self.applyLikedBatch(gained: gained, lost: lost, source: source)
            } catch {
                // Keep failed checks grey and pending so a hold retries membership first.
            }
        }
    }

    /// Applies a whole membership check at once. Writing each track through
    /// `setLiked` would publish once per song, which repaints every list row.
    private func applyLikedBatch(gained: Set<String>, lost: Set<String>, source: AudioSource) {
        guard !gained.isEmpty || !lost.isEmpty else { return }
        if source == .netease {
            var updated = likedNetEaseTrackIDs
            updated.formUnion(gained)
            updated.subtract(lost)
            guard updated != likedNetEaseTrackIDs else { return }
            likedNetEaseTrackIDs = updated
        } else {
            var updated = likedSpotifyTrackIDs
            updated.formUnion(gained)
            updated.subtract(lost)
            guard updated != likedSpotifyTrackIDs else { return }
            likedSpotifyTrackIDs = updated
        }
    }

    /// Called only by a centre hold. A regular centre tap retains confirmSelection().
    @discardableResult
    func toggleSelectedTrackLike() -> Bool {
        guard let track = likeTargetTrack, let id = trackLikeID(for: track) else { return false }
        let source = track.source
        let key = source.rawValue + ":" + id
        guard !pendingLikeToggles.contains(key) else { return false }
        let generation = likeGeneration
        let needsCheck = likedCheckTokens[key] != nil
        let previouslyLiked = isLiked(track)
        pendingLikeToggles.insert(key)
        likedCheckTokens[key] = nil
        likeStatus = nil
        if !needsCheck, source == .netease { setLiked(!previouslyLiked, trackID: id, source: source) }
        Task { [weak self] in
            guard let self, self.likeGeneration == generation else { return }
            var wasLiked = previouslyLiked
            do {
                if needsCheck {
                    // A hold can arrive before the membership check completes.
                    if source == .netease {
                        let liked = try await self.netease.likedTrackIDs([id])
                        wasLiked = liked.contains(id)
                    } else {
                        wasLiked = try await self.spotify.isLiked(trackID: id)
                    }
                    guard self.likeGeneration == generation else { return }
                    self.setLiked(source == .netease ? !wasLiked : wasLiked, trackID: id, source: source)
                }
                if source == .netease {
                    if wasLiked { try await self.netease.unlike(track: track) }
                    else { try await self.netease.like(track: track) }
                } else {
                    if wasLiked { try await self.spotify.unlike(track: track) }
                    else { try await self.spotify.like(track: track) }
                }
                guard self.likeGeneration == generation else { return }
                if source == .spotify {
                    // The service merges successful playlist writes with official
                    // Liked Songs, so the heart also reflects the intended write path.
                    let mergedLiked = try await self.spotify.isLiked(trackID: id)
                    guard self.likeGeneration == generation else { return }
                    self.setLiked(mergedLiked, trackID: id, source: source)
                    self.likeStatus = mergedLiked ? "已喜欢" : "已取消喜欢"
                    if mergedLiked != wasLiked {
                        self.likeAnimation = LikeAnimationEvent(trackID: id, isLiked: mergedLiked)
                    }
                } else {
                    self.likeStatus = wasLiked ? "已取消喜欢" : "已喜欢"
                    self.likeAnimation = LikeAnimationEvent(trackID: id, isLiked: !wasLiked)
                }
                self.pendingLikeToggles.remove(key)
                self.likedSongsNeedsRefresh = true
                if source == .netease { self.likedSongChanges[id] = !wasLiked }
                // A heart press is an import into the library: the row shows up in
                // 歌曲/歌手/专辑 right away instead of on the next refresh.
                let nowLiked = source == .spotify ? self.isLiked(track) : !wasLiked
                self.applyLikedChange(track: track, isLiked: nowLiked)
                if self.currentScreen == .songs { self.loadLibrary(.songs) }
            } catch {
                guard self.likeGeneration == generation else { return }
                self.pendingLikeToggles.remove(key)
                self.setLiked(source == .spotify ? false : wasLiked, trackID: id, source: source)
                // A failed membership read leaves its state unknown; the next
                // hold must check before toggling.
                if needsCheck || source == .spotify { self.likedCheckTokens[key] = UUID() }
                self.alertMessage = error.localizedDescription
            }
        }
        return true
    }

    private func resetLikedState() {
        likeGeneration = UUID()
        likedCheckTokens = [:]
        likedChecksInFlight = [:]
        pendingLikeToggles = []
        likedSpotifyTrackIDs = []
        likedNetEaseTrackIDs = []
        likedSongsNeedsRefresh = false
        likedSongChanges = [:]
        likeStatus = nil
        likeAnimation = nil
    }

    @discardableResult
    func handleWheelRotation(by direction: Int) -> Bool {
        if currentScreen == .nowPlaying {
            guard direction != 0 else { return false }
            adjustVolume(by: direction > 0 ? 0.01 : -0.01)
            HapticEngine.shared.tick()
            // Feedback is handled here; returning false keeps volume steps free of click sounds.
            return false
        }
        return moveSelection(by: direction)
    }

    func adjustVolume(by delta: Float) {
        guard currentScreen == .nowPlaying, delta.isFinite else { return }
        let target = volumeController.adjustVolume(by: delta)
        showVolumeBar(target)
    }

    private func showVolumeBar(_ level: Float) {
        volumeBarTask?.cancel()
        let generation = UUID()
        volumeBarGeneration = generation
        volumeLevel = level
        isVolumeBarVisible = true
        volumeBarTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) }
            catch { return }
            guard !Task.isCancelled, let self,
                  self.volumeBarGeneration == generation else { return }
            self.isVolumeBarVisible = false
            self.volumeBarTask = nil
        }
    }

    func seekBy(seconds: Double) {
        guard let track = currentTrack, durationSeconds.isFinite, durationSeconds > 0,
              elapsedSeconds.isFinite, seconds.isFinite, seconds != 0 else { return }
        let target = min(durationSeconds, max(0, elapsedSeconds + seconds))
        lastWheelSeek = (track.source, track.id, ProcessInfo.processInfo.systemUptime)
        if !restoredPlaybackNeedsStart {
            if track.source == .netease {
                streamingPlayer.seek(to: target)
            } else {
                spotify.seek(toPosition: Int(target * 1000))
            }
        }
        elapsedSeconds = target
        savePlaybackState()
        let minutes = Int(target) / 60
        let remainder = Int(target) % 60
        let position = String(format: "%d:%02d", minutes, remainder)
        showWheelStatus(seconds > 0 ? "快进至 \(position)" : "快退 \(position)")
    }

    private var hasRecentWheelSeek: Bool {
        guard let track = currentTrack, let seek = lastWheelSeek else { return false }
        return seek.source == track.source && seek.trackID == track.id
            && ProcessInfo.processInfo.systemUptime - seek.timestamp < 0.3
    }

    private func showWheelStatus(_ status: String) {
        wheelStatusTask?.cancel()
        let generation = UUID()
        wheelStatusGeneration = generation
        wheelStatus = status
        wheelStatusTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) }
            catch { return }
            guard !Task.isCancelled, let self,
                  self.wheelStatusGeneration == generation else { return }
            self.wheelStatus = nil
            self.wheelStatusTask = nil
        }
    }

    func togglePlayPause() {
        guard let track = currentTrack else {
            alertMessage = selectedSource == .spotify && !spotify.isLoggedIn
                ? "请先前往“设置”登录 Spotify，再搜索或播放歌曲。"
                : nil
            return
        }
        if track.source == .spotify && !spotify.isLoggedIn {
            alertMessage = "Spotify 登录已失效，请在设置中重新登录后恢复播放。"
            return
        }
        if restoredPlaybackNeedsStart {
            startPlayback(track, at: queueIndex, position: elapsedSeconds)
            return
        }
        if isPlaying && (playbackCommandPending
            || (preservesPlayingDuringTrackChange && track.source == .spotify
                && spotify.currentURI != track.spotifyURI)) {
            // Stop a resolving track request before it can start audio after this pause.
            cancelPendingPlayback()
            // A pending silent recovery is a retry of this song; a deliberate pause
            // must not be undone by it a few seconds later.
            cancelSilentRiskRecovery()
            // A pause can be the last thing the app does before it is killed, so the
            // seconds heard so far are reported now instead of waiting for a next track.
            if track.source == .netease { reportCurrentNetEasePlay() }
            if track.source == .spotify { spotify.pause() }
            else { streamingPlayer.pause() }
            isPlaying = false
            restoredPlaybackNeedsStart = true
            savePlaybackState()
            return
        }
        // A deliberate pause must be reflected even if App Remote just disconnected.
        preservesPlayingDuringTrackChange = false
        // Pressing play is a fresh try: the silent ladder starts from the top again.
        cancelSilentRiskRecovery()
        if track.source == .spotify {
            if isPlaying { spotify.pause(); isPlaying = false } else { spotify.resume() }
        } else {
            if isPlaying {
                // Report the seconds heard before the pause; a resumed song then sends
                // only the remainder, so one play is never counted twice.
                reportCurrentNetEasePlay()
                streamingPlayer.pause()
            } else {
                // Resume the existing player item first; only re-request the URL
                // and rebuild when there is nothing to resume or resume fails.
                if streamingPlayer.hasCurrentItem {
                    do {
                        try streamingPlayer.resume()
                    } catch {
                        startPlayback(track, at: queueIndex, radio: isRadioMode,
                                      sourceID: playbackSourceID, position: elapsedSeconds,
                                      isResume: true)
                    }
                } else {
                    startPlayback(track, at: queueIndex, radio: isRadioMode,
                                  sourceID: playbackSourceID, position: elapsedSeconds,
                                  isResume: true)
                }
            }
        }
        savePlaybackState()
    }

    /// iPod's skip-back key is two-stage: while a track is under way it restarts
    /// that track, and only a second press (or one within the first 3 seconds)
    /// steps back to the previous track.
    func previous() {
        guard let track = currentTrack else { return }
        if elapsedSeconds > 3.0 {
            lastWheelSeek = (track.source, track.id, ProcessInfo.processInfo.systemUptime)
            if !restoredPlaybackNeedsStart {
                if track.source == .netease { streamingPlayer.seek(to: 0) }
                else { spotify.seek(toPosition: 0) }
            }
            elapsedSeconds = 0
            savePlaybackState()
        } else {
            _ = advanceTrack(by: -1, reason: .manual)
        }
    }
    func next() { _ = advanceTrack(by: 1, reason: .manual) }

    private func handleNaturalEnd() {
        guard let track = currentTrack else { return }
        if track.source == .netease { reportCurrentNetEasePlay() }
        consecutiveNetEaseFailures = 0
        lastHandledNetEaseFailure = nil
        if playbackMode == .repeatOne {
            let index = queueIndex.flatMap { queue.indices.contains($0) && queue[$0].id == track.id ? $0 : nil }
                ?? queue.firstIndex(where: { $0.id == track.id && $0.source == track.source })
            if replayFinishedNetEaseTrack(at: index) { return }
            startPlayback(track, at: index, radio: isRadioMode, sourceID: playbackSourceID)
            return
        }
        if !advanceTrack(by: 1, reason: .naturalEnd) { stopAtQueueEnd() }
    }

    /// Repeats the track that just ended without asking the service for its stream
    /// address again. A finished player item is still attached to `StreamingPlayer`,
    /// so rewinding it restarts instantly; re-resolving the address on every pass
    /// meant a single refusal skipped the song (and a one-song queue never looped).
    @discardableResult
    private func replayFinishedNetEaseTrack(at index: Int?) -> Bool {
        guard currentTrack?.source == .netease else { return false }
        // Drop any late address resolution so it cannot start a second item on top
        // of the replay.
        cancelPendingPlayback()
        restoredPlaybackNeedsStart = false
        guard streamingPlayer.replay() else { return false }
        if let index, queue.indices.contains(index) { queueIndex = index }
        pendingPlaybackSeek = nil
        pendingSpotifySeekConfirmed = false
        elapsedSeconds = 0
        reportedPlaySeconds = 0
        consecutiveNetEaseFailures = 0
        lastHandledNetEaseFailure = nil
        lastRetriedNetEaseTrackID = nil
        // The player now reports playing, so the sink above has already flipped
        // `isPlaying`; refresh the system card with the reset position.
        syncNowPlayingInfo()
        savePlaybackState()
        return true
    }

    /// Pure queue-index math (wrap), extracted for testing. Every playback mode
    /// keeps the queue running — 列表循环 and 随机播放 both wrap at either end, and
    /// 单曲循环 never asks for a neighbour at all — so the only "no next" case is
    /// an empty queue.
    static func nextQueueIndex(current: Int?, count: Int, direction: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index = current else { return 0 }
        let candidate = index + direction
        if (0..<count).contains(candidate) { return candidate }
        return (candidate + count) % count
    }

    func advanceTrack(by direction: Int, reason: QueueAdvanceReason) -> Bool {
        if reason != .playbackFailure {
            consecutiveNetEaseFailures = 0
            lastHandledNetEaseFailure = nil
        }
        guard !queue.isEmpty else { return false }
        let cursor = currentTrack?.id ?? requestedTrackID
        let index = queueIndex.flatMap { queue.indices.contains($0) && queue[$0].id == cursor ? $0 : nil }
            ?? queue.firstIndex(where: { $0.id == cursor })
        guard let target = Self.nextQueueIndex(current: index, count: queue.count, direction: direction) else {
            return false
        }
        // A one-song queue (or a wrap that lands back on the same track) repeats
        // the item in place instead of resolving its address again.
        let targetTrack = queue[target]
        if reason == .naturalEnd, targetTrack.id == currentTrack?.id,
           targetTrack.source == currentTrack?.source,
           replayFinishedNetEaseTrack(at: target) {
            return true
        }
        startPlayback(targetTrack, at: target, direction: direction > 0 ? .forward : .backward,
                      radio: isRadioMode, sourceID: playbackSourceID,
                      preservingFailureCount: reason == .playbackFailure)
        return true
    }

    private func stopAtQueueEnd() {
        cancelPendingPlayback()
        cancelSilentRiskRecovery()
        streamingPlayer.stop(deactivateSession: true)
        if currentTrack?.source == .spotify { spotify.pause() }
        preservesPlayingDuringTrackChange = false
        isPlaying = false
        elapsedSeconds = 0
        restoredPlaybackNeedsStart = currentTrack != nil
        savePlaybackState()
    }

    private func handleNetEasePlaybackFailure(_ error: Error, track: Track, generation: UUID) {
        guard track.source == .netease, playbackGeneration == generation,
              requestedTrackID == track.id, currentTrack?.id == track.id,
              currentTrack?.source == .netease else { return }
        guard lastHandledNetEaseFailure != generation else { return }
        lastHandledNetEaseFailure = generation
        // A -460 is a short window about the caller and says nothing about this song.
        // None of it belongs on screen: no pause, no skip to the wrong song, no alert.
        // The player keeps its position (and its playing look, if it was playing) and
        // asks for the same address again after a pause until the window lifts.
        if case NetEaseClient.ClientError.riskControl = error {
            playbackCommandPending = false
            beginSilentRiskRecovery(for: track)
            return
        }
        preservesPlayingDuringTrackChange = false
        playbackCommandPending = false
        isPlaying = false
        consecutiveNetEaseFailures += 1
        // Retry once at the same position (e.g. a transient network loss) before skipping.
        // The count survives the retry: without that the < 3 ceiling below could never
        // be reached, and a dead queue retried every song forever.
        if lastRetriedNetEaseTrackID != track.id {
            lastRetriedNetEaseTrackID = track.id
            // Only resume where it stopped if the item actually loaded. A failure while
            // the address was still resolving has no progress of its own, and reusing the
            // displayed position started the song in the middle.
            let resumePosition = durationSeconds > 0 && elapsedSeconds.isFinite && elapsedSeconds > 0
                ? elapsedSeconds : 0
            startPlayback(track, at: queueIndex, radio: isRadioMode,
                          sourceID: playbackSourceID, position: resumePosition,
                          preservingFailureCount: true, isResume: true)
            return
        }
        // The connection is gone, not this song: skipping would only queue more doomed
        // requests (each one now retried once) and burn through the queue while the
        // network is down. Stay on the song with a clear message instead.
        if case NetEaseClient.ClientError.transport = error {
            stopAfterRepeatedFailures(error)
            return
        }
        guard consecutiveNetEaseFailures < 3,
              advanceTrack(by: 1, reason: .playbackFailure) else {
            stopAfterRepeatedFailures(error)
            return
        }
    }

    /// Backoff for asking the same song again after a -460.
    ///
    /// The first steps are deliberately short. Against a flagged egress IP the answer
    /// flips between refused and served even when the same request is repeated seconds
    /// apart, so there is no window "worth waiting out" — the cheapest way to get an
    /// address is to ask again promptly, and the cheap step turns a refusal into a
    /// sub-second gap instead of the one-and-a-half-second one it used to be. The
    /// later steps still back off, so a stubborn window is not probed in a tight loop.
    private static let silentRiskRetryDelays: [TimeInterval] = [0.5, 1, 1.5, 2, 3, 5, 8, 12, 18, 25]

    /// Keeps the failed song at its position and tries it again quietly. The attempt
    /// counter survives re-entry, so a retry that is refused again waits longer instead
    /// of restarting the ladder at the shortest delay.
    private func beginSilentRiskRecovery(for track: Track) {
        silentRiskRetryTask?.cancel()
        silentRiskRetryTask = nil
        guard silentRiskRetryAttempt < Self.silentRiskRetryDelays.count else {
            // The window has outlived every step: stop asking rather than probing the
            // service forever. Still silent — the next press is a fresh try.
            preservesPlayingDuringTrackChange = false
            isPlaying = false
            restoredPlaybackNeedsStart = currentTrack != nil
            savePlaybackState()
            return
        }
        let delay = Self.silentRiskRetryDelays[silentRiskRetryAttempt]
        silentRiskRetryAttempt += 1
        let generation = playbackGeneration
        // Only a song whose audio had already loaded can resume where it stopped; an
        // address that never resolved has no position of its own to keep.
        let position = durationSeconds.isFinite && durationSeconds > 0
            && elapsedSeconds.isFinite && elapsedSeconds > 0 ? elapsedSeconds : 0
        silentRiskRetryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled,
                  self.playbackGeneration == generation,
                  self.currentTrack?.id == track.id,
                  self.requestedTrackID == track.id else { return }
            self.silentRiskRetryTask = nil
            self.startPlayback(track, at: self.queueIndex, radio: self.isRadioMode,
                               sourceID: self.playbackSourceID, position: position,
                               preservingFailureCount: true, isResume: true)
        }
    }

    private func cancelSilentRiskRecovery() {
        silentRiskRetryTask?.cancel()
        silentRiskRetryTask = nil
        silentRiskRetryAttempt = 0
    }

    private func stopAfterRepeatedFailures(_ error: Error) {
        cancelPendingPlayback()
        cancelSilentRiskRecovery()
        streamingPlayer.stop(deactivateSession: true)
        isPlaying = false
        restoredPlaybackNeedsStart = currentTrack != nil
        alertMessage = consecutiveNetEaseFailures >= 3
            ? error.localizedDescription + "\n" + L10n.text("已连续 3 首播放失败，已停止。")
            : error.localizedDescription
    }

    private func reportCurrentNetEasePlay() {
        guard let track = currentTrack, track.source == .netease,
              netease.userID != nil, elapsedSeconds.isFinite else { return }
        // Snapshot before stop() publishes zero progress or a caller starts another queue.
        let playedSeconds = Int(elapsedSeconds) - reportedPlaySeconds
        guard playedSeconds >= 10 else { return }
        // Search, charts and recommendations play without a playlist origin; naming the
        // album keeps the play attributed instead of arriving as an anonymous source.
        let sourceID = playbackSourceID ?? track.albumID
        reportedPlaySeconds += playedSeconds
        Task { [netease] in
            // Behind the next song's address, not in front of it. A play report and a
            // song address are the same small server, and the report used to leave
            // first on every skip — the deployed `/scrobble` reload posts two upstream
            // elog entries before it answers, so the address waited for all of it. A
            // short pause lets `/song/url` claim the server; if the address is still
            // travelling after that, the client's own priority rule holds this back
            // until it lands. A lost report is a stat that arrives with the next skip.
            do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
            try? await netease.scrobble(track: track, playedSeconds: playedSeconds, sourceID: sourceID)
        }
    }

    private func startPlayback(_ track: Track, at index: Int? = nil,
                               direction: TrackTransitionDirection = .forward,
                               radio: Bool = false,
                               sourceID: String? = nil, position: Double = 0,
                               preservingFailureCount: Bool = false,
                               isResume: Bool = false) {
        if !isResume { reportCurrentNetEasePlay() }
        // A user-chosen track ends any silent recovery; a retry of the same track
        // (`isResume`) is the recovery itself and keeps its attempt counter.
        if !isResume { cancelSilentRiskRecovery() }
        if !preservingFailureCount {
            consecutiveNetEaseFailures = 0
            lastHandledNetEaseFailure = nil
        }
        if !isResume { lastRetriedNetEaseTrackID = nil }
        // Anything that is not the station ends radio mode: the next song belongs
        // to a finite queue that must not be refilled.
        if !radio { stopRadio() }
        // A position may only be honoured for the very track that is already loaded:
        // same identity, and audio that actually arrived. A value left over from the
        // previous song (or one a stale progress tick wrote onto this one) is a fresh
        // start, not a resume — starting a brand-new item in the middle of a song is
        // never what a caller meant.
        let sameTrackResume = currentTrack?.id == track.id && currentTrack?.source == track.source
            && durationSeconds.isFinite && durationSeconds > 0
        let requestedPosition = sameTrackResume ? position : 0
        let startPosition = track.duration > 0 && requestedPosition >= track.duration
            ? 0
            : min(max(0, requestedPosition), track.duration > 0 ? track.duration : .infinity)
        queueIndex = index ?? queue.firstIndex(where: { $0.id == track.id })
        if isRadioMode { refillRadioIfNeeded() }
        let continuesPlaying = isPlaying
        cancelPendingPlayback()
        preservesPlayingDuringTrackChange = continuesPlaying
        playbackCommandPending = true
        requestedTrackID = track.id
        let generation = playbackGeneration
        pendingPlaybackSeek = nil
        streamingPlayer.stop()
        if currentTrack?.source == .spotify && track.source != .spotify { spotify.pause() }
        // Publish the requested metadata immediately, then resolve audio in the
        // existing cancellable task. Same-ID resolution/callbacks cannot replay a slide.
        // Assign position before the track: currentTrack's didSet saves the playback
        // snapshot, and saving it with the previous song's elapsed time made a relaunch
        // resume the new song in the middle.
        elapsedSeconds = startPosition
        durationSeconds = startPosition > 0 ? track.duration : 0
        trackTransitionDirection = direction
        currentTrack = track
        restoredPlaybackNeedsStart = false
        if startPosition > 0 { pendingPlaybackSeek = (track.source, track.id, startPosition) }
        pendingSpotifySeekConfirmed = false
        // A start that resumes a saved position continues the same hearing, and the report
        // above already accounted the seconds up to it. Only a from-the-top start is a new count.
        if !isResume, startPosition == 0 { reportedPlaySeconds = 0 }
        playbackSourceID = sourceID
        savePlaybackState()
        // Publish metadata before URL resolution so the system card switches to the
        // new song immediately, instead of showing the previous one while buffering.
        syncNowPlayingInfo()
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                if track.source == .netease {
                    var resolved = try await self.netease.playbackTrack(track)
                    guard !Task.isCancelled, self.playbackGeneration == generation else { return }
                    guard let url = resolved.streamURL else {
                        let error = NetEaseClient.ClientError.message("这首歌没有可播放地址。会员歌曲请先在设置中扫码登录；也可能受版权或地区限制。")
                        self.handleNetEasePlaybackFailure(error, track: track, generation: generation)
                        return
                    }
                    // `resolved` is a copy of the metadata playback started with. If the
                    // cover was resolved while `/song/url/v1` was in flight (it can take
                    // seconds), republishing this copy would drop the artwork back to
                    // the placeholder — the cover appearing and then vanishing.
                    if resolved.artworkURL == nil {
                        resolved.artworkURL = self.knownArtwork(for: resolved)
                    }
                    self.currentTrack = resolved
                    self.syncNowPlayingInfo()
                    try self.streamingPlayer.play(url: url)
                } else {
                    self.currentTrack = track
                    try await self.spotify.play(track)
                }
                guard !Task.isCancelled, self.playbackGeneration == generation else { return }
                self.playbackCommandPending = false
            } catch {
                guard !Task.isCancelled, self.playbackGeneration == generation else { return }
                if track.source == .netease {
                    self.handleNetEasePlaybackFailure(error, track: track, generation: generation)
                } else {
                    self.preservesPlayingDuringTrackChange = false
                    self.playbackCommandPending = false
                    self.isPlaying = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancelPendingPlayback() {
        playbackTask?.cancel()
        playbackGeneration = UUID()
        preservesPlayingDuringTrackChange = false
        playbackCommandPending = false
    }

    func settingsChanged() {
        let address = UserDefaults.standard.string(forKey: "neteaseBaseURL") ?? ""
        let storedMode = UserDefaults.standard.string(forKey: "neteaseConnectionMode")
        let mode = NetEaseConnectionMode.resolved(storedRaw: storedMode, address: address)
        let addressChanged = address != configuredNetEaseURL
        let modeChanged = mode != configuredNetEaseMode
        if addressChanged || modeChanged {
            configuredNetEaseURL = address
            configuredNetEaseMode = mode
            neteaseMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "neteaseConnectionMode")
            cancelNetEaseStatusCheck()
            cancelNetEaseQRLogin()
            netease.configure(mode: mode, baseURL: address)
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if mode == .gateway, trimmed.isEmpty {
                neteaseLoginStatus = "请先到“设置 → 网易云设置”填写自建网关地址。"
            } else if addressChanged, !modeChanged {
                neteaseLoginStatus = "服务地址已更新，登录凭据已保留；请检查登录"
            } else if mode == .direct {
                neteaseLoginStatus = "已切换为直连官方接口，登录凭据已保留；请检查登录"
            } else {
                neteaseLoginStatus = "已切换为自建网关，登录凭据已保留；请检查登录"
            }
        }
        spotify.configurationChanged()
    }

    func setNetEaseMode(_ mode: NetEaseConnectionMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "neteaseConnectionMode")
        settingsChanged()
    }

    private func restoreNetEaseLogin() {
        let address = configuredNetEaseURL
        neteaseStatusTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                let status = try await self.netease.restoreSession()
                guard !Task.isCancelled, self.configuredNetEaseURL == address else { return }
                if let status { self.neteaseLoginStatus = status }
                self.neteaseRiskStatusRetries = 0
            } catch {
                guard !Task.isCancelled, self.configuredNetEaseURL == address else { return }
                // A refused probe says nothing about the credentials. Claiming the user
                // is logged out here would send them to scan a QR code because of a
                // window that lifts by itself, so ask again quietly instead.
                if Self.isRiskRefusal(error) {
                    self.retryNetEaseStatusAfterRisk(address: address)
                    return
                }
                self.neteaseLoginStatus = "尚未登录；会员歌曲需要扫码登录"
            }
        }
    }

    /// Two quiet re-probes at most. The saved cookie is untouched either way, so a probe
    /// that never succeeds only leaves the status text as it was.
    private func retryNetEaseStatusAfterRisk(address: String) {
        guard neteaseRiskStatusRetries < 2 else { return }
        neteaseRiskStatusRetries += 1
        Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.configuredNetEaseURL == address else { return }
            self.restoreNetEaseLogin()
        }
    }

    private func cancelNetEaseStatusCheck() {
        neteaseStatusTask?.cancel()
        neteaseStatusTask = nil
    }

    func checkNetEaseLogin() {
        cancelNetEaseStatusCheck()
        let address = configuredNetEaseURL
        neteaseStatusTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                let status = try await self.netease.loginStatus()
                guard !Task.isCancelled, self.configuredNetEaseURL == address else { return }
                self.neteaseLoginStatus = status
                self.neteaseRiskStatusRetries = 0
            } catch {
                guard !Task.isCancelled, self.configuredNetEaseURL == address else { return }
                if case NetEaseClient.ClientError.loginRequired = error, self.selectedSource == .netease {
                    self.resetLikedState()
                }
                // A check the user asked for still has to say something, unless the
                // service only refused the window: then the old status stands.
                if Self.isRiskRefusal(error) {
                    self.retryNetEaseStatusAfterRisk(address: address)
                    return
                }
                self.neteaseLoginStatus = L10n.error(error.localizedDescription)
            }
        }
    }

    func startNetEaseQRLogin() {
        cancelNetEaseStatusCheck()
        cancelNetEaseQRLogin()
        let generation = qrGeneration
        // Scanning a second account must not inherit the first one's library.
        let previousUserID = netease.userID
        isNetEaseLoggingIn = true
        neteaseLoginStatus = "正在生成二维码…"
        qrTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.qrGeneration == generation { self.isNetEaseLoggingIn = false } }
            do {
                let login = try await self.netease.createQRLogin()
                try Task.checkCancellation()
                guard self.qrGeneration == generation else { return }
                let filter = CIFilter.qrCodeGenerator()
                filter.message = Data(login.url.utf8)
                filter.correctionLevel = "M"
                guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                      let image = CIContext().createCGImage(output, from: output.extent) else {
                    self.neteaseLoginStatus = "二维码生成失败，请重试。"
                    return
                }
                self.neteaseQRImage = UIImage(cgImage: image)
                self.neteaseLoginStatus = "请用网易云音乐扫码并在手机上确认登录"
                for _ in 0..<90 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let status = try await self.netease.checkQRLogin(key: login.key)
                    try Task.checkCancellation()
                    guard self.qrGeneration == generation else { return }
                    switch status {
                    case .waiting: break
                    case .scanned: self.neteaseLoginStatus = "已扫码，请在网易云音乐中确认登录"
                    case .expired:
                        self.neteaseQRImage = nil
                        self.neteaseLoginStatus = "二维码已过期，请重新生成。"
                        return
                    case .authorized:
                        let switchedAccounts = previousUserID != nil && previousUserID != self.netease.userID
                        if switchedAccounts {
                            self.clearLocalIndex(.netease)
                            self.cachedLikedSongs[.netease] = nil
                            self.likedSongsCache.remove(.netease)
                            self.netEaseArtworkAttempted.removeAll()
                        }
                        if self.selectedSource == .netease {
                            self.resetLikedState()
                            if switchedAccounts { self.resetLibrary(clearingCaches: true) }
                        }
                        self.neteaseQRImage = nil
                        // The cookie is already saved; a failing status read must not
                        // report the login itself as failed.
                        self.neteaseLoginStatus = (try? await self.netease.loginStatus()) ?? "已登录"
                        return
                    }
                }
                self.neteaseQRImage = nil
                self.neteaseLoginStatus = "二维码已过期，请重新生成。"
            } catch {
                guard !Task.isCancelled, self.qrGeneration == generation else { return }
                self.neteaseQRImage = nil
                self.neteaseLoginStatus = L10n.error(error.localizedDescription)
            }
        }
    }

    func cancelNetEaseQRLogin() {
        qrTask?.cancel()
        qrTask = nil
        qrGeneration = UUID()
        neteaseQRImage = nil
        isNetEaseLoggingIn = false
    }

    func logoutNetEase() {
        cancelNetEaseStatusCheck()
        cancelNetEaseQRLogin()
        let generation = qrGeneration
        screenListCache.removeAll()
        if selectedSource == .netease {
            resetLikedState()
            resetLibrary(clearingCaches: true)
        }
        // The saved playlist index belongs to the account, whatever screen is open.
        clearLocalIndex(.netease)
        cachedLikedSongs[.netease] = nil
        likedSongsCache.remove(.netease)
        netEaseArtworkFillTask?.cancel()
        netEaseArtworkAttempted.removeAll()
        Task { [weak self] in
            guard let self else { return }
            do { try await self.netease.logout() }
            catch is CancellationError { return }
            catch { /* logout() clears the local session even when the server is unavailable. */ }
            guard self.qrGeneration == generation else { return }
            self.neteaseLoginStatus = "已退出登录，会员歌曲需要重新扫码"
        }
    }

    func loginSpotify() {
        spotify.login(
            clientID: UserDefaults.standard.string(forKey: "spotifyClientID") ?? "",
            redirectURI: UserDefaults.standard.string(forKey: "spotifyRedirectURI") ?? "ipodplayer://spotify-login-callback"
        )
    }

    func logoutSpotify() {
        spotify.logout()
        clearLocalIndex(.spotify)
        cachedLikedSongs[.spotify] = nil
        likedSongsCache.remove(.spotify)
        sourcePlaybackStates[.spotify] = nil
        if currentTrack?.source == .spotify {
            cancelPendingPlayback()
            currentTrack = nil
            isPlaying = false
            elapsedSeconds = 0
            durationSeconds = 0
        }
        if selectedSource == .spotify {
            resetLibrary(clearingCaches: true)
            searchTask?.cancel()
            searchGeneration = UUID()
            isSearching = false
            searchHasMore = false
            searchNextOffset = 0
            isLoadingMoreSearch = false
            searchLoadMoreFailed = false
            searchNotice = nil
            searchResultsQuery = ""
            searchResults = []
            searchListID = UUID()
            queue = []
            requestedTrackID = nil
        }
    }

    func handleURL(_ url: URL) { spotify.handleURL(url) }
    func handleSceneActive() {
        if selectedSource == .spotify { spotify.handleSceneActive() }
        if selectedSource == .netease {
            // Hearts can change in the NetEase app while this one is in the background.
            netease.invalidateLikedMembershipCache()
            if let currentTrack, currentTrack.source == .netease {
                refreshLikedState(for: [currentTrack])
            }
        }
        syncNowPlayingInfo()
    }
    func handleApplicationWillTerminate() {
        savePlaybackState()
        spotify.disconnect()
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        remoteCommandHandlers = [
            (center.playCommand, center.playCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isPlaying else { return }
                    self.togglePlayPause()
                }
                return .success
            }),
            (center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isPlaying else { return }
                    self.togglePlayPause()
                }
                return .success
            }),
            (center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.togglePlayPause() }
                return .success
            }),
            (center.nextTrackCommand, center.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.next() }
                return .success
            }),
            (center.previousTrackCommand, center.previousTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.previous() }
                return .success
            }),
            (center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return }
                    self.seekBy(seconds: event.positionTime - self.elapsedSeconds)
                }
                return .success
            })
        ]
        center.likeCommand.isEnabled = false
        center.dislikeCommand.isEnabled = false
        center.bookmarkCommand.isEnabled = false
    }

    /// Everything system Now Playing shows except the position, which it advances
    /// by itself from the playback rate.
    private struct NowPlayingSignature: Equatable {
        let track: Track?
        let isPlaying: Bool
        let hasQueue: Bool
        let duration: Double
        let hasArtwork: Bool
    }

    @ObservationIgnored private var lastNowPlayingSignature: NowPlayingSignature?
    @ObservationIgnored private var lastNowPlayingElapsed: Double = 0
    @ObservationIgnored private var lastNowPlayingSyncTime: TimeInterval = 0

    private var nowPlayingDuration: Double {
        let fallback = currentTrack.map { $0.duration.isFinite ? max(0, $0.duration) : 0 } ?? 0
        return durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : fallback
    }

    private var nowPlayingSignature: NowPlayingSignature {
        NowPlayingSignature(track: currentTrack, isPlaying: isPlaying, hasQueue: !queue.isEmpty,
                            duration: nowPlayingDuration, hasArtwork: nowPlayingArtwork != nil)
    }

    private func syncNowPlayingInfo() {
        guard !isRestoringPlayback else { return }
        // Track, play/pause and artwork changes always sync immediately, so the
        // system HUD never keeps a stale button or cover. Progress alone only
        // syncs once it drifts from the position the system projects (a seek or
        // a stall): re-sending the same state every second woke the media daemon.
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = elapsedSeconds.isFinite ? max(0, elapsedSeconds) : 0
        if nowPlayingSignature == lastNowPlayingSignature {
            let projected = lastNowPlayingElapsed + (isPlaying ? now - lastNowPlayingSyncTime : 0)
            if abs(elapsed - projected) < 1 { return }
        }
        // Recorded after the artwork bookkeeping below, so a cover that is still
        // loading leaves the signature open for the call that delivers it.
        defer {
            lastNowPlayingSignature = nowPlayingSignature
            lastNowPlayingElapsed = elapsed
            lastNowPlayingSyncTime = now
        }
        let commandCenter = MPRemoteCommandCenter.shared()
        guard let track = currentTrack else {
            nowPlayingArtworkTask?.cancel()
            nowPlayingArtworkTask = nil
            nowPlayingArtworkKey = nil
            nowPlayingArtwork = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            commandCenter.playCommand.isEnabled = false
            commandCenter.pauseCommand.isEnabled = false
            commandCenter.togglePlayPauseCommand.isEnabled = false
            commandCenter.nextTrackCommand.isEnabled = false
            commandCenter.previousTrackCommand.isEnabled = false
            commandCenter.changePlaybackPositionCommand.isEnabled = false
            return
        }
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = !queue.isEmpty
        commandCenter.previousTrackCommand.isEnabled = !queue.isEmpty
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        // Source and URL are part of identity: equal IDs and late image responses
        // must never carry another track's cover into system Now Playing.
        let key = track.source.rawValue + "|" + track.id + "|" + (track.artworkURL?.absoluteString ?? "")
        if nowPlayingArtworkKey != key {
            nowPlayingArtworkTask?.cancel()
            nowPlayingArtworkTask = nil
            nowPlayingArtworkKey = key
            nowPlayingArtwork = nil
            if let image = CachedImageLoader.shared.cachedImage(for: track.artworkURL) {
                nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            } else if let url = track.artworkURL {
                nowPlayingArtworkTask = Task { @MainActor [weak self] in
                    let image = await CachedImageLoader.shared.image(for: url)
                    guard !Task.isCancelled, let self, self.nowPlayingArtworkKey == key else { return }
                    self.nowPlayingArtworkTask = nil
                    guard let image else { return }
                    self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    self.syncNowPlayingInfo()
                }
            }
        }
        let duration = nowPlayingDuration
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyArtwork: nowPlayingArtwork ?? Self.nowPlayingPlaceholderArtwork,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: duration > 0 ? min(elapsed, duration) : elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            // Tells the system this is music, so the lock screen and Dynamic Island
            // render the media card (with artwork) instead of a generic audio session.
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if !queue.isEmpty, let index = queueIndex, queue.indices.contains(index) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static let nowPlayingPlaceholderArtwork: MPMediaItemArtwork = {
        let size = CGSize(width: 300, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.16, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(systemName: "music.note")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 105, y: 105, width: 90, height: 90))
        }
        return MPMediaItemArtwork(boundsSize: size) { _ in image }
    }()

    private func applyPlayingState(_ playing: Bool) {
        // stop()/buffering while changing songs is not a user pause.
        if preservesPlayingDuringTrackChange {
            guard playing else { return }
            // Spotify can still publish the old song while its play command connects.
            let requestedTrackIsPlaying = currentTrack?.source != .spotify
                || (currentTrack?.spotifyURI != nil && spotify.currentURI == currentTrack?.spotifyURI)
            if !playbackCommandPending && requestedTrackIsPlaying {
                preservesPlayingDuringTrackChange = false
            }
        }
        // The player republishes progress four times a second; assigning an equal
        // value would still run the didSet on every tick.
        guard isPlaying != playing else { return }
        isPlaying = playing
    }

    private func observePlayers() {
        streamingPlayer.$isPlaying.combineLatest(streamingPlayer.$elapsedSeconds, streamingPlayer.$durationSeconds)
            .sink { [weak self] playing, elapsed, duration in
                guard let self, self.currentTrack?.source == .netease,
                      !self.restoredPlaybackNeedsStart else { return }
                let playingChanged = self.isPlaying != playing
                self.applyPlayingState(playing)
                if playing {
                    self.consecutiveNetEaseFailures = 0
                    self.lastHandledNetEaseFailure = nil
                    // Audio is back: the silent ladder is over and a later refusal
                    // starts from the shortest wait again.
                    self.silentRiskRetryTask?.cancel()
                    self.silentRiskRetryTask = nil
                    self.silentRiskRetryAttempt = 0
                }
                // Preserve cumulative 100ms wheel seeks while older player
                // readings are in flight; actual progress resumes after release.
                if !self.hasRecentWheelSeek && self.pendingPlaybackSeek == nil { self.elapsedSeconds = elapsed }
                if self.pendingPlaybackSeek == nil || duration > 0 { self.durationSeconds = duration }
                self.applyPendingPlaybackSeek(duration: duration)
                if playingChanged { self.savePlaybackState() }
                else { self.savePlaybackProgress() }
                // `elapsedSeconds` / `durationSeconds` / `isPlaying` each sync the
                // system card from their didSet, so progress needs no extra call.
                self.prefetchUpcomingIfNeeded(elapsed: elapsed, duration: duration)
            }.store(in: &subscriptions)
        spotify.$isPlaying.combineLatest(spotify.$elapsedSeconds, spotify.$durationSeconds)
            .sink { [weak self] playing, elapsed, duration in
                guard let self, self.currentTrack?.source == .spotify,
                      !self.restoredPlaybackNeedsStart else { return }
                let playingChanged = self.isPlaying != playing
                self.applyPlayingState(playing)
                if !self.hasRecentWheelSeek && self.pendingPlaybackSeek == nil { self.elapsedSeconds = elapsed }
                if self.pendingPlaybackSeek == nil || duration > 0 { self.durationSeconds = duration }
                self.applyPendingPlaybackSeek(duration: duration)
                if playingChanged { self.savePlaybackState() }
                else { self.savePlaybackProgress() }
            }.store(in: &subscriptions)
        spotify.$isLoggedIn.sink { [weak self] loggedIn in
            self?.isSpotifyLoggedIn = loggedIn
            if !loggedIn, self?.selectedSource == .spotify { self?.resetLikedState() }
        }.store(in: &subscriptions)
        spotify.$statusMessage.sink { [weak self] in self?.spotifyStatus = $0 }.store(in: &subscriptions)
        streamingPlayer.onError = { [weak self] message in
            guard let self, let track = self.currentTrack, track.source == .netease else { return }
            self.handleNetEasePlaybackFailure(NetEaseClient.ClientError.message(message),
                                              track: track, generation: self.playbackGeneration)
        }
        streamingPlayer.onInterruptionEnded = { [weak self] in
            guard let self, let track = self.currentTrack, track.source == .netease,
                  self.selectedSource == .netease else { return }
            self.startPlayback(track, at: self.queueIndex, radio: self.isRadioMode,
                               sourceID: self.playbackSourceID, position: self.elapsedSeconds,
                               isResume: true)
        }
        spotify.onError = { [weak self] message in
            if self?.preservesPlayingDuringTrackChange == true {
                self?.preservesPlayingDuringTrackChange = false
                self?.isPlaying = false
            }
            self?.alertMessage = message
        }
        spotify.onEnded = { [weak self] in
            guard let self, self.currentTrack?.source == .spotify,
                  self.selectedSource == .spotify, !self.restoredPlaybackNeedsStart else { return }
            self.handleNaturalEnd()
        }
        streamingPlayer.onEnded = { [weak self] in
            guard let self, self.currentTrack?.source == .netease else { return }
            self.handleNaturalEnd()
        }
        spotify.onTrackChange = { [weak self] track in
            guard let self, self.selectedSource == .spotify,
                  !self.restoredPlaybackNeedsStart else { return }
            // A song address is already in flight. Ignore Spotify's own autoplay until it lands.
            if self.playbackCommandPending, self.requestedTrackID != track.id { return }
            if self.currentTrack?.id != track.id {
                let oldIndex = self.queueIndex.flatMap {
                    self.queue.indices.contains($0) && self.queue[$0].id == self.currentTrack?.id ? $0 : nil
                } ?? self.queue.firstIndex(where: { $0.id == self.currentTrack?.id })
                let newIndex = self.queue.firstIndex(where: { $0.spotifyURI == track.spotifyURI })
                if let oldIndex, let newIndex {
                    let count = self.queue.count
                    if newIndex == (oldIndex + 1) % count {
                        self.trackTransitionDirection = .forward
                    } else if newIndex == (oldIndex + count - 1) % count || newIndex < oldIndex {
                        self.trackTransitionDirection = .backward
                    } else {
                        self.trackTransitionDirection = .forward
                    }
                } else {
                    self.trackTransitionDirection = .forward
                }
                self.elapsedSeconds = 0
                self.durationSeconds = 0
            }
            if let matchedIndex = self.queue.firstIndex(where: { $0.spotifyURI == track.spotifyURI }) {
                self.queueIndex = matchedIndex
                self.currentTrack = self.queue[matchedIndex]
            } else {
                self.currentTrack = track
            }
            if self.pendingPlaybackSeek?.source == .spotify,
               self.pendingPlaybackSeek?.trackID == track.id {
                self.pendingSpotifySeekConfirmed = true
                self.applyPendingPlaybackSeek(duration: self.spotify.durationSeconds)
            }
        }
    }
}
