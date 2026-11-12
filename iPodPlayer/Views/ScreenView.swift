import SwiftUI
import UIKit

@MainActor
struct ScreenView: View {
    let viewModel: PlayerViewModel
    var safeTop: CGFloat = 0
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The stack depth as of the last screen this view drew. In the update where
    /// the depth changes it still holds the old value, so comparing the two says
    /// which way that navigation went: a push slides in from the right, MENU slides
    /// back in from the left.
    @State private var lastDepth = 1
    private var navigatesForward: Bool { viewModel.navigation.count >= lastDepth }

    var body: some View {
        ZStack {
            if viewModel.currentScreen == .nowPlaying {
                NowPlayingView(viewModel: viewModel, clock: viewModel.clock, safeTop: safeTop)
                    .background(AppThemePreset.midnight.palette.lcdBackground)
                    .modifier(ScreenEntryMotion(scale: reduceMotion ? 1 : 1.04))
            } else {
                standardScreen
                    .modifier(ScreenEntryMotion())
            }
        }
        // 3.1.1: a screen change is never animated as a swap. An animated removal —
        // even `removal: .identity` — keeps the outgoing screen in the hierarchy for
        // the length of the animation, and because it reads the shared view model it
        // drew the *new* screen's rows next to the new screen: pages mixed together.
        // The swap is now instant (the old screen is gone in the same frame) and the
        // incoming screen animates itself in (`ScreenEntryMotion`). This also stops
        // ContentView's `immersive` animation from leaking into the swap. Only
        // transactions that change the screen are affected; every other animation
        // inside (lens glide, Now Playing drift, switches) runs as before.
        .transaction(value: viewModel.currentScreen) { $0.animation = nil }
        .environment(\.locale, Locale(identifier: viewModel.language.rawValue))
        .onChange(of: viewModel.navigation.count) { _, new in
            lastDepth = new
        }
    }

