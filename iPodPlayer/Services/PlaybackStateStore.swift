import Foundation

/// The queue, the playing track and the position, kept across launches.
///
/// This used to live in `UserDefaults`, written from the main actor at every track
/// change: a song change saved the snapshot four times (the track assignment, the
/// explicit save, the resolved metadata copy and the first playing callback), and each
/// one encoded up to 400 persisted tracks on the main thread while the transition
/// animation was running. The records now live in files under Application Support,
/// encoded off the main actor, with the debounce owned by the view model.
@MainActor
final class PlaybackStateStore {
    static let shared = PlaybackStateStore()

    /// The decoded contents of both records, produced off the main actor.
    struct Restored: Sendable {
        let snapshot: PlaybackSnapshot?
        let progress: PlaybackProgress?
    }

    /// Lightweight position-only record, written between full snapshots without
    /// re-encoding the queue.
    struct PlaybackProgress: Codable, Sendable {
        let trackID: String
        let source: String
        let elapsedSeconds: Double
        /// Seconds already reported for this play. Without it a relaunch cannot tell a
        /// paused-then-closed play (already reported) from one killed mid-track (not yet
        /// reported), and resuming re-sends the opening seconds as a new play.
        let reportedPlaySeconds: Int?
    }

    struct PersistedTrack: Codable, Sendable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let source: String
        let spotifyURI: String?
        let artworkURL: URL?
        /// Missing on snapshots written before the album was kept; decodes as nil.
        let albumID: String?
        /// Missing on older snapshots; decodes as false.
        let isPodcastEpisode: Bool?
        /// Missing on older snapshots and on songs; kept so a relaunched episode can still
        /// be reported as its own program instead of as the underlying catalogue song.
        let podcastProgramID: String?
        let podcastRadioID: String?

        init(_ track: Track) {
            id = track.id
            title = track.title
            artist = track.artist
            album = track.album
            duration = track.duration
            source = track.source.rawValue
            spotifyURI = track.spotifyURI
            artworkURL = track.artworkURL
            albumID = track.albumID
            isPodcastEpisode = track.isPodcastEpisode
            podcastProgramID = track.podcastProgramID
            podcastRadioID = track.podcastRadioID
        }

