import AVFoundation
import AudioToolbox
import CoreHaptics
import UIKit

/// Shared haptics, with gentle keyboard UI sounds for wheel steps and key taps.
///
/// The engine can be stopped behind our back: a phone call or Siri takes the
/// audio session, the app is suspended for a while, the system resets media
/// services, or a scene-phase change never arrives. Every one of those used to
/// leave the engine marked as unusable — or, worse, left an interrupted flag
/// that silently swallowed every later tick — until the app was relaunched.
/// So this engine is self-healing: any stop tears the engine down, a failed
/// start retries on a short backoff, and every user interaction gets one more
/// chance to bring it back.
@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    private var engine: CHHapticEngine?
    private var tickPlayer: CHHapticPatternPlayer?
    private var isRunning = false
    private var isActive = false
    private var runningSince: TimeInterval = 0
    private var retryCount = 0
    private var recoveryTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let fallback = UIImpactFeedbackGenerator(style: .heavy)
    private var clickSound: SystemSoundID = 1155
    private var scrollSound: SystemSoundID = 1104

    /// Short retry ladder for a stopped or failed engine. Waiting for the
    /// interruption-ended notification alone is not enough: several kinds of
    /// interruption never deliver it.
    private static let recoveryDelays: [Double] = [0.2, 0.6, 1.5, 4]

    /// A freshly started engine can drop the very first short pattern, so a
    /// tick inside this window uses the impact generator instead of going mute.
    private static let warmUpDuration: TimeInterval = 0.15

    private init() {
        prepareKeyboardSounds()
        observeInterruptions()
        observeApplicationState()
        observeMediaServices()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else {
            if active { fallback.prepare() }
            return
        }
        isActive = active
        if active {
            retryCount = 0
            startIfNeeded()
            fallback.prepare()
        } else {
            recoveryTask?.cancel()
            recoveryTask = nil
            resetEngine()
        }
    }

    func prepare() {
        adoptActiveStateIfNeeded()
        guard isActive else { return }
        startIfNeeded()
        fallback.prepare()
    }

    func tick() {
        adoptActiveStateIfNeeded()
        guard isActive else { return }
        if startIfNeeded() == .running, let engine, isWarm {
            do {
                // Reuse one pattern/player instead of rebuilding both per tick.
                if tickPlayer == nil {
                    // One sharp transient gives the tick a clean edge without a springy tail.
                    let strike = CHHapticEvent(eventType: .hapticTransient, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    ], relativeTime: 0)
                    let pattern = try CHHapticPattern(events: [strike], parameters: [])
                    tickPlayer = try engine.makePlayer(with: pattern)
                }
                try tickPlayer?.start(atTime: CHHapticTimeImmediate)
                return
            } catch {
                // A reset, suspension or route change can invalidate the player
                // while the engine still claims to be running. Rebuild both.
                resetEngine()
                scheduleRecovery()
            }
        }
        // Either the engine was just started (a cold engine can swallow the
        // first pattern) or it is unavailable right now. The impact generator
        // is always warm and fires immediately, so the interaction still ticks.
        fallback.impactOccurred(intensity: 1.0)
        fallback.prepare()
    }

    func click() {
        adoptActiveStateIfNeeded()
        guard isActive else { return }
        AudioServicesPlaySystemSound(clickSound)
    }

    func scrollClick() {
        adoptActiveStateIfNeeded()
        guard isActive else { return }
        AudioServicesPlaySystemSound(scrollSound)
    }

    private func prepareKeyboardSounds() {
        // Built-in UI sounds obey Ring/Silent without touching the playback session.
        var isUISound: UInt32 = 1
        for sound in [clickSound, scrollSound] {
            var soundID = sound
            AudioServicesSetProperty(kAudioServicesPropertyIsUISound,
                                    UInt32(MemoryLayout<SystemSoundID>.size), &soundID,
                                    UInt32(MemoryLayout<UInt32>.size), &isUISound)
        }
    }

    // MARK: - Engine lifecycle

    private enum StartResult {
        case running, started, failed
    }

    @discardableResult
    private func startIfNeeded() -> StartResult {
        guard isActive else { return .failed }
        if isRunning, engine != nil { return .running }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return .failed }
        do {
            let hapticEngine: CHHapticEngine
            if let engine {
                hapticEngine = engine
            } else {
                hapticEngine = try makeEngine()
                engine = hapticEngine
            }
            try hapticEngine.start()
            isRunning = true
            runningSince = ProcessInfo.processInfo.systemUptime
            retryCount = 0
            return .started
        } catch {
            // A failed start can leave the engine unusable (media services
            // reset, server error). Throw it away and rebuild on the retry.
            resetEngine()
            scheduleRecovery()
            return .failed
        }
    }

    private func makeEngine() throws -> CHHapticEngine {
        let newEngine = try CHHapticEngine()
        newEngine.playsHapticsOnly = true
        // Keep it alive between ticks; a shutdown engine silently drops patterns.
        newEngine.isAutoShutdownEnabled = false
        newEngine.resetHandler = { [weak self, weak newEngine] in
            Task { @MainActor [weak self, weak newEngine] in
                guard let self, let newEngine, self.engine === newEngine else { return }
                self.resetEngine()
                self.scheduleRecovery()
            }
        }
        newEngine.stoppedHandler = { [weak self, weak newEngine] _ in
            Task { @MainActor [weak self, weak newEngine] in
                guard let self, let newEngine, self.engine === newEngine else { return }
                self.resetEngine()
                // Covers interruptions whose `ended` notification never comes.
                self.scheduleRecovery()
            }
        }
        return newEngine
    }

    private func resetEngine() {
        isRunning = false
        runningSince = 0
        tickPlayer = nil
        let engine = self.engine
        self.engine = nil
        engine?.stop(completionHandler: nil)
    }

    private var isWarm: Bool {
        isRunning && runningSince > 0
            && ProcessInfo.processInfo.systemUptime - runningSince >= Self.warmUpDuration
    }

    private func scheduleRecovery() {
        guard isActive, recoveryTask == nil, retryCount < Self.recoveryDelays.count else { return }
        let delay = Self.recoveryDelays[retryCount]
        retryCount += 1
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.recoveryTask = nil
            guard self.isActive else { return }
            if self.startIfNeeded() == .failed {
                self.scheduleRecovery()
            }
        }
    }

    private func recoverNow() {
        recoveryTask?.cancel()
        recoveryTask = nil
        retryCount = 0
        guard isActive else { return }
        if startIfNeeded() == .failed {
            scheduleRecovery()
        }
    }

    // MARK: - State

    /// `scenePhase` drives `setActive`, but it can miss a transition (and the
    /// initial `onAppear` can run while the scene is still inactive). When the
    /// app is demonstrably active but we think otherwise, adopt the truth
    /// instead of swallowing the tick.
    private func adoptActiveStateIfNeeded() {
        guard !isActive, UIApplication.shared.applicationState == .active else { return }
        isActive = true
        retryCount = 0
    }

    private func observeApplicationState() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setActive(true) }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setActive(false) }
        })
    }

    private func observeInterruptions() {
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let rawType = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            Task { @MainActor [weak self] in
                guard let self, let rawType,
                      let interruption = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                switch interruption {
                case .began:
                    // The system stops the engine; drop the stale engine so the
                    // retry starts from a clean state.
                    self.resetEngine()
                    self.scheduleRecovery()
                case .ended:
                    self.recoverNow()
                @unknown default:
                    self.scheduleRecovery()
                }
            }
        })
    }

    private func observeMediaServices() {
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Every existing engine and player is invalid after a reset.
                self.resetEngine()
                self.recoverNow()
            }
        })
    }
}