    /// iOS's own push curve: fast out, long settle.
    static let navigationAnimation = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.38)

    /// A push slides the new list in from the trailing side; MENU slides the parent
    /// back in from the leading side. The outgoing list leaves at once (see `body`).
    /// Reduce Motion fades only.
    private var screenEntryOffset: CGFloat {
        reduceMotion ? 0 : (navigatesForward ? 72 : -72)
    }

    private var standardScreen: some View {
        VStack(spacing: 0) {
            screenContent
                .modifier(ScreenEntryMotion(offsetX: screenEntryOffset))
                .id(viewModel.currentScreen)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The title strip floats over the list: rows scroll up under its glass.
                .safeAreaInset(edge: .top, spacing: 0) { header }
                .clipped()

            LCDFooterBar(viewModel: viewModel)
        }
        .foregroundStyle(appearance.theme.lcdText)
        .background(appearance.theme.lcdBackground)
        .clipped()
    }

    @ViewBuilder
    private var screenContent: some View {
        switch viewModel.currentScreen {
        case .sources:
            SourceSwitcherView(viewModel: viewModel)
        case .search:
            SearchView(viewModel: viewModel)
        case .dailyRecommendations, .radio, .songs, .podcastEpisodes,
             .playlistTracks, .artistTracks, .albumTracks:
            TrackListView(viewModel: viewModel)
        case .appearance, .neteaseSettings, .spotifySettings, .languages:
            SettingsView(viewModel: viewModel, screen: viewModel.currentScreen)
        case .home:
            homeSplit
        default:
            menu
        }
    }

    /// 3.1: the root menu is the iPod classic's split screen. The same list, in
    /// the same order, on the leading side; a preview of whatever the lens is on
    /// fills the trailing side and runs up under the glass title strip.
    private var homeSplit: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                menu
                    .frame(width: (geometry.size.width * 0.55).rounded())
                HomePreviewPane(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The glass title strip. Same title, same two status marks as before; the
    /// strip itself is translucent so the list reads through it as it scrolls.
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // Screen titles are localized where they are built; an artist or
                // album name must not be run through the catalog a second time.
                Text(verbatim: viewModel.currentScreen.title)
                    .font(AppFont.header)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .modifier(ScreenEntryMotion(offsetX: reduceMotion ? 0 : (navigatesForward ? 40 : -26)))
                    .id(viewModel.currentScreen.title)
                Spacer(minLength: 4)
                // Always the same two slots: play/pause on the right, then the
                // playback mode. The mode never turns off and the play slot keeps
                // its width when it is empty, so the title bar does not reflow when
                // the setting changes or the first song starts. Both use the shared
                // ink-normalised glyph, which Now Playing draws at its large size.
                //
                // The play mark says whether something is loaded at all: an iPod
                // that has nothing in it shows no transport mark, and a lone "play"
                // triangle on a fresh launch read as a state when it was only an
                // empty slot. The mode is the quieter of the two marks.
                let hasTrack = viewModel.currentTrack != nil
                StatusGlyph(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill",
                            label: viewModel.isPlaying ? "暂停" : "播放",
                            inkHeight: Metrics.statusGlyphInkHeight,
                            slotWidth: Metrics.statusGlyphSlot,
                            tint: appearance.theme.lcdText)
                    .opacity(hasTrack ? 1 : 0)
                    .accessibilityHidden(!hasTrack)
                StatusGlyph(systemName: viewModel.playbackMode.symbolName,
                            label: viewModel.playbackMode.displayName,
                            inkHeight: Metrics.statusGlyphInkHeight,
                            slotWidth: Metrics.statusGlyphSlot,
                            tint: appearance.theme.lcdSecondaryText)
                    .padding(.trailing, 2)
            }
            // 10pt, the same grid the rows use. An 18pt header inset left the
            // title 8pt inboard of every row it was titling.
            .padding(.horizontal, Metrics.horizontalInset)
            .frame(height: Metrics.headerHeight)
            .padding(.top, safeTop)
            .background {
                // Glass: the theme's header gradient, thinned, over a blur of the rows
                // passing underneath.
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    appearance.theme.headerGradient.opacity(appearance.theme.isDark ? 0.80 : 0.72)
                }
                .environment(\.colorScheme, appearance.theme.isDark ? .dark : .light)
            }
            // The iOS 5/6 navigation bar carried a hard gloss across its top half.
            // Keeping it as a separate layer means the palette can stay matte.
            .overlay {
                LinearGradient(stops: [
                    .init(color: Color.white.opacity(appearance.theme.isDark ? 0.10 : 0.34), location: 0),
                    .init(color: Color.white.opacity(appearance.theme.isDark ? 0.03 : 0.12), location: 0.48),
                    .init(color: Color.clear, location: 0.52)
                ], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                // A hairline shadow under the gloss pins the bar to the list below it.
                Rectangle()
                    .fill(Color.black.opacity(appearance.theme.isDark ? 0.18 : 0.06))
                    .frame(height: 1)
                    .allowsHitTesting(false)
            }

            Rectangle().fill(appearance.theme.headerDivider.opacity(0.55)).frame(height: 0.5)
        }
        .shadow(color: .black.opacity(appearance.theme.isDark ? 0.30 : 0.08), radius: 6, y: 3)
    }

    private var menu: some View {
        // `menuEntries` and `selectedIndex` each rebuild the whole list. Read once per
        // pass: per row, an artist or album list cost N rebuilds of N entries.
        let entries = viewModel.menuEntries
        let selectedIndex = viewModel.selectedIndex
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            viewModel.selectMenuEntry(at: index)
                        } label: {
                            menuRow(entry, selected: index == selectedIndex)
                        }
                        .buttonStyle(LCDPressFeedbackStyle())
                        .id(entry.id)
                    }
                    if let message = viewModel.emptyStateMessage {
                        LCDEmptyState(message: message, tint: appearance.theme.lcdSecondaryText)
                            .padding(.vertical, 24)
                    }
                }
                // 3.1.5: one lens for the whole list, in the scroll content.
                .lcdLensHost()
            }
            .scrollIndicators(.hidden)
            .lcdEdgeFade(appearance.theme.lcdBackground)
            .modifier(LCDFastScrollIndex(selectedIndex: selectedIndex, count: entries.count) { index in
                entries.indices.contains(index) ? LCDFastScrollIndex.indexLetter(entries[index].title) : nil
            })
            .onChange(of: selectedIndex) { _, index in
                scrollToEntry(at: index, in: entries, proxy: proxy, animated: true)
            }
            .onChange(of: viewModel.currentScreen) { _, _ in
                scrollToEntry(at: selectedIndex, in: entries, proxy: proxy)
            }
            .onAppear {
                scrollToEntry(at: selectedIndex, in: entries, proxy: proxy)
            }
        }
    }

    /// The lazy stack can only reach rows it has not built yet by their ForEach identity.
    private func scrollToEntry(at index: Int, in entries: [MenuEntry], proxy: ScrollViewProxy,
                               animated: Bool = false) {
        guard entries.indices.contains(index) else { return }
        proxy.lcdFollow(entries[index].id, anchor: .center, animated: animated)
    }

    private func menuRow(_ entry: MenuEntry, selected: Bool) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                // MenuEntry already holds display text, localized at construction.
                Text(verbatim: entry.title)
                    .font(AppFont.title)
                if let detail = entry.detail {
                    Text(verbatim: detail)
                        .font(AppFont.detail)
                        .foregroundStyle(selected ? appearance.theme.selectionSecondaryInk : appearance.theme.lcdSecondaryText)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 3)
            if let switchValue = entry.switchValue {
                LCDSlideLock(isOn: switchValue)
            } else if entry.marked {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
            } else if entry.showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(selected ? appearance.theme.selectionSecondaryInk : appearance.theme.lcdSecondaryText)
            }
        }
        .padding(.horizontal, Metrics.horizontalInset)
        // One rule for every LCD row: a subtitle makes the row 60pt, otherwise 50pt.
        .frame(height: entry.detail == nil ? Metrics.singleLineRowHeight : Metrics.doubleLineRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(selected ? appearance.theme.selectionInk : appearance.theme.lcdText)
        .lcdSelectionBackground(selected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A small LCD slide-lock: the row remains the wheel/tap interaction target.
/// The knob is the iOS 26 shape — a wide capsule, not a dot — drawn by hand so it
/// looks the same on every OS version and stays legible on the pale LCD tracks.
@MainActor
struct LCDSlideLock: View {
    let isOn: Bool
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        Capsule()
            .fill(isOn ? appearance.theme.switchTrackOn : appearance.theme.switchTrackOff)
            .overlay { Capsule().strokeBorder(Color.black.opacity(appearance.theme.isDark ? 0.30 : 0.08), lineWidth: 0.5) }
            .frame(width: 52, height: 30)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(appearance.theme.switchKnob)
                    .overlay {
                        // The knob's own specular edge.
                        Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.9), Color.white.opacity(0)],
                                                              startPoint: .top, endPoint: .bottom),
                                               lineWidth: 1)
                    }
                    .frame(width: 32, height: 24)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1.5)
                    .padding(3)
            }
            .animation(.snappy(duration: 0.22), value: isOn)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - Shared LCD pieces

