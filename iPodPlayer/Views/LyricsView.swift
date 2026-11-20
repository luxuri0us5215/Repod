import SwiftUI

// MARK: - 3.2 lyrics views (immersive Now Playing)

/// Lyric type. New York (the system serif) for an editorial feel; Chinese falls
/// back to PingFang at the same weight, which keeps CJK lines crisp.
enum LyricFont {
    static let line = Font.system(size: 24, weight: .bold, design: .serif)
    static let plainLine = Font.system(size: 20, weight: .semibold, design: .serif)
    static let translation = Font.system(size: 14, weight: .medium)
    static let note = Font.system(size: 17, weight: .regular, design: .serif).italic()
}

/// Song time between the player's progress ticks (4 Hz on NetEase, slower on
/// Spotify): it runs on from the last tick while playing, so lines change on time
/// instead of up to a quarter second late. Only redraws ~10× a second while
/// playing; paused, it sits still on the clock's value.
struct LyricsClock<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    let isPlaying: Bool
    @ViewBuilder let content: (Double) -> Content
    @State private var anchor: Double
    @State private var anchorDate = Date()

    /// 3.2.5: starts from the clock's real position. Starting from 0 made the first
    /// frame show the song's opening line, then jump to the right one a moment
    /// later — the drum spun through the song as the page opened.
    init(clock: PlaybackClock, isPlaying: Bool, @ViewBuilder content: @escaping (Double) -> Content) {
        _clock = ObservedObject(wrappedValue: clock)
        self.isPlaying = isPlaying
        self.content = content
        _anchor = State(initialValue: clock.elapsedSeconds)
    }

    /// Lines light a touch early, the way a singer's breath leads the word.
    private static var lead: Double { 0.2 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !isPlaying)) { context in
            content(time(at: context.date) + Self.lead)
        }
        .onAppear { reanchor(clock.elapsedSeconds) }
        .onChange(of: clock.elapsedSeconds) { _, value in reanchor(value) }
        .onChange(of: isPlaying) { _, _ in reanchor(clock.elapsedSeconds) }
    }

    private func reanchor(_ value: Double) {
        anchor = value
        anchorDate = Date()
    }

    private func time(at date: Date) -> Double {
        guard isPlaying else { return clock.elapsedSeconds }
        // Never run more than a few seconds past the last real tick.
        return anchor + min(3, max(0, date.timeIntervalSince(anchorDate)))
    }
}

// MARK: - Full lyrics: the drum

/// 3.2: synced lyrics on a turning drum. Three lines show: the one being sung in
/// the middle, large and bright, with its translation; the one before above it and
/// the one after below it, smaller and tilted away round the drum's curve. On each
/// new line the drum turns one step: the lower line rolls up into the middle as the
/// middle one rolls over the top. No faded edges: the outer lines are set apart by
/// size and tilt, not by dissolving into the background. A tap on the line above
/// or below jumps the song there.
struct LyricsDrum: View, Equatable {
    let lyrics: Lyrics
    let activeIndex: Int?
    let isPlaying: Bool
    let onSeek: (LyricLine) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Degrees between neighbouring lines on the drum.
    static let step: Double = 40

    static func == (lhs: LyricsDrum, rhs: LyricsDrum) -> Bool {
        lhs.lyrics == rhs.lyrics && lhs.activeIndex == rhs.activeIndex && lhs.isPlaying == rhs.isPlaying
    }

