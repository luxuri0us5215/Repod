import Foundation

// MARK: - 3.2 lyrics for the immersive Now Playing
//
// NetEase songs ask NetEase first (`/lyric`, which also carries its Chinese
// translation of foreign songs). Spotify songs, and NetEase songs NetEase has no
// timed lyrics for, ask LRCLIB (lrclib.net): free, no key, synced LRC.

/// What NetEase's `/lyric` answered.
struct NetEaseLyricPayload {
    let lyric: String?
    let translation: String?
    /// `nolyric` / `pureMusic`: NetEase knows the song has no words.
    let isInstrumental: Bool
}

/// One line of a song's lyrics.
struct LyricLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case words
        /// A long instrumental stretch: drawn as three breathing dots.
        case interlude
    }

    let id: Int
    /// Seconds into the song (0 for plain, untimed lyrics).
    let time: Double
    let text: String
    var translation: String?
    var kind: Kind = .words
}

struct Lyrics: Equatable {
    enum Timing: Equatable {
        case synced
        /// Words without times: shown as a still page the thumb can scroll.
        case plain
    }

    let trackKey: String
    let timing: Timing
    let lines: [LyricLine]

    /// The last line whose time has come; nil before the first line (or untimed).
    func activeIndex(at time: Double) -> Int? {
        guard timing == .synced, let first = lines.first, time >= first.time else { return nil }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].time <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    static func == (lhs: Lyrics, rhs: Lyrics) -> Bool {
        lhs.trackKey == rhs.trackKey && lhs.timing == rhs.timing && lhs.lines.count == rhs.lines.count
    }
}

enum LyricsState: Equatable {
    case idle
    case loading(String)
    case loaded(Lyrics)
    case instrumental(String)
    case unavailable(String)

    var trackKey: String? {
        switch self {
        case .idle: return nil
        case .loading(let key), .instrumental(let key), .unavailable(let key): return key
        case .loaded(let lyrics): return lyrics.trackKey
        }
    }

    var lyrics: Lyrics? {
        if case .loaded(let lyrics) = self { return lyrics }
        return nil
    }
}

/// Owns the current song's lyrics. Its own observable object, like `PlaybackClock`,
/// so a lyrics answer repaints only the lyrics views, never the lists.
///
/// 3.2.8: one lookup per song, shared by `load` (the song on screen) and `prefetch`
/// (the next song, fetched ahead so its lyrics are there when it starts). The
/// network and the parsing run off the main thread; only the finished state is
/// published here.
@MainActor
final class LyricsStore: ObservableObject {
    @Published private(set) var state: LyricsState = .idle

    private var cache: [String: LyricsState] = [:]
    private var cacheOrder: [String] = []
    private static let cacheLimit = 40
    /// Lookups travelling, by song key.
    private var inFlight: [String: (id: UUID, task: Task<Outcome, Never>)] = [:]
    /// The song `prefetch` asked for: kept travelling when the screen moves on.
    private var prefetchKey: String?
    /// Waits for the shown song's lookup and publishes it.
    private var displayTask: Task<Void, Never>?

    typealias NetEaseLyricFetch = @MainActor (String) async throws -> NetEaseLyricPayload

    static func key(for track: Track) -> String { track.source.rawValue + ":" + track.id }

    /// Whether `track`'s answer is already here (so a prefetch would do nothing).
    func hasAnswer(for track: Track) -> Bool {
        let key = Self.key(for: track)
        return cache[key] != nil || inFlight[key] != nil
    }

