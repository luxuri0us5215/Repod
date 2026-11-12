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
    /// Clear glass instead of the lacquered ring: the immersive Now Playing lays the
    /// wheel over the artwork. Geometry, keys and gestures are the same.
    var glass: Bool = false

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
    /// Where the thumb is on the ring (radians, as `angle(at:)` measures), and
    /// whether the refraction that follows it is showing.
    @State private var touchAngle: Double = -Double.pi / 2
    @State private var touchVisible = false

    private enum KeyZone: Hashable {
        case menu, previous, next, playPause, confirm
    }

    private var centreRadius: CGFloat { diameter * 0.18 }
    private var ringInnerRadius: CGFloat { diameter * 0.195 }
    private var labelOffset: CGFloat { diameter * 0.365 }

    /// 3.1.5: one ink rule for the glass wheel — white on a dark body (and on the
    /// immersive clear glass), a soft graphite on a light one.
    private var labelInk: Color {
        glass || appearance.theme.isDark ? Color.white.opacity(0.92) : Color(white: 0.36)
    }

    /// 3.1.8: half the length of the refractive arc under the thumb, in radians
    /// (0.8 ≈ 46° each side, so the arc covers about a quarter of the wheel).
    private static let refractionHalfArc: CGFloat = 0.8

    var body: some View {
        ZStack {
            // The ring, its labels and the press light rock together as one disc. The
            // centre key stays outside this group: a glass layer cannot live inside a
            // 3D transform (it renders black), and on a real iPod the centre switch is
            // a separate part from the wheel that rocks beneath it anyway.
            ZStack {
                // The shadow sits outside the refraction layer, which only draws
                // inside the disc's own square.
                discShadow

                ZStack {
                    if glass { glassSurface } else { glassDisc }

                    ForEach([KeyZone.menu, .next, .playPause, .previous], id: \.self) { zone in
                        pressGlow(for: zone)
                    }

                    keyLabels
                }
                .frame(width: diameter, height: diameter)
                // 3.1.8: the touch indicator is the glass itself bending — not a spot
                // but an arc of refraction that fills the whole ring band (centre key
                // edge to rim) and runs along the ring, centred on the thumb. Whatever
                // it covers — surface, press light, a key label — is stretched round
                // the curve; no rim, shadow or outline, and it fades out at every edge.
                .modifier(WheelRefraction(diameter: diameter,
                                          innerRadius: ringInnerRadius,
                                          angle: touchAngle,
                                          halfArc: Self.refractionHalfArc,
                                          strength: touchVisible ? 1 : 0))
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: touchVisible)
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
        .foregroundStyle(labelInk)
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
    //
    // 3.1.5: the wheel is one disc of thick glass set into the body (it was a
    // lacquered pebble). No live glass: this all sits inside the press tilt, where a
    // system glass layer renders black, so the glass is drawn — the body seen through
    // it, the thickness at the rim, the light carried through and gathered on the far
    // side, a broad surface sheen and a rim that catches the light twice.

    /// A deeper, more saturated cousin of the theme tint: the colour thick glass
    /// takes on at its edge, so mint deepens green and sunset warm, not grey.
    private var tintShade: Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(appearance.theme.wheelTint)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        else { return .black }
        return Color(hue: Double(hue), saturation: Double(min(1, saturation * 1.3)),
                     brightness: Double(brightness * 0.30))
    }

    /// Glass casts a lighter shadow than lacquer. A bare silhouette casts it, so the
    /// blur never has to chew through the gradient layers.
    @ViewBuilder
    private var discShadow: some View {
        if glass {
            Circle()
                .fill(Color.white.opacity(0.13))
                .shadow(color: .black.opacity(0.35), radius: diameter * 0.05, y: diameter * 0.03)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            let dark = appearance.theme.isDark
            Circle()
                .fill(appearance.theme.bodyBackground)
                .padding(0.5)
                .shadow(color: .black.opacity(dark ? 0.22 : 0.06),
                        radius: diameter * 0.010, x: 0, y: diameter * 0.005)
                .shadow(color: .black.opacity(dark ? 0.30 : 0.11),
                        radius: diameter * 0.045, x: 0, y: diameter * 0.025)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The glass disc, in the body's own colour.
    private var glassDisc: some View {
        let dark = appearance.theme.isDark
        let edge: Color = dark ? .white : tintShade
        return ZStack {
            // Seen through the glass: the body behind it, a shade deeper (thick glass
            // absorbs a little) and lit from the lower right — a lens turns the light over.
            Circle().fill(appearance.theme.bodyBackground)
            Circle().fill(LinearGradient(
                colors: [Color.black.opacity(dark ? 0.10 : 0.06), Color.white.opacity(dark ? 0.05 : 0.20)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().fill(appearance.theme.wheelTint.opacity(dark ? 0.05 : 0.10))

            // Thickness at the rim: the view bends hard there, so a band just inside
            // the edge deepens. Eased in from well inside, so it never reads as a line.
            Circle().fill(RadialGradient(
                stops: [
                    .init(color: edge.opacity(0), location: 0.62),
                    .init(color: edge.opacity(dark ? 0.04 : 0.06), location: 0.80),
                    .init(color: edge.opacity(dark ? 0.12 : 0.20), location: 0.94),
                    .init(color: edge.opacity(dark ? 0.07 : 0.10), location: 1.00),
                ],
                center: .center, startRadius: 0, endRadius: diameter / 2))

            // The light carried through the glass, gathered on the far side.
            Circle().fill(RadialGradient(
                colors: [Color.white.opacity(dark ? 0.09 : 0.30), Color.white.opacity(0)],
                center: UnitPoint(x: 0.68, y: 0.80), startRadius: 0, endRadius: diameter * 0.36))

            // The surface sheen: one broad, soft highlight on the upper left.
            if !reduceTransparency {
                Circle().fill(RadialGradient(
                    stops: [
                        .init(color: Color.white.opacity(dark ? 0.16 : 0.42), location: 0.00),
                        .init(color: Color.white.opacity(dark ? 0.07 : 0.18), location: 0.38),
                        .init(color: Color.white.opacity(0), location: 1.00),
                    ],
                    center: UnitPoint(x: 0.32, y: 0.22), startRadius: 0, endRadius: diameter * 0.56))
            }

            // The well the centre key sits in: the glass curves down into it.
            Circle().fill(RadialGradient(
                stops: [
                    .init(color: edge.opacity(dark ? 0.16 : 0.14), location: 0.80),
                    .init(color: edge.opacity(0), location: 1.00),
                ],
                center: .center, startRadius: 0, endRadius: ringInnerRadius * 1.5))
                .frame(width: ringInnerRadius * 3, height: ringInnerRadius * 3)

            // The rim catches the key light on the upper left and lets it out again on
            // the lower right; the sides stay dim. Clockwise from three o'clock.
            Circle().strokeBorder(AngularGradient(
                stops: [
                    .init(color: Color.white.opacity(dark ? 0.20 : 0.45), location: 0.000),
                    .init(color: Color.white.opacity(dark ? 0.32 : 0.65), location: 0.125),
                    .init(color: Color.white.opacity(dark ? 0.06 : 0.12), location: 0.375),
                    .init(color: Color.white.opacity(dark ? 0.55 : 0.95), location: 0.625),
                    .init(color: Color.white.opacity(dark ? 0.06 : 0.12), location: 0.875),
                    .init(color: Color.white.opacity(dark ? 0.20 : 0.45), location: 1.000),
                ],
                center: .center, angle: .degrees(0)),
                                  lineWidth: 1.2)
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
        let tint: Color = appearance.theme.isDark ? .white : .black
        let peak = appearance.theme.isDark ? 0.22 : 0.10
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
                .fill(glass ? Color.black.opacity(0.22) : Color.black)
                .padding(0.5)
                .shadow(color: .black.opacity(pressed ? 0.14 : 0.10),
                        radius: diameter * (pressed ? 0.006 : 0.010),
                        x: 0, y: diameter * (pressed ? 0.003 : 0.005))
                .shadow(color: .black.opacity(pressed ? 0.12 : 0.22),
                        radius: diameter * (pressed ? 0.014 : 0.030),
                        x: diameter * (pressed ? 0.003 : 0.007),
                        y: diameter * (pressed ? 0.008 : 0.019))

            if glass {
                Circle().fill(Color.white.opacity(pressed ? 0.26 : 0.18))
            } else {
                // 3.1.5: the same glass as the ring, a little brighter, since it
                // stands proud of the disc. Pressed, it dims a touch.
                Circle().fill(appearance.theme.bodyBackground)
                Circle().fill(LinearGradient(
                    colors: [Color.white.opacity(darkFace ? 0.10 : 0.30), Color.black.opacity(darkFace ? 0.10 : 0.04)],
                    startPoint: .top, endPoint: .bottom))
                Circle().fill(appearance.theme.wheelTint.opacity(darkFace ? 0.05 : 0.10))
                Circle().fill(Color.black.opacity(pressed ? (darkFace ? 0.14 : 0.07) : 0))
            }
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
                if beganOnRing, isOnRing(value.location) {
                    touchAngle = angle(at: value.location)
                    if !touchVisible { touchVisible = true }
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
        touchVisible = false
    }

    /// The four ring labels. They sit inside the refraction layer, so they swell
    /// and bend as the thumb passes over them.
    private var keyLabels: some View {
        ZStack {
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
    }

    /// The glass ring: a faint white fill with a bright upper rim and a soft
    /// return underneath. No live blur: this layer sits inside the press tilt,
    /// where a glass effect renders black, and the immersive screen behind it is
    /// already a blur of the artwork.
    private var glassSurface: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0)],
                                     center: UnitPoint(x: 0.5, y: 0.1), startRadius: 0, endRadius: diameter * 0.6))
            Circle()
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.62), Color.white.opacity(0.08), Color.white.opacity(0.22)],
                                             startPoint: .top, endPoint: .bottom),
                              lineWidth: 1.2)
            Circle()
                .stroke(Color.black.opacity(0.14), lineWidth: diameter * 0.012)
                .frame(width: ringInnerRadius * 2 + 4, height: ringInnerRadius * 2 + 4)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

/// 3.1.8: the refractive arc under the thumb (`WheelLens.metal`). Only the strength
/// animates (the arc fades in and opens out from the thumb); its angle follows the
/// thumb directly, so it never sweeps round from where the last touch was.
private struct WheelRefraction: ViewModifier, Animatable {
    var diameter: CGFloat
    var innerRadius: CGFloat
    var angle: Double
    var halfArc: CGFloat
    var strength: CGFloat

    var animatableData: CGFloat {
        get { strength }
        set { strength = newValue }
    }

    func body(content: Content) -> some View {
        // Furthest a sample can travel: the stretch along the outer edge of the arc.
        let reach = diameter * 0.5 * halfArc * 0.32 + 2
        content.layerEffect(
            ShaderLibrary.wheelArcRefraction(.float2(diameter / 2, diameter / 2),
                                             .float(innerRadius),
                                             .float(diameter / 2),
                                             .float(angle),
                                             .float(halfArc),
                                             .float(strength)),
            maxSampleOffset: CGSize(width: reach, height: reach),
            isEnabled: strength > 0.001)
    }
}
