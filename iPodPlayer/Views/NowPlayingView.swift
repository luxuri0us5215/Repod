import Foundation
import SwiftUI
import UIKit

@MainActor
struct NowPlayingView: View {
    let viewModel: PlayerViewModel
    @ObservedObject var clock: PlaybackClock
    /// 3.1.3: the LCD band behind the Dynamic Island / status bar. The screen now
    /// runs up under it (the cover glow included) and the glass title strip covers
    /// it, as on every list. Before, the band was padded off in flat midnight and
    /// met the glowing backdrop in a hard seam.
    var safeTop: CGFloat = 0
    private let displayPalette = AppThemePreset.midnight.palette
    @Environment(\.scenePhase) private var scenePhase
    @State private var displayedTrack: Track?
    @State private var isVisible = false
    @State private var animationSession = UUID()
    @State private var floatingHeartID: UUID?

    var body: some View {
        GeometryReader { geometry in
            mainContent(in: geometry)
        }
        .background(displayPalette.lcdBackground)
        .onAppear {
            isVisible = true
            resetVisuals()
        }
        .onDisappear {
            isVisible = false
            resetVisuals()
        }
        .onChange(of: scenePhase) { _, _ in resetVisuals() }
        .onChange(of: viewModel.currentTrack) { _, track in
            updateDisplayedTrack(track)
        }
        .onChange(of: viewModel.likeAnimation) { _, event in
            guard isVisible, scenePhase == .active, let event, event.isLiked,
                  let track = displayedTrack, event.trackID == viewModel.trackLikeID(for: track) else { return }
            floatingHeartID = event.id
        }
    }

    /// The layout is split at the seams the type checker struggled with: the
    /// track block, the empty state and the corner status each type-check on
    /// their own instead of as one deeply nested expression.
    private func mainContent(in geometry: GeometryProxy) -> some View {
        // Four bands on one 18pt inset: status marks, the source mark, the track
        // (cover + text, centred in whatever height is left) and the progress.
        // The status row is a real row now, not an overlay with a matching magic
        // top padding, so the cover budget below is the sum of the rows.
        VStack(alignment: .leading, spacing: 0) {
            // 3.1.3: the status marks moved into the top row (see `topRow`).
            brandHeader(source: viewModel.currentTrack?.source ?? viewModel.selectedSource)
                .padding(.top, Layout.stripToBrand)

            if let track = displayedTrack {
                trackBlock(track, in: geometry)
                    .padding(.vertical, Layout.coverGap)
                // Track identity animates only the artwork/text container.
                // Progress, timestamps and the footer always update immediately.
                NowPlayingProgress(viewModel: viewModel, clock: clock)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
            } else {
                // No track, no progress — but the wheel still changes the volume
                // here, so the row keeps the progress bar's slot and turns into
                // the volume bar on demand.
                VStack(spacing: 0) {
                    emptyState
                    NowPlayingProgress(viewModel: viewModel, clock: clock, hasTrack: false)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                }
            }
        }
        .padding(.horizontal, Layout.inset)
        .padding(.bottom, Layout.inset)
        .padding(.top, safeTop + Layout.stripHeight)
        .frame(width: geometry.size.width, height: geometry.size.height)
        // 3.1: the screen is lit by the song — a slow-drifting blur of its cover
        // under a dark wash, instead of a flat midnight panel. It fills the whole
        // LCD, the band under the glass strip included.
        .background {
            NowPlayingBackdrop(url: (displayedTrack ?? viewModel.currentTrack)?.artworkURL,
                               base: displayPalette.lcdBackground)
        }
        .overlay(alignment: .top) { topRow }
    }

