import SwiftUI
import UIKit

enum AppThemePreset: String, CaseIterable, Identifiable {
    case classic = "经典白"
    case midnight = "午夜黑"
    case mint = "薄荷绿"
    case sunset = "落日橙"

    var id: String { rawValue }

    var palette: ThemePalette {
        switch self {
        case .classic:
            return ThemePalette(screenBackground: Color(red: 0.97, green: 0.97, blue: 0.95),
                                lcdBackground: Color(red: 0.97, green: 0.98, blue: 0.95),
                                headerTop: .white, headerBottom: Color(white: 0.79),
                                headerDivider: Color(white: 0.56),
                                footerBackground: Color(white: 0.93), footerDivider: Color(white: 0.78),
                                barBackground: Color(red: 0.90, green: 0.91, blue: 0.91),
                                backgroundTop: .white,
                                backgroundBottom: .white,
                                bodyBackground: .white, wheelTint: Color(red: 0.76, green: 0.83, blue: 0.92),
                                accent: Color(red: 0.08, green: 0.36, blue: 0.75), isDark: false,
                                // A white body has no light left to add; only a little shade gives it volume.
                                bodyHighlight: Color.white.opacity(0),
                                bodyShade: Color(red: 0.28, green: 0.30, blue: 0.34).opacity(0.07))
        case .midnight:
            return ThemePalette(screenBackground: Color(red: 0.055, green: 0.065, blue: 0.085),
                                lcdBackground: Color(red: 0.055, green: 0.065, blue: 0.085),
                                headerTop: Color(red: 0.22, green: 0.24, blue: 0.27),
                                headerBottom: Color(red: 0.10, green: 0.12, blue: 0.15),
                                headerDivider: Color(white: 0.28),
                                footerBackground: Color(white: 0.11), footerDivider: Color(white: 0.24),
                                barBackground: Color(red: 0.13, green: 0.15, blue: 0.19),
                                backgroundTop: Color(red: 0.12, green: 0.16, blue: 0.25),
                                backgroundBottom: Color(red: 0.03, green: 0.05, blue: 0.1),
                                bodyBackground: Color(white: 0.1), wheelTint: Color(red: 0.68, green: 0.72, blue: 0.85),
                                accent: Color(red: 0.59, green: 0.72, blue: 1), isDark: true,
                                bodyHighlight: Color(red: 0.70, green: 0.78, blue: 1).opacity(0.10),
                                bodyShade: Color.black.opacity(0.30))
        case .mint:
            return ThemePalette(screenBackground: Color(red: 0.89, green: 0.96, blue: 0.91),
                                lcdBackground: Color(red: 0.93, green: 0.98, blue: 0.94),
                                headerTop: Color(red: 0.98, green: 1, blue: 0.98),
                                headerBottom: Color(red: 0.76, green: 0.84, blue: 0.78),
                                headerDivider: Color(red: 0.50, green: 0.59, blue: 0.52),
                                footerBackground: Color(red: 0.89, green: 0.94, blue: 0.90),
                                footerDivider: Color(red: 0.74, green: 0.80, blue: 0.75),
                                barBackground: Color(red: 0.81, green: 0.90, blue: 0.84),
                                backgroundTop: Color(red: 0.89, green: 0.98, blue: 0.93),
                                backgroundBottom: Color(red: 0.58, green: 0.82, blue: 0.72),
                                bodyBackground: Color(red: 0.69, green: 0.83, blue: 0.77),
                                wheelTint: Color(red: 0.6, green: 0.83, blue: 0.71),
                                accent: Color(red: 0.03, green: 0.38, blue: 0.27), isDark: false,
                                bodyHighlight: Color.white.opacity(0.34),
                                bodyShade: Color(red: 0.06, green: 0.30, blue: 0.22).opacity(0.16))
        case .sunset:
            return ThemePalette(screenBackground: Color(red: 1, green: 0.94, blue: 0.86),
                                lcdBackground: Color(red: 1, green: 0.96, blue: 0.90),
                                headerTop: Color(red: 1, green: 0.99, blue: 0.96),
                                headerBottom: Color(red: 0.87, green: 0.80, blue: 0.71),
                                headerDivider: Color(red: 0.65, green: 0.57, blue: 0.48),
                                footerBackground: Color(red: 0.97, green: 0.92, blue: 0.85),
                                footerDivider: Color(red: 0.83, green: 0.77, blue: 0.68),
                                barBackground: Color(red: 0.96, green: 0.86, blue: 0.73),
                                backgroundTop: Color(red: 1, green: 0.94, blue: 0.84),
                                backgroundBottom: Color(red: 0.96, green: 0.67, blue: 0.51),
                                bodyBackground: Color(red: 0.91, green: 0.73, blue: 0.6),
                                wheelTint: Color(red: 0.98, green: 0.76, blue: 0.56),
                                accent: Color(red: 0.65, green: 0.23, blue: 0.09), isDark: false,
                                bodyHighlight: Color.white.opacity(0.34),
                                bodyShade: Color(red: 0.45, green: 0.16, blue: 0.05).opacity(0.18))
        }
    }
}

