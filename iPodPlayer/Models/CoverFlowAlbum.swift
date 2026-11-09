import Foundation

/// An album represented only by tracks already returned by the selected source.
/// Stage 1 has no album IDs, so artwork/title identify albums when available.
struct CoverFlowAlbum: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let tracks: [Track]

    /// One entry per distinct song, in the order the supplied list uses. Cover
    /// Flow on a browsed song list must not fold several rows into one cover.
    static func songs(from tracks: [Track], source: AudioSource) -> [CoverFlowAlbum] {
        var seen = Set<String>()
        var songs: [CoverFlowAlbum] = []
        for track in tracks where track.source == source {
            guard seen.insert(track.id).inserted else { continue }
            songs.append(CoverFlowAlbum(id: songKey(track),
                                        title: track.title,
                                        artist: track.artist,
                                        artworkURL: track.artworkURL,
                                        tracks: [track]))
        }
        return songs
    }

    /// Album grouping is only used for very long lists, where one slot per song
    /// would build an impractically large looping carousel.
    static func albums(from tracks: [Track], source: AudioSource) -> [CoverFlowAlbum] {
        var uniqueTracks: [Track] = []
        var seenTracks = Set<String>()
        for track in tracks where track.source == source {
            if seenTracks.insert(track.id).inserted { uniqueTracks.append(track) }
        }

        // A missing image can join a known album when its title/artist identify
        // exactly one artwork group. Different known covers remain distinct.
        var artworkKeysByMetadata: [String: Set<String>] = [:]
        for track in uniqueTracks where hasAlbum(track) && track.artworkURL != nil {
            artworkKeysByMetadata[metadataKey(track), default: []].insert(albumKey(track))
        }

        var groups: [[Track]] = []
        var indices: [String: Int] = [:]
        var identities: [String] = []
        for track in uniqueTracks {
            let key: String
            let matchingArtwork = artworkKeysByMetadata[metadataKey(track)] ?? []
            if hasAlbum(track), track.artworkURL == nil,
               matchingArtwork.count == 1, let knownKey = matchingArtwork.first {
                key = knownKey
            } else {
                key = albumKey(track)
            }
            if let index = indices[key] {
                groups[index].append(track)
            } else {
                indices[key] = groups.count
                identities.append(key)
                groups.append([track])
            }
        }

        return groups.enumerated().map { index, tracks in
            let first = tracks[0]
            return CoverFlowAlbum(id: identities[index],
                                  title: hasAlbum(first) ? first.album : first.title,
                                  artist: first.artist,
                                  artworkURL: tracks.compactMap(\.artworkURL).first,
                                  tracks: tracks)
        }
    }

    func contains(_ track: Track) -> Bool {
        // Track membership survives /song/detail adding or changing artwork.
        tracks.contains { $0.source == track.source && $0.id == track.id }
            || id == Self.albumKey(track)
    }

    private static func hasAlbum(_ track: Track) -> Bool {
        let title = normalized(track.album)
        return !title.isEmpty && title != "未知专辑"
    }

    private static func metadataKey(_ track: Track) -> String {
        [track.source.rawValue, normalized(track.album), normalized(track.artist)].joined(separator: "\u{1F}")
    }

    private static func songKey(_ track: Track) -> String {
        [track.source.rawValue, "song", track.id].joined(separator: "\u{1F}")
    }

    private static func albumKey(_ track: Track) -> String {
        guard hasAlbum(track) else { return track.source.rawValue + "\u{1F}track\u{1F}" + track.id }
        if let artwork = track.artworkURL {
            // Query parameters commonly resize the same source image.
            var components = URLComponents(url: artwork, resolvingAgainstBaseURL: false)
            components?.query = nil
            components?.fragment = nil
            let imageIdentity = components?.string ?? artwork.absoluteString
            return [track.source.rawValue, normalized(track.album), imageIdentity].joined(separator: "\u{1F}")
        }
        return metadataKey(track)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
