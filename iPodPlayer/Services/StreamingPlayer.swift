import AVFoundation
import Combine
import Foundation
import UIKit

/// AVPlayer is used only for server-provided NetEase streaming URLs.
@MainActor
final class StreamingPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsedSeconds = 0.0
    @Published private(set) var durationSeconds = 0.0
    var onError: ((String) -> Void)?
    var onEnded: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?

    /// 3.1.15: a queue player, so the next song can be attached and buffering while
    /// this one plays (see `preload`). It advances by itself only while such an item
    /// is queued; otherwise it parks at the end of the item, exactly like the plain
    /// `AVPlayer` it replaces, which `replay()` and `resume()` rely on.
    private let player = AVQueuePlayer()
    /// The item this player reports on. Usually `player.currentItem`; for the few
    /// milliseconds after a gapless hand-over the queue player is already playing the
    /// next item while the view model still describes the old song.
    private var activeItem: AVPlayerItem?
    /// The next song, attached behind the active item and buffering.
    private var preloaded: (item: AVPlayerItem, trackID: String)?
    /// The preloaded item after the queue player moved onto it, waiting for the view
    /// model's `play(url:trackID:)` (or `prepareForTrackChange`) to claim it.
    private var handedOver: (item: AVPlayerItem, trackID: String)?
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
    /// 3.1.12: `setActive` can block for a long time (Xcode's "AVAudioSession Hang
    /// Risk"), so activation and deactivation run here, off the main thread. One
    /// serial queue keeps a stop's deactivation ahead of the next start's activation.
    private nonisolated static let sessionQueue = DispatchQueue(
        label: ((Bundle.main.bundleIdentifier ?? "repod") + ".audio-session"), qos: .userInitiated
    )

    init() {
        // A plain AVPlayer parks at the end of an item; keep that unless something
        // is queued behind it.
        player.actionAtItemEnd = .pause
        installTimeObserver(interval: Self.foregroundTick)
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
        // 3.2.8: on the lock screen nobody sees the progress bar, and the system card
        // projects the position on its own. Four readings a second there only woke
        // the main thread (and the progress chain behind it) for nothing; one a second
        // still keeps the 3 s preload mark and the saved position on time.
        notifications.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.installTimeObserver(interval: Self.backgroundTick) }
        })
        notifications.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.installTimeObserver(interval: Self.foregroundTick) }
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
    /// already ours. A track change needs neither.
    ///
    /// The category stays synchronous: it is set once, and it must be in place before
    /// the first `play()` so the song keeps playing in the background and through the
    /// silent switch. Activation is queued off the main thread; AVPlayer can start
    /// meanwhile, and a failed activation is simply retried on the next start.
    private func activateSessionIfNeeded() throws {
        if !isSessionConfigured {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            isSessionConfigured = true
        }
        guard !isSessionActive else { return }
        isSessionActive = true
        // A strong capture (the player is main-actor isolated, so it is Sendable)
        // avoids a captured `weak var` in concurrent code; it lives only until
        // activation returns.
        Self.sessionQueue.async { [self] in
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                Task { @MainActor in self.isSessionActive = false }
            }
        }
    }

    /// Progress readings: four a second on screen, one a second in the background.
    private nonisolated static let foregroundTick: Double = 0.25
    private nonisolated static let backgroundTick: Double = 1
    private var timeObserverInterval: Double = 0

    /// (Re)installs the periodic progress reading at `interval`.
    private func installTimeObserver(interval: Double) {
        guard interval != timeObserverInterval else { return }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserverInterval = interval
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: interval, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            // Applied synchronously on the main queue. Hopping through a Task let a
            // reading for the previous item land after a track change, overwriting the
            // new track's zero position with the old song's progress.
            MainActor.assumeIsolated {
                self?.updateProgress(time)
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        statusObservation?.invalidate()
        controlObservation?.invalidate()
        for notification in notifications { NotificationCenter.default.removeObserver(notification) }
    }

    /// Starts `url`. When `trackID` names the song that was preloaded and the queue
    /// player has already moved onto it (a natural end) — or can move onto it right
    /// now (a skip to the next song) — that buffered item is adopted instead of a new
    /// one being opened, so the song starts without a gap.
    func play(url: URL, trackID: String? = nil) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw PlaybackError.invalidURL
        }
        try activateSessionIfNeeded()
        if let trackID, claimPreloadedItem(for: trackID) {
            adoptHandedOverItem()
            return
        }
        statusObservation?.invalidate()
        shouldResumeAfterInterruption = false
        terminalItemID = nil
        clearPreload()
        handedOver = nil
        player.pause()
        let item = AVPlayerItem(url: url)
        player.removeAllItems()
        player.insert(item, after: nil)
        activeItem = item
        elapsedSeconds = 0
        durationSeconds = 0
        isPlaying = false
        // The player is one instance for the whole process and a paused item may have
        // been parked anywhere. A new item belongs at its beginning, so state that
        // explicitly instead of relying on the queue change to imply it.
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        observeStatus(of: item)
        player.play()
    }

    // MARK: Gapless preload (3.1.15)

    /// The song the view model asked to have ready next, if it is still queued.
    var preloadedTrackID: String? { preloaded?.trackID }

    /// Attaches the next song behind the one playing, so the queue player buffers it
    /// in advance and moves onto it the instant this one ends. This replaces the old
    /// "warm the CDN host" probe: the item itself opens the connection, and the
    /// silence between songs (and the round trip after a natural end, which happened
    /// in the background on a locked phone) goes away.
    ///
    /// The caller withdraws it (`cancelPreload`) whenever the next song changes —
    /// a new queue, shuffle, 单曲循环 — so the queue player can never move onto a
    /// song the view model is not going to play.
    func preload(url: URL, trackID: String) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              let active = activeItem, active === player.currentItem,
              terminalItemID != ObjectIdentifier(active) else { return }
        if preloaded?.trackID == trackID { return }
        clearPreload()
        let item = AVPlayerItem(url: url)
        guard player.canInsert(item, after: active) else { return }
        player.insert(item, after: active)
        preloaded = (item, trackID)
        player.actionAtItemEnd = .advance
    }

    /// Takes the queued next song back out. The current song then parks at its end
    /// again, as it did before preloading existed.
    func cancelPreload() {
        clearPreload()
    }

    /// Called by the view model before it starts resolving a new song. The buffered
    /// next song survives (and a skip moves onto it at once); any other change stops
    /// the player exactly as `stop()` always did.
    func prepareForTrackChange(toTrackID trackID: String?) {
        if let trackID, claimPreloadedItem(for: trackID) { return }
        stop()
    }

    /// True when `trackID`'s preloaded item is (now) the queue player's current item.
    private func claimPreloadedItem(for trackID: String) -> Bool {
        if let handedOver, handedOver.trackID == trackID, handedOver.item === player.currentItem {
            return true
        }
        guard let next = preloaded, next.trackID == trackID,
              let active = activeItem, active === player.currentItem,
              player.items().count > 1, player.items()[1] === next.item else { return false }
        // A skip to the very song that is buffering: move onto it now.
        preloaded = nil
        handedOver = next
        player.advanceToNextItem()
        return player.currentItem === next.item
    }

    /// Makes the handed-over item the one this player reports on, and plays it.
    private func adoptHandedOverItem() {
        guard let next = handedOver else { return }
        handedOver = nil
        statusObservation?.invalidate()
        shouldResumeAfterInterruption = false
        terminalItemID = nil
        activeItem = next.item
        player.actionAtItemEnd = .pause
        observeStatus(of: next.item)
        player.play()
        // Publishes the new item's position and duration straight away; it may
        // already be a fraction of a second in.
        updateProgress(player.currentTime())
    }

    private func clearPreload() {
        if let next = preloaded, next.item !== player.currentItem,
           player.items().contains(where: { $0 === next.item }) {
            player.remove(next.item)
        }
        preloaded = nil
        player.actionAtItemEnd = .pause
    }

    private func observeStatus(of item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, item === self.activeItem else { return }
                if item.status == .failed {
                    self.finish(item, error: "无法播放此歌曲。请确认服务在线、歌曲有播放权限，并重新获取播放地址。")
                }
            }
        }
    }

    func pause() {
        shouldResumeAfterInterruption = false
        player.pause()
        isPlaying = false
        updateProgress(player.currentTime())
    }

    var hasCurrentItem: Bool { activeItem != nil && activeItem === player.currentItem }

    func resume() throws {
        guard let item = activeItem, item === player.currentItem else { return }
        shouldResumeAfterInterruption = false
        try activateSessionIfNeeded()
        if durationSeconds > 0, elapsedSeconds >= durationSeconds { player.seek(to: .zero) }
        player.play()
    }

    func seek(to seconds: Double) {
        guard let item = activeItem, item === player.currentItem, seconds.isFinite,
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
        // After a gapless hand-over the current item is already the next song; there
        // is nothing of the finished one left to rewind.
        guard let item = activeItem, item === player.currentItem else { return false }
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
        preloaded = nil
        handedOver = nil
        activeItem = nil
        // A queue player keeps queued items through `replaceCurrentItem(nil)`.
        player.removeAllItems()
        player.actionAtItemEnd = .pause
        elapsedSeconds = 0
        durationSeconds = 0
        // Only deactivate the audio session on a true stop (queue end / give up),
        // not on a track change where playback resumes immediately.
        if deactivateSession, hadItem {
            // Off the main thread for the same reason as activation. Marked inactive
            // now, so the next start queues its activation behind this one.
            isSessionActive = false
            Self.sessionQueue.async {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func finish(_ item: AVPlayerItem, error: String?) {
        guard item === activeItem else { return }
        let id = ObjectIdentifier(item)
        guard terminalItemID != id else { return }
        terminalItemID = id
        shouldResumeAfterInterruption = false
        if error != nil {
            // A failed song is retried or skipped by the view model; it must not slide
            // into the preloaded one on its own.
            clearPreload()
            player.pause()
        } else if let next = preloaded {
            // The queue player is moving (or has moved) onto the buffered song. Hold it
            // for the view model's track change to claim.
            preloaded = nil
            if player.items().contains(where: { $0 === next.item }) { handedOver = next }
        }
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
        // Between a gapless hand-over and its adoption the queue player is already on
        // the next song; reporting its position would put it on the old one.
        guard player.currentItem === activeItem else { return }
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
        // A handed-over next song is not the terminal item, so it reports as playing
        // and a gapless natural end does not read as a pause.
        if let terminalItemID, ObjectIdentifier(item) == terminalItemID { return false }
        return player.timeControlStatus != .paused
    }

    private enum PlaybackError: LocalizedError {
        case invalidURL
        var errorDescription: String? { "歌曲没有可用的网络播放地址。" }
    }
}
