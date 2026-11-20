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
    /// 3.1.15: false while the immersive Now Playing covers this screen. The LCD
    /// is only faded out there (it keeps its place so the wheel does not move), and
    /// a faded view still runs: the backdrop's drift and the 30 Hz motion updates
    /// behind the tilt kept going under the immersive copy, doing everything twice.
    var effectsActive: Bool = true
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
                               base: displayPalette.lcdBackground,
                               isAnimating: viewModel.isPlaying && effectsActive)
        }
        .overlay(alignment: .top) { topRow }
    }

    /// The list header's row (3.2.3: play/pause and playback mode on the left, no
    /// title; 30pt plus the band above it), in the Now Playing screen's own midnight
    /// palette. 3.1.5: drawn on the backdrop itself, not on a glass strip.
    private var topRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: Layout.markSpacing) {
                // 3.2.3: no "Now Playing" title; the two marks lead the row.
                // 3.2.6: larger (18pt ink instead of 12), one colour, and lined up
                // with the content below: the row starts at the same 18pt inset as
                // the source mark and the cover, and play/pause sits flush left in
                // a fixed slot, so its edge stays on that line and the mode mark
                // does not shift when play turns into pause.
                let hasTrack = viewModel.currentTrack != nil
                StatusGlyph(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill",
                            label: viewModel.isPlaying ? "暂停" : "播放",
                            inkHeight: Layout.markInk,
                            tint: displayPalette.lcdText)
                    .frame(width: Layout.markSlot, alignment: .leading)
                    .opacity(hasTrack ? 1 : 0)
                    .accessibilityHidden(!hasTrack)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
                StatusGlyph(systemName: viewModel.playbackMode.symbolName,
                            label: viewModel.playbackMode.displayName,
                            inkHeight: Layout.markInk,
                            tint: displayPalette.lcdText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Layout.inset)
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
        /// 3.2.6: the top row's play/pause and mode marks.
        static let markInk: CGFloat = 18
        /// Wide enough for the wider of play / pause at that height.
        static let markSlot: CGFloat = 20
        static let markSpacing: CGFloat = 12
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
                    .nowPlayingHero("cover", onImmersivePage: false)
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
                    .nowPlayingHero("title", onImmersivePage: false, properties: .position)
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
                        .nowPlayingHero("artist", onImmersivePage: false, properties: .position)
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
        ArtworkTilt(cornerRadius: Metrics.nowPlayingArtworkRadius, isActive: effectsActive) {
            ZStack {
                if Metrics.artworkGlowOpacity > 0 {
                    // The cover's own colours bleeding softly out from behind it, like an
                    // LCD backlight. 3.1.15: a pre-blurred bitmap of the cover's square
                    // with its own soft edge, instead of a live `.blur(18)` that the 3D
                    // tilt above made the GPU redo on every motion update.
                    BlurredArtwork(url: url, style: .glow) { glow in
                        if let glow {
                            glow
                                .frame(width: side * ArtworkBlurStyle.glowFrameScale,
                                       height: side * ArtworkBlurStyle.glowFrameScale)
                                // Lays out at the cover's size, so the tilt's specular
                                // overlay stays on the cover; the soft edge draws past it.
                                .frame(width: side, height: side)
                                .opacity(Metrics.artworkGlowOpacity)
                                .scaleEffect(1.04)
                                .offset(y: 6)
                                .accessibilityHidden(true)
                        }
                    }
                }
                CachedArtwork(url: url) { image in
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
///
/// 3.1.15: the blur is baked into a 64 px bitmap once per cover (see
/// `ArtworkBlurStyle.backdrop`) instead of a live `.blur(48)` over a 1.6× screen-size
/// image, which the GPU recomputed on every frame of a drift that never stopped.
/// The drift now runs only while music is playing and the screen is showing: it is
/// driven by a pausable timeline at 30 fps (an 18 s move needs no more) and it
/// freezes in place on pause, continuing from the same spot on play.
@MainActor
struct NowPlayingBackdrop: View {
    let url: URL?
    let base: Color
    /// How dark the wash over the blur is (1 = the in-LCD screen).
    var wash: Double = 1
    /// Drifts only while this is true: playing, and not hidden behind another screen.
    var isAnimating: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Drift time already run before the current stretch, and when that stretch began.
    @State private var driftElapsed: Double = 0
    @State private var driftStartedAt: Date?

    /// One full there-and-back, matching the old 18 s autoreversing animation.
    private static let driftPeriod: Double = 36

    private var drifts: Bool { isAnimating && !reduceMotion }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                base
                if !reduceTransparency {
                    BlurredArtwork(url: url, style: .backdrop) { image in
                        if let image {
                            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !drifts)) { context in
                                let phase = driftPhase(at: context.date)
                                image
                                    .scaledToFill()
                                    .frame(width: size.width * 1.6, height: size.height * 1.6)
                                    .opacity(0.62)
                                    .scaleEffect(1 + 0.16 * phase)
                                    .offset(x: size.width * (0.04 - 0.12 * phase),
                                            y: size.height * (-0.03 + 0.08 * phase))
                            }
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
        .onAppear { updateDriftClock() }
        .onChange(of: drifts) { _, _ in updateDriftClock() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Banks the time run so far when the drift stops and starts a new stretch when
    /// it resumes, so pausing freezes the light where it is instead of snapping.
    private func updateDriftClock() {
        let now = Date()
        if drifts {
            if driftStartedAt == nil { driftStartedAt = now }
        } else if let started = driftStartedAt {
            driftElapsed += max(0, now.timeIntervalSince(started))
            driftStartedAt = nil
        }
    }

    /// 0…1…0 over one period, eased at both ends like `.easeInOut`.
    private func driftPhase(at date: Date) -> CGFloat {
        guard !reduceMotion else { return 0 }
        var time = driftElapsed
        if let started = driftStartedAt { time += max(0, date.timeIntervalSince(started)) }
        return CGFloat((1 - cos(2 * Double.pi * time / Self.driftPeriod)) / 2)
    }
}

/// Optional (Settings → Appearance → Immersive Now Playing, or hold the wheel's
/// play/pause key on Now Playing): the song fills the whole phone and the click
/// wheel is clear glass over it.
///
/// 3.2.3: one centred column, three blocks of about equal weight — the cover, the
/// title with artist · album in New York serif, and the lyrics turning on a
/// three-line drum (`LyricsDrum`); progress at the foot, just above the wheel. The
/// play/pause, mode and source marks live in the band beside the Dynamic Island
/// (their own row on phones without one).
///
/// 3.2.3: stays mounted the whole time Now Playing is up, faded out when not in
/// use, so switching in and out animates an already-drawn page (no first-frame
/// artwork, no insert/remove). `isActive` pauses its drift and lyrics clock while
/// it is hidden. 3.2.4: cover, title and artist travel from/to their places on
/// the LCD page (`nowPlayingHero`); the rest slides in.
@MainActor
struct ImmersiveNowPlayingView: View {
    let viewModel: PlayerViewModel
    let safeTop: CGFloat
    /// Height kept clear at the bottom for the wheel.
    let wheelSpace: CGFloat
    /// The wheel's own size: content runs down to just above its rim.
    let wheelDiameter: CGFloat
    /// False while hidden behind the LCD: nothing animates.
    var isActive: Bool = true
    /// 3.2.8: the immersive switch itself (on even in landscape, where the page is
    /// not shown). The page stays mounted on Now Playing with the switch off, so the
    /// hold can animate into it, but asks for lyrics only once it is on.
    var lyricsEnabled: Bool = true
    private let palette = AppThemePreset.midnight.palette
    /// 3.2.5: opened straight from another screen (Home's Now Playing row with the
    /// setting on). The page then makes its own entrance: the cover flies from
    /// where Home's preview card showed it (or grows in place), title and artist
    /// grow out of the card's caption, the rest slides in. Captured once, when the
    /// page is created; switching on Now Playing uses the shared-element flight.
    @State private var entrance: ImmersiveEntrance?
    @State private var entered: Bool

    init(viewModel: PlayerViewModel, safeTop: CGFloat, wheelSpace: CGFloat, wheelDiameter: CGFloat,
         isActive: Bool = true, lyricsEnabled: Bool = true, entrance: ImmersiveEntrance? = nil) {
        self.viewModel = viewModel
        self.safeTop = safeTop
        self.wheelSpace = wheelSpace
        self.wheelDiameter = wheelDiameter
        self.isActive = isActive
        self.lyricsEnabled = lyricsEnabled
        // Created already showing = arriving from another screen.
        _entrance = State(initialValue: isActive ? (entrance ?? ImmersiveEntrance()) : nil)
        _entered = State(initialValue: !isActive)
    }

    /// The arrival's spring (no bounce), and the small stagger of the parts that
    /// slide in after the cover.
    private static let arrive = Animation.spring(response: 0.55, dampingFraction: 1)
    private func arriving(after delay: Double) -> Animation { Self.arrive.delay(delay) }
    /// Page-only parts are in place once the page is both switched on and entered.
    private var settled: Bool { isActive && entered }

    var body: some View {
        GeometryReader { geometry in
            let track = viewModel.currentTrack
            let layout = Layout(size: geometry.size, safeTop: safeTop,
                                wheelSpace: wheelSpace, wheelDiameter: wheelDiameter)
            ZStack(alignment: .top) {
                NowPlayingBackdrop(url: track?.artworkURL,
                                   base: Color(red: 0.02, green: 0.05, blue: 0.07),
                                   wash: 0.85,
                                   isAnimating: viewModel.isPlaying && isActive)
                // A quieter ground for the lyrics than a bright cover gives.
                Color.black.opacity(0.12)
                    .allowsHitTesting(false)

                statusBand(track: track, layout: layout)
                    // 3.2.4: page-only elements slide into place as the page comes in.
                    .offset(y: settled ? 0 : -14)
                    .opacity(entered ? 1 : 0)
                    .animation(arriving(after: 0.08), value: entered)

                VStack(spacing: 0) {
                    if let track {
                        coverAndTitle(track, layout: layout)
                        ImmersiveLyricsPane(store: viewModel.lyrics, trackKey: LyricsStore.key(for: track),
                                            clock: viewModel.clock,
                                            isPlaying: viewModel.isPlaying && isActive,
                                            onSeek: { seek(to: $0) })
                            .frame(maxWidth: .infinity)
                            .frame(height: layout.drumHeight)
                            .padding(.top, Layout.infoToDrum)
                            .offset(y: settled ? 0 : 40)
                            .opacity(entered ? 1 : 0)
                            .animation(arriving(after: 0.06), value: entered)
                        Spacer(minLength: Layout.drumToProgress)
                        NowPlayingProgress(viewModel: viewModel, clock: viewModel.clock)
                            .frame(height: Layout.progressHeight, alignment: .bottom)
                            .offset(y: settled ? 0 : 28)
                            .opacity(entered ? 1 : 0)
                            .animation(arriving(after: 0.1), value: entered)
                    } else {
                        LCDEmptyState(message: viewModel.emptyStateMessage ?? "暂无歌曲",
                                      tint: palette.lcdSecondaryText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        NowPlayingProgress(viewModel: viewModel, clock: viewModel.clock, hasTrack: false)
                            .frame(height: Layout.progressHeight, alignment: .bottom)
                    }
                }
                .padding(.horizontal, Layout.margin)
                .padding(.top, layout.contentTop)
                .frame(width: geometry.size.width, height: layout.contentBottom, alignment: .top)
                .animation(.easeOut(duration: 0.3), value: track?.id)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            // 3.2.8: switching on (the hold, or Settings) changes this id, so the
            // request starts in the same moment the page begins to fly in.
            .task(id: (lyricsEnabled ? "on|" : "off|") + (track.map { LyricsStore.key(for: $0) } ?? "")) {
                guard lyricsEnabled else { return }
                viewModel.loadLyrics(for: track)
            }
            .onAppear {
                guard !entered else { return }
                // One frame at the start pose, then everything moves to its place.
                DispatchQueue.main.async { entered = true }
            }
        }
    }

    // MARK: Status band

    /// Play/pause and mode on the left, the source on the right — in the band
    /// beside the Dynamic Island, where the status bar would be.
    private func statusBand(track: Track?, layout: Layout) -> some View {
        let source = track?.source ?? viewModel.selectedSource
        return HStack(spacing: 8) {
            StatusGlyph(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill",
                        label: viewModel.isPlaying ? "暂停" : "播放",
                        inkHeight: Layout.statusInk, tint: Color.white)
            StatusGlyph(systemName: viewModel.playbackMode.symbolName,
                        label: viewModel.playbackMode.displayName,
                        inkHeight: Layout.statusInk, slotWidth: Layout.statusInk + 5,
                        tint: Color.white)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Circle()
                    .fill(source == .spotify
                          ? Color(red: 29.0 / 255, green: 185.0 / 255, blue: 84.0 / 255)
                          : Color(red: 221.0 / 255, green: 0, blue: 27.0 / 255))
                    .frame(width: 9, height: 9)
                Text(verbatim: source.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("音源：" + source.displayName)
        }
        .frame(height: Layout.statusRowHeight)
        .padding(.horizontal, layout.usesIslandBand ? 34 : Layout.margin)
        .padding(.top, layout.statusCenterY - Layout.statusRowHeight / 2)
        .frame(maxWidth: .infinity)
    }

    // MARK: Cover and title

    /// The cover, centred, with the title and artist · album centred under it.
    private func coverAndTitle(_ track: Track, layout: Layout) -> some View {
        let cover = entranceMove(from: entrance?.cover, toCenter: layout.coverCenter,
                                 size: CGSize(width: layout.coverSide, height: layout.coverSide),
                                 fallbackScale: 0.86)
        let titleMove = entranceMove(from: entrance?.title, toCenter: layout.titleCenter,
                                     size: nil, fallbackScale: 1, fallbackRise: 18,
                                     fromScale: 13.0 / 22.0)
        let artistMove = entranceMove(from: entrance?.artist, toCenter: layout.artistCenter,
                                      size: nil, fallbackScale: 1, fallbackRise: 18,
                                      fromScale: 12.0 / 13.0)
        return VStack(spacing: 0) {
            artwork(track.artworkURL, side: layout.coverSide)
                .nowPlayingHero("cover", onImmersivePage: true)
                .modifier(cover)
                .animation(Self.arrive, value: entered)
                // Playing, the cover sits forward; paused, it settles back a little.
                .scaleEffect(viewModel.isPlaying ? 1 : 0.92)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: viewModel.isPlaying)

            VStack(spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    title(track.title, size: 22)
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    heart(for: track)
                }
                .nowPlayingHero("title", onImmersivePage: true, properties: .position)
                .modifier(titleMove)
                .animation(arriving(after: 0.03), value: entered)
                .frame(height: Layout.titleHeight)
                Text(verbatim: track.album.isEmpty ? track.artist : track.artist + "  ·  " + track.album)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
                    .nowPlayingHero("artist", onImmersivePage: true, properties: .position)
                    .modifier(artistMove)
                    .animation(arriving(after: 0.05), value: entered)
                    .frame(height: Layout.subtitleHeight)
            }
            .multilineTextAlignment(.center)
            .padding(.top, Layout.coverToInfo)
        }
        .frame(maxWidth: .infinity)
        .id(track.id)
        .transition(.opacity)
    }

    /// Where an element starts its arrival: on top of its counterpart on Home's
    /// preview card (moved and scaled to it), or — with no card to come from —
    /// slightly small / lower and transparent, in its own place.
    private func entranceMove(from start: CGRect?, toCenter end: CGPoint, size: CGSize?,
                              fallbackScale: CGFloat, fallbackRise: CGFloat = 0,
                              fromScale: CGFloat = 1) -> EntranceMove {
        guard !entered, entrance != nil else { return EntranceMove() }
        if let start {
            let scale = size.map { start.width / max(1, $0.width) } ?? fromScale
            return EntranceMove(offset: CGSize(width: start.midX - end.x, height: start.midY - end.y),
                                scale: scale, opacity: 1)
        }
        return EntranceMove(offset: CGSize(width: 0, height: fallbackRise),
                            scale: fallbackScale, opacity: 0)
    }

    // MARK: Pieces

    private func seek(to line: LyricLine) {
        let delta = line.time - viewModel.elapsedSeconds
        guard abs(delta) > 0.3 else { return }
        HapticEngine.shared.tick()
        viewModel.seekBy(seconds: delta)
    }

    @ViewBuilder
    private func heart(for track: Track) -> some View {
        if viewModel.trackLikeID(for: track) != nil {
            TrackLikeHeart(isLiked: viewModel.isLiked(track), confirmation: nil, showsOutline: false)
        }
    }

    /// New York serif; Latin titles in its italic, as on the LCD screen.
    private func title(_ text: String, size: CGFloat) -> Text {
        let title = Text(verbatim: text).font(.system(size: size, weight: .semibold, design: .serif))
        return NowPlayingView.isLatinTitle(text) ? title.italic() : title
    }

    private func artwork(_ url: URL?, side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return ZStack {
            // 3.1.15: pre-blurred, like the LCD cover's backlight (was `.blur(22)`).
            BlurredArtwork(url: url, style: .glow) { glow in
                if let glow {
                    glow
                        .frame(width: side * ArtworkBlurStyle.glowFrameScale,
                               height: side * ArtworkBlurStyle.glowFrameScale)
                        // Lays out at the cover's size so the stroke and shadow below
                        // stay on the cover; the soft edge just draws past it.
                        .frame(width: side, height: side)
                        .opacity(0.5)
                        .offset(y: 8)
                        .accessibilityHidden(true)
                }
            }
            CachedArtwork(url: url) { image in
                if let image {
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
        .shadow(color: .black.opacity(0.45), radius: 18, y: 12)
        .frame(width: side, height: side)
        .accessibilityLabel(url == nil ? "专辑封面占位图" : "专辑封面")
    }

    // MARK: Layout

    /// Where everything goes: after the title, the gaps and the progress, the cover
    /// takes 52 % of what is left (capped by the width) and the drum the rest, so the
    /// two read as equals.
    private struct Layout {
        static let margin: CGFloat = 28
        static let statusInk: CGFloat = 14
        static let statusRowHeight: CGFloat = 18
        static let coverToInfo: CGFloat = 14
        static let titleHeight: CGFloat = 28
        static let subtitleHeight: CGFloat = 17
        static let infoToDrum: CGFloat = 8
        static let drumToProgress: CGFloat = 8
        static let progressHeight: CGFloat = 28

        let usesIslandBand: Bool
        let statusCenterY: CGFloat
        let contentTop: CGFloat
        let contentBottom: CGFloat
        let coverSide: CGFloat
        let drumHeight: CGFloat
        /// 3.2.5: resting centres (in the page's = the phone's coordinates), for the
        /// arrival from Home's preview card.
        let coverCenter: CGPoint
        let titleCenter: CGPoint
        let artistCenter: CGPoint

        init(size: CGSize, safeTop: CGFloat, wheelSpace: CGFloat, wheelDiameter: CGFloat) {
            // Dynamic Island phones (safe top ≥ 59) have room beside the island; notch
            // and home-button phones get a row of their own.
            usesIslandBand = safeTop >= 56
            if usesIslandBand {
                statusCenterY = safeTop / 2 + 1
                contentTop = safeTop + 8
            } else {
                let rowTop = safeTop + 10
                statusCenterY = rowTop + Self.statusRowHeight / 2
                contentTop = rowTop + Self.statusRowHeight + 14
            }
            let wheelTop = size.height - wheelSpace + max(0, (wheelSpace - wheelDiameter) / 2)
            contentBottom = max(contentTop + 220, wheelTop - 14)
            let chrome = Self.coverToInfo + Self.titleHeight + 3 + Self.subtitleHeight
                + Self.infoToDrum + Self.drumToProgress + Self.progressHeight
            let shared = contentBottom - contentTop - chrome
            let width = size.width - Self.margin * 2
            coverSide = max(90, min(width, shared * 0.52).rounded(.down))
            drumHeight = max(70, shared - coverSide)
            let midX = size.width / 2
            coverCenter = CGPoint(x: midX, y: contentTop + coverSide / 2)
            let infoTop = contentTop + coverSide + Self.coverToInfo
            titleCenter = CGPoint(x: midX, y: infoTop + Self.titleHeight / 2)
            artistCenter = CGPoint(x: midX, y: infoTop + Self.titleHeight + 3 + Self.subtitleHeight / 2)
        }
    }
}

/// 3.2.5: where Home's preview card shows the Now Playing cover, title and artist
/// (global frames), so the immersive page can open out of them.
struct ImmersiveEntrance: Equatable {
    var cover: CGRect?
    var title: CGRect?
    var artist: CGRect?
}

struct ImmersiveEntranceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports this view's global frame under `key` while `enabled`.
    func immersiveEntranceAnchor(_ key: String, enabled: Bool) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: ImmersiveEntranceKey.self,
                                       value: enabled ? [key: proxy.frame(in: .global)] : [:])
            }
        }
    }
}

/// An element's start pose for the arrival; identity once it has entered.
struct EntranceMove: ViewModifier {
    var offset: CGSize = .zero
    var scale: CGFloat = 1
    var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .opacity(opacity)
    }
}

/// 3.2.4: Normal ↔ immersive moves each element to its place. The cover, the
/// title and the artist exist on both pages and are joined by
/// `matchedGeometryEffect` in one namespace (`ContentView` puts it in the
/// environment): the page being shown is the source, the hidden page's copy sits
/// exactly on top of it, so when the switch flips they travel together from their
/// spot on one page to their spot on the other while the two pages cross-fade.
/// Everything that exists on one page only fades and slides in or out.
struct NowPlayingHeroSpace: Equatable {
    let namespace: Namespace.ID
    /// Which page is the source: the immersive one while it is showing.
    let immersive: Bool
}

private struct NowPlayingHeroKey: EnvironmentKey {
    static let defaultValue: NowPlayingHeroSpace? = nil
}

extension EnvironmentValues {
    var nowPlayingHero: NowPlayingHeroSpace? {
        get { self[NowPlayingHeroKey.self] }
        set { self[NowPlayingHeroKey.self] = newValue }
    }
}

extension View {
    /// Joins this element to its twin on the other Now Playing page.
    /// Size and place for the cover; place only (`.position`) for text, which keeps
    /// its own size so it never truncates mid-flight.
    func nowPlayingHero(_ id: String, onImmersivePage: Bool,
                        properties: MatchedGeometryProperties = .frame) -> some View {
        modifier(NowPlayingHeroModifier(id: id, onImmersivePage: onImmersivePage, properties: properties))
    }
}

private struct NowPlayingHeroModifier: ViewModifier {
    let id: String
    let onImmersivePage: Bool
    let properties: MatchedGeometryProperties
    @Environment(\.nowPlayingHero) private var hero

    func body(content: Content) -> some View {
        if let hero {
            content.matchedGeometryEffect(id: id, in: hero.namespace, properties: properties,
                                          isSource: hero.immersive == onImmersivePage)
        } else {
            content
        }
    }
}

/// The drum (or untimed lyrics, or a note), on its own observation so a lyrics
/// answer or a clock tick repaints only this.
private struct ImmersiveLyricsPane: View {
    @ObservedObject var store: LyricsStore
    let trackKey: String
    let clock: PlaybackClock
    let isPlaying: Bool
    let onSeek: (LyricLine) -> Void

    var body: some View {
        // The store may still hold the last song's answer for the frame before
        // this song's request starts.
        let state = store.state.trackKey == trackKey ? store.state : .loading(trackKey)
        if let lyrics = state.lyrics {
            if lyrics.timing == .synced {
                LyricsClock(clock: clock, isPlaying: isPlaying) { time in
                    LyricsDrum(lyrics: lyrics, activeIndex: lyrics.activeIndex(at: time),
                               isPlaying: isPlaying, onSeek: onSeek)
                        .equatable()
                }
            } else {
                PlainLyricsPage(lyrics: lyrics)
            }
        } else {
            LyricsNote(state: state)
        }
    }
}