struct ThemePalette {
    // Preserve the existing landscape palette separately from the portrait LCD.
    let screenBackground: Color
    let lcdBackground: Color
    let headerTop: Color
    let headerBottom: Color
    let headerDivider: Color
    let footerBackground: Color
    let footerDivider: Color
    // The landscape Cover Flow information panel keeps its existing solid fill.
    let barBackground: Color
    let backgroundTop: Color
    let backgroundBottom: Color
    let bodyBackground: Color
    let wheelTint: Color
    let accent: Color
    let isDark: Bool
    /// The body's light and shade (see `BodyLighting`). The colour carries its own
    /// opacity, kept low so the body still reads as one flat lacquer.
    let bodyHighlight: Color
    let bodyShade: Color

    var headerGradient: LinearGradient {
        LinearGradient(colors: [headerTop, headerBottom], startPoint: .top, endPoint: .bottom)
    }

    var lcdText: Color { isDark ? Color(white: 0.92) : Color(white: 0.12) }
    var lcdSecondaryText: Color { isDark ? Color(white: 0.64) : Color(white: 0.38) }
    var text: Color { isDark ? Color(white: 0.97) : Color(white: 0.1) }
    var secondaryText: Color { isDark ? Color(white: 0.8) : Color(white: 0.29) }
    var divider: Color { isDark ? Color(white: 0.36) : Color(white: 0.64) }

    /// The LCD switch is drawn, not a system control, so its three surfaces come
    /// from the palette instead of being hardcoded grey — an off-track of
    /// `Color(white: 0.84)` was a bright pill on the midnight screen.
    var switchTrackOn: Color {
        isDark ? Color(red: 0.42, green: 0.52, blue: 0.72)
               : Color(red: 0.863, green: 0.902, blue: 0.949)
    }
    var switchTrackOff: Color { isDark ? Color(white: 0.26) : Color(white: 0.84) }
    var switchKnob: Color { isDark ? Color(white: 0.86) : .white }

    /// The selection bar is deliberately theme-independent: it is the hardware's
    /// own highlight (the classic iPod blue), not a brand colour of the theme, so
    /// it must not swing when the user picks 薄荷绿 or 落日橙.
    var selectionTop: Color { Color(red: 0.863, green: 0.902, blue: 0.949) }
    var selectionBottom: Color { Color(red: 0.761, green: 0.824, blue: 0.894) }
}

/// One set of numbers for the whole LCD. A list row, a settings row, a search row
/// and the header title all start on the same vertical line and share one row
/// height rule, so no screen can drift a couple of points out of alignment.
enum Metrics {
    /// The left/right inset of every piece of LCD text.
    static let horizontalInset: CGFloat = 10
    static let singleLineRowHeight: CGFloat = 50
    static let doubleLineRowHeight: CGFloat = 60
    static let headerHeight: CGFloat = 30
    static let footerHeight: CGFloat = 24

    /// Header status marks: a shared ink height plus a fixed slot, so cycling the
    /// playback mode cannot move the title or the trailing margin.
    static let statusGlyphInkHeight: CGFloat = 12
    static let statusGlyphSlot: CGFloat = 17
    static let statusGlyphInkHeightLarge: CGFloat = 22
    static let statusGlyphSlotLarge: CGFloat = 28

    /// The radius ladder: artwork, small controls, LCD panels.
    static let artworkRadius: CGFloat = 8
    static let controlRadius: CGFloat = 13
    static let edgeFadeHeight: CGFloat = 6
    static let panelInset: CGFloat = 12

