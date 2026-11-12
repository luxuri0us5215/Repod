import SwiftUI
import UIKit

// MARK: - Liquid Glass, as the iPod's own material
//
// The device is still an iPod: the body, the wheel, the LCD menu and the blue
// selection bar keep their hardware meaning. Liquid Glass (iOS 26+) is used only
// where a real iPod already had a glossy clear layer *above* something else:
//
//   · the LCD's cover glass          → `LCDBezel` + `LCDCoverGlass` (hand-drawn)
//   · the wheel (3.1.5: all glass)   → hand-drawn glass + `WheelLens.metal`
//   · the wheel's centre button      → real `glassEffect`
//   · floating info over Cover Flow  → real `glassEffect`
//   · the selection bar              → `LCDSelectionBar` (a lens, not a stripe)
//
// Rows, titles and body text never sit on glass: the LCD stays opaque and crisp.
// Every iOS 26 call is behind `#available`; iOS 17–25 get the same layout with a
// material and a hairline instead.

extension View {
    /// Liquid Glass on iOS 26 and later; a thin material with a hairline rim before.
    /// `tint` colours the glass itself, so keep it faint.
    @ViewBuilder
    func lcdGlass<S: InsettableShape>(in shape: S,
                                      tint: Color? = nil,
                                      fallback: Material = .ultraThinMaterial) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(tint), in: shape)
        } else {
            background(fallback, in: shape)
                .overlay { shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5) }
        }
    }
}

// MARK: - Selection lens

/// The selection lens: a saturated blue glass capsule with white ink, inset from
/// the panel edge, with a sheen across its top half, a bright upper rim, a darker
/// lower lip and a soft blue shadow under it. The colour is the hardware blue and
/// never follows the theme. Setting `Metrics.selectionInset`,
/// `selectionVerticalInset` and `selectionRadius` to 0 gives a full-bleed bar.
@MainActor
struct LCDSelectionBar: View {
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.selectionRadius, style: .continuous)
        shape
            .fill(appearance.selectionGradient)
            .overlay {
                // The sheen: bright at the top, gone by the middle.
                shape.inset(by: 1.5)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.38), Color.white.opacity(0.03)],
                                         startPoint: .top, endPoint: .center))
                    .padding(.horizontal, 5)
                    .padding(.bottom, 4)
            }
            .overlay {
                // Specular rim on top, a deeper blue lip underneath.
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.62),
                                                           Color.white.opacity(0.10),
                                                           Color(red: 0.02, green: 0.13, blue: 0.41).opacity(0.50)],
                                                  startPoint: .top, endPoint: .bottom),
                                   lineWidth: 1)
            }
            .shadow(color: Color(red: 0.08, green: 0.33, blue: 0.80).opacity(0.45), radius: 7, y: 5)
            .shadow(color: Color(red: 0.03, green: 0.14, blue: 0.41).opacity(0.30), radius: 1, y: 1)
            .padding(.horizontal, Metrics.selectionInset)
            .padding(.vertical, Metrics.selectionVerticalInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The same footprint as the lens, for a finger-down overlay.
struct LCDSelectionFootprint: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: Metrics.selectionRadius, style: .continuous)
            .path(in: rect.insetBy(dx: Metrics.selectionInset, dy: Metrics.selectionVerticalInset))
    }
}

// MARK: Lens host (3.1.5)
//
// 3.1–3.1.4 drew a lens inside every selected row and joined them with
// `matchedGeometryEffect`. Spun fast, that flickered: each step tore one lens down
// and built another, the matched animation ran in screen coordinates while
// `scrollTo` moved the rows under it in the next update, and a lazy stack could
// drop the row the animation was flying from. Now a list hosts *one* lens that
// lives in its scroll content: the selected row only reports where it is, and the
// lens glides there in content coordinates, so scrolling carries the lens and the
// rows together and nothing is ever created or destroyed while the wheel turns.

/// Where the selected row is, in whatever coordinate space reads it.
private struct LCDLensAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

private struct LCDLensHostedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a list that draws the lens itself (`lcdLensHost()`).
    var lcdLensHosted: Bool {
        get { self[LCDLensHostedKey.self] }
        set { self[LCDLensHostedKey.self] = newValue }
    }
}

/// Put on a list's stack, *inside* its scroll view. Rows below it that use
/// `lcdSelectionBackground` stop drawing their own lens and report their frame;
/// this draws the one lens behind them and glides it between rows.
@MainActor
struct LCDLensHost: ViewModifier {
    /// Critically damped: no overshoot, so the lens and a list scrolling on the
    /// same curve never drift apart, and it does not wobble when the wheel
    /// outruns it. Shared with `ScrollViewProxy.lcdFollow`.
    static let glide = Animation.spring(response: 0.24, dampingFraction: 1.0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.lcdLensHosted, true)
            .backgroundPreferenceValue(LCDLensAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    if let anchor {
                        let rect = proxy[anchor]
                        LCDSelectionBar()
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .animation(reduceMotion ? nil : Self.glide, value: rect)
                    }
                }
            }
    }
}

extension View {
    /// One gliding selection lens for every row under this view.
    func lcdLensHost() -> some View { modifier(LCDLensHost()) }
}

