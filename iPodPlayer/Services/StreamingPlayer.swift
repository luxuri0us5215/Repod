import AVFoundation
import Combine
import Foundation

/// AVPlayer is used only for server-provided NetEase streaming URLs.
@MainActor
final class StreamingPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsedSeconds = 0.0
    @Published private(set) var durationSeconds = 0.0
    var onError: ((String) -> Void)?
    var onEnded: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var terminalItemID: ObjectIdentifier?
    private var shouldResumeAfterInterruption = false
    /// `setCategory` describes the app, not the song, and `setActive(true)` only has to
    /// happen again after the system took the session away (an interruption, a media
    /// services reset, or an explicit stop). Doing both on every track change put two
    /// audio-session calls on the main thread at the exact moment the transition ran.
    private var isSessionConfigured = false
    private var isSessionActive = false

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            // Applied synchronously on the main queue. Hopping through a Task let a
            // reading for the previous item land after a track change, overwriting the
            // new track's zero position with the old song's progress.
            MainActor.assumeIsolated {
                self?.updateProgress(time)
            }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = self.isPlaybackRequested
            }
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                self?.finish(item, error: nil)
            }
        })
        notifications.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                self?.finish(item, error: "网络播放中断，请检查网络后重新选择歌曲。")
            }
        })
        notifications.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor [weak self] in
                guard let self, let type, let interruption = AVAudioSession.InterruptionType(rawValue: type) else { return }
                switch interruption {
                case .began:
                    self.shouldResumeAfterInterruption = self.player.timeControlStatus == .playing || self.isPlaying
                    self.player.pause()
                    self.isPlaying = false
                    // The system has taken the session; activation is needed again
                    // before this player can make sound.
                    self.isSessionActive = false
                case .ended:
                    let shouldResume = self.shouldResumeAfterInterruption
                        && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    self.shouldResumeAfterInterruption = false
                    if shouldResume { self.onInterruptionEnded?() }
                @unknown default:
                    self.shouldResumeAfterInterruption = false
                }
            }
        })
        notifications.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor [weak self] in self?.pause() }
            }
        })
        // The session is rebuilt from scratch after a media services reset, so the two
        // flags must not claim it is still configured.
        notifications.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSessionConfigured = false
                self?.isSessionActive = false
            }
        })
    }

    /// The category is set once per process; activation only when the session is not
    /// already ours. Both calls are cheap-ish but land on the main thread, and a track
    /// change does not need either of them.
    private func activateSessionIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        if !isSessionConfigured {
            try session.setCategory(.playback, mode: .default)
            isSessionConfigured = true
        }
        if !isSessionActive {
            try session.setActive(true)
            isSessionActive = true
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        statusObservation?.invalidate()
        controlObservation?.invalidate()
        for notification in notifications { NotificationCenter.default.removeObserver(notification) }
    }

    func play(url: URL) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw PlaybackError.invalidURL
        }
        try activateSessionIfNeeded()
        statusObservation?.invalidate()
        shouldResumeAfterInterruption = false
        terminalItemID = nil
        player.pause()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        elapsedSeconds = 0
        durationSeconds = 0
        isPlaying = false
        // The player is one instance for the whole process and a paused item may have
        // been parked anywhere. A new item belongs at its beginning, so state that
        // explicitly instead of relying on `replaceCurrentItem` to imply it.
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                if item.status == .failed {
                    self.finish(item, error: "无法播放此歌曲。请确认服务在线、歌曲有播放权限，并重新获取播放地址。")
                }
            }
        }
        player.play()
    }

    /// Opens the CDN host of an address that was resolved ahead of time, so the next
    /// track change does not pay DNS + TLS on its first bytes. In 歌曲 this matters
    /// more than anywhere else: the list is ordered by title, so consecutive songs
    /// live on unrelated hosts, while an album or a themed playlist tends to reuse one.
    ///
    /// Only the asset's header is asked for (whether it is playable) and the asset is
    /// then discarded — nothing is buffered, decoded or played, and no audio session
    /// call is involved. A failure is dropped in silence: the real item will open the
    /// connection itself, exactly as it did before.
    nonisolated static func warm(url: URL) async {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let asset = AVURLAsset(url: url)
        _ = try? await asset.load(.isPlayable)
    }

    func pause() {
        shouldResumeAfterInterruption = false
        player.pause()
        isPlaying = false
        updateProgress(player.currentTime())
    }

    var hasCurrentItem: Bool { player.currentItem != nil }

    func resume() throws {
        guard player.currentItem != nil else { return }
        shouldResumeAfterInterruption = false
        try activateSessionIfNeeded()
        if durationSeconds > 0, elapsedSeconds >= durationSeconds { player.seek(to: .zero) }
        player.play()
    }

    func seek(to seconds: Double) {
        guard player.currentItem != nil, seconds.isFinite,
              durationSeconds.isFinite, durationSeconds > 0 else { return }
        let target = min(durationSeconds, max(0, seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        elapsedSeconds = target
    }

    /// Replays the item that just finished instead of resolving its stream address
    /// again. The finished item is still attached to the player, so this starts
    /// instantly and cannot fail the way a second `/song/url` lookup can — a failed
    /// lookup is handled as a dead track and skips to the next song.
    @discardableResult
    func replay() -> Bool {
        guard let item = player.currentItem else { return false }
        shouldResumeAfterInterruption = false
        do { try activateSessionIfNeeded() }
        catch { return false }
        // finish() marked this item terminal; clearing it lets progress and
        // play/pause reporting start again for the new pass.
        terminalItemID = nil
        elapsedSeconds = 0
        isPlaying = true
        // Start inside the seek's completion. Calling play() while the item is
        // still parked at its end lets the seek finish first and leaves the player
        // paused — which is what made 单曲循环 stop instead of looping.
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item,
                      self.terminalItemID == nil else { return }
                self.player.play()
            }
        }
        return true
    }

    func stop(deactivateSession: Bool = false) {
        let hadItem = player.currentItem != nil
        pause()
        terminalItemID = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
        elapsedSeconds = 0
        durationSeconds = 0
        // Only deactivate the audio session on a true stop (queue end / give up),
        // not on a track change where playback resumes immediately.
        if deactivateSession, hadItem {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                isSessionActive = false
            } catch {
                // Still ours as far as this player is concerned; the next start retries.
            }
        }
    }

    private func finish(_ item: AVPlayerItem, error: String?) {
        guard item === player.currentItem else { return }
        let id = ObjectIdentifier(item)
        guard terminalItemID != id else { return }
        terminalItemID = id
        shouldResumeAfterInterruption = false
        if error != nil { player.pause() }
        isPlaying = false
        if let error { onError?(error) }
        else { onEnded?() }
    }

    /// `time` is accepted for the observer's signature but deliberately not trusted:
    /// it was sampled for the item the observer fired on, and a tick queued for the
    /// previous song can still be delivered after a track change. Taking that value
    /// wrote the old song's position onto the new one, and a following resume, retry or
    /// relaunch then used it as a start position — the "starts mid-song" report. The
    /// player's own reading always describes the item attached right now, and is zero
    /// when there is none.
    private func updateProgress(_ time: CMTime) {
        let reading = player.currentTime()
        let rawDuration = player.currentItem?.duration.seconds ?? 0
        let duration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : 0
        var elapsed = reading.seconds.isFinite ? max(0, reading.seconds) : 0
        if duration > 0 { elapsed = min(elapsed, duration) }
        let playing = isPlaybackRequested
        // @Published emits on every assignment, equal or not, and the view model
        // combines all three: unconditional writes ran its sink four times a tick.
        let durationChanged = durationSeconds != duration
        if durationChanged { durationSeconds = duration }
        // A pending resume seek reads the stored duration back, which @Published
        // only updates after emitting. The elapsed write that follows a new duration
        // is the emission that sees it, so it must happen even at an equal position.
        if durationChanged || elapsedSeconds != elapsed { elapsedSeconds = elapsed }
        if isPlaying != playing { isPlaying = playing }
    }

    /// `.waitingToPlayAtSpecifiedRate` is a buffering pause, not a user pause:
    /// reporting it as stopped made a one-second network hiccup look like a pause.
    private var isPlaybackRequested: Bool {
        guard let item = player.currentItem else { return false }
        if let terminalItemID, ObjectIdentifier(item) == terminalItemID { return false }
        return player.timeControlStatus != .paused
    }

    private enum PlaybackError: LocalizedError {
        case invalidURL
        var errorDescription: String? { "歌曲没有可用的网络播放地址。" }
    }
}
