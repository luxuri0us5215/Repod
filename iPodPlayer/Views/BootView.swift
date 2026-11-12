import SwiftUI
import UIKit

/// The boot screen (3.1.11): the Halo mark, picked up from the system launch
/// screen without a seam.
///
/// The system launch screen (`UILaunchScreen` in Info.plist) is the
/// `LaunchBackground` colour with the `LaunchMark` image — the wheel as a glass
/// ring and its centre key — centred on the whole window. Both assets have a
/// light and a dark appearance, like the app icon. This view's first frame is
/// exactly that frame: same colour, same image, same size, same place. It reads
/// the *system* appearance, not the app's theme override, because that is what
/// the launch screen was drawn with.
///
/// While the library index loads, the thumb's blue light circles the ring. When
/// the library is ready the light slows down and comes to rest at one o'clock —
/// where it sits on the app icon — so the last frame of the splash *is* the
/// icon. Then the key clicks and the screen eases away while the parent fades
/// it out. There is no gesture: a loading screen is never half-openable.
@MainActor
struct BootView: View {
    /// True once the saved library index is ready.
    let isReady: Bool
    /// Called when the exit begins; the parent fades the whole screen away.
    let onFinished: () -> Void

    // MARK: Geometry
    //
    // `LaunchMark` is drawn on a 1024 canvas by the icon generator; the radii
    // below are that canvas's, scaled to `markSide`. The launch screen shows the
    // image at its point size (@2x 480 px, @3x 720 px), so `markSide` must stay
    // 240 or the hand-over jumps.
    static let markSide: CGFloat = 240
    private static let unit = markSide / 1024
    private static let ringOuter = 318 * unit
    private static let ringInner = 116 * unit
    private static let keyRadius = 104 * unit

    // MARK: The thumb's light (same maths as the icon)

    /// Where the light rests: one o'clock, as on the icon.
    private static let restAngle: Double = -40 * .pi / 180
    // nonisolated: `thumbFalloff` uses it as a default argument, and default
    // arguments are evaluated outside the main actor. A Double constant is safe anywhere.
    /// Half the light's length along the ring.
    nonisolated private static let halfArc: Double = 62 * .pi / 180
    /// One turn while loading.
    private static let turn: TimeInterval = 1.25
    private static var speed: Double { 2 * .pi / turn }
    /// The light slows to rest over this much of the ring.
    private static let settleDistance: Double = 1.4
    /// Long enough that a fast launch reads as a mark, not a flash.
    private static let minimumDwell: TimeInterval = 0.55
    /// Start angle, chosen so that a library that is already ready begins
    /// settling exactly when the dwell ends.
    private static var startAngle: Double { restAngle - settleDistance - speed * minimumDwell }

    private enum Phase { case spinning, settling, finished }