        var track: Track? {
            guard let source = AudioSource(rawValue: source), !id.isEmpty, !title.isEmpty,
                  duration.isFinite, duration >= 0 else { return nil }
            if source == .spotify, spotifyURI?.hasPrefix("spotify:track:") != true { return nil }
            return Track(id: id, title: title, artist: artist, album: album, duration: duration,
                         source: source, spotifyURI: spotifyURI, streamURL: nil,
                         artworkURL: artworkURL, albumID: albumID,
                         isPodcastEpisode: isPodcastEpisode ?? false,
                         podcastProgramID: podcastProgramID, podcastRadioID: podcastRadioID)
        }
    }

    struct PlaybackSnapshot: Codable, Sendable {
        let version: Int
        let currentTrack: PersistedTrack
        let queue: [PersistedTrack]
        let queueIndex: Int
        let elapsedSeconds: Double
        let wasPlaying: Bool
        /// Original order captured before shuffle. Missing on snapshots saved before this field existed.
        let queueBaseTracks: [PersistedTrack]?

        /// The pathological-metadata fallback drops the pre-shuffle order and keeps the
        /// queue: a relaunch still resumes in place, it just cannot unshuffle.
        func droppingShuffleBase() -> PlaybackSnapshot {
            PlaybackSnapshot(version: version, currentTrack: currentTrack, queue: queue,
                             queueIndex: queueIndex, elapsedSeconds: elapsedSeconds,
                             wasPlaying: wasPlaying, queueBaseTracks: nil)
        }
    }

    /// Keys written by the version that kept this in `UserDefaults`. Read once, then
    /// deleted: two copies of a 900 KB record would only drift.
    private static let legacyStateKey = "playbackState"
    private static let legacyProgressKey = "playbackProgress"
    /// `UserDefaults` was happy with a smaller value; a file has no such limit, but
    /// keeping the budget means an old build reading a migrated file still can.
    private nonisolated static let byteBudget = 900_000

    private let directoryURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        directoryURL = support.appendingPathComponent("Playback", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private var stateURL: URL { directoryURL.appendingPathComponent("PlaybackState.json") }
    private var progressURL: URL { directoryURL.appendingPathComponent("PlaybackProgress.json") }

    /// Reads both records. A store written by an older build is migrated in place on
    /// the first launch after the update, then the old keys are removed.
    func load() async -> Restored {
        let stateURL = self.stateURL
        let progressURL = self.progressURL
        let legacyState = UserDefaults.standard.data(forKey: Self.legacyStateKey)
        let legacyProgress = UserDefaults.standard.data(forKey: Self.legacyProgressKey)
        let restored = await Task.detached(priority: .userInitiated) {
            Self.read(stateURL: stateURL, progressURL: progressURL,
                      legacyState: legacyState, legacyProgress: legacyProgress)
        }.value
        if legacyState != nil { UserDefaults.standard.removeObject(forKey: Self.legacyStateKey) }
        if legacyProgress != nil { UserDefaults.standard.removeObject(forKey: Self.legacyProgressKey) }
        return restored
    }

    /// Encodes and writes both records off the main actor. The debounced caller may
    /// still have a newer snapshot queued by the time this finishes; whoever awaits
    /// last writes, which is the same ordering the previous synchronous saves had.
    func save(_ snapshot: PlaybackSnapshot, progress: PlaybackProgress?) async {
        let stateURL = self.stateURL
        let progressURL = self.progressURL
        await Task.detached(priority: .utility) {
            Self.write(snapshot, to: stateURL)
            if let progress { Self.write(progress, to: progressURL) }
        }.value
    }

    func saveProgress(_ progress: PlaybackProgress) async {
        let progressURL = self.progressURL
        await Task.detached(priority: .utility) {
            Self.write(progress, to: progressURL)
        }.value
    }

    /// The background transition suspends the process right after this returns, so the
    /// last write cannot be deferred.
    func flush(_ snapshot: PlaybackSnapshot, progress: PlaybackProgress?) {
        Self.write(snapshot, to: stateURL)
        if let progress { Self.write(progress, to: progressURL) }
    }

    /// No playing track means there is nothing to resume.
    func removeAll() {
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: progressURL)
        UserDefaults.standard.removeObject(forKey: Self.legacyStateKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyProgressKey)
    }

    private nonisolated static func read(stateURL: URL, progressURL: URL,
                                         legacyState: Data?, legacyProgress: Data?) -> Restored {
        let decoder = JSONDecoder()
        var stateData = try? Data(contentsOf: stateURL)
        var progressData = try? Data(contentsOf: progressURL)
        // Migrating here costs one file write on the first launch after the update; the
        // next launch reads the file and never looks at the old keys again.
        if stateData == nil, let legacyState {
            stateData = legacyState
            try? legacyState.write(to: stateURL, options: .atomic)
        }
        if progressData == nil, let legacyProgress {
            progressData = legacyProgress
            try? legacyProgress.write(to: progressURL, options: .atomic)
        }
        return Restored(
            snapshot: stateData.flatMap { try? decoder.decode(PlaybackSnapshot.self, from: $0) },
            progress: progressData.flatMap { try? decoder.decode(PlaybackProgress.self, from: $0) }
        )
    }

    private nonisolated static func write(_ snapshot: PlaybackSnapshot, to url: URL) {
        guard let data = encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated static func write(_ progress: PlaybackProgress, to url: URL) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated static func encode(_ snapshot: PlaybackSnapshot) -> Data? {
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        // Pathological metadata (very long titles) can still exceed the budget. Repeating
        // a shuffled queue is the only optional part, so that is what goes.
        if data.count > byteBudget, snapshot.queueBaseTracks != nil,
           let trimmed = try? JSONEncoder().encode(snapshot.droppingShuffleBase()) {
            return trimmed
        }
        return data
    }
}
