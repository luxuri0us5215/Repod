import Foundation

/// Network-backed screens already had their rows, then forgot them on relaunch,
/// so every entry opened on an empty list and waited for the server. The last
/// contents of those screens are kept on disk instead: the screen opens with
/// what it had, and its refresh runs behind that frame.
///
/// Like the other caches here this is rebuildable metadata: stream URLs and
/// credentials have no representation, and losing it costs one refresh.
@MainActor
final class ScreenListCache {
    static let shared = ScreenListCache()

    var onSaveFailure: (() -> Void)?

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("ScreenLists.json")
    }()
    /// Enough for a large recommended list; recommendations are not a library.
    private let trackCapacity = 600
    private var lists: [String: ListEntry] = [:]
    private var playlists: [String: PlaylistEntry] = [:]
    private var writeTask: Task<Void, Never>?
    private var needsWrite = false
    private var isLoaded = false

    func load() async {
        guard !isLoaded else { return }
        isLoaded = true
        let fileURL = self.fileURL
        let capacity = self.trackCapacity
        let stored = await Task.detached(priority: .userInitiated) {
            Self.read(fileURL: fileURL, capacity: capacity)
        }.value
        lists = stored.lists
        playlists = stored.playlists
    }

    /// Covers only the screens whose contents are a server snapshot. The liked
    /// list and playlist tracks have their own stores.
    private static func key(_ screen: AppScreen, source: AudioSource) -> String? {
        switch screen {
        case .dailyRecommendations: return "daily|" + source.rawValue
        default: return nil
        }
    }

    /// A nil account on either side accepts the entry: at boot the login may not
    /// be restored yet, and every entry is dropped on logout anyway.
    func tracks(for screen: AppScreen, source: AudioSource,
                account: String?, maxAge: TimeInterval) -> [Track]? {
        guard let key = Self.key(screen, source: source), let entry = lists[key] else { return nil }
        if Date().timeIntervalSince(entry.savedAt) > maxAge {
            lists[key] = nil
            scheduleSave()
            return nil
        }
        if let stored = entry.account, let account, stored != account {
            lists[key] = nil
            scheduleSave()
            return nil
        }
        let tracks = entry.tracks.compactMap(\.track).filter { $0.source == source }
        return tracks.isEmpty ? nil : tracks
    }

    func store(_ tracks: [Track], for screen: AppScreen, source: AudioSource, account: String?) {
        guard let key = Self.key(screen, source: source) else { return }
        let stored = tracks.filter { $0.source == source }.map(StoredTrack.init)
        guard !stored.isEmpty else { return }
        let trimmed = Array(stored.prefix(trackCapacity))
        // `savedAt` is bookkeeping, not content. Comparing it made every prewarm and
        // refresh look like a change, so the whole file was rewritten each time.
        if var existing = lists[key], existing.account == account, existing.tracks == trimmed {
            existing.savedAt = Date()
            lists[key] = existing
            return
        }
        lists[key] = ListEntry(savedAt: Date(), account: account, tracks: trimmed)
        scheduleSave()
    }

    func playlists(for source: AudioSource, account: String?) -> [MusicPlaylist]? {
        guard let entry = playlists[source.rawValue] else { return nil }
        if let stored = entry.account, let account, stored != account {
            playlists[source.rawValue] = nil
            scheduleSave()
            return nil
        }
        let items = entry.items.compactMap(\.playlist).filter { $0.source == source }
        return items.isEmpty ? nil : items
    }

    func store(playlists items: [MusicPlaylist], for source: AudioSource, account: String?) {
        let stored = items.filter { $0.source == source }.map(StoredPlaylist.init)
        guard !stored.isEmpty else { return }
        if var existing = playlists[source.rawValue],
           existing.account == account, existing.items == stored {
            existing.savedAt = Date()
            playlists[source.rawValue] = existing
            return
        }
        playlists[source.rawValue] = PlaylistEntry(savedAt: Date(), account: account, items: stored)
        scheduleSave()
    }

    /// Logout and account switches must not leave another account's rows behind.
    func removeAll() {
        guard !lists.isEmpty || !playlists.isEmpty else { return }
        lists = [:]
        playlists = [:]
        scheduleSave()
    }

    /// Like the library index, writes are coalesced: this file is a cache.
    private func scheduleSave() {
        needsWrite = true
        guard writeTask == nil else { return }
        writeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            while true {
                guard let self, self.needsWrite else { break }
                self.needsWrite = false
                let payload = Payload(lists: self.lists, playlists: self.playlists)
                let url = self.fileURL
                if await Self.write(payload, to: url) { self.onSaveFailure?() }
            }
            guard let self else { return }
            self.writeTask = nil
            if self.needsWrite { self.scheduleSave() }
        }
    }

    private nonisolated static func read(fileURL: URL, capacity: Int) -> Payload {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else { return Payload() }
        var payload = decoded
        payload.lists = payload.lists.compactMapValues { entry in
            guard !entry.tracks.isEmpty else { return nil }
            var trimmed = entry
            if trimmed.tracks.count > capacity { trimmed.tracks = Array(trimmed.tracks.prefix(capacity)) }
            return trimmed
        }
        payload.playlists = payload.playlists.filter { !$0.value.items.isEmpty }
        return payload
    }

    private nonisolated static func write(_ payload: Payload, to url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(payload)
                try data.write(to: url, options: .atomic)
                return false
            } catch {
                return true
            }
        }.value
    }

    private struct Payload: Codable {
        var lists: [String: ListEntry] = [:]
        var playlists: [String: PlaylistEntry] = [:]
    }

    private struct ListEntry: Codable {
        var savedAt: Date
        let account: String?
        var tracks: [StoredTrack]
    }

    private struct PlaylistEntry: Codable {
        var savedAt: Date
        let account: String?
        var items: [StoredPlaylist]
    }

    private struct StoredTrack: Codable, Equatable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let rawSource: String
        let spotifyURI: String?
        let artworkURL: URL?

        init(_ track: Track) {
            id = track.id
            title = track.title
            artist = track.artist
            album = track.album
            duration = track.duration.isFinite ? max(0, track.duration) : 0
            rawSource = track.source.rawValue
            spotifyURI = track.spotifyURI
            artworkURL = track.artworkURL
        }

        var track: Track? {
            guard let source = AudioSource(rawValue: rawSource) else { return nil }
            return Track(id: id, title: title, artist: artist, album: album, duration: duration,
                         source: source, spotifyURI: spotifyURI, streamURL: nil, artworkURL: artworkURL)
        }
    }

    private struct StoredPlaylist: Codable, Equatable {
        let id: String
        let title: String
        let trackCount: Int?
        let rawSource: String
        /// Absent in files written before 1.81; those simply sort alphabetically.
        let isLiked: Bool?

        init(_ playlist: MusicPlaylist) {
            id = playlist.id
            title = playlist.title
            trackCount = playlist.trackCount
            rawSource = playlist.source.rawValue
            isLiked = playlist.isLiked
        }

        var playlist: MusicPlaylist? {
            guard let source = AudioSource(rawValue: rawSource) else { return nil }
            return MusicPlaylist(id: id, title: title, trackCount: trackCount,
                                 source: source, isLiked: isLiked ?? false)
        }
    }
}