/// One renderer for every status mark on the LCD. Each symbol is cropped to the
/// ink it actually paints and scaled to a common ink height, so a wide mark
/// (shuffle), a narrow one (pause) and a filled one (play) share one visual size
/// and one centre line; an `HStack`'s spacing is then the exact edge-to-edge gap.
/// A caller that passes `slotWidth` also pins the mark's box, so cycling the
/// playback mode never slides its neighbour.
@MainActor
struct StatusGlyph: View {
    let systemName: String
    let label: String
    var inkHeight: CGFloat = Metrics.statusGlyphInkHeight
    var slotWidth: CGFloat? = nil
    var tint: Color = .primary

    var body: some View {
        Image(uiImage: StatusGlyphInk.image(systemName, inkHeight: inkHeight))
            .renderingMode(.template)
            .foregroundStyle(tint)
            .frame(width: slotWidth, height: inkHeight)
            .accessibilityLabel(label)
    }
}

/// The ink-normalised bitmap cache. SF Symbols keep their designed proportions at
/// one point size, but those proportions leave shuffle taller and wider than
/// play/pause and leave each glyph with its own side bearings; cropping to the
/// ink removes both differences.
@MainActor
enum StatusGlyphInk {
    private static var cache: [String: UIImage] = [:]

    static func image(_ systemName: String, inkHeight: CGFloat) -> UIImage {
        let key = systemName + "@" + String(format: "%.1f", inkHeight)
        if let cached = cache[key] { return cached }
        let configuration = UIImage.SymbolConfiguration(pointSize: inkHeight + 2, weight: .semibold)
        guard let symbol = UIImage(systemName: systemName, withConfiguration: configuration) else {
            return UIImage()
        }
        let normalized = normalizingInk(symbol, height: inkHeight)
        cache[key] = normalized
        return normalized
    }