    /// The list header's row (title on the left, play/pause and playback mode on the
    /// right, 30pt plus the band above it), in the Now Playing screen's own midnight
    /// palette. 3.1.5: drawn on the backdrop itself, not on a glass strip.
    private var topRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(verbatim: viewModel.currentScreen.title)
                    .font(AppFont.header)
                    .foregroundStyle(displayPalette.lcdText)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                let hasTrack = viewModel.currentTrack != nil
                StatusGlyph(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill",
                            label: viewModel.isPlaying ? "暂停" : "播放",
                            inkHeight: Metrics.statusGlyphInkHeight,
                            slotWidth: Metrics.statusGlyphSlot,
                            tint: displayPalette.lcdText)
                    .opacity(hasTrack ? 1 : 0)
                    .accessibilityHidden(!hasTrack)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
                StatusGlyph(systemName: viewModel.playbackMode.symbolName,
                            label: viewModel.playbackMode.displayName,
                            inkHeight: Metrics.statusGlyphInkHeight,
                            slotWidth: Metrics.statusGlyphSlot,
                            tint: displayPalette.lcdSecondaryText)
                    .padding(.trailing, 2)
            }
            .padding(.horizontal, Metrics.horizontalInset)
            .frame(height: Metrics.headerHeight)
            .padding(.top, safeTop)
            // Keeps the 0.5pt the old divider took, so the layout budget is unchanged.
            Color.clear.frame(height: 0.5)
        }
        // 3.1.5: no surface of its own. The row sits straight on the cover-lit
        // backdrop, whose top wash already darkens this band, so Now Playing is one
        // continuous block from the top edge down instead of a glass strip laid
        // over a second panel.
    }

    /// Every fixed height on this screen, so the cover's budget is a sum instead of
    /// a number somebody once measured.
    private enum Layout {
        static let inset: CGFloat = 18
        /// The top row (30pt + 0.5pt), drawn over the content.
        static let stripHeight: CGFloat = Metrics.headerHeight + 0.5
        /// Air between the strip and the source mark.
        static let stripToBrand: CGFloat = 16
        static let brandHeight: CGFloat = 32
        /// Minimum air above and below the cover. On a tall screen the cover is
        /// centred and the air grows; on a short one it is exactly this.
        static let coverGap: CGFloat = 13
        /// 5pt bar + 7pt gap + one 12pt timestamp line, with a little slack.
        static let progressHeight: CGFloat = 28
        static let coverTextGap: CGFloat = 14
        static var chrome: CGFloat {
            inset + stripHeight + stripToBrand + brandHeight
                + coverGap * 2 + progressHeight
        }
    }

    private func trackBlock(_ track: Track, in geometry: GeometryProxy) -> some View {
        let artworkSide = max(64, min(180, (geometry.size.width - Layout.inset * 2) / 2,
                                      geometry.size.height - safeTop - Layout.chrome))
        return ZStack {
            HStack(alignment: .center, spacing: Layout.coverTextGap) {
                // No `.clipped()` here: the face clips itself, and a frame clip would
                // cut off the backlight glow that bleeds past the cover's edge.
                artwork(url: track.artworkURL, side: artworkSide)
                    .frame(width: artworkSide, height: artworkSide)
                // Title on its own; artist and album are one group, so they sit
                // closer to each other (3pt) than to the title (8pt). The block can
                // never be taller than the cover, so a long title truncates instead
                // of pushing into the rows above and below.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        titleText(track.title)
                            .font(AppFont.hero)
                            .foregroundStyle(displayPalette.lcdText)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        if let likeID = viewModel.trackLikeID(for: track) {
                            TrackLikeHeart(
                                isLiked: viewModel.isLiked(track),
                                confirmation: likeConfirmation(for: likeID),
                                showsOutline: false
                            )
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        FloatingHeartOverlay(
                            isCurrentTrack: track.id == viewModel.currentTrack?.id,
                            heartID: floatingHeartID
                        ) { floatingHeartID = nil }
                    }
                    Text(verbatim: track.artist)
                        .font(AppFont.body)
                        .foregroundStyle(displayPalette.lcdText)
                        .lineLimit(2)
                        .padding(.top, 8)
                    Text(verbatim: track.album)
                        .font(AppFont.detail)
                        .foregroundStyle(displayPalette.lcdSecondaryText)
                        .lineLimit(2)
                        .padding(.top, 3)
                }
                .frame(maxWidth: .infinity, maxHeight: artworkSide, alignment: .leading)
            }
            .id(track.id)
            .transition(songTransition)
        }
        .id(animationSession)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var emptyState: some View {
        LCDEmptyState(message: viewModel.emptyStateMessage ?? "暂无歌曲",
                      tint: displayPalette.lcdSecondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusRow: some View {
        HStack(spacing: 9) {
            // Play/pause first, then the playback mode — the same order as the
            // list header. Both are drawn by the shared ink-normalised renderer at
            // its large size; the mode keeps a fixed slot so cycling it does not
            // slide its neighbour.
            StatusGlyph(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill",
                        label: viewModel.isPlaying ? "暂停" : "播放",
                        inkHeight: Metrics.statusGlyphInkHeightLarge,
                        tint: displayPalette.lcdText)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
            StatusGlyph(systemName: viewModel.playbackMode.symbolName,
                        label: viewModel.playbackMode.displayName,
                        inkHeight: Metrics.statusGlyphInkHeightLarge,
                        slotWidth: Metrics.statusGlyphSlotLarge,
                        tint: displayPalette.lcdText)
            // The row spans the full content width, so the marks keep their left
            // alignment whatever the wordmark below is.
            Spacer(minLength: 0)
        }
        .frame(height: Metrics.statusGlyphInkHeightLarge)
    }

    private var songTransition: AnyTransition {
        let fromRight = viewModel.trackTransitionDirection == .forward
        return .asymmetric(
            insertion: .move(edge: fromRight ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: fromRight ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func updateDisplayedTrack(_ track: Track?) {
        let changedID = displayedTrack?.id != track?.id
        let shouldAnimate = isVisible && scenePhase == .active && changedID
            && displayedTrack != nil && track != nil
        var transaction = Transaction(animation: shouldAnimate ? .easeOut(duration: 0.3) : nil)
        transaction.disablesAnimations = !shouldAnimate
        withTransaction(transaction) {
            displayedTrack = track
            if changedID { floatingHeartID = nil }
        }
    }

    private func resetVisuals() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // Replacing the container discards any outgoing track, even if the
            // scene was suspended halfway through a transition. No history queues.
            animationSession = UUID()
            displayedTrack = viewModel.currentTrack
            floatingHeartID = nil
        }
    }

    /// The source mark as it was in 2.0: a 32pt round badge and the wordmark in the
    /// hero weight, bare on the LCD. (2.1's glass chip was tried and put back.)
    private func brandHeader(source: AudioSource) -> some View {
        HStack(spacing: 7) {
            if source == .spotify {
                ZStack {
                    Circle().fill(spotifyGreen)
                    SpotifyArcs()
                        .stroke(Color.black, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
                Text("Spotify")
                    .foregroundStyle(spotifyGreen)
            } else {
                ZStack {
                    Circle().fill(neteaseRed)
                    // The official mark as a line drawing, with the note head and
                    // the bottom band of the outer ring filled in, so red only
                    // shows through the record's opening and the teardrop gap
                    // under the stylus.
                    Image("NetEaseLogo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 21, height: 23)
                        .foregroundStyle(Color.white)
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
                Text("网易云音乐")
                    .foregroundStyle(Color.white)
            }
        }
        .font(AppFont.hero)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音源：" + source.displayName)
    }

    private var spotifyGreen: Color {
        Color(red: 29.0 / 255, green: 185.0 / 255, blue: 84.0 / 255)
    }

    private var neteaseRed: Color {
        // Official NetEase Cloud Music red (#DD001B), taken from the brand icon.
        Color(red: 221.0 / 255, green: 0.0, blue: 27.0 / 255)
    }

    private func titleText(_ title: String) -> Text {
        // Song titles are user data, never app copy.
        let text = Text(verbatim: title)
        return Self.isLatinTitle(title) ? text.italic() : text
    }

    /// The heart's confirmation burst belongs to one track only. Kept out of the
    /// row builder: inlining the ternary with both branches optional pushed that
    /// expression past the type checker's budget.
    private func likeConfirmation(for likeID: String) -> LikeAnimationEvent? {
        guard viewModel.likeAnimation?.trackID == likeID else { return nil }
        return viewModel.likeAnimation
    }

    static func isLatinTitle(_ title: String) -> Bool {
        // Ignore punctuation, digits and combining accents; every letter must
        // be Latin. Mixed Latin/CJK titles keep all their glyphs upright.
        let letters = title.unicodeScalars.filter { CharacterSet.letters.contains($0)
            && !CharacterSet.nonBaseCharacters.contains($0) }
        return !letters.isEmpty && letters.allSatisfy { scalar in
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x02AF,
                 0x1D00...0x1DBF, 0x1E00...0x1EFF, 0x2C60...0x2C7F,
                 0xA720...0xA7FF, 0xAB30...0xAB6F, 0x10780...0x107BF,
                 0x1DF00...0x1DFFF: return true
            default: return false
            }
        }
    }

    private func artwork(url: URL?, side: CGFloat) -> some View {
        // The cover and its backlight lean with the phone; the rest of the screen
        // stays put, so the card reads as an object sitting on the glass.
        ArtworkTilt(cornerRadius: Metrics.nowPlayingArtworkRadius) {
            CachedArtwork(url: url) { image in
                ZStack {
                    if let image, Metrics.artworkGlowOpacity > 0 {
                        // The cover's own colours bleeding softly out from behind it, like an
                        // LCD backlight. Clipped to the cover's square first so a non-square
                        // image cannot spill, then blurred.
                        Color.clear
                            .overlay { image.resizable().scaledToFill() }
                            .clipped()
                            .blur(radius: 18)
                            .opacity(Metrics.artworkGlowOpacity)
                            .scaleEffect(1.04)
                            .offset(y: 6)
                            .accessibilityHidden(true)
                    }
                    artworkFace(image, side: side)
                }
            }
        }
        .accessibilityLabel(url == nil ? "专辑封面占位图" : "专辑封面")
    }

    private func artworkFace(_ image: Image?, side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.nowPlayingArtworkRadius, style: .continuous)
        return Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                // No cover: a faintly lit slab with the note scaled to the cover, so
                // the empty square reads as a placeholder, not as a hole in the screen.
                ZStack {
                    displayPalette.footerBackground
                    LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.26, weight: .light))
                        .foregroundStyle(displayPalette.lcdSecondaryText.opacity(0.8))
                }
            }
        }
        .clipShape(shape)
        // A pale cover must not melt into the dark screen.
        .overlay { shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1) }
    }
}

