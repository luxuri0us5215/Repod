import Foundation

/// 我喜欢的音乐 is the list opened most often, and a NetEase refresh costs a
/// full playlist page walk plus song-detail batches. The last successful list is
/// kept on disk so the screen can open instantly and refresh behind it, and so
/// the boot screen can warm it before the user gets there.
///
/// This is a rebuildable metadata cache: stream URLs and credentials have no
/// representation here, and losing it costs one refresh.
@MainActor
final class LikedSongsCache {
    var onSaveFailure: (() -> Void)?

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("LikedSongs.json")
    }()
    /// A whole liked library of 10,000 songs is several megabytes of JSON.
    private let capacity = 20_000
    /// Rows are already `Track`s: the conversion happens on the reading thread.
    /// Building up to 20,000 of them inside `load()` ran on the main actor, in
    /// the middle of the boot screen's own window.
    private var entries: [String: Entry] = [:]
    private var writeTask: Task<Void, Never>?
    private var needsWrite = false
    private var isLoaded = false

    func load() async {
        guard !isLoaded else { return }
        isLoaded = true
        let fileURL = self.fileURL
        let capacity = self.capacity
        entries = await Task.detached(priority: .userInitiated) {
            Self.read(fileURL: fileURL, capacity: capacity)
        }.value
    }

    /// `account` guards against showing one account's list to another. A nil
    /// account on either side accepts the entry: at boot the login has not been
    /// restored yet, and the list is dropped on logout anyway.
    func tracks(for source: AudioSource, account: String?) -> [Track]? {
        guard let entry = entries[source.rawValue] else { return nil }
        if let stored = entry.account, let account, stored != account {
            entries[source.rawValue] = nil
            scheduleSave()
            return nil
        }
        // `read` already filtered by source and dropped rows it could not rebuild.
        return entry.tracks.isEmpty ? nil : entry.tracks
    }

    func store(_ tracks: [Track], for source: AudioSource, account: String?) {
        let kept = Array(tracks.lazy.filter { $0.source == source }.prefix(capacity))
        guard !kept.isEmpty else { return }
        let previous = entries[source.rawValue]
        guard previous?.account != account || previous?.tracks != kept else { return }
        entries[source.rawValue] = Entry(account: account, tracks: kept)
        scheduleSave()
    }

    func remove(_ source: AudioSource) {
        guard entries.removeValue(forKey: source.rawValue) != nil else { return }
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
                let snapshot = self.entries
                let url = self.fileURL
                if await Self.write(snapshot, to: url) { self.onSaveFailure?() }
            }
            guard let self else { return }
            self.writeTask = nil
            if self.needsWrite { self.scheduleSave() }
        }
    }

    /// Reads, trims and converts on the calling (background) thread, so the main
    /// actor only stores the finished dictionary.
    private nonisolated static func read(fileURL: URL, capacity: Int) -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: StoredEntry].self, from: data) else { return [:] }
        var result: [String: Entry] = [:]
        for (key, entry) in decoded {
            guard let source = AudioSource(rawValue: key) else { continue }
            let tracks = entry.tracks.compactMap(\.track).filter { $0.source == source }
            guard !tracks.isEmpty else { continue }
            result[key] = Entry(account: entry.account,
                                tracks: tracks.count > capacity ? Array(tracks.prefix(capacity)) : tracks)
        }
        return result
    }

    private static func write(_ entries: [String: Entry], to url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            do {
                // The `Track` → `StoredTrack` conversion and the encoding both
                // happen here, not on the main actor that scheduled the save.
                let stored = entries.mapValues {
                    StoredEntry(account: $0.account, tracks: $0.tracks.map(StoredTrack.init))
                }
                let data = try JSONEncoder().encode(stored)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return false
            } catch {
                return true
            }
        }.value
    }

    private struct Entry {
        let account: String?
        var tracks: [Track]
    }

    private struct StoredEntry: Codable {
        let account: String?
        var tracks: [StoredTrack]
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
}