    private static func normalizingInk(_ symbol: UIImage, height: CGFloat) -> UIImage {
        guard symbol.size.width > 0, symbol.size.height > 0 else { return symbol }
        let format = UIGraphicsImageRendererFormat()
        // Render vector symbols at the display scale while preserving their point size.
        let rendered = UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
            symbol.withTintColor(.white, renderingMode: .alwaysOriginal).draw(at: .zero)
        }
        guard let bitmap = rendered.cgImage else { return symbol }
        let width = bitmap.width
        let pixelHeight = bitmap.height
        var pixels = [UInt8](repeating: 0, count: width * pixelHeight * 4)
        let ink: CGRect? = pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> CGRect? in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: pixelHeight,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                            | CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(pixelHeight)))
            guard let alpha = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var minX = width, maxX = -1, minY = pixelHeight, maxY = -1
            for y in 0..<pixelHeight {
                for x in 0..<width where alpha[(y * width + x) * 4 + 3] > 0 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        guard let ink,
              let cropped = bitmap.cropping(to: ink) else { return symbol }
        let inked = UIImage(cgImage: cropped, scale: rendered.scale, orientation: .up)
        let target = CGSize(width: (inked.size.width * height / inked.size.height).rounded(),
                            height: height)
        let output = UIGraphicsImageRendererFormat()
        output.scale = rendered.scale
        return UIGraphicsImageRenderer(size: target, format: output).image { _ in
            inked.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// The LCD's bottom line. It only speaks when there is something to say: the
/// wheel's transient feedback, a like confirmation, or a running load. Idle it is
/// blank — the source name already sits in the screen's own header, and the "3 / 42"
/// counter put a number under every list. The bar keeps its height either way, so
/// a status appearing or leaving never moves the list above it.
///
/// Centred, not left/right: the panel's bottom corners are rounded (concentric
/// with the device, up to 43pt), and 10pt-inset text on a 24pt bar sat inside that
/// curve and was clipped. Centred text is nowhere near a corner on any device.
///
/// Its own view so the wheel — which changes `selectedIndex` on every step —
/// repaints this strip and not the whole screen.
@MainActor
private struct LCDFooterBar: View {
    let viewModel: PlayerViewModel
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(appearance.theme.footerDivider)
                .frame(height: 1)
                .opacity(hasStatus ? 1 : 0)
            statusLine
                .font(AppFont.caption)
                .lineLimit(1)
                .foregroundStyle(appearance.theme.lcdSecondaryText)
                .padding(.horizontal, Metrics.horizontalInset)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.footerHeight - 1)
        }
        // Idle: no hairline and no tinted strip, so the list ends on the panel
        // instead of above a chin. Active: the strip comes back with its divider,
        // the way a status line reads as a separate band.
        .background(hasStatus ? appearance.theme.footerBackground : Color.clear)
        .animation(.easeInOut(duration: 0.18), value: hasStatus)
        .accessibilityElement(children: .combine)
        .accessibilityHidden(!hasStatus)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 5) {
            if let status = viewModel.wheelStatus ?? viewModel.likeStatus {
                Text(status)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(appearance.theme.lcdText)
            } else if viewModel.isSearching {
                ProgressView().controlSize(.mini)
                Text("正在搜索")
            } else if viewModel.isLoadingLibrary {
                ProgressView().controlSize(.mini)
                Text("正在载入")
            }
        }
    }

    /// Nothing transient is showing, so the strip is blank and silent.
    private var hasStatus: Bool {
        viewModel.wheelStatus != nil || viewModel.likeStatus != nil
            || viewModel.isSearching || viewModel.isLoadingLibrary
    }
}

