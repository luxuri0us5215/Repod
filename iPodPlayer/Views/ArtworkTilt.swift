import CoreMotion
import SwiftUI

/// Turns the phone's tilt into a small, damped offset for the Now Playing cover.
///
/// The cover is a physical object on the screen: when the phone leans left the
/// card leans with it, and a highlight sweeps across the glass. The effect is
/// deliberately small — the artwork still reads as a flat square at rest, it just
/// gains a little depth while the phone moves.
///
/// Feeding it:
/// - gravity is measured relative to the pose the phone was in when Now Playing
///   opened, so the card starts level instead of inheriting the angle the phone
///   happened to be held at;
/// - a low-pass filter plus a dead zone keep hand tremor and a phone resting on a
///   table from making the cover shiver;
/// - it only runs while the screen is on and the app is in the foreground.
@MainActor
final class TiltDriver: ObservableObject {
    /// -1…1 on both axes: `width` is left/right lean, `height` is forward/back lean.
    @Published private(set) var offset: CGSize = .zero

    /// How much of gravity counts as a full lean. Tilting the phone by roughly a
    /// quarter of a turn reaches the clamp, which is well past the angles a thumb
    /// on the wheel actually produces.
    private static let gravityToUnit: CGFloat = 2.4
    private static let smoothing: CGFloat = 0.22
    /// Below this the tilt is treated as noise and the cover stays flat.
    private static let deadZone: CGFloat = 0.035
    private static let publishDelta: CGFloat = 0.004

    private let manager = CMMotionManager()
    private var baseline: CGPoint?
    private var smoothed: CGPoint = .zero
    private var isRunning = false
    private var autoTimer: Timer?
    private var autoPhase: Double = 0
    private var fixtureActive = false

    init() {
        #if DEBUG
        // The simulator has no gyroscope. A fixture pins the effect to a known
        // angle (or makes it oscillate) so the visuals can be checked in a
        // screenshot or a screen recording.
        if let raw = ProcessInfo.processInfo.environment["REPOD_FIXTURE_TILT"], !raw.isEmpty {
            fixtureActive = true
            if raw == "auto" {
                startAutoOscillation()
            } else {
                let parts = raw.split(separator: ",").compactMap {
                    Double($0.trimmingCharacters(in: .whitespaces))
                }
                if parts.count == 2 {
                    offset = CGSize(width: Self.clamp(CGFloat(parts[0])),
                                    height: Self.clamp(CGFloat(parts[1])))
                }
            }
        }
        #endif
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        guard !fixtureActive, !autoOscillating else { return }
        guard manager.isDeviceMotionAvailable else { return }
        baseline = nil
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let gravity = motion?.gravity else { return }
            Task { @MainActor [weak self] in
                self?.ingest(x: CGFloat(gravity.x), z: CGFloat(gravity.z))
            }
        }
    }

    func stop() {
        isRunning = false
        if manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
        }
        smoothed = .zero
        baseline = nil
        if !autoOscillating, offset != .zero {
            offset = .zero
        }
    }

    private func ingest(x: CGFloat, z: CGFloat) {
        guard isRunning else { return }
        guard let base = baseline else {
            baseline = CGPoint(x: x, y: z)
            return
        }
        let target = CGPoint(x: Self.unit(x - base.x), y: Self.unit(z - base.y))
        smoothed.x += (target.x - smoothed.x) * Self.smoothing
        smoothed.y += (target.y - smoothed.y) * Self.smoothing
        let softened = CGPoint(x: Self.softDeadZone(smoothed.x), y: Self.softDeadZone(smoothed.y))
        let next = CGSize(width: softened.x, height: softened.y)
        if abs(next.width - offset.width) > Self.publishDelta
            || abs(next.height - offset.height) > Self.publishDelta {
            offset = next
        }
    }

    private func startAutoOscillation() {
        guard autoTimer == nil else { return }
        autoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                autoPhase += 1.0 / 30.0
                offset = CGSize(width: CGFloat(sin(autoPhase * 0.9)) * 0.75,
                                height: CGFloat(cos(autoPhase * 0.6)) * 0.5)
            }
        }
    }

    private var autoOscillating: Bool { autoTimer != nil }

    private static func unit(_ delta: CGFloat) -> CGFloat {
        clamp(delta * gravityToUnit)
    }

    /// Zero for small leans, then eases in so leaving the dead zone does not pop.
    private static func softDeadZone(_ value: CGFloat) -> CGFloat {
        let magnitude = abs(value)
        guard magnitude > deadZone else { return 0 }
        let span = 0.08
        let ramp = min(1, (magnitude - deadZone) / span)
        let eased = ramp * ramp * (3 - 2 * ramp)
        return value.sign == .minus ? -eased * magnitude : eased * magnitude
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(1, max(-1, value))
    }
}

