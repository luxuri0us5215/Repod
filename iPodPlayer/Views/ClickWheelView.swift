import SwiftUI
import UIKit

/// One touch surface arbitrates ring rotation and all five key taps. Labels
/// never intercept a drag, and a drag can never become a button tap on release.
@MainActor
struct ClickWheelView: View {
    let diameter: CGFloat
    let isPlaying: Bool
    let canToggleLike: Bool
    let onStep: (Int) -> Bool
    let onRotationEnded: () -> Void
    let onMenu: () -> Void
    let onMenuLongPress: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onPlayPause: () -> Void
    let onSeekForward: (Double) -> Void
    let onSeekBackward: (Double) -> Void
    let onConfirm: () -> Void
    let onConfirmLongPress: () -> Bool

    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @GestureState private var gestureIsActive = false
    @State private var tracker = WheelRotationTracker()
    @State private var startLocation: CGPoint?
    @State private var startZone: KeyZone?
    @State private var pressedZone: KeyZone?
    @State private var beganOnRing = false
    @State private var hasDragged = false
    @State private var tapCandidate = false
    @State private var centreHoldTask: Task<Void, Never>?
    @State private var ringHoldTask: Task<Void, Never>?
    @State private var menuHoldTask: Task<Void, Never>?
    @State private var longPressFired = false

    private enum KeyZone: Hashable {
        case menu, previous, next, playPause, confirm
    }

    private var centreRadius: CGFloat { diameter * 0.18 }
    private var ringInnerRadius: CGFloat { diameter * 0.195 }
    private var labelOffset: CGFloat { diameter * 0.365 }

    private var usesBlackRing: Bool { appearance.effectiveThemePreset == .classic }

    /// The ring's base lacquer, lit corner first: the light comes from the upper left.
    private var ringColors: [Color] {
        usesBlackRing ? [Color(white: 0.17), Color(white: 0.07)] : [.white, Color(white: 0.91)]
    }

    private var centreButtonColors: [Color] {
        pressedZone == .confirm
            ? [appearance.theme.headerBottom, appearance.theme.headerTop]
            : [appearance.theme.headerTop, appearance.theme.headerBottom]
    }

    var body: some View {
        ZStack {
            // The ring, its labels and the press light rock together as one disc. The
            // centre key stays outside this group: a glass layer cannot live inside a
            // 3D transform (it renders black), and on a real iPod the centre switch is
            // a separate part from the wheel that rocks beneath it anyway.
            ZStack {
                discSurface

                ForEach([KeyZone.menu, .next, .playPause, .previous], id: \.self) { zone in
                    pressGlow(for: zone)
                }

                // The rim's catch-light and the centre key's soft shade sit above the
                // press light, so a pressed quadrant never dulls them.
                discSoftEdges

                Text("MENU")
                    .font(.system(size: diameter * 0.046, weight: .bold, design: .rounded))
                    .modifier(KeyLabelPress(pressed: pressedZone == .menu))
                    .offset(y: -labelOffset)
                WheelSkipGlyph(pointsLeft: true)
                    .frame(width: diameter * 0.09, height: diameter * 0.05)
                    .modifier(KeyLabelPress(pressed: pressedZone == .previous))
                    .offset(x: -labelOffset)
                WheelSkipGlyph(pointsLeft: false)
                    .frame(width: diameter * 0.09, height: diameter * 0.05)
                    .modifier(KeyLabelPress(pressed: pressedZone == .next))
                    .offset(x: labelOffset)
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                    Image(systemName: "pause.fill")
                }
                .font(.system(size: diameter * 0.05, weight: .semibold))
                .modifier(KeyLabelPress(pressed: pressedZone == .playPause))
                .offset(y: labelOffset)
            }
            .animation(.easeOut(duration: 0.14), value: pressedZone)
            // A render transform on drawn content only: the touch surface is the
            // untransformed frame further down, so zones and gestures see exactly the
            // geometry they always did.
            .rotation3DEffect(.degrees(pressTilt.x), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(pressTilt.y), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: pressedZone)

            centreButton
        }
        .font(.system(size: diameter * 0.06, weight: .semibold))
        .foregroundStyle(usesBlackRing ? .white : Color(white: 0.43))
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(touchGesture)
        .onChange(of: gestureIsActive) { _, active in
            // GestureState also resets when the system cancels a touch.
            if !active { resetInteraction() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { resetInteraction() }
        }
        .onDisappear { resetInteraction() }
        .accessibilityRepresentation {
            VStack {
                Text("点按式转盘")
                    .accessibilityHint("向上轻扫选择下一项，向下轻扫选择上一项。")
                    .accessibilityAdjustableAction { adjustment in
                        switch adjustment {
                        case .increment: emitStep(1)
                        case .decrement: emitStep(-1)
                        @unknown default: break
                        }
                        onRotationEnded()
                    }
                Button("MENU", action: onMenu)
                    .accessibilityHint("长按返回主菜单")
                Button("返回主菜单", action: onMenuLongPress)
                Button("上一首", action: onPrevious)
                Button("确认", action: onConfirm)
                if canToggleLike {
                    Button("喜欢 / 取消喜欢") { _ = onConfirmLongPress() }
                }
                Button("下一首", action: onNext)
                Button(isPlaying ? "暂停" : "播放", action: onPlayPause)
            }
        }
    }