/// A direct tap on a row dims its ink while the finger is down. The wheel's
/// selection bar is a different signal and never moves for a touch, so without
/// this a tapped row looked like it had not been pressed at all.
@MainActor
struct LCDPressFeedbackStyle: ButtonStyle {
    @EnvironmentObject private var appearance: AppearanceSettings

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                if configuration.isPressed {
                    // The same footprint as the selection lens, so a touched row and a
                    // wheel-selected row are the same shape.
                    LCDSelectionFootprint()
                        .fill(Color.black.opacity(appearance.theme.isDark ? 0.22 : 0.10))
                        .allowsHitTesting(false)
                }
            }
    }
}

/// How far a scroll view's content has moved under each edge, as 0…1 of the fade
/// height. Quantised to quarters so the scroll callback fires a few times per edge
/// crossing instead of on every frame.
private struct LCDScrollEdges: Equatable {
    var top: CGFloat
    var bottom: CGFloat
}

/// Rows fade into the LCD under the header and above the footer instead of being
/// cut off mid-glyph at the clip edge.
///
/// Each fade only exists while there is content under it. Always-on, it also
/// painted over the selection lens whenever the first or last row was selected:
/// the lens' top (or bottom) edge dissolved into the screen exactly where the list
/// starts, which is where nothing needs hiding. On iOS 17 there is no way to read
/// the scroll position, so it keeps the old always-on fade there.
@MainActor
private struct LCDEdgeFade: ViewModifier {
    let color: Color
    /// Until the scroll view reports, assume a list that starts at its top with
    /// more below it, which is how every list on the LCD opens.
    @State private var edges = LCDScrollEdges(top: 0, bottom: 1)

    private var tracksScroll: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    func body(content: Content) -> some View {
        tracked(content)
            // 3.1.5: iOS 26 adds its own soft scroll-edge blur under any bar placed
            // with `safeAreaInset`. It is drawn by the system scroll view, outside
            // the LCD's rounded clip, so rows bled through it past the panel's
            // corners. The glass title strip already is that effect, so it is off.
            .lcdScrollEdgeEffectHidden()
            .overlay(alignment: .top) {
                fade(from: color, to: color.opacity(0))
                    .opacity(tracksScroll ? edges.top : 1)
            }
            .overlay(alignment: .bottom) {
                fade(from: color.opacity(0), to: color)
                    .opacity(tracksScroll ? edges.bottom : 1)
            }
    }