    /// Shows `track`'s lyrics: from the cache, from a lookup already travelling
    /// (a prefetch), or from a new one.
    func load(_ track: Track?, netEase: @escaping NetEaseLyricFetch) {
        guard let track else {
            displayTask?.cancel()
            dropUnwantedLookup(state.trackKey)
            state = .idle
            return
        }
        let key = Self.key(for: track)
        if case .loading(let loadingKey) = state, loadingKey == key { return }
        let previousKey = state.trackKey
        displayTask?.cancel()
        displayTask = nil
        if previousKey != key { dropUnwantedLookup(previousKey) }
        if let cached = cache[key] {
            state = cached
            return
        }
        // A podcast episode's id names a DJ audio asset, not a song.
        guard !track.isPodcastEpisode else {
            state = .unavailable(key)
            return
        }
        state = .loading(key)
        let lookup = lookup(track, key: key, netEase: netEase)
        displayTask = Task { [weak self] in
            let outcome = await lookup.value
            guard !Task.isCancelled, let self, self.state.trackKey == key else { return }
            self.state = outcome.state
        }
    }

    /// Fetches `track`'s lyrics into the cache without showing them.
    func prefetch(_ track: Track, netEase: @escaping NetEaseLyricFetch) {
        guard !track.isPodcastEpisode, !hasAnswer(for: track) else { return }
        let key = Self.key(for: track)
        prefetchKey = key
        _ = lookup(track, key: key, netEase: netEase)
    }

    /// A song skipped past while its lyrics were still loading: stop asking, unless
    /// it is the prefetched next song. (Quickly skipping through ten songs should
    /// not leave ten lyric requests queued behind the next song's address.)
    private func dropUnwantedLookup(_ key: String?) {
        guard let key, key != prefetchKey, let travelling = inFlight[key] else { return }
        travelling.task.cancel()
        inFlight[key] = nil
    }

    private func lookup(_ track: Track, key: String, netEase: @escaping NetEaseLyricFetch) -> Task<Outcome, Never> {
        if let travelling = inFlight[key] { return travelling.task }
        let id = UUID()
        let task = Task<Outcome, Never> { [weak self] in
            // `fetch` is nonisolated: the requests' replies are decoded and the LRC
            // parsed on a background thread, not on the main thread where the song
            // change is animating.
            let outcome = await Self.fetch(track: track, key: key, netEase: netEase)
            guard let self else { return outcome }
            if self.inFlight[key]?.id == id { self.inFlight[key] = nil }
            if self.prefetchKey == key { self.prefetchKey = nil }
            // A network failure is not an answer: the next visit asks again.
            if outcome.isDefinitive, !Task.isCancelled { self.remember(outcome.state, for: key) }
            return outcome
        }
        inFlight[key] = (id, task)
        return task
    }

    private func remember(_ state: LyricsState, for key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = state
        while cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    struct Outcome {
        let state: LyricsState
        let isDefinitive: Bool
    }

    private nonisolated static func fetch(track: Track, key: String,
                                          netEase: NetEaseLyricFetch) async -> Outcome {
        var networkFailed = false
        if track.source == .netease {
            do {
                let payload = try await netEase(track.id)
                if payload.isInstrumental { return Outcome(state: .instrumental(key), isDefinitive: true) }
                if let lyric = payload.lyric {
                    let state = LyricsBuilder.state(key: key, lyric: lyric, translation: payload.translation)
                    if case .unavailable = state {} else { return Outcome(state: state, isDefinitive: true) }
                }
            } catch is CancellationError {
                return Outcome(state: .unavailable(key), isDefinitive: false)
            } catch {
                networkFailed = true
            }
        }
        guard !Task.isCancelled else { return Outcome(state: .unavailable(key), isDefinitive: false) }
        do {
            if let state = try await LRCLib.lookup(track: track, key: key) {
                return Outcome(state: state, isDefinitive: true)
            }
            return Outcome(state: .unavailable(key), isDefinitive: !networkFailed)
        } catch {
            return Outcome(state: .unavailable(key), isDefinitive: false)
        }
    }
}

// MARK: - Building lines

enum LyricsBuilder {
    /// A stretch this long between two lines (or before the first) gets the dots.
    static let interludeGap: Double = 8

