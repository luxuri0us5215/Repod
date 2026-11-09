import Foundation

/// Only metadata from playlist loads survives across sessions, filtered by source in the UI.
/// Stream URLs and authentication state deliberately have no representation in this file.
///
/// 歌曲 / 歌手 / 专辑 are derived from the liked-songs cache, not from here. This store
/// keeps two things: the rows of each playlist that has been opened this session (so
/// reopening a list paints instantly) and the playlist membership index, which lets
/// the store answer "does this playlist already have rows?" without a full fetch.
@MainActor
final class LocalLibraryStore {
    /// Reported off the write path, which no longer blocks the caller.
    var onSaveFailure: (() -> Void)?

    /// Bumped whenever what the file is allowed to hold changes. 1.x also indexed
    /// every playlist in the account as if it were part of the library; that
    /// pollution is dropped exactly once.
    private static let schemaVersion = 2
    private static let schemaVersionKey = "localLibrarySchemaVersion"

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("LocalLibrary.json")
    }()
    private let legacyFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LocalLibrary.json")

    private let capacity = 20_000
    private var records: [String: StoredTrack] = [:]
    private var needsWrite = false
    private var writeTask: Task<Void, Never>?
    /// Bumped by every mutation; it invalidates the membership-ID snapshot below.
    private var mutationStamp = 0
    /// Per-playlist revisions. A single global stamp meant that indexing one
    /// playlist invalidated every other playlist's cached rows, so sweeping a
    /// list of playlists rescanned the whole store once per playlist after any write.
    private var playlistRevisions: [String: Int] = [:]
    private var playlistTrackCache: [String: (revision: Int, tracks: [Track])] = [:]
    private var playlistTrackOrder: [String] = []
    private var playlistTrackCacheTotal = 0
    /// Enough for the playlists a session opens; a whole library of playlists
    /// must not be able to pin every row copy in memory.
    private static let playlistTrackCacheLimit = 16
    private static let playlistTrackCacheTrackLimit = 60_000
    private var playlistIDsCache: (stamp: Int, ids: Set<String>)?
    /// Set when `load()` dropped records and the file should be rewritten once the
    /// first frame is up, not during launch.
    private var needsRewriteAfterLoad = false

    /// Reads and validates the index on a background thread. A 20k-track
    /// library is ~6 MB of JSON and takes ~100 ms to decode, which used to block
    /// the first frame because this ran synchronously inside the view model's init.
    func load() async throws {
        dropIncompatibleSnapshot()
        let fileURL = self.fileURL
        let legacyFileURL = self.legacyFileURL
        let capacity = self.capacity
        let loaded = try await Task.detached(priority: .userInitiated) {
            try Self.readIndex(fileURL: fileURL, legacyFileURL: legacyFileURL, capacity: capacity)
        }.value
        records = loaded.records
        playlistIDsCache = nil
        clearPlaylistTrackCache()
        // Stage 1.11 also saved searches/playback. Only rewrite when this pass
        // actually dropped something; re-encoding a multi-megabyte file on every
        // launch cost more than the cleanup was worth. The write itself is deferred
        // past the first frame: it is several megabytes and nothing needs it yet.
        needsRewriteAfterLoad = loaded.needsRewrite
    }

    /// A file written by an older schema is not migrated: it is a rebuildable
    /// metadata index, so deleting it costs one playlist refetch and removes the
    /// rows the old library-wide indexing left behind.
    private func dropIncompatibleSnapshot() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.schemaVersionKey) != Self.schemaVersion else { return }
        defaults.set(Self.schemaVersion, forKey: Self.schemaVersionKey)
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: legacyFileURL)
    }

    /// Starts the deferred post-load cleanup write. Called once the boot screen is
    /// gone, so the encode does not compete with the first frame for disk and CPU.
    func writeDeferredCleanup() {
        guard needsRewriteAfterLoad else { return }
        needsRewriteAfterLoad = false
        scheduleSave()
    }

    func tracks(in playlist: MusicPlaylist) -> [Track] {
        let revision = playlistRevisions[playlist.id] ?? 0
        if let cached = playlistTrackCache[playlist.id], cached.revision == revision {
            // Keep recently read playlists at the back so an eviction drops the
            // one opened longest ago.
            playlistTrackOrder.removeAll { $0 == playlist.id }
            playlistTrackOrder.append(playlist.id)
            return cached.tracks
        }
        let tracks = records.values.filter {
            $0.source == playlist.source.rawValue && $0.playlistPositions[playlist.id] != nil
        }.sorted {
            let lhs = $0.playlistPositions[playlist.id] ?? 0
            let rhs = $1.playlistPositions[playlist.id] ?? 0
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }.compactMap(\.track)
        cachePlaylistTracks(tracks, id: playlist.id, revision: revision)
        return tracks
    }

    private func cachePlaylistTracks(_ tracks: [Track], id: String, revision: Int) {
        if let previous = playlistTrackCache[id] {
            playlistTrackCacheTotal -= previous.tracks.count
        }
        playlistTrackCache[id] = (revision, tracks)
        playlistTrackCacheTotal += tracks.count
        playlistTrackOrder.removeAll { $0 == id }
        playlistTrackOrder.append(id)
        while playlistTrackOrder.count > Self.playlistTrackCacheLimit
            || (playlistTrackOrder.count > 1 && playlistTrackCacheTotal > Self.playlistTrackCacheTrackLimit) {
            let evicted = playlistTrackOrder.removeFirst()
            if let entry = playlistTrackCache.removeValue(forKey: evicted) {
                playlistTrackCacheTotal -= entry.tracks.count
            }
        }
    }

    private func clearPlaylistTrackCache() {
        playlistTrackCache = [:]
        playlistTrackOrder = []
        playlistTrackCacheTotal = 0
    }

    /// Playlists that already have rows here, so callers can tell a first fetch
    /// from a refresh without scanning the store once per playlist.
    private func indexedPlaylistIDs() -> Set<String> {
        if let cached = playlistIDsCache, cached.stamp == mutationStamp { return cached.ids }
        var ids = Set<String>()
        for record in records.values { ids.formUnion(record.playlistPositions.keys) }
        playlistIDsCache = (mutationStamp, ids)
        return ids
    }

    /// Drops memberships in playlists this account no longer has. Only call this
    /// with a complete playlist list: without it a deleted or unfollowed playlist
    /// keeps its songs in the store forever.
    @discardableResult
    func retainPlaylists(_ playlistIDs: Set<String>, source: AudioSource) -> Bool {
        var changed = false
        for key in Array(records.keys) {
            guard var record = records[key], record.source == source.rawValue else { continue }
            // Common case: nothing to drop. Checking first avoids building a copy
            // of every record's membership dictionary on the main actor.
            if record.playlistPositions.keys.allSatisfy({ playlistIDs.contains($0) }) { continue }
            let kept = record.playlistPositions.filter { playlistIDs.contains($0.key) }
            if kept.isEmpty {
                records[key] = nil
            } else {
                record.playlistPositions = kept
                records[key] = record
            }
            changed = true
        }
        guard changed else { return false }
        mutationStamp &+= 1
        playlistIDsCache = nil
        // Which playlists lost rows is not tracked per revision; a complete list
        // refresh is rare, so dropping the row cache is cheaper than guessing.
        clearPlaylistTrackCache()
        scheduleSave()
        return true
    }

    /// Removes everything remembered for one source, so another account or a
    /// logout never inherits the previous library index.
    func removeSource(_ source: AudioSource) {
        let keys = records.keys.filter { records[$0]?.source == source.rawValue }
        guard !keys.isEmpty else { return }
        for key in keys { records[key] = nil }
        mutationStamp &+= 1
        playlistIDsCache = nil
        clearPlaylistTrackCache()
        scheduleSave()
    }

    /// One successful API collection replaces that playlist's membership, including an empty result.
    /// Each update writes one atomic snapshot after the whole batch, never inside the track loop.
    /// Returns false when the stored rows already match, so callers can skip the
    /// save that a read does not need.
    @discardableResult
    func remember(_ tracks: [Track], playlist: MusicPlaylist) -> Bool {
        // Reopening a playlist inside its refresh window returns the same rows.
        // Writing them again invalidated the row cache and the on-disk snapshot
        // for what was only a read.
        guard !playlistContentsMatch(tracks, playlist: playlist) else { return false }
        // Only this playlist's rows are about to change; other playlists keep
        // their cached rows and their revisions.
        var emptied: [String] = []
        if indexedPlaylistIDs().contains(playlist.id) {
            for key in Array(records.keys) where records[key]?.source == playlist.source.rawValue {
                guard records[key]?.playlistPositions.removeValue(forKey: playlist.id) != nil else { continue }
                if records[key]?.playlistPositions.isEmpty == true { emptied.append(key) }
            }
        }
        // A song removed from its last known playlist no longer belongs in this store.
        // Removing only the keys that became empty avoids rebuilding the dictionary.
        for key in emptied { records[key] = nil }
        var seen = Set<String>()
        for (position, track) in tracks.enumerated() {
            guard track.source == playlist.source else { continue }
            let key = Self.key(track)
            guard seen.insert(key).inserted else { continue }
            let previous = records[key]
            var memberships = previous?.playlistPositions ?? [:]
            memberships[playlist.id] = position
            records[key] = StoredTrack(
                id: track.id, title: track.title, artist: track.artist, album: track.album,
                artworkURL: track.artworkURL ?? previous?.artworkURL,
                duration: track.duration.isFinite ? max(0, track.duration) : 0,
                source: track.source.rawValue, spotifyURI: track.spotifyURI,
                lastSeen: Date(), playlistPositions: memberships
            )
        }
        mutationStamp &+= 1
        playlistRevisions[playlist.id, default: 0] &+= 1
        playlistIDsCache = nil
        // Only trims above the capacity limit can drop other playlists' rows.
        if trim() { clearPlaylistTrackCache() }
        scheduleSave()
        return true
    }

    /// True when the stored rows for this playlist are exactly the incoming ones,
    /// in the same order, with no cover the fresh response could add. The store
    /// then has nothing to write.
    private func playlistContentsMatch(_ incoming: [Track], playlist: MusicPlaylist) -> Bool {
        // A playlist with no rows cannot match; this also avoids scanning the
        // store once for every playlist added for the first time.
        guard indexedPlaylistIDs().contains(playlist.id) else { return false }
        // `tracks` is the parameter name elsewhere; the store method must be
        // reached explicitly here.
        let stored = self.tracks(in: playlist)
        guard !stored.isEmpty else { return false }
        var position = 0
        for track in incoming {
            guard track.source == playlist.source else { continue }
            guard position < stored.count else { return false }
            let previous = stored[position]
            guard (track.spotifyTrackID ?? track.id) == (previous.spotifyTrackID ?? previous.id) else {
                return false
            }
            // A locally stored row without art gains it from the fresh response;
            // that changes what the playlist shows and must take the write path.
            if previous.artworkURL == nil, track.artworkURL != nil { return false }
            position += 1
        }
        return position == stored.count
    }

    /// A full 20k-track library encodes to several megabytes. Doing that on the main
    /// actor for every indexed playlist stalled the UI, so the snapshot is encoded and
    /// written off the main actor. Consecutive calls coalesce into one write: this file
    /// is a rebuildable metadata index, so losing a sub-second update window is safe.
    private func scheduleSave() {
        needsWrite = true
        guard writeTask == nil else { return }
        writeTask = Task { [weak self] in
            // Coalesce bursts: a playlist sweep saves one playlist at a time.
            try? await Task.sleep(nanoseconds: 400_000_000)
            while true {
                guard let self, self.needsWrite else { break }
                self.needsWrite = false
                let snapshot = self.records
                let url = self.fileURL
                if await Self.write(snapshot, to: url) { self.onSaveFailure?() }
            }
            guard let self else { return }
            self.writeTask = nil
            // A save requested while this worker was finishing still needs to run.
            if self.needsWrite { self.scheduleSave() }
        }
    }

    private static func write(_ records: [String: StoredTrack], to url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(records)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return false
            } catch {
                return true
            }
        }.value
    }

    /// Sorting the whole store is only necessary when its capacity is exceeded.
    @discardableResult
    private func trim() -> Bool {
        let trimmed = Self.trimmed(records, capacity: capacity)
        guard trimmed.count != records.count else { return false }
        records = trimmed
        mutationStamp &+= 1
        return true
    }

    private struct LoadedIndex {
        let records: [String: StoredTrack]
        let needsRewrite: Bool
    }

    /// Runs off the main actor, so it may only touch values passed in.
    private nonisolated static func readIndex(fileURL: URL, legacyFileURL: URL,
                                              capacity: Int) throws -> LoadedIndex {
        // One-time migration: move the legacy Documents copy into Application Support.
        if !FileManager.default.fileExists(atPath: fileURL.path),
           FileManager.default.fileExists(atPath: legacyFileURL.path) {
            try? FileManager.default.moveItem(at: legacyFileURL, to: fileURL)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return LoadedIndex(records: [:], needsRewrite: false)
        }
        let stored = try JSONDecoder().decode([String: StoredTrack].self, from: Data(contentsOf: fileURL))
        var merged: [String: StoredTrack] = [:]
        for record in stored.values {
            guard !record.playlistPositions.isEmpty, let track = record.track else { continue }
            let key = key(track)
            if let previous = merged[key], previous.lastSeen > record.lastSeen { continue }
            merged[key] = record
        }
        let trimmed = trimmed(merged, capacity: capacity)
        return LoadedIndex(records: trimmed, needsRewrite: trimmed.count != stored.count)
    }

    private nonisolated static func trimmed(_ records: [String: StoredTrack],
                                            capacity: Int) -> [String: StoredTrack] {
        guard records.count > capacity else { return records }
        let newest = records.sorted {
            $0.value.lastSeen == $1.value.lastSeen
                ? $0.key < $1.key : $0.value.lastSeen > $1.value.lastSeen
        }.prefix(capacity)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    private nonisolated static func key(_ track: Track) -> String {
        track.source.rawValue + ":" + (track.spotifyTrackID ?? track.id)
    }

    private struct StoredTrack: Codable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let artworkURL: URL?
        let duration: Double
        let source: String
        let spotifyURI: String?
        let lastSeen: Date
        var playlistPositions: [String: Int]

        var track: Track? {
            guard let source = AudioSource(rawValue: source) else { return nil }
            return Track(id: id, title: title, artist: artist, album: album, duration: duration,
                         source: source, spotifyURI: spotifyURI, artworkURL: artworkURL)
        }
    }
}
