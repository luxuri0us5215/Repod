import SwiftUI
import UIKit
import Observation

// MARK: - Motion

/// Fires a display link without the link retaining the motion model.
@MainActor
private final class CoverFlowFrameTarget: NSObject {
    var onFrame: ((CADisplayLink) -> Void)?
    @objc func frame(_ link: CADisplayLink) { onFrame?(link) }
}

/// Cover Flow's position, as a fractional cover index ("slot").
///
/// 3.1.6 rewrite. The old flow lived inside a `ScrollView` + `LazyHStack` with a
/// UIKit probe that moved the scroll view's bounds behind SwiftUI's back. Two
/// bugs came out of that: the probe reported slot 0 (the scroll view's initial
/// offset) before the deferred centring landed, which replaced the playing song
/// as the remembered selection; and the lazy stack never built the slots left of
/// a programmatic jump until a real drag scrolled them in.
///
/// Now there is no scroll view. A drag writes `position` directly; a release, a
/// tap or a step hands it to an exactly integrated, critically damped spring on
/// a display link. The value on screen is always the value here, so a cover can
/// be caught mid-glide without a jump, and every visible cover is laid out from
/// `position` on every frame — none waits to be loaded in.
@MainActor
@Observable
final class CoverFlowMotion {
    /// Shorter lists stop at both ends (with a rubber band) instead of looping,
    /// so the same cover never appears twice on screen.
    nonisolated static let loopThreshold = 16

    nonisolated static func loops(count: Int) -> Bool { count >= loopThreshold }

    nonisolated static func albumIndex(for slot: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        if loops(count: count) { return (slot % count + count) % count }
        return min(max(slot, 0), count - 1)
    }

    /// Fractional slot. Unbounded while looping.
    private(set) var position: Double = 0
    /// `position` rounded. Published only when it changes, so views that need
    /// just the centred cover do not redraw on every frame.
    private(set) var centeredIndex = 0

    @ObservationIgnored private(set) var count = 0
    @ObservationIgnored private(set) var isDragging = false
    @ObservationIgnored private var velocity: Double = 0
    @ObservationIgnored private var target: Double?
    @ObservationIgnored private var dragOrigin: Double = 0
    @ObservationIgnored private var dragBaseline: Double = 0
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var frameTarget: CoverFlowFrameTarget?
    @ObservationIgnored private var lastFrame: CFTimeInterval?

    /// Spring stiffness (natural frequency, rad/s): a one-cover step settles in about 0.45 s.
    private let omega: Double = 11

    var loops: Bool { Self.loops(count: count) }
    var isSettled: Bool { target == nil && !isDragging }

    func configure(count: Int) {
        self.count = count
    }

    func albumIndex(for slot: Int) -> Int { Self.albumIndex(for: slot, count: count) }

    /// The slot showing `albumIndex` that is closest to where the flow is now.
    func nearestSlot(for albumIndex: Int) -> Int {
        guard loops, count > 0 else { return albumIndex }
        let turns = ((position - Double(albumIndex)) / Double(count)).rounded()
        return albumIndex + Int(turns) * count
    }

    func jump(to slot: Int) {
        stop()
        isDragging = false
        set(Double(slot))
    }

    // MARK: Drag

    func beginDrag(at slots: Double) {
        stop()
        isDragging = true
        dragOrigin = position
        dragBaseline = slots
    }

    func drag(to slots: Double) {
        guard isDragging else { return }
        var raw = dragOrigin + (slots - dragBaseline)
        if !loops { raw = rubberBand(raw) }
        set(raw)
    }

    /// `v` is in slots per second.
    func endDrag(velocity v: Double) {
        guard isDragging else { return }
        isDragging = false
        var goal = (position + max(-9, min(9, v * 0.32))).rounded()
        if abs(v) > 1.2 {
            // A deliberate flick always reaches at least the next cover in its direction.
            goal = v > 0 ? max(goal, position.rounded(.down) + 1)
                         : min(goal, position.rounded(.up) - 1)
        }
        glide(to: goal, velocity: v)
    }

    // MARK: Glide

    func step(_ delta: Int) {
        guard !isDragging else { return }
        glide(to: (target ?? position.rounded()) + Double(delta))
    }