    @ViewBuilder
    private func tracked(_ content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: LCDScrollEdges.self) { geometry in
                func steps(_ distance: CGFloat) -> CGFloat {
                    (min(max(distance / Metrics.edgeFadeHeight, 0), 1) * 4).rounded() / 4
                }
                return LCDScrollEdges(top: steps(geometry.visibleRect.minY),
                                      bottom: steps(geometry.contentSize.height - geometry.visibleRect.maxY))
            } action: { _, new in
                withAnimation(.easeOut(duration: 0.12)) { edges = new }
            }
        } else {
            content
        }
    }

    private func fade(from start: Color, to end: Color) -> some View {
        LinearGradient(colors: [start, end], startPoint: .top, endPoint: .bottom)
            .frame(height: Metrics.edgeFadeHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    func lcdEdgeFade(_ color: Color) -> some View { modifier(LCDEdgeFade(color: color)) }

    @ViewBuilder
    func lcdScrollEdgeEffectHidden() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}

/// The one empty/placeholder block: a light symbol over a single line of text, in
/// the LCD's own secondary colour. The list, Now Playing and Cover Flow each used
/// to draw their own version at a different size and colour.
@MainActor
struct LCDEmptyState: View {
    let message: String
    var symbol: String = "music.note"
    var tint: Color

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .accessibilityHidden(true)
            Text(message)
                .font(AppFont.body)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.horizontalInset)
        .accessibilityElement(children: .combine)
    }
}

/// Spin the wheel fast through a long list and a glass bubble shows the first
/// letter of the row under the lens, the way the iPod classic flashed a letter
/// while you flew through Songs. It appears only after several steps in quick
/// succession, so ordinary scrolling never sees it, and leaves shortly after the
/// wheel stops.
@MainActor
struct LCDFastScrollIndex: ViewModifier {
    let selectedIndex: Int
    let count: Int
    let label: (Int) -> String?
    @EnvironmentObject private var appearance: AppearanceSettings
    @State private var stamps: [TimeInterval] = []
    @State private var letter: String?
    @State private var hideTask: Task<Void, Never>?

    /// Lists shorter than this are quick to scroll anyway.
    private static let minimumCount = 20
    /// This many steps inside `window` seconds counts as a fast spin.
    private static let stepsToShow = 4
    private static let window: TimeInterval = 0.4