extension ScrollViewProxy {
    /// 3.1.6: keep the selected row in view *on the lens's own curve*.
    ///
    /// The lens lives in the scroll content and glides to the new row on
    /// `LCDLensHost.glide`. 3.1.5 then re-centred the list with an instant
    /// `scrollTo`, so on every wheel step the list jumped a row while the lens,
    /// carried up with it, sprang back down: the highlight bounced and the list
    /// shook. Now a wheel step scrolls on the same spring, in the same frame, so
    /// the list glides and the lens stays put on screen; near the top or bottom,
    /// where the list cannot scroll any further, the lens glides instead.
    ///
    /// `animated: false` (first appearance, a new screen) jumps, with every
    /// inherited animation stripped. Reduce Motion always jumps.
    @MainActor
    func lcdFollow<ID: Hashable>(_ id: ID, anchor: UnitPoint?, animated: Bool) {
        if animated, !UIAccessibility.isReduceMotionEnabled {
            withAnimation(LCDLensHost.glide) { scrollTo(id, anchor: anchor) }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollTo(id, anchor: anchor) }
        }
    }
}

/// The lens behind one row. Inside a hosted list the row only publishes its frame
/// (see `LCDLensHost`); anywhere else — the Search input row, say — it draws its
/// own lens. The ink changes on the same spring the lens moves on.
@MainActor
private struct LCDSelectionBackground: ViewModifier {
    let selected: Bool
    @Environment(\.lcdLensHosted) private var hosted
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Group {
            if hosted {
                content
                    .anchorPreference(key: LCDLensAnchorKey.self, value: .bounds) { selected ? $0 : nil }
            } else {
                content
                    .background {
                        if selected { LCDSelectionBar() }
                    }
            }
        }
        .transaction(value: selected) { transaction in
            transaction.animation = reduceMotion ? nil : LCDLensHost.glide
        }
    }
}

extension View {
    /// The wheel's selection signal for one row: the lens behind it.
    func lcdSelectionBackground(_ selected: Bool) -> some View {
        modifier(LCDSelectionBackground(selected: selected))
    }
}

// MARK: - LCD bezel and cover glass

/// 3.1.5: the black glass the LCD sits in, drawn as a stroke of the screen's own
/// outline. A stroke is an exact offset of its path, so the band is precisely
/// `width` on every side and all the way round each corner. Before, the band was
/// the gap between two separately-rounded rectangles, with a light rim on two sides
/// only and a shadow under the third, and it read as uneven.
///
/// Drawn as a background of the clipped screen: the inner half of each stroke is
/// hidden by the screen itself, the outer half is the bezel.
@MainActor
struct LCDBezel: View {
    let screenRadius: CGFloat
    let width: CGFloat
    /// The outermost hairline, the same all the way round, so the panel's silhouette
    /// never vanishes into the body. Steel on the silver body.
    let rim: AnyShapeStyle
    var rimWidth: CGFloat = 0.75

    static let black = Color(red: 0.024, green: 0.027, blue: 0.039)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: screenRadius, style: .continuous)
        ZStack {
            shape.stroke(rim, lineWidth: width * 2)
            shape.stroke(Self.black, lineWidth: max(0, width - rimWidth) * 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What a real iPod had over its LCD: a faint gloss across the upper-left, and an
/// even edge where the glass meets the bezel. Drawn, not `glassEffect`: a live
/// glass layer over the whole screen would blur and lens the text beneath it.
///
/// `isDarkScreen` follows what is on the LCD, not the body theme — Now Playing is
/// always a dark screen, even inside the white classic body.
@MainActor
struct LCDCoverGlass: View {
    /// The screen's radius (inside the bezel).
    let cornerRadius: CGFloat
    let isDarkScreen: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if !reduceTransparency {
                shape.fill(LinearGradient(
                    stops: [.init(color: Color.white.opacity(isDarkScreen ? 0.06 : 0.18), location: 0),
                            .init(color: Color.white.opacity(0), location: 0.36)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            // One uniform edge, the same weight on all four sides. (3.1.4's rim was
            // bright upper-left and gone lower-right, so the black border looked
            // thin on two sides and thick on the other two.)
            shape.strokeBorder(Color.black.opacity(isDarkScreen ? 0.35 : 0.14), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Body lighting

/// A little volume for the plastic: a soft key light at the top and a shade at the
/// bottom. Colours come from the theme; the opacity stays low enough that the
/// body still reads as one flat lacquer colour.
@MainActor
struct BodyLighting: View {
    let palette: ThemePalette

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack {
                RadialGradient(colors: [palette.bodyHighlight, .clear],
                               center: UnitPoint(x: 0.5, y: 0),
                               startRadius: 0, endRadius: height * 0.55)
                RadialGradient(colors: [.clear, palette.bodyShade],
                               center: UnitPoint(x: 0.5, y: 0.42),
                               startRadius: height * 0.34, endRadius: height * 0.86)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Keyboard

/// 3.1.5: put the keyboard away *now*. Setting a `@FocusState` to nil only takes
/// effect after the next view update, and that update is usually the expensive one
/// (a new search result list, a screen push), so the keyboard used to start down a
/// beat after the action that dismissed it. Resigning the first responder starts
/// the system's hide animation in the same run-loop turn; the focus state follows.
@MainActor
enum LCDKeyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}
