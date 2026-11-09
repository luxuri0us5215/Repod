import SwiftUI

// MARK: - Liquid Glass, as the iPod's own material
//
// The device is still an iPod: the body, the wheel, the LCD menu and the blue
// selection bar keep their hardware meaning. Liquid Glass (iOS 26+) is used only
// where a real iPod already had a glossy clear layer *above* something else:
//
//   · the LCD's cover glass          → `LCDCoverGlass` (hand-drawn rim + gloss)
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

/// The iPod-blue selection bar, drawn as a lens: inset from the panel edge, with
/// a soft top sheen and a specular rim. The colour is still the hardware blue and
/// never follows the theme. Setting `Metrics.selectionInset`,
/// `selectionVerticalInset` and `selectionRadius` to 0 gives the old full-bleed bar.
@MainActor
struct LCDSelectionBar: View {
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.selectionRadius, style: .continuous)
        shape
            .fill(appearance.selectionGradient)
            .overlay {
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0)],
                                          startPoint: .top, endPoint: .center))
            }
            .overlay {
                // A pale blue bar on a near-white LCD needs a defined edge.
                shape.strokeBorder(Color(red: 0.42, green: 0.55, blue: 0.74).opacity(0.40), lineWidth: 0.75)
            }
            .overlay {
                shape.inset(by: 0.75)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0)],
                                                 startPoint: .top, endPoint: .bottom),
                                  lineWidth: 1)
            }
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

extension View {
    /// The wheel's selection signal for one row: the lens behind it.
    ///
    /// It switches instantly, with no fade. The wheel steps faster than any fade
    /// can finish (and the list jumps to the new row with no animation), so a
    /// per-row fade left the lens half-drawn and a row behind the content: the old
    /// row's lens still fading out while the new one faded in, and the ink colour
    /// (black on the lens) trailing the same way. Like the hardware, the lens is
    /// either on a row or it is not.
    ///
    /// The transaction guard keeps it that way if a caller ever changes the
    /// selection inside an animated transaction: no animation, and no implicit
    /// opacity transition on the lens, for the rows whose `selected` flips.
    func lcdSelectionBackground(_ selected: Bool) -> some View {
        background {
            if selected { LCDSelectionBar() }
        }
        .transaction(value: selected) { $0.animation = nil }
    }
}

// MARK: - LCD cover glass

/// What a real iPod had over its LCD: a rim that catches light and a faint gloss
/// across the upper-left. Drawn, not `glassEffect`: a live glass layer over the
/// whole screen would blur and lens the text beneath it.
///
/// `isDarkScreen` follows what is on the LCD, not the body theme — Now Playing is
/// always a dark screen, even inside the white classic body.
@MainActor
struct LCDCoverGlass: View {
    let cornerRadius: CGFloat
    let isDarkScreen: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if !reduceTransparency {
                shape.fill(LinearGradient(
                    stops: [.init(color: Color.white.opacity(isDarkScreen ? 0.07 : 0.20), location: 0),
                            .init(color: Color.white.opacity(0), location: 0.36)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            // Outer hairline: the silhouette against the body.
            shape.strokeBorder(isDarkScreen ? Color.white.opacity(0.09) : Color.black.opacity(0.10),
                               lineWidth: 1)
            // Specular rim: bright where the light hits, gone by the far corner,
            // with a faint return on the underside.
            shape.inset(by: 1)
                .strokeBorder(LinearGradient(
                    colors: [Color.white.opacity(isDarkScreen ? 0.34 : 0.85),
                             Color.white.opacity(0),
                             isDarkScreen ? Color.white.opacity(0.10) : Color.black.opacity(0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1)
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