    /// Without a velocity, the current one carries over, so retargeting a
    /// moving flow (a tap or a step mid-glide) never stalls it.
    func glide(to slot: Double, velocity v: Double? = nil) {
        var goal = slot.rounded()
        if !loops { goal = min(max(goal, 0), Double(max(count - 1, 0))) }
        target = goal
        let v = v ?? velocity
        let distance = goal - position
        // A critically damped spring passes its goal only if it sets off toward
        // it faster than omega × distance; hand over just under that.
        let limit = omega * abs(distance) * 0.9
        velocity = v * distance > 0 ? max(-limit, min(limit, v)) : 0
        startLink()
    }

    func stop() {
        link?.invalidate()
        link = nil
        frameTarget = nil
        target = nil
        velocity = 0
        lastFrame = nil
    }

    private func startLink() {
        guard link == nil else { return }
        let proxy = CoverFlowFrameTarget()
        proxy.onFrame = { [weak self] link in self?.advance(link) }
        let link = CADisplayLink(target: proxy, selector: #selector(CoverFlowFrameTarget.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        frameTarget = proxy
        lastFrame = nil
    }

    private func advance(_ link: CADisplayLink) {
        guard let goal = target else { stop(); return }
        let now = link.targetTimestamp
        let dt = lastFrame.map { min(max(now - $0, 0), 1.0 / 20) } ?? link.duration
        lastFrame = now
        // Exact critically damped solution over dt: stable at any frame rate.
        let x0 = position - goal
        let v0 = velocity
        let decay = exp(-omega * dt)
        let x = (x0 + (v0 + omega * x0) * dt) * decay
        let v = (v0 - omega * (v0 + omega * x0) * dt) * decay
        if abs(x) < 0.0008, abs(v) < 0.02 {
            stop()
            set(goal)
            return
        }
        velocity = v
        set(goal + x)
    }

    private func set(_ value: Double) {
        position = value
        var slot = Int(value.rounded())
        if !loops { slot = min(max(slot, 0), max(count - 1, 0)) }
        if slot != centeredIndex { centeredIndex = slot }
    }

    /// Past either end of a short list the flow gives way less and less, up to
    /// just over half a cover.
    private func rubberBand(_ raw: Double) -> Double {
        let upper = Double(max(count - 1, 0))
        func resist(_ overshoot: Double) -> Double { 0.55 * overshoot / (1 + overshoot) }
        if raw < 0 { return -resist(-raw) }
        if raw > upper { return upper + resist(raw - upper) }
        return raw
    }
}

// MARK: - Layout

/// The classic Cover Flow stage: a flat cover in the middle, and stacks of covers
/// turned toward it on either side, all standing on one mirrored floor.
struct CoverFlowMetrics {
    static let panelHeight: CGFloat = 54
    static let spacing: CGFloat = 16
    /// How far the side covers are turned toward the centre.
    static let sideAngle: Double = 64

    let side: CGFloat
    let reflection: CGFloat
    /// Centre of the centre cover to centre of the first cover in either stack.
    let centerGap: CGFloat
    /// Spacing within a side stack.
    let sidePitch: CGFloat
    /// Finger travel that moves the flow by one cover.
    let dragPitch: CGFloat
    let halfWidth: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let sideInset: CGFloat

    init(size: CGSize, insets: EdgeInsets) {
        topInset = max(insets.top, 10)
        bottomInset = max(insets.bottom, 10)
        sideInset = max(20, insets.leading, insets.trailing)
        let available = size.height - topInset - bottomInset - Self.panelHeight - Self.spacing
        side = max(96, min(240, available / 1.30, size.width * 0.34)).rounded()
        reflection = (side * 0.28).rounded()
        centerGap = side * 0.80
        sidePitch = side * 0.25
        dragPitch = side * 0.55
        halfWidth = size.width / 2
    }

    var stageHeight: CGFloat { side + 2 + reflection }

    /// Where a cover meets its reflection, as a unit point of the cover view.
    /// Side covers shrink toward it, so every cover stands on the same floor.
    var floorAnchor: UnitPoint { UnitPoint(x: 0.5, y: side / stageHeight) }