/// Wraps the cover (and its backlight glow) in the tilt treatment: two small 3D
/// rotations, a few points of parallax, and a specular sweep that follows the
/// lean. Everything else on the screen stays still.
@MainActor
struct ArtworkTilt<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder var content: Content

    @StateObject private var driver = TiltDriver()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let lean = reduceMotion ? .zero : driver.offset
        content
            .overlay {
                if !reduceMotion {
                    specular(for: lean)
                }
            }
            .rotation3DEffect(.degrees(Double(lean.height) * -ArtworkTiltMetrics.maxDegrees),
                              axis: (x: 1, y: 0, z: 0), perspective: 0.55)
            .rotation3DEffect(.degrees(Double(lean.width) * ArtworkTiltMetrics.maxDegrees),
                              axis: (x: 0, y: 1, z: 0), perspective: 0.55)
            .offset(x: lean.width * ArtworkTiltMetrics.parallax,
                    y: lean.height * ArtworkTiltMetrics.parallax * 0.75)
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.8), value: lean)
            .onAppear { driver.start() }
            .onDisappear { driver.stop() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { driver.start() } else { driver.stop() }
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { driver.stop() } else { driver.start() }
            }
    }

    private func specular(for lean: CGSize) -> some View {
        // The glass shows a reflection only while it is being tilted: at rest the
        // artwork is clean, and leaning the phone slides a narrow streak of light
        // across it. The streak is a bright core over a soft halo — a reflection
        // with falloff, not a wash over the whole cover.
        let leanMagnitude = min(1, hypot(lean.width, lean.height) * 1.4)
        return GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let travel = width * 0.42 * lean.width
            ZStack {
                ReflectionStreak(width: width * 0.60, height: height * 1.8, blur: width * 0.10,
                                 opacity: 0.075 * leanMagnitude)
                    .offset(x: -width * 0.16 + travel, y: -height * 0.06)
                    .rotationEffect(.degrees(24))
                ReflectionStreak(width: width * 0.15, height: height * 1.8, blur: width * 0.012,
                                 opacity: 0.20 * leanMagnitude)
                    .offset(x: -width * 0.10 + travel, y: -height * 0.06)
                    .rotationEffect(.degrees(24))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One soft-edged band for the specular sweep: a horizontal white ramp that is
/// blurred and rotated into a diagonal streak.
@MainActor
private struct ReflectionStreak: View {
    let width: CGFloat
    let height: CGFloat
    let blur: CGFloat
    let opacity: Double

    var body: some View {
        Rectangle()
            .fill(LinearGradient(stops: [
                .init(color: Color.white.opacity(0), location: 0),
                .init(color: Color.white.opacity(1), location: 0.5),
                .init(color: Color.white.opacity(0), location: 1)
            ], startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: height)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

/// Degrees at full lean. Small on purpose: 5° reads as material, 12° reads as a
/// gimmick and starts to fight the wheel below the cover.
private enum ArtworkTiltMetrics {
    static let maxDegrees: Double = 5
    static let parallax: CGFloat = 4
}