    @State private var phase: Phase = .spinning
    @State private var settledAngle: Double = -40 * .pi / 180   // = restAngle
    @State private var appeared = false
    @State private var keyPressed = false
    @State private var exiting = false
    @State private var startDate = Date()
    @State private var finishStarted = false
    @State private var systemScheme: ColorScheme = BootView.systemColorScheme()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)

            ZStack {
                // Same colour as the system launch screen, so frame one matches.
                Color("LaunchBackground")

                // The icon's background, fading in over it after the hand-over.
                background
                    .opacity(appeared ? 1 : 0)

                mark
                    .position(center)

                Text(verbatim: "Repod")
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.primary.opacity(0.86))
                    .position(x: center.x, y: center.y + Self.ringOuter + 40)
                    .opacity(appeared && !exiting ? 1 : 0)
                    .offset(y: appeared ? 0 : 5)
            }
            .scaleEffect(exiting ? 1.06 : 1)
            .overlay(alignment: .bottom) { footer }
        }
        .ignoresSafeArea()
        // The launch screen used the system appearance; so does this screen,
        // whatever theme the app forces on the player underneath.
        .environment(\.colorScheme, systemScheme)
        .onAppear {
            startDate = Date()
            systemScheme = Self.systemColorScheme()
            // Let the system's launch zoom settle on the identical first frame
            // before anything changes.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.12))
                withAnimation(.easeOut(duration: 0.45)) { appeared = true }
            }
        }
        // Keyed on readiness, and measured from the first frame: the exit starts
        // as soon as both the dwell and the library are done, in either order.
        .task(id: isReady) { await finishWhenReady() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("正在启动"))
        .accessibilityValue(L10n.text("正在准备曲库…"))
    }

    // MARK: - Background

    private var isDark: Bool { systemScheme == .dark }

    private var background: some View {
        ZStack {
            LinearGradient(colors: isDark
                           ? [Color(red: 0.149, green: 0.165, blue: 0.200), Color(red: 0.039, green: 0.043, blue: 0.059)]
                           : [Color(red: 0.984, green: 0.984, blue: 0.988), Color(red: 0.863, green: 0.878, blue: 0.906)],
                           startPoint: .top, endPoint: .bottom)
            if isDark {
                // A faint cool light from above, as on the dark icon.
                RadialGradient(colors: [Color(red: 0.23, green: 0.29, blue: 0.40).opacity(0.24), .clear],
                               center: .top, startRadius: 0, endRadius: 520)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Mark

    private var mark: some View {
        ZStack {
            // The thumb's glow, just outside the ring.
            thumbLayer { angle in glow.rotationEffect(.radians(angle)) }

            // The launch image itself: pixel-identical to the system's frame.
            Image("LaunchMark")
                .resizable()
                .interpolation(.high)
                .frame(width: Self.markSide, height: Self.markSide)

            // The thumb: light caught inside the glass ring.
            thumbLayer { angle in light.rotationEffect(.radians(angle)) }

            // The key, pressed.
            Circle()
                .fill(Color.black.opacity(keyPressed ? 0.10 : 0))
                .frame(width: Self.keyRadius * 2, height: Self.keyRadius * 2)
        }
        .frame(width: Self.markSide, height: Self.markSide)
        .scaleEffect(keyPressed ? 0.985 : 1)
        .accessibilityHidden(true)
    }

    /// Drives a thumb layer: by the clock while spinning, by an animated angle
    /// while settling and after.
    @ViewBuilder
    private func thumbLayer<Content: View>(@ViewBuilder _ content: @escaping (Double) -> Content) -> some View {
        Group {
            if phase == .spinning && !reduceMotion {
                TimelineView(.animation) { context in
                    content(spinAngle(at: context.date))
                }
            } else {
                content(reduceMotion ? Self.restAngle : settledAngle)
            }
        }
        .opacity(appeared ? 1 : 0)
    }

    private func spinAngle(at date: Date) -> Double {
        Self.startAngle + date.timeIntervalSince(startDate) * Self.speed
    }

    /// The light in the ring, drawn centred on angle 0 (three o'clock).
    private var light: some View {
        let blue = isDark ? Color(red: 0.239, green: 0.525, blue: 0.969) : Color(red: 0.184, green: 0.482, blue: 0.961)
        let high = isDark ? Color(red: 0.612, green: 0.796, blue: 1.0) : Color(red: 0.490, green: 0.722, blue: 1.0)
        let highStrength = isDark ? 0.85 : 0.45
        return ZStack {
            Self.thumbFalloff(blue, power: 1, inner: Self.ringInner, outer: Self.ringOuter)
                .opacity(0.95)
            Self.thumbFalloff(high, power: 2.2, inner: Self.ringInner, outer: Self.ringOuter)
                .opacity(highStrength)
        }
        .frame(width: Self.markSide, height: Self.markSide)
        .mask {
            Annulus(inner: Self.ringInner, outer: Self.ringOuter)
                .fill(style: FillStyle(eoFill: true))
        }
    }

    /// The light's glow, outside the ring only.
    private var glow: some View {
        let deep = Color(red: 0.102, green: 0.337, blue: 0.812)
        let pad = 40 * Self.unit
        return Self.thumbFalloff(deep, power: 1, inner: Self.ringInner - pad, outer: Self.ringOuter + pad,
                                 halfArc: Self.halfArc * 1.05, closedEnds: true)
            .frame(width: Self.markSide, height: Self.markSide)
            .blur(radius: 28 * Self.unit)
            .opacity(isDark ? 0.38 : 0.22)
            .mask {
                NotRing(inner: Self.ringInner, outer: Self.ringOuter)
                    .fill(style: FillStyle(eoFill: true))
            }
    }

    /// `colour` × across-band falloff × along-ring falloff, centred on angle 0.
    /// Across: a Gaussian over the band (σ 0.3); along: (1 − v²)²; both raised to
    /// `power` — the same profile the icon generator paints.
    private static func thumbFalloff(_ colour: Color, power: Double, inner: CGFloat, outer: CGFloat,
                                     halfArc: Double = BootView.halfArc, closedEnds: Bool = false) -> some View {
        let across = stops(power: power, closedEnds: closedEnds) { exp(-pow(($0 - 0.5) / 0.3, 2)) }
        let along = stops(power: power, closedEnds: true) { pow(max(0, 1 - pow(2 * $0 - 1, 2)), 2) }
        return colour
            .mask {
                RadialGradient(stops: across, center: .center, startRadius: inner, endRadius: outer)
            }
            .mask {
                AngularGradient(stops: along, center: .center,
                                startAngle: .zero, endAngle: .radians(halfArc * 2))
                    .rotationEffect(.radians(-halfArc))
            }
    }

    private static func stops(power: Double, closedEnds: Bool, _ f: (Double) -> Double) -> [Gradient.Stop] {
        (0...20).map { i in
            let location = Double(i) / 20
            var value = pow(f(location), power)
            if closedEnds && (i == 0 || i == 20) { value = 0 }
            return Gradient.Stop(color: .white.opacity(value), location: location)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text(L10n.text("正在准备曲库…"))
            if !Self.marketingVersion.isEmpty {
                Text(verbatim: "·")
                Text(verbatim: Self.marketingVersion)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.secondary.opacity(0.75))
        .padding(.bottom, 48)
        .opacity(appeared && phase == .spinning ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: phase)
        .accessibilityHidden(true)
    }

    // MARK: - Exit timeline

    private func finishWhenReady() async {
        let elapsed = Date().timeIntervalSince(startDate)
        if elapsed < Self.minimumDwell {
            try? await Task.sleep(for: .seconds(Self.minimumDwell - elapsed))
        }
        guard !Task.isCancelled, isReady, !finishStarted else { return }
        finishStarted = true

        if reduceMotion {
            phase = .finished
            try? await Task.sleep(for: .seconds(0.2))
            onFinished()
            return
        }

        // Keep spinning until the light is `settleDistance` short of one
        // o'clock, then ease it to rest there. The ease starts at the spinning
        // speed (initial slope 2 × distance / duration), so there is no jolt.
        let now = spinAngle(at: Date())
        let turns = ((now + Self.settleDistance - Self.restAngle) / (2 * .pi)).rounded(.up)
        let target = Self.restAngle + turns * 2 * .pi
        let wait = max(0, (target - Self.settleDistance - now) / Self.speed)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }

        let from = spinAngle(at: Date())
        let distance = max(0.3, target - from)
        let duration = 2 * distance / Self.speed
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            settledAngle = from
            phase = .settling
        }
        // Next frame, so the switch from the clock to the animated angle lands
        // first and the ease starts from where the light actually is.
        try? await Task.sleep(for: .milliseconds(16))
        withAnimation(.timingCurve(0.3, 0.6, 0.6, 1.0, duration: duration)) {
            settledAngle = target
        }
        try? await Task.sleep(for: .seconds(duration + 0.14))

        // At rest: this frame is the app icon. The key clicks, and away.
        phase = .finished
        withAnimation(.easeIn(duration: 0.08)) { keyPressed = true }
        try? await Task.sleep(for: .seconds(0.10))
        withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) { keyPressed = false }
        withAnimation(.easeIn(duration: 0.38)) { exiting = true }
        try? await Task.sleep(for: .seconds(0.04))
        onFinished()
    }

    // MARK: - Helpers

    /// The appearance the system launch screen was drawn with: the screen's,
    /// which an app-level `preferredColorScheme` does not change.
    /// `nonisolated` so it can seed the `@State` default (views are built on the
    /// main thread, which `assumeIsolated` checks).
    nonisolated private static func systemColorScheme() -> ColorScheme {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let style = scene?.screen.traitCollection.userInterfaceStyle ?? UITraitCollection.current.userInterfaceStyle
            return style == .dark ? .dark : .light
        }
    }

    private static var marketingVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }
}

/// A ring between two radii, centred in its rect. Fill with `eoFill: true`.
private struct Annulus: Shape {
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        path.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        return path
    }
}

/// Everything except the ring: the rect, minus the annulus. Fill with `eoFill: true`.
private struct NotRing: Shape {
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Annulus(inner: inner, outer: outer).path(in: rect)
        path.addRect(rect.insetBy(dx: -rect.width, dy: -rect.height))
        return path
    }
}