    /// Every slot that can be on screen around `position`, plus one either side.
    func visibleSlots(around position: Double, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let reach = Int(ceil(max(0, halfWidth - centerGap) / sidePitch)) + 2
        let centre = Int(position.rounded())
        var low = centre - reach
        var high = centre + reach
        if !CoverFlowMotion.loops(count: count) {
            low = max(low, 0)
            high = min(high, count - 1)
        }
        guard low <= high else { return [] }
        return Array(low...high)
    }
}

/// Places one cover from its distance to the centre (in slots).
private struct CoverFlowPlacement: ViewModifier {
    let distance: Double
    let metrics: CoverFlowMetrics

    func body(content: Content) -> some View {
        let magnitude = abs(distance)
        let turn = min(magnitude, 1)               // 0 at the centre, 1 in a stack
        let sign: Double = distance < 0 ? -1 : 1
        let x = magnitude < 1
            ? distance * Double(metrics.centerGap)
            : sign * (Double(metrics.centerGap) + (magnitude - 1) * Double(metrics.sidePitch))
        // Deeper into a stack, a little darker: depth without fog.
        let dim = 0.30 * turn + min(0.22, max(0, magnitude - 1) * 0.05)
        content
            .brightness(-dim)
            .scaleEffect(CGFloat(1 - 0.12 * turn), anchor: metrics.floorAnchor)
            .rotation3DEffect(.degrees(-sign * turn * CoverFlowMetrics.sideAngle),
                              axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .offset(x: CGFloat(x))
    }
}

// MARK: - Covers

private struct CoverFlowCover: View {
    let album: CoverFlowAlbum
    let metrics: CoverFlowMetrics

    var body: some View {
        CachedArtwork(url: album.artworkURL) { image in
            VStack(spacing: 2) {
                face(image)
                // The same decoded image, mirrored; the reflection never loads a URL.
                face(image)
                    .scaleEffect(x: 1, y: -1)
                    .frame(height: metrics.reflection, alignment: .top)
                    .clipped()
                    .mask(LinearGradient(colors: [.black.opacity(0.36), .black.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: metrics.side, height: metrics.stageHeight)
    }

    private func face(_ image: Image?) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.artworkRadius, style: .continuous)
        return Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.17), Color(white: 0.09)],
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note")
                        .font(.system(size: metrics.side * 0.2, weight: .light))
                        .foregroundStyle(Color(white: 0.62))
                }
            }
        }
        .frame(width: metrics.side, height: metrics.side)
        .clipShape(shape)
        // A hairline of glass on the edge keeps dark covers off the black floor.
        .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
    }
}

private struct CoverFlowStage: View {
    let albums: [CoverFlowAlbum]
    let motion: CoverFlowMotion
    let metrics: CoverFlowMetrics
    let onTap: (Int) -> Void

    var body: some View {
        // The only view that reads `position`, so only the covers redraw per frame.
        let position = motion.position
        ZStack {
            ForEach(metrics.visibleSlots(around: position, count: albums.count), id: \.self) { slot in
                let distance = Double(slot) - position
                CoverFlowCover(album: albums[CoverFlowMotion.albumIndex(for: slot, count: albums.count)],
                               metrics: metrics)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(slot) }
                    .modifier(CoverFlowPlacement(distance: distance, metrics: metrics))
                    .zIndex(-abs(distance))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: metrics.stageHeight)
    }
}

// MARK: - Page

@MainActor
struct CoverFlowView: View {
    let viewModel: PlayerViewModel
    let safeInsets: EdgeInsets
    @State private var motion = CoverFlowMotion()
    @State private var centeredAlbumID: String?
    @State private var centeredTrackID: String?
    @GestureState private var isTouching = false