    func body(content: Content) -> some View {
        content
            .overlay {
                if let letter {
                    bubble(letter)
                        .transition(.scale(scale: 0.82).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: letter == nil)
            .onChange(of: selectedIndex) { _, index in noteStep(at: index) }
            .onDisappear {
                hideTask?.cancel()
                letter = nil
                stamps = []
            }
    }

    private func noteStep(at index: Int) {
        guard count >= Self.minimumCount else { return }
        let now = ProcessInfo.processInfo.systemUptime
        stamps = (stamps + [now]).filter { now - $0 < Self.window }
        guard stamps.count >= Self.stepsToShow || letter != nil,
              let text = label(index) else { return }
        letter = text
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            letter = nil
        }
    }

    private func bubble(_ text: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        return Text(verbatim: text)
            .font(AppFont.indexBubble)
            .foregroundStyle(appearance.theme.lcdText)
            .frame(width: 96, height: 96)
            .background(.regularMaterial, in: shape)
            .overlay { shape.strokeBorder(Color.white.opacity(appearance.theme.isDark ? 0.18 : 0.70), lineWidth: 0.75) }
            .shadow(color: .black.opacity(0.22), radius: 16, y: 10)
            .environment(\.colorScheme, appearance.theme.isDark ? .dark : .light)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The index letter for a row title: its first letter or digit, upper-cased.
    /// A Chinese title shows its first character.
    static func indexLetter(_ title: String) -> String? {
        guard let first = title.first(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return String(first).uppercased()
    }
}

/// The trailing half of the root menu: a picture of the selected row. Music shows
/// a 2 × 2 grid of covers, Podcasts the first show's cover, Now Playing the
/// current song, Playback Mode its symbol, Settings the body colours. It changes
/// with the lens and never takes a touch; the list beside it is the control.
@MainActor
struct HomePreviewPane: View {
    let viewModel: PlayerViewModel
    @EnvironmentObject private var appearance: AppearanceSettings

    private enum Kind: Hashable { case music, podcasts, settings, mode, nowPlaying, none }

    /// 3.1.2: the pane follows the LCD's own rules instead of inventing its own.
    /// It sits below the title strip (no longer under it), uses the theme's LCD
    /// colours, and every row gets the same layout: one square card, centred,
    /// with a caption under it in the list's type. Nothing is rotated, cropped to
    /// the pane's tall shape, or drifting.
    private enum Layout {
        static let inset: CGFloat = 14
        static let cardRadius: CGFloat = 10
        static let captionGap: CGFloat = 10
    }

    private var selectedEntry: MenuEntry? {
        let entries = viewModel.menuEntries
        let index = viewModel.selectedIndex
        return entries.indices.contains(index) ? entries[index] : nil
    }

    private func kind(of entry: MenuEntry?) -> Kind {
        guard let entry else { return .none }
        switch entry.action {
        case .open(.music): return .music
        case .open(.podcasts): return .podcasts
        case .open(.settings): return .settings
        case .open(.nowPlaying): return .nowPlaying
        case .playbackMode: return .mode
        default: return .none
        }
    }

    private var theme: ThemePalette { appearance.theme }

    var body: some View {
        let entry = selectedEntry
        let kind = kind(of: entry)
        GeometryReader { geometry in
            let side = max(0, min(geometry.size.width - Layout.inset * 2, geometry.size.height * 0.62))
            VStack(spacing: Layout.captionGap) {
                card(kind, side: side)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                            .strokeBorder(theme.lcdText.opacity(0.10), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.16), radius: 8, y: 4)
                caption(kind, entry: entry)
                    .frame(width: side)
            }
            .opacity(kind == .none ? 0 : 1)
            .frame(width: geometry.size.width, height: geometry.size.height)
            // Same fix as the screen swap: instant swap, the new card fades itself in.
            .modifier(ScreenEntryMotion(animation: .easeOut(duration: 0.22)))
            .id(kind)
        }
        .transaction(value: kind) { $0.animation = nil }
        .background(theme.lcdBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.headerDivider.opacity(0.55)).frame(width: 0.5)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Card

    @ViewBuilder
    private func card(_ kind: Kind, side: CGFloat) -> some View {
        switch kind {
        case .music:
            let urls = viewModel.coverFlowAlbums.prefix(4).compactMap(\.artworkURL)
            if urls.isEmpty { placeholder("music.note") } else { mosaic(urls, side: side) }
        case .podcasts:
            artwork(viewModel.podcastShows.first?.artworkURL, symbol: "mic")
        case .nowPlaying:
            artwork(viewModel.currentTrack?.artworkURL, symbol: "music.note")
        case .mode:
            symbolCard(viewModel.playbackMode.symbolName, side: side)
        case .settings:
            bodyColours(side: side)
        case .none:
            Color.clear
        }
    }

    /// Four covers in a 2 × 2 grid, the way the classic showed a library.
    private func mosaic(_ urls: [URL], side: CGFloat) -> some View {
        let gap: CGFloat = 2
        let tile = (side - gap) / 2
        let filled = (0..<4).map { urls[$0 % urls.count] }
        return VStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<2, id: \.self) { column in
                        artwork(filled[row * 2 + column], symbol: "music.note")
                            .frame(width: tile, height: tile)
                            .clipped()
                    }
                }
            }
        }
        .background(theme.lcdText.opacity(0.08))
    }

    private func artwork(_ url: URL?, symbol: String) -> some View {
        CachedArtwork(url: url) { image in
            if let image {
                image.resizable().scaledToFill()
            } else {
                placeholder(symbol)
            }
        }
    }

    private func placeholder(_ symbol: String) -> some View {
        ZStack {
            theme.lcdText.opacity(0.07)
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.lcdSecondaryText)
        }
    }

    private func symbolCard(_ symbol: String, side: CGFloat) -> some View {
        ZStack {
            appearance.accent.opacity(theme.isDark ? 0.22 : 0.14)
            Image(systemName: symbol)
                .font(.system(size: side * 0.36, weight: .semibold))
                .foregroundStyle(appearance.accent)
        }
    }

    /// Three little iPods in body colours, the current one in front.
    private func bodyColours(side: CGFloat) -> some View {
        let current = appearance.effectiveThemePreset
        let others = AppThemePreset.allCases.filter { $0 != current }
        let small = side * 0.30
        return ZStack {
            theme.lcdText.opacity(0.07)
            ZStack {
                miniPod(others[others.count > 2 ? 1 : 0].palette, width: small)
                    .rotationEffect(.degrees(-12)).offset(x: -side * 0.24, y: side * 0.04)
                miniPod(others[others.count > 2 ? 2 : 0].palette, width: small)
                    .rotationEffect(.degrees(12)).offset(x: side * 0.24, y: side * 0.04)
                miniPod(current.palette, width: side * 0.36)
            }
        }
    }

    private func miniPod(_ palette: ThemePalette, width: CGFloat) -> some View {
        let height = width * 1.72
        let shape = RoundedRectangle(cornerRadius: width * 0.2, style: .continuous)
        return ZStack(alignment: .top) {
            shape.fill(palette.bodyBackground)
            shape.strokeBorder(Color.black.opacity(0.16), lineWidth: 1)
            RoundedRectangle(cornerRadius: width * 0.14, style: .continuous)
                .fill(Color(white: 0.05))
                .frame(width: width - 8, height: height * 0.45)
                .padding(.top, 4)
            Circle()
                .fill(Color.white.opacity(palette.isDark ? 0.22 : 0.92))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 1))
                .overlay(Circle().fill(palette.bodyBackground).frame(width: width * 0.22, height: width * 0.22)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 1)))
                .frame(width: width * 0.6, height: width * 0.6)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, height * 0.08)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.25), radius: 4, y: 3)
    }

    // MARK: Caption

    /// Two lines in the list's own type and colours. Strings come from what the
    /// app already shows (the row's title and subtitle, the track, the show), so
    /// nothing new needs translating.
    private func caption(_ kind: Kind, entry: MenuEntry?) -> some View {
        let lines: (String, String?) = {
            switch kind {
            case .nowPlaying:
                return (viewModel.currentTrack?.title ?? entry?.title ?? "", viewModel.currentTrack?.artist)
            case .podcasts:
                if let show = viewModel.podcastShows.first { return (show.title, show.author) }
                return (entry?.title ?? "", entry?.detail)
            default:
                return (entry?.title ?? "", entry?.detail)
            }
        }()
        return VStack(spacing: 2) {
            Text(verbatim: lines.0)
                .font(AppFont.detail.weight(.semibold))
                .foregroundStyle(theme.lcdText)
            if let detail = lines.1, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(AppFont.caption)
                    .foregroundStyle(theme.lcdSecondaryText)
            }
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
    }
}