    var body: some View {
        GeometryReader { geometry in
            let focus = activeIndex ?? -1
            let height = geometry.size.height
            // 3.2.2: sized from the pane, which now takes about half the page.
            let radius = min(height * 0.44, 140)
            let fontSize: CGFloat = height >= 180 ? 28 : (height >= 130 ? 24 : 20)
            // Two lines for the sung line only where the drum is tall enough to
            // keep it clear of its neighbours; otherwise one line, shrunk to fit.
            let lineLimit = height >= 220 ? 2 : 1
            // The three visible lines plus one hidden on each side, already on the
            // drum, so a turn brings the next line in from behind instead of popping.
            let lower = max(0, focus - 2)
            let upper = min(lyrics.lines.count - 1, focus + 2)
            ZStack {
                if lower <= upper {
                    ForEach(lyrics.lines[lower...upper]) { line in
                        let slot = line.id - focus
                        DrumLine(line: line, isCentre: slot == 0, isPlaying: isPlaying,
                                 fontSize: fontSize, lineLimit: lineLimit)
                            .frame(width: geometry.size.width)
                            .modifier(DrumPlacement(position: Double(slot), radius: radius))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard abs(slot) == 1, line.kind == .words else { return }
                                onSeek(line)
                            }
                            .allowsHitTesting(abs(slot) <= 1)
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(reduceMotion ? .easeInOut(duration: 0.25)
                                    : .spring(response: 0.6, dampingFraction: 0.82),
                       value: focus)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("歌词"))
        .accessibilityValue(activeIndex.map { lyrics.lines[$0].text } ?? "")
    }
}

/// Where a line sits on the drum. `position` is its distance from the middle in
/// lines and animates continuously, so a turning line travels along the arc
/// (height, tilt, size and brightness all follow the same angle) rather than
/// sliding straight between two spots.
private struct DrumPlacement: ViewModifier, Animatable {
    var position: Double
    let radius: CGFloat

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    func body(content: Content) -> some View {
        let clamped = max(-2.2, min(2.2, position))
        let degrees = clamped * LyricsDrum.step
        let distance = abs(clamped)
        // 1 in the middle, 0 one step out.
        let prominence = max(0, 1 - distance)
        let opacity = distance <= 1 ? 0.55 + 0.45 * prominence : max(0, 0.55 * (2 - distance))
        return content
            .scaleEffect(0.7 + 0.3 * prominence)
            .rotation3DEffect(.degrees(-degrees), axis: (x: 1, y: 0, z: 0),
                              anchor: .center, perspective: 0.45)
            .offset(y: radius * CGFloat(sin(degrees * .pi / 180)))
            .opacity(opacity)
    }
}

private struct DrumLine: View {
    let line: LyricLine
    let isCentre: Bool
    let isPlaying: Bool
    let fontSize: CGFloat
    let lineLimit: Int

    var body: some View {
        VStack(spacing: 6) {
            if line.kind == .interlude {
                InterludeDots(isActive: isCentre, isPlaying: isPlaying)
                    .frame(height: fontSize)
            } else {
                Text(verbatim: line.text)
                    .font(.system(size: fontSize, weight: .bold, design: .serif))
                    .foregroundStyle(Color.white)
                    .lineLimit(lineLimit)
                    .minimumScaleFactor(lineLimit == 1 ? 0.55 : 0.75)
                    .shadow(color: Color.white.opacity(isCentre ? 0.28 : 0), radius: 10)
                if isCentre, let translation = line.translation {
                    Text(verbatim: translation)
                        .font(LyricFont.translation)
                        .foregroundStyle(Color.white.opacity(0.74))
                        .lineLimit(2)
                        .transition(.opacity)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// Three dots that breathe while the band plays on its own.
struct InterludeDots: View {
    let isActive: Bool
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .modifier(Breath(index: index, isOn: isActive && isPlaying && !reduceMotion))
            }
        }
        .opacity(isActive ? 0.95 : 0.4)
        .accessibilityHidden(true)
    }

    private struct Breath: ViewModifier {
        let index: Int
        let isOn: Bool
        func body(content: Content) -> some View {
            if isOn {
                content.phaseAnimator([false, true]) { dot, phase in
                    dot.scaleEffect(phase ? 1.18 : 0.78).opacity(phase ? 1 : 0.45)
                } animation: { _ in
                    .easeInOut(duration: 0.9).delay(Double(index) * 0.18)
                }
            } else {
                content
            }
        }
    }
}

/// Untimed lyrics: a still page the thumb scrolls.
struct PlainLyricsPage: View {
    let lyrics: Lyrics

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(lyrics.lines) { line in
                    Text(verbatim: line.text)
                        .font(LyricFont.plainLine)
                        .foregroundStyle(Color.white.opacity(0.86))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 12)
        }
        // No faded edges (3.2): lines are cut cleanly by the pane.
        .clipped()
    }
}

// MARK: - Notes

/// Loading / no lyrics / instrumental, set in the lyrics' own serif.
struct LyricsNote: View {
    let state: LyricsState

    var body: some View {
        Group {
            switch state {
            case .loading:
                InterludeDots(isActive: true, isPlaying: true)
                    .accessibilityLabel(L10n.text("正在载入歌词…"))
            case .instrumental:
                Text(verbatim: L10n.text("纯音乐，请欣赏")).font(LyricFont.note)
            case .unavailable:
                Text(verbatim: L10n.text("暂无歌词")).font(LyricFont.note)
            case .idle, .loaded:
                EmptyView()
            }
        }
        .foregroundStyle(Color.white.opacity(0.58))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