    var body: some View {
        GeometryReader { geometry in
            let albums = viewModel.coverFlowAlbums
            let metrics = CoverFlowMetrics(size: geometry.size, insets: safeInsets)
            let centered = albums.first { $0.id == centeredAlbumID }

            ZStack {
                // The reflection fades into a full-page black floor in every theme.
                Color.black.ignoresSafeArea()
                // A faint pool of light behind the centre cover.
                RadialGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0)],
                               center: UnitPoint(x: 0.5, y: 0.42),
                               startRadius: 0, endRadius: geometry.size.width * 0.42)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                if albums.isEmpty {
                    emptyState
                        .padding(.horizontal, metrics.sideInset)
                } else {
                    VStack(spacing: CoverFlowMetrics.spacing) {
                        CoverFlowStage(albums: albums, motion: motion, metrics: metrics) { slot in
                            tapped(slot)
                        }
                        // Stacks melt into the dark at the screen edges. Taller than the
                        // stage so turned covers' near edges are never cut off.
                        .mask { edgeFade.padding(.vertical, -60) }

                        ZStack { infoPanel(centered) }
                            .frame(maxWidth: 580)
                            .frame(height: CoverFlowMetrics.panelHeight)
                            .padding(.horizontal, metrics.sideInset)
                            .animation(.easeOut(duration: 0.16), value: centeredAlbumID)
                    }
                    .padding(.top, metrics.topInset)
                    .padding(.bottom, metrics.bottomInset)
                    .frame(maxHeight: .infinity)
                    .accessibilityElement(children: .ignore)
                    // Library names are user data, not app copy.
                    .accessibilityLabel(Text(verbatim: centered.map { $0.title + "，" + $0.artist } ?? ""))
                    .accessibilityHint(Text(hintText(for: centered)))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        if let centered { viewModel.playCoverFlowAlbum(centered) }
                    }
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: motion.step(1)
                        case .decrement: motion.step(-1)
                        @unknown default: break
                        }
                    }
                }
            }
            .foregroundStyle(Color.white)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(drag(pitch: metrics.dragPitch))
            // Entering Cover Flow always opens on the song that is playing.
            .onAppear { reconcile(preferPlaying: true) }
            .onChange(of: viewModel.coverFlowIdentity) { _, _ in reconcile(preferPlaying: false) }
            .onChange(of: motion.centeredIndex) { _, slot in centeredSlotChanged(slot) }
            .onChange(of: viewModel.currentTrack?.id) { previous, _ in followPlayback(from: previous) }
            // A drag the system cancels (rotation, an alert) never reports onEnded.
            .onChange(of: isTouching) { _, touching in
                if !touching { motion.endDrag(velocity: 0) }
            }
            .onDisappear { motion.stop() }
            .task(id: centeredAlbumID) { await prefetchNeighbours() }
        }
    }

    // MARK: Input

    private func drag(pitch: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($isTouching) { _, touching, _ in touching = true }
            .onChanged { value in
                let slots = -Double(value.translation.width / pitch)
                if motion.isDragging {
                    motion.drag(to: slots)
                } else {
                    // Measured from here, so the 6pt slop never jolts the flow.
                    motion.beginDrag(at: slots)
                }
            }
            .onEnded { value in
                motion.endDrag(velocity: -Double(value.velocity.width / pitch))
            }
    }

    /// A side cover glides to the centre; the centred cover plays (or pauses).
    private func tapped(_ slot: Int) {
        let albums = viewModel.coverFlowAlbums
        let index = CoverFlowMotion.albumIndex(for: slot, count: albums.count)
        guard albums.indices.contains(index) else { return }
        if slot == motion.centeredIndex, abs(motion.position - Double(slot)) < 0.2 {
            viewModel.playCoverFlowAlbum(albums[index])
        } else {
            motion.glide(to: Double(slot))
        }
    }

    // MARK: Selection

    private func reconcile(preferPlaying: Bool) {
        let albums = viewModel.coverFlowAlbums
        let previousCount = motion.count
        motion.configure(count: albums.count)
        guard !albums.isEmpty else {
            motion.jump(to: 0)
            centeredAlbumID = nil
            centeredTrackID = nil
            return
        }
        let playing = albums.firstIndex { viewModel.isCurrentCoverFlowAlbum($0) }
        // Keep focus when resolving a real track adds artwork and changes its album ID.
        let kept = albums.firstIndex { $0.id == centeredAlbumID }
            ?? albums.firstIndex { album in album.tracks.contains { $0.id == centeredTrackID } }
        let index = (preferPlaying ? (playing ?? kept) : (kept ?? playing)) ?? 0
        centeredAlbumID = albums[index].id
        centeredTrackID = albums[index].tracks.first?.id
        // Same list, same cover in the middle: leave a running glide alone.
        if !preferPlaying, previousCount == albums.count,
           motion.albumIndex(for: motion.centeredIndex) == index { return }
        motion.jump(to: index)
    }

    private func centeredSlotChanged(_ slot: Int) {
        let albums = viewModel.coverFlowAlbums
        let index = CoverFlowMotion.albumIndex(for: slot, count: albums.count)
        guard albums.indices.contains(index) else { return }
        let album = albums[index]
        guard album.id != centeredAlbumID else { return }
        centeredAlbumID = album.id
        centeredTrackID = album.tracks.first?.id
        HapticEngine.shared.tick()
    }

    /// When the song changes while the flow is resting on it (the track ended,
    /// next/previous from the lock screen), the flow follows to the new song.
    /// Someone browsing elsewhere is left where they are.
    private func followPlayback(from previousID: String?) {
        guard !motion.isDragging, let previousID else { return }
        let albums = viewModel.coverFlowAlbums
        guard let centered = albums.first(where: { $0.id == centeredAlbumID }),
              centered.tracks.contains(where: { $0.id == previousID }),
              let index = albums.firstIndex(where: { viewModel.isCurrentCoverFlowAlbum($0) }) else { return }
        motion.glide(to: Double(motion.nearestSlot(for: index)))
    }

    private func prefetchNeighbours() async {
        // Short debounce: a continuous spin should not queue every cover it passes.
        do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
        let albums = viewModel.coverFlowAlbums
        guard !Task.isCancelled, let albumID = centeredAlbumID,
              let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        var urls: [URL] = []
        for offset in -6...6 {
            let neighbour = albums[CoverFlowMotion.albumIndex(for: index + offset, count: albums.count)]
            if let url = neighbour.artworkURL, !urls.contains(url) { urls.append(url) }
        }
        guard !urls.isEmpty else { return }
        await CachedImageLoader.shared.prefetch(urls)
    }

    // MARK: Pieces

    @ViewBuilder
    private func infoPanel(_ album: CoverFlowAlbum?) -> some View {
        if let album {
            let track = displayedTrack(in: album)
            let isCurrent = viewModel.isCurrentCoverFlowAlbum(album)
            HStack(spacing: 9) {
                if isCurrent {
                    Image(systemName: viewModel.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(white: 0.82))
                }
                VStack(spacing: 2) {
                    Text(verbatim: track?.title ?? album.title)
                        .font(AppFont.body)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(verbatim: track?.artist ?? album.artist)
                        .font(AppFont.detail)
                        .foregroundStyle(Color(white: 0.68))
                        .lineLimit(1)
                }
                .multilineTextAlignment(.center)
            }
            // A floating glass capsule that hugs the title. The page is black in every
            // theme, so the glass is forced to its dark variant — otherwise a light
            // system setting would turn it white under white text.
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .lcdGlass(in: Capsule(), fallback: .ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .id(album.id)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    private func displayedTrack(in album: CoverFlowAlbum) -> Track? {
        if let track = viewModel.currentTrack, album.contains(track) { return track }
        return album.tracks.first(where: { $0.id == centeredTrackID }) ?? album.tracks.first
    }

    private func hintText(for album: CoverFlowAlbum?) -> String {
        guard let album else { return "" }
        if viewModel.isCurrentCoverFlowAlbum(album) { return "轻点暂停或继续播放" }
        return album.tracks.count > 1 ? "轻点播放专辑中的歌曲" : "轻点播放这首歌曲"
    }

    private var edgeFade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.10),
            .init(color: .black, location: 0.90),
            .init(color: .clear, location: 1)
        ], startPoint: .leading, endPoint: .trailing)
    }

    private var emptyState: some View {
        // Neutral on the black page: a theme accent (mint, sunset) jumps out of it.
        LCDEmptyState(message: "暂无歌曲", symbol: "square.stack", tint: Color(white: 0.70))
    }
}
