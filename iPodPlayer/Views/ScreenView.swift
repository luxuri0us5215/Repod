import SwiftUI
import UIKit

@MainActor
struct ScreenView: View {
    let viewModel: PlayerViewModel
    var safeTop: CGFloat = 0
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        Group {
            if viewModel.currentScreen == .nowPlaying {
                NowPlayingView(viewModel: viewModel, clock: viewModel.clock)
                    .padding(.top, safeTop)
                    .background(AppThemePreset.midnight.palette.lcdBackground)
            } else {
                standardScreen
            }
        }
        .environment(\.locale, Locale(identifier: viewModel.language.rawValue))
    }

    private var standardScreen: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // Screen titles are localized where they are built; an artist or
                // album name must not be run through the catalog a second time.
                Text(verbatim: viewModel.currentScreen.title)
                    .font(AppFont.header)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
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
            }
            // 10pt, the same grid the rows use. An 18pt header inset left the
            // title 8pt inboard of every row it was titling.
            .padding(.horizontal, Metrics.horizontalInset)
            .frame(height: Metrics.headerHeight)
            .padding(.top, safeTop)
            .background(appearance.theme.headerGradient)

            Rectangle().fill(appearance.theme.headerDivider).frame(height: 1)

            Group {
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
                default:
                    menu
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Rectangle().fill(appearance.theme.footerDivider).frame(height: 1)
            LCDFooterBar(viewModel: viewModel)
        }
        .foregroundStyle(appearance.theme.lcdText)
        .background(appearance.theme.lcdBackground)
        .clipped()
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
            }
            .scrollIndicators(.hidden)
            .lcdEdgeFade(appearance.theme.lcdBackground)
            .onChange(of: selectedIndex) { _, index in
                scrollToEntry(at: index, in: entries, proxy: proxy)
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
    private func scrollToEntry(at index: Int, in entries: [MenuEntry], proxy: ScrollViewProxy) {
        guard entries.indices.contains(index) else { return }
        proxy.scrollTo(entries[index].id, anchor: .center)
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
                        .foregroundStyle(selected ? Color.black : appearance.theme.lcdSecondaryText)
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
                    .foregroundStyle(selected ? Color.black : appearance.theme.lcdSecondaryText)
            }
        }
        .padding(.horizontal, Metrics.horizontalInset)
        // One rule for every LCD row: a subtitle makes the row 60pt, otherwise 50pt.
        .frame(height: entry.detail == nil ? Metrics.singleLineRowHeight : Metrics.doubleLineRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(selected ? Color.black : appearance.theme.lcdText)
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
        statusLine
            .font(AppFont.caption)
            .lineLimit(1)
            .foregroundStyle(appearance.theme.lcdSecondaryText)
            .padding(.horizontal, Metrics.horizontalInset)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.footerHeight)
            .background(appearance.theme.footerBackground)
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