    /// The selection lens (see `LCDSelectionBar`). Concentric with the panel: the
    /// panel's radius is the device's minus `panelInset`, and the lens sits a few
    /// points inside it. All three at 0 restores the full-bleed classic bar.
    static let selectionInset: CGFloat = 4
    static let selectionVerticalInset: CGFloat = 2
    static let selectionRadius: CGFloat = 12

    /// The Now Playing cover is the one large cover on the device, so it takes a
    /// larger radius than the 8pt small covers. `artworkGlowOpacity` is the cover's
    /// own colour bleeding softly behind it, like an LCD backlight; 0 turns it off.
    static let nowPlayingArtworkRadius: CGFloat = 14
    static let artworkGlowOpacity: Double = 0.40
}

/// Six type sizes instead of the twelve the screens had accumulated. One family
/// (SF) throughout: the list and the Now Playing screen used to swap between SF
/// and HelveticaNeue, so the same song title changed typeface when it opened.
enum AppFont {
    /// Now Playing title and the source wordmark.
    static let hero = Font.system(size: 22, weight: .bold)
    /// A selected row's primary line.
    static let title = Font.system(size: 19, weight: .semibold)
    /// An LCD screen title.
    static let header = Font.system(size: 15, weight: .bold)
    static let body = Font.system(size: 15)
    static let detail = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let micro = Font.system(size: 11, weight: .semibold)
    static let microRegular = Font.system(size: 11)
}

@MainActor
final class AppearanceSettings: ObservableObject {
    @AppStorage("appearanceFollowSystem") var followsSystem = true {
        willSet { objectWillChange.send() }
        didSet { persistEffectiveTheme() }
    }
    @AppStorage("appearanceEffectiveTheme") private var savedEffectiveTheme = AppThemePreset.classic.rawValue
    @Published private(set) var systemColorScheme: ColorScheme = .light
    @Published var selectedTheme: AppThemePreset {
        didSet {
            UserDefaults.standard.set(selectedTheme.rawValue, forKey: "appearanceTheme")
            persistEffectiveTheme()
        }
    }
    @Published var useCustomAccent: Bool {
        didSet { UserDefaults.standard.set(useCustomAccent, forKey: "useCustomAccent") }
    }
    @Published var customAccent: Color {
        didSet { saveAccent() }
    }

    var effectiveThemePreset: AppThemePreset {
        guard followsSystem else { return selectedTheme }
        if systemColorScheme == .dark { return .midnight }
        return selectedTheme.palette.isDark ? .classic : selectedTheme
    }
    var theme: ThemePalette { effectiveThemePreset.palette }
    // System appearance changes the surfaces, while the user's chosen accent stays put.
    var accent: Color { useCustomAccent ? customAccent : selectedTheme.palette.accent }

    var selectionGradient: LinearGradient {
        // Classic iPod selection is blue in every theme, independent of custom controls.
        LinearGradient(colors: [theme.selectionTop, theme.selectionBottom],
                       startPoint: .top, endPoint: .bottom)
    }

    init() {
        let defaults = UserDefaults.standard
        selectedTheme = AppThemePreset(rawValue: defaults.string(forKey: "appearanceTheme") ?? "") ?? .classic
        useCustomAccent = defaults.bool(forKey: "useCustomAccent")
        let components = defaults.array(forKey: "customAccentRGBA") as? [Double]
        if let components, components.count == 4 {
            customAccent = Color(.sRGB, red: components[0], green: components[1], blue: components[2], opacity: components[3])
        } else {
            customAccent = Color(red: 0.08, green: 0.36, blue: 0.75)
        }
        systemColorScheme = savedEffectiveTheme == AppThemePreset.midnight.rawValue ? .dark : .light
        persistEffectiveTheme()
    }

    func updateSystemColorScheme(_ scheme: ColorScheme) {
        guard systemColorScheme != scheme else { return }
        systemColorScheme = scheme
        persistEffectiveTheme()
    }

    private func persistEffectiveTheme() {
        savedEffectiveTheme = effectiveThemePreset.rawValue
    }

    private func saveAccent() {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(customAccent).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
        UserDefaults.standard.set([Double(red), Double(green), Double(blue), Double(alpha)], forKey: "customAccentRGBA")
    }
}