    static func state(key: String, lyric: String, translation: String?) -> LyricsState {
        let entries = LRCParser.entries(lyric).filter { !isCredit($0.text) }
        let words = entries.filter { !$0.text.isEmpty }
        guard !words.isEmpty else {
            // Text that carries no time tags at all is still lyrics, just untimed.
            let plain = LRCParser.untimedLines(lyric).filter { !isCredit($0) }
            guard !plain.isEmpty else { return .unavailable(key) }
            return plainState(key: key, lines: plain)
        }
        if words.count <= 2, words.contains(where: { isInstrumentalNote($0.text) }) {
            return .instrumental(key)
        }

        var translations: [Int: String] = [:]
        if let translation {
            for entry in LRCParser.entries(translation) where !isCredit(entry.text) {
                let text = entry.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, text != "//" else { continue }
                translations[Int((entry.time * 100).rounded())] = text
            }
        }

        var lines: [LyricLine] = []
        func append(_ time: Double, _ text: String, _ kind: LyricLine.Kind) {
            var line = LyricLine(id: lines.count, time: time, text: text, kind: kind)
            if kind == .words { line.translation = matchTranslation(near: time, in: translations) }
            lines.append(line)
        }

        if let first = words.first, first.time >= interludeGap {
            append(0, "", .interlude)
        }
        for (index, entry) in entries.enumerated() {
            let nextWordsTime = entries[(index + 1)...].first(where: { !$0.text.isEmpty })?.time
            if entry.text.isEmpty {
                // An empty timed line is the song's own "music only" marker.
                if let next = nextWordsTime, next - entry.time >= interludeGap,
                   lines.last?.kind != .interlude, !lines.isEmpty {
                    append(entry.time, "", .interlude)
                }
                continue
            }
            append(entry.time, entry.text, .words)
            // A long silence with no marker: the line holds for a while, then the dots.
            if let next = nextWordsTime, next - entry.time >= interludeGap * 2,
               entries[index + 1].text.isEmpty == false {
                append(entry.time + interludeGap * 0.75, "", .interlude)
            }
        }
        guard lines.contains(where: { $0.kind == .words }) else { return .unavailable(key) }
        return .loaded(Lyrics(trackKey: key, timing: .synced, lines: lines))
    }

    static func plainState(key: String, lines: [String]) -> LyricsState {
        let built = lines.enumerated().map { LyricLine(id: $0.offset, time: 0, text: $0.element) }
        return .loaded(Lyrics(trackKey: key, timing: .plain, lines: built))
    }

    /// Translations are timed like the original but not always to the hundredth.
    private static func matchTranslation(near time: Double, in table: [Int: String]) -> String? {
        let centi = Int((time * 100).rounded())
        if let exact = table[centi] { return exact }
        for delta in 1...3 {
            if let close = table[centi - delta] ?? table[centi + delta] { return close }
        }
        return nil
    }

    private static let creditWords = [
        "作词", "作曲", "编曲", "制作", "作詞", "編曲", "製作", "混音", "和声", "和聲",
        "录音", "錄音", "母带", "母帶", "监制", "監製", "出品", "发行", "發行", "企划", "企劃",
        "策划", "統籌", "统筹", "吉他", "贝斯", "貝斯", "鼓", "弦乐", "弦樂", "配唱", "人声", "人聲",
        "lyric", "compos", "arrang", "produc", "written", "mix", "master", "record", "vocal", "guitar", "bass", "drum"
    ]

    /// "作词 : 方文山", "Composer: …": the credits NetEase puts in the lyric itself.
    static func isCredit(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[..<colon].lowercased()
        guard label.count <= 16 else { return false }
        return creditWords.contains { label.contains($0) }
    }

    private static func isInstrumentalNote(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return text.contains("纯音乐") || text.contains("純音樂") || lowered.contains("instrumental")
    }
}

// MARK: - LRC

enum LRCParser {
    struct Entry {
        let time: Double
        let text: String
    }