/// 3.1.1: the entrance of a newly inserted screen (or title, or Home preview).
/// Put it *inside* the `.id(...)` so every new identity gets fresh state: the view
/// is drawn once at its start pose and then animates to rest on appear. Nothing
/// animates on the way out, so two screens are never on the LCD at the same time.
/// The start pose is captured once, when the view is created; later body passes
/// (the navigation depth updating, say) do not move it.
@MainActor
struct ScreenEntryMotion: ViewModifier {
    @State private var startX: CGFloat
    @State private var startScale: CGFloat
    @State private var settled = false
    private let animation: Animation

    /// `nil` means the navigation curve. It is resolved in the body, not as the
    /// default value: default arguments are evaluated outside the main actor, so
    /// they cannot read `ScreenView.navigationAnimation`.
    init(offsetX: CGFloat = 0, scale: CGFloat = 1, animation: Animation? = nil) {
        _startX = State(initialValue: offsetX)
        _startScale = State(initialValue: scale)
        self.animation = animation ?? ScreenView.navigationAnimation
    }

    func body(content: Content) -> some View {
        content
            .offset(x: settled ? 0 : startX)
            .scaleEffect(settled ? 1 : startScale)
            .opacity(settled ? 1 : 0)
            .animation(animation, value: settled)
            .onAppear { settled = true }
    }
}