/// The heart's burst over the title row. A separate view so neither the row body
/// nor a `@ViewBuilder` function has to carry this optional-and-delayed subtree.
@MainActor
private struct FloatingHeartOverlay: View {
    let isCurrentTrack: Bool
    let heartID: UUID?
    let onFinish: () -> Void

    var body: some View {
        if isCurrentTrack, let heartID {
            FloatingLikeHeart()
                .id(heartID)
                .allowsHitTesting(false)
                .task(id: heartID) {
                    do { try await Task.sleep(for: .milliseconds(400)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    onFinish()
                }
        }
    }
}

/// Observes the clock alone, so the 4 Hz position ticks repaint the progress row
/// instead of the artwork, titles and every screen that observes the view model.
///
/// It is also the volume bar, the way a real iPod's is: while the wheel changes
/// the volume, this same 5pt line fills with the volume level and the timestamps
/// become a 音量 / percent readout. Nothing appears above the screen, so the
/// feedback can never cover the cover or the title, and the row's height never
/// changes.
@MainActor
private struct NowPlayingProgress: View {
    let viewModel: PlayerViewModel
    @ObservedObject var clock: PlaybackClock
    /// False on the empty state: there is no progress to draw, but the row still
    /// holds the volume bar's slot and shows it when the wheel turns.
    var hasTrack = true
    private let palette = AppThemePreset.midnight.palette

    var body: some View {
        // One container: as two sibling views in the parent's stack, the bar and
        // its own timestamps inherited the parent's 12pt spacing and read as two
        // unrelated rows.
        VStack(alignment: .leading, spacing: 7) {
            bar
            readout
                .font(AppFont.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(palette.lcdSecondaryText)
                // The like confirmation sits in the gap between the two
                // timestamps; while the row belongs to the volume it stays out.
                .overlay {
                    if !showsVolume, let status = viewModel.likeStatus {
                        Text(status)
                            .font(AppFont.microRegular)
                            .foregroundStyle(palette.lcdText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, 56)
                    }
                }
        }
        .opacity(isVisible ? 1 : 0)
        .accessibilityHidden(!isVisible)
    }

    /// The one line that is either the track's progress or the volume level.
    private var bar: some View {
        // A drawn capsule, not a scrubber: seeking stays on the wheel's long press.
        Capsule()
            .fill(palette.lcdText.opacity(0.20))
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(palette.lcdText)
                        .frame(width: geometry.size.width * fill)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(showsVolume ? "音量" : "播放进度")
            .accessibilityValue(showsVolume ? volumePercent
                                 : "已播放" + formattedTime(clock.elapsedSeconds) + "，剩余时间" + remainingTime)
    }

    private var readout: some View {
        HStack(spacing: 0) {
            if showsVolume {
                // Just the label: the bar already says how loud it is, and a
                // number next to a 5pt line reads as a measurement rather than
                // as the iPod's own feedback. (VoiceOver still gets the percent.)
                Text(verbatim: L10n.text("音量"))
                Spacer(minLength: 0)
            } else {
                Text(verbatim: formattedTime(clock.elapsedSeconds))
                Spacer(minLength: 0)
                Text(verbatim: remainingTime)
            }
        }
    }

    private var showsVolume: Bool { viewModel.isVolumeBarVisible }

    private var isVisible: Bool { hasTrack || showsVolume }

    private var fill: CGFloat {
        if showsVolume { return CGFloat(min(max(viewModel.volumeLevel, 0), 1)) }
        guard hasTrack else { return 0 }
        return CGFloat(progress)
    }

    private var volumePercent: String {
        "\(Int((viewModel.volumeLevel * 100).rounded()))%"
    }

    private var progress: Double {
        let duration = clock.durationSeconds
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(clock.elapsedSeconds / duration, 0), 1)
    }

    private var remainingTime: String {
        "-" + formattedTime(clock.durationSeconds - clock.elapsedSeconds)
    }

    private func formattedTime(_ seconds: Double) -> String {
        let safe = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", safe / 60, safe % 60)
    }
}

private struct FloatingLikeHeart: View {
    @State private var risen = false

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 24))
            .foregroundStyle(Color.red)
            .scaleEffect(risen ? 1.2 : 1.0)
            .offset(y: risen ? -40 : 0)
            .opacity(risen ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.easeOut(duration: 0.4)) { risen = true }
            }
    }
}

