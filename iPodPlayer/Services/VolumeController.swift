import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// One system volume shared by NetEase and Spotify. SystemVolumeView mounts
/// the slider on Now Playing; AVAudioSession observation continues on every screen.
@MainActor
final class VolumeController {
    let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 120, height: 24))
    private(set) var systemVolume = AVAudioSession.sharedInstance().outputVolume
    private var volumeObservation: NSKeyValueObservation?
    private var wheelTarget: Float?

    var outputVolume: Float { AVAudioSession.sharedInstance().outputVolume }

    init() {
        volumeView.isUserInteractionEnabled = false
        volumeView.accessibilityElementsHidden = true
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            // KVO is a signal, not a snapshot: several changes may be queued
            // before this MainActor task runs, so read the live system value.
            Task { @MainActor [weak self] in self?.systemVolumeChanged() }
        }
    }

    private func systemVolumeChanged() {
        // Observation synchronizes state only. It must never overwrite the
        // active gesture's accumulator or its displayed target.
        systemVolume = outputVolume
    }

    func adjustVolume(by delta: Float) -> Float {
        // A new turn starts at the audible system level, even when Spotify owns
        // the audio session and this app receives no volume KVO notifications.
        if wheelTarget == nil { systemVolumeChanged() }
        let target = min(1, max(0, (wheelTarget ?? systemVolume) + delta))
        // Own the target before sending the slider event: iOS may refresh the
        // slider or report an intermediate/duplicate system value at any time.
        wheelTarget = target
        setVolume(target)
        return target
    }

    func endWheelAdjustment() {
        wheelTarget = nil
        systemVolumeChanged()
    }

    func setVolume(_ value: Float) {
        volumeView.layoutIfNeeded()
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        let target = min(1, max(0, value))
        slider.setValue(target, animated: false)
        slider.sendActions(for: .valueChanged)
    }
}

@MainActor
struct SystemVolumeView: UIViewRepresentable {
    let controller: VolumeController

    func makeUIView(context: Context) -> MPVolumeView {
        let view = controller.volumeView
        view.layoutIfNeeded()
        // Volume may have changed while this view was absent on a list screen.
        // Refresh the wheel's starting value without writing to the system.
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.setValue(controller.outputVolume, animated: false)
        }
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) { }
}