    // MARK: Material
    //
    // Everything below is paint. The geometry, zones and gestures are untouched,
    // and none of these layers takes a touch.

    // The wheel is one soft, rounded pebble lit from the upper left, like the body
    // around it. There are no edges to find: no bevel, no groove, no streaks. Only
    // broad gradients that ease in and out, so nothing ever reads as a line or a facet.

    /// Picks a value for the black ring or for the light one.
    private func finish<T>(dark: T, light: T) -> T { usesBlackRing ? dark : light }

    /// A deeper, more saturated cousin of the theme tint: the colour the lacquer turns
    /// where it curves into shade, so mint shades green and sunset shades warm, not grey.
    private var tintShade: Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(appearance.theme.wheelTint)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        else { return .black }
        return Color(hue: Double(hue), saturation: Double(min(1, saturation * 1.3)),
                     brightness: Double(brightness * 0.30))
    }

    /// The colour of the ring's shade: black on the black ring, tinted lacquer on a light one.
    private var shadeColor: Color { usesBlackRing ? .black : tintShade }

    /// The disc: shadows, then the lacquer curving away from the light.
    private var discSurface: some View {
        ZStack {
            // A bare silhouette casts the shadows, so the blur never has to chew through
            // the gradient layers: a wide soft one that lets the wheel float on the body,
            // and only a faint, loose one for contact.
            Circle()
                .fill(ringColors[1])
                .padding(0.5)
                .shadow(color: .black.opacity(finish(dark: 0.14, light: 0.09)),
                        radius: diameter * 0.014, x: 0, y: diameter * 0.007)
                .shadow(color: .black.opacity(finish(dark: 0.22, light: 0.17)),
                        radius: diameter * 0.05, x: 0, y: diameter * 0.028)

            Circle()
                .fill(LinearGradient(colors: ringColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                // The lacquer: the theme colour as paint, so mint and sunset read as colour
                // under the gloss and not as a grey ring.
                .overlay(Circle().fill(appearance.theme.wheelTint.opacity(finish(dark: 0.07, light: 0.24))))
                .overlay { if !reduceTransparency { domeLight } }
                .overlay(edgeRoll)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One broad, low-contrast highlight on the upper left of a smooth dome. Eased
    /// through several stops so it has no visible edge anywhere.
    private var domeLight: some View {
        let peak = finish(dark: 0.21, light: 0.44)
        return Circle()
            .fill(RadialGradient(
                stops: [
                    .init(color: Color.white.opacity(peak), location: 0.00),
                    .init(color: Color.white.opacity(peak * 0.72), location: 0.22),
                    .init(color: Color.white.opacity(peak * 0.40), location: 0.48),
                    .init(color: Color.white.opacity(peak * 0.14), location: 0.74),
                    .init(color: Color.white.opacity(0), location: 1.00),
                ],
                center: UnitPoint(x: 0.35, y: 0.27),
                startRadius: 0, endRadius: diameter * 0.78))
    }

    /// The surface rolling over toward the rim: a wide, gentle falloff that starts well
    /// inside the edge and deepens smoothly, instead of a line at the edge.
    private var edgeRoll: some View {
        let depth = finish(dark: 0.28, light: 0.15)
        return Circle()
            .fill(RadialGradient(
                stops: [
                    .init(color: shadeColor.opacity(0), location: 0.74),
                    .init(color: shadeColor.opacity(depth * 0.20), location: 0.84),
                    .init(color: shadeColor.opacity(depth * 0.55), location: 0.93),
                    .init(color: shadeColor.opacity(depth), location: 1.00),
                ],
                center: .center, startRadius: 0, endRadius: diameter / 2))
    }

    /// What sits above the press light: a single faint catch-light along the lit rim,
    /// and the soft shade the centre key's recess throws onto the ring.
    private var discSoftEdges: some View {
        // The recess shade is a radial fall-off centred a touch up and to the left, since
        // the upper-left wall is the one the light does not reach. It is darkest right at
        // the key's edge and is gone well before the labels, with no outer edge.
        let reach = diameter * 0.30
        let shade = usesBlackRing ? Color.black.opacity(0.55) : tintShade.opacity(0.21)
        let rim = finish(dark: 0.26, light: 0.80)
        return ZStack {
            Circle()
                .fill(RadialGradient(
                    stops: [
                        .init(color: shade, location: 0.00),
                        .init(color: shade, location: 0.56),
                        .init(color: shade.opacity(0.60), location: 0.66),
                        .init(color: shade.opacity(0.30), location: 0.77),
                        .init(color: shade.opacity(0.10), location: 0.88),
                        .init(color: shade.opacity(0), location: 1.00),
                    ],
                    center: .center, startRadius: 0, endRadius: reach))
                .frame(width: reach * 2, height: reach * 2)
                .offset(x: -diameter * 0.005, y: -diameter * 0.009)

            // The catch-light: brightest toward the light and fading smoothly to nothing
            // around both sides, so it never starts or stops anywhere.
            if !reduceTransparency {
                Circle()
                    .inset(by: 0.5)
                    .strokeBorder(AngularGradient(
                        stops: [
                            .init(color: Color.white.opacity(0), location: 0.300),
                            .init(color: Color.white.opacity(rim * 0.10), location: 0.380),
                            .init(color: Color.white.opacity(rim * 0.42), location: 0.470),
                            .init(color: Color.white.opacity(rim * 0.82), location: 0.550),
                            .init(color: Color.white.opacity(rim), location: 0.625),
                            .init(color: Color.white.opacity(rim * 0.82), location: 0.700),
                            .init(color: Color.white.opacity(rim * 0.42), location: 0.780),
                            .init(color: Color.white.opacity(rim * 0.10), location: 0.870),
                            .init(color: Color.white.opacity(0), location: 0.950),
                            .init(color: Color.white.opacity(0), location: 1.000),
                        ],
                        center: .center, angle: .degrees(0)),
                                  lineWidth: diameter * 0.007)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Press response
    //
    // The wheel answers a press as one object, never with a separate shape laid on
    // top of it: the whole disc pivots a little toward the pressed key (it is a
    // rocker on a real iPod), and the ring itself brightens — or, on a light ring,
    // shades — in that key's quadrant, feathered into the surface on every side.

    /// How far the wheel rocks toward the pressed key.
    private static let pressTiltDegrees = 4.0

    /// The key's bearing on the ring, clockwise from three o'clock.
    private func keyBearing(_ zone: KeyZone) -> Double {
        switch zone {
        case .next: return 0
        case .playPause: return 90
        case .previous: return 180
        case .menu: return 270
        case .confirm: return 0
        }
    }

    /// A soft, wedge-shaped wash on the ring. Angular falloff makes it a quadrant
    /// of light; the radial mask keeps it off the centre key and lets it die out
    /// toward the rim, so there is no edge to read as a shape.
    private func pressGlow(for zone: KeyZone) -> some View {
        let tint: Color = usesBlackRing ? .white : .black
        let peak = usesBlackRing ? 0.28 : 0.11
        let pressed = pressedZone == zone
        return Circle()
            .fill(AngularGradient(
                stops: [
                    .init(color: tint.opacity(0), location: 0.00),
                    .init(color: tint.opacity(0), location: 0.34),
                    .init(color: tint.opacity(peak * 0.30), location: 0.42),
                    .init(color: tint.opacity(peak), location: 0.50),
                    .init(color: tint.opacity(peak * 0.30), location: 0.58),
                    .init(color: tint.opacity(0), location: 0.66),
                    .init(color: tint.opacity(0), location: 1.00),
                ],
                center: .center, angle: .degrees(keyBearing(zone) - 180)))
            .mask(RadialGradient(
                stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: .black, location: 0.50),
                    .init(color: .black.opacity(0.45), location: 1.00),
                ],
                center: .center, startRadius: ringInnerRadius, endRadius: diameter / 2))
            .opacity(pressed ? 1 : 0)
            // In fast, out slower: the light lingers a beat after the finger lifts.
            .animation(pressed ? .easeOut(duration: 0.10) : .easeOut(duration: 0.32), value: pressedZone)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Rocking about the horizontal axis answers MENU and play/pause, about the
    /// vertical axis answers the two skip keys. Which sign tips which way is fixed
    /// by `pressTilt` below.
    private var pressTilt: (x: Double, y: Double) {
        // Reduce Motion keeps the light and drops the rocking.
        guard !reduceMotion else { return (x: 0, y: 0) }
        let t = Self.pressTiltDegrees
        switch pressedZone {
        case .menu: return (x: t, y: 0)
        case .playPause: return (x: -t, y: 0)
        case .previous: return (x: 0, y: -t)
        case .next: return (x: 0, y: t)
        case .confirm, .none: return (x: 0, y: 0)
        }
    }

    /// The centre key keeps its opaque themed face; on iOS 26 a glass layer sits on
    /// top of it for the lens edge and specular, and before that a drawn rim does.
    /// It is a soft round dome and dips slightly while pressed.
    private var centreButton: some View {
        let size = centreRadius * 2
        let pressed = pressedZone == .confirm
        let darkFace = appearance.theme.isDark
        return ZStack {
            // The key casts onto the ring, softly, down and to the right. Pressed, it sits
            // closer to the surface, so the shadow tightens. A bare silhouette casts it,
            // never the glass layer.
            Circle()
                .fill(Color.black)
                .padding(0.5)
                .shadow(color: .black.opacity(pressed ? 0.14 : 0.10),
                        radius: diameter * (pressed ? 0.006 : 0.010),
                        x: 0, y: diameter * (pressed ? 0.003 : 0.005))
                .shadow(color: .black.opacity(pressed ? 0.12 : 0.22),
                        radius: diameter * (pressed ? 0.014 : 0.030),
                        x: diameter * (pressed ? 0.003 : 0.007),
                        y: diameter * (pressed ? 0.008 : 0.019))

            Circle().fill(LinearGradient(colors: centreButtonColors, startPoint: .top, endPoint: .bottom))
            if !reduceTransparency {
                // A domed face: the light pools softly on the upper left. Under the glass,
                // so the lens edge refracts it.
                let peak = (darkFace ? 0.16 : 0.55) * (pressed ? 0.4 : 1)
                Circle().fill(RadialGradient(
                    stops: [
                        .init(color: Color.white.opacity(peak), location: 0.00),
                        .init(color: Color.white.opacity(peak * 0.70), location: 0.25),
                        .init(color: Color.white.opacity(peak * 0.32), location: 0.55),
                        .init(color: Color.white.opacity(0), location: 1.00),
                    ],
                    center: UnitPoint(x: 0.36, y: 0.25),
                    startRadius: 0, endRadius: size * 0.80))
            }
            // The face turning away toward the rim, eased in from well inside it.
            Circle().fill(RadialGradient(
                stops: [
                    .init(color: .clear, location: 0.50),
                    .init(color: Color.black.opacity(darkFace ? 0.12 : 0.05), location: 0.78),
                    .init(color: Color.black.opacity(darkFace ? 0.30 : 0.14), location: 1.00),
                ],
                center: .center, startRadius: 0, endRadius: size / 2))
            if #available(iOS 26.0, *) {
                // `.clear`, untinted: `.regular` blurred the face's gradient into a flat
                // tinted disc. Clear keeps the gradient and only adds the lens edge.
                Circle().fill(Color.clear)
                    .glassEffect(.clear, in: Circle())
            }
            Circle().strokeBorder(appearance.accent.opacity(0.32), lineWidth: 1)
            Circle().inset(by: 1.5)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(darkFace ? 0.5 : 0.7), Color.white.opacity(0)],
                                             startPoint: .top, endPoint: .center),
                              lineWidth: 1)
        }
        .frame(width: size, height: size)
        .scaleEffect(pressed ? 0.95 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.65), value: pressed)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var touchGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($gestureIsActive) { _, active, _ in active = true }
            .onChanged { value in
                guard scenePhase == .active else {
                    resetInteraction()
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                if startLocation == nil {
                    startLocation = value.startLocation
                    startZone = zone(at: value.startLocation)
                    pressedZone = startZone
                    tapCandidate = startZone != nil
                    beganOnRing = isOnRing(value.startLocation)
                    HapticEngine.shared.prepare()
                    if startZone == .confirm { beginCentreHold() }
                    if let ringZone = startZone, ringZone != .confirm { beginRingHold(in: ringZone) }
                    if startZone == .menu { beginMenuHold() }
                    if beganOnRing {
                        _ = tracker.update(angle: angle(at: value.startLocation), timestamp: now)
                    }
                }

                let distance = hypot(
                    value.location.x - value.startLocation.x,
                    value.location.y - value.startLocation.y
                )
                if zone(at: value.location) != startZone {
                    ringHoldTask?.cancel()
                    menuHoldTask?.cancel()
                }
                if distance > 8 {
                    hasDragged = true
                    tapCandidate = false
                    pressedZone = nil
                    centreHoldTask?.cancel()
                    ringHoldTask?.cancel()
                    menuHoldTask?.cancel()
                }
                guard hasDragged, beganOnRing else { return }
                guard isOnRing(value.location) else {
                    // Re-entry establishes a fresh baseline rather than
                    // interpreting a trip across the centre as rotation.
                    tracker.reset()
                    return
                }

                let steps = tracker.update(angle: angle(at: value.location), timestamp: now)
                for _ in 0..<abs(steps) {
                    emitStep(steps > 0 ? 1 : -1)
                }
            }
            .onEnded { value in
                let endDistance = hypot(
                    value.location.x - value.startLocation.x,
                    value.location.y - value.startLocation.y
                )
                let tappedZone = startZone
                let shouldTap = tapCandidate && !hasDragged && !longPressFired && endDistance <= 8
                    && tappedZone == zone(at: value.location)
                resetInteraction()
                guard shouldTap, let tappedZone else { return }
                HapticEngine.shared.tick()
                HapticEngine.shared.click()
                switch tappedZone {
                case .menu: onMenu()
                case .previous: onPrevious()
                case .next: onNext()
                case .playPause: onPlayPause()
                case .confirm: onConfirm()
                }
            }
    }

    private func beginCentreHold() {
        centreHoldTask?.cancel()
        centreHoldTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 550_000_000) }
            catch { return }
            guard !Task.isCancelled, scenePhase == .active,
                  startZone == .confirm, tapCandidate, !hasDragged, !longPressFired else { return }
            // Consume the release even when this source/screen has no like action.
            longPressFired = true
            tapCandidate = false
            if onConfirmLongPress() {
                HapticEngine.shared.tick()
            }
        }
    }

    /// MENU held down leaves every pushed screen at once, the way a string of
    /// MENU presses would. It rejoins the same hold machinery as the other keys,
    /// so a drag or a second finger still cancels it before it fires.
    private func beginMenuHold() {
        menuHoldTask?.cancel()
        menuHoldTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 550_000_000) }
            catch { return }
            guard !Task.isCancelled, scenePhase == .active,
                  startZone == .menu, tapCandidate, !hasDragged, !longPressFired else { return }
            longPressFired = true
            tapCandidate = false
            HapticEngine.shared.tick()
            onMenuLongPress()
        }
    }

    private func beginRingHold(in zone: KeyZone) {
        guard zone == .previous || zone == .next else { return }
        ringHoldTask?.cancel()
        ringHoldTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 550_000_000) }
            catch { return }
            guard !Task.isCancelled, scenePhase == .active,
                  startZone == zone, tapCandidate, !hasDragged, !longPressFired else { return }
            longPressFired = true
            tapCandidate = false
            let engagedAt = ProcessInfo.processInfo.systemUptime
            var lastSeekStep = 1
            HapticEngine.shared.tick()
            performRingHold(in: zone, stepSeconds: 1)

            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
                guard !Task.isCancelled, scenePhase == .active,
                      startZone == zone, !hasDragged, longPressFired else { return }
                let holdSeconds = max(0, ProcessInfo.processInfo.systemUptime - engagedAt)
                let seekStep = min(10, 1 + Int(holdSeconds))
                if (zone == .previous || zone == .next), seekStep > lastSeekStep {
                    HapticEngine.shared.tick()
                }
                lastSeekStep = seekStep
                performRingHold(in: zone, stepSeconds: Double(seekStep))
            }
        }
    }

    private func performRingHold(in zone: KeyZone, stepSeconds: Double) {
        switch zone {
        case .previous: onSeekBackward(stepSeconds)
        case .next: onSeekForward(stepSeconds)
        case .menu, .playPause, .confirm: break
        }
    }

    private func emitStep(_ direction: Int) {
        // A screen without selectable rows returns false, so it cannot tick
        // while a hidden menu index changes behind Now Playing.
        if onStep(direction) {
            HapticEngine.shared.tick()
            HapticEngine.shared.scrollClick()
        }
    }

    private func radius(at point: CGPoint) -> CGFloat {
        hypot(point.x - diameter / 2, point.y - diameter / 2)
    }

    private func isOnRing(_ point: CGPoint) -> Bool {
        let radius = radius(at: point)
        return radius >= ringInnerRadius && radius <= diameter / 2
    }

    private func angle(at point: CGPoint) -> Double {
        atan2(Double(point.y - diameter / 2), Double(point.x - diameter / 2))
    }

    private func zone(at point: CGPoint) -> KeyZone? {
        if radius(at: point) <= centreRadius { return .confirm }
        guard isOnRing(point) else { return nil }
        let dx = point.x - diameter / 2
        let dy = point.y - diameter / 2
        if abs(dx) > abs(dy) { return dx > 0 ? .next : .previous }
        return dy > 0 ? .playPause : .menu
    }

    private func resetInteraction() {
        onRotationEnded()
        centreHoldTask?.cancel()
        centreHoldTask = nil
        ringHoldTask?.cancel()
        ringHoldTask = nil
        menuHoldTask?.cancel()
        menuHoldTask = nil
        longPressFired = false
        tracker.reset()
        startLocation = nil
        startZone = nil
        pressedZone = nil
        beganOnRing = false
        hasDragged = false
        tapCandidate = false
    }
}

/// A key label eases back and softens while its key is down: a slight sink, not a
/// flash. Driven by the wheel's single `pressedZone` animation.
private struct KeyLabelPress: ViewModifier {
    let pressed: Bool

    func body(content: Content) -> some View {
        content
            .opacity(pressed ? 0.55 : 1)
            .scaleEffect(pressed ? 0.93 : 1)
    }
}

private struct WheelSkipGlyph: Shape {
    let pointsLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // A bar and two triangles; mirror the previous key for the next key.
        path.addRect(CGRect(x: rect.minX + rect.width * (pointsLeft ? 0 : 0.91),
                            y: rect.minY, width: rect.width * 0.09, height: rect.height))
        for tip in [CGFloat(0.14), CGFloat(0.57)] {
            let base = tip + 0.41
            path.move(to: CGPoint(x: rect.minX + rect.width * (pointsLeft ? tip : 1 - tip),
                                  y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * (pointsLeft ? base : 1 - base),
                                     y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * (pointsLeft ? base : 1 - base),
                                     y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}