private struct SpotifyArcs: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Three rounded arcs, progressively shorter toward the bottom.
        for index in 0..<3 {
            let inset = CGFloat(index) * 0.045
            let y = 0.34 + CGFloat(index) * 0.18
            path.move(to: CGPoint(x: rect.width * (0.23 + inset), y: rect.height * y))
            path.addQuadCurve(to: CGPoint(x: rect.width * (0.79 - inset), y: rect.height * (y + 0.055)),
                              control: CGPoint(x: rect.width * 0.52, y: rect.height * (y - 0.13)))
        }
        return path
    }
}

// MARK: - 3.1 backdrop and immersive screen

/// The song's cover, blurred and slowly drifting under a dark wash: the light the
/// screen gives off while it plays. Reduce Transparency keeps the flat panel;
/// Reduce Motion keeps it still.
@MainActor
struct NowPlayingBackdrop: View {
    let url: URL?
    let base: Color
    /// How dark the wash over the blur is (1 = the in-LCD screen).
    var wash: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var drift = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                base
                if !reduceTransparency {
                    CachedArtwork(url: url) { image in
                        if let image {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: size.width * 1.6, height: size.height * 1.6)
                                .blur(radius: 48)
                                .saturation(1.5)
                                .opacity(0.62)
                                .scaleEffect(drift ? 1.16 : 1)
                                .offset(x: drift ? -size.width * 0.08 : size.width * 0.04,
                                        y: drift ? size.height * 0.05 : -size.height * 0.03)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    LinearGradient(stops: [
                        .init(color: Color.black.opacity(0.55 * wash), location: 0),
                        .init(color: Color.black.opacity(0.18 * wash), location: 0.40),
                        .init(color: Color.black.opacity(0.62 * wash), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .animation(.easeInOut(duration: 0.6), value: url)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) { drift = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Optional (Settings → Appearance → Immersive Now Playing): the song fills the
/// whole phone and the click wheel is clear glass over it. The same four bands
/// as the LCD screen, in the same order — marks and source, cover, title, progress.
@MainActor
struct ImmersiveNowPlayingView: View {
    let viewModel: PlayerViewModel
    let safeTop: CGFloat
    /// Height kept clear at the bottom for the wheel.
    let wheelSpace: CGFloat
    private let palette = AppThemePreset.midnight.palette

    var body: some View {
        GeometryReader { geometry in
            let track = viewModel.currentTrack
            let source = track?.source ?? viewModel.selectedSource
            let side = max(120, min(geometry.size.width - 108, geometry.size.height - wheelSpace - safeTop - 230))
            ZStack(alignment: .top) {
                NowPlayingBackdrop(url: track?.artworkURL,
                                   base: Color(red: 0.02, green: 0.05, blue: 0.07), wash: 0.7)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 9) {
                        StatusGlyph(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill",
                                    label: viewModel.isPlaying ? "暂停" : "播放",
                                    inkHeight: Metrics.statusGlyphInkHeightLarge, tint: palette.lcdText)
                        StatusGlyph(systemName: viewModel.playbackMode.symbolName,
                                    label: viewModel.playbackMode.displayName,
                                    inkHeight: Metrics.statusGlyphInkHeightLarge,
                                    slotWidth: Metrics.statusGlyphSlotLarge, tint: palette.lcdText)
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(source == .spotify
                                      ? Color(red: 29.0 / 255, green: 185.0 / 255, blue: 84.0 / 255)
                                      : Color(red: 221.0 / 255, green: 0, blue: 27.0 / 255))
                                .frame(width: 22, height: 22)
                            Text(verbatim: source == .spotify ? "Spotify" : L10n.text("网易云音乐"))
                                .font(AppFont.header)
                                .foregroundStyle(Color.white)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("音源：" + source.displayName)
                    }
                    .frame(height: Metrics.statusGlyphInkHeightLarge)
                    .padding(.top, safeTop + 14)

                    if let track {
                        cover(track.artworkURL, side: side)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)
                            .id(track.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                title(track.title)
                                    .font(.system(size: 25, weight: .bold))
                                    .foregroundStyle(Color.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                if viewModel.trackLikeID(for: track) != nil {
                                    TrackLikeHeart(isLiked: viewModel.isLiked(track), confirmation: nil,
                                                   showsOutline: false)
                                }
                            }
                            Text(verbatim: track.artist)
                                .font(.system(size: 16))
                                .foregroundStyle(Color.white.opacity(0.92))
                                .lineLimit(1)
                            Text(verbatim: track.album)
                                .font(AppFont.detail)
                                .foregroundStyle(Color.white.opacity(0.74))
                                .lineLimit(1)
                        }
                        .padding(.top, 18)

                        NowPlayingProgress(viewModel: viewModel, clock: viewModel.clock)
                            .padding(.top, 14)
                    } else {
                        LCDEmptyState(message: viewModel.emptyStateMessage ?? "暂无歌曲", tint: palette.lcdSecondaryText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        NowPlayingProgress(viewModel: viewModel, clock: viewModel.clock, hasTrack: false)
                    }
                    Spacer(minLength: wheelSpace)
                }
                .padding(.horizontal, 28)
                .animation(.easeOut(duration: 0.3), value: track?.id)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func title(_ text: String) -> Text {
        let title = Text(verbatim: text)
        return NowPlayingView.isLatinTitle(text) ? title.italic() : title
    }

    private func cover(_ url: URL?, side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return CachedArtwork(url: url) { image in
            ZStack {
                if let image {
                    image.resizable().scaledToFill()
                        .frame(width: side, height: side)
                        .blur(radius: 22)
                        .opacity(0.5)
                        .offset(y: 8)
                        .accessibilityHidden(true)
                    image.resizable().scaledToFill()
                        .frame(width: side, height: side)
                        .clipShape(shape)
                } else {
                    shape.fill(Color.white.opacity(0.08))
                        .frame(width: side, height: side)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: side * 0.26, weight: .light))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                }
            }
        }
        .overlay { shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1) }
        .shadow(color: .black.opacity(0.45), radius: 20, y: 14)
        .frame(width: side, height: side)
        .accessibilityLabel(url == nil ? "专辑封面占位图" : "专辑封面")
    }
}