    static func entries(_ raw: String) -> [Entry] {
        var offset = 0.0
        var found: [(order: Int, entry: Entry)] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("{") {
                // NetEase's newer credit lines: {"t":0,"c":[{"tx":"作词: "},{"tx":"…"}]}
                if let entry = jsonEntry(line) { found.append((found.count, entry)) }
                continue
            }
            var rest = Substring(line)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = timestamp(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let milliseconds = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = milliseconds / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for time in times { found.append((found.count, Entry(time: time, text: text))) }
        }
        // A positive [offset:] means the words come sooner.
        return found
            .sorted { $0.entry.time == $1.entry.time ? $0.order < $1.order : $0.entry.time < $1.entry.time }
            .map { Entry(time: max(0, $0.entry.time - offset), text: $0.entry.text) }
    }

    /// Lines of a lyric that has no time tags (metadata tags dropped).
    static func untimedLines(_ raw: String) -> [String] {
        raw.components(separatedBy: .newlines).compactMap { rawLine in
            var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                line = line[line.index(after: close)...]
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.isEmpty || text.hasPrefix("{") ? nil : text
        }
    }

    /// mm:ss, mm:ss.xx, mm:ss.xxx or mm:ss:xx.
    static func timestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber),
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else { return nil }
        var fraction = 0.0
        if parts.count == 3 {
            guard parts[2].allSatisfy(\.isNumber), let value = Double("0." + parts[2]) else { return nil }
            fraction = value
        }
        return minutes * 60 + seconds + fraction
    }

    private static func jsonEntry(_ line: String) -> Entry? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let milliseconds = (object["t"] as? NSNumber)?.doubleValue,
              let pieces = object["c"] as? [[String: Any]] else { return nil }
        let text = pieces.compactMap { $0["tx"] as? String }.joined()
            .trimmingCharacters(in: .whitespaces)
        return Entry(time: milliseconds / 1000, text: text)
    }
}

// MARK: - LRCLIB

enum LRCLib {
    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: configuration)
    }()

    static func lookup(track: Track, key: String) async throws -> LyricsState? {
        let title = track.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        let primaryArtist = track.artist
            .components(separatedBy: CharacterSet(charactersIn: ",、&/;"))
            .first?.trimmingCharacters(in: .whitespaces) ?? track.artist

        // 1. The exact signature (title, artist, album, length).
        var items = [URLQueryItem(name: "track_name", value: title),
                     URLQueryItem(name: "artist_name", value: track.artist)]
        if !track.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: track.album)) }
        if track.duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))) }
        if let record: Record = try await get("https://lrclib.net/api/get", items),
           let state = state(from: record, key: key) {
            return state
        }

        // 2. A search, keeping only versions of about the same length.
        let found: [Record] = try await get("https://lrclib.net/api/search", [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: primaryArtist)
        ]) ?? []
        let fitting = found.filter { record in
            guard track.duration > 0, let duration = record.duration else { return true }
            return abs(duration - track.duration) <= 3
        }
        let best = fitting.first { !($0.syncedLyrics ?? "").isEmpty }
            ?? fitting.first { $0.instrumental == true }
            ?? fitting.first { !($0.plainLyrics ?? "").isEmpty }
        return best.flatMap { state(from: $0, key: key) }
    }

    private static func state(from record: Record, key: String) -> LyricsState? {
        if let synced = record.syncedLyrics, !synced.isEmpty {
            let state = LyricsBuilder.state(key: key, lyric: synced, translation: nil)
            if case .unavailable = state {} else { return state }
        }
        if record.instrumental == true { return .instrumental(key) }
        if let plain = record.plainLyrics {
            let lines = LRCParser.untimedLines(plain)
            if !lines.isEmpty { return LyricsBuilder.plainState(key: key, lines: lines) }
        }
        return nil
    }

    /// nil for a 404 (LRCLIB's "no such song"); throws for anything else unexpected.
    private static func get<T: Decodable>(_ base: String, _ items: [URLQueryItem]) async throws -> T? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        // LRCLIB asks clients to say who they are.
        request.setValue("Repod/3.2 (personal iPod-style player)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200...299).contains(status) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
