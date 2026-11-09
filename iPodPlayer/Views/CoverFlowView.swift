import SwiftUI
import UIKit

/// Scroll copies share album identity and artwork; only their scroll IDs differ.
struct CoverFlowLoop {
    let albumCount: Int
    let copyCount: Int

    init(albumCount: Int, visibleSlotCount: Int) {
        self.albumCount = max(0, albumCount)
        // A release can travel seven slots without rebasing the visible curve.
        // Leave that travel plus a viewport of neighbours on either side.
        copyCount = albumCount > 1 ? max(3, 2 * ((visibleSlotCount + 7 + albumCount - 1) / albumCount) + 3) : 1
    }

    var slotCount: Int { albumCount * copyCount }

    func albumIndex(for slot: Int) -> Int {
        guard albumCount > 0 else { return 0 }
        return (slot % albumCount + albumCount) % albumCount
    }

    func realSlot(for slot: Int) -> Int {
        (copyCount / 2) * albumCount + albumIndex(for: slot)
    }

    func steppedSlot(from slot: Int, direction: Int) -> Int {
        realSlot(for: slot + direction)
    }
}

private struct CoverFlowSlotAnchors: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Keep native dragging; own release momentum, exact settling and centre reporting.
private struct CoverFlowScrollProbe: UIViewRepresentable {
    @MainActor final class State: NSObject, UIScrollViewDelegate {
        weak var view: UIView?
        private weak var observedScrollView: UIScrollView?
        private weak var downstreamDelegate: UIScrollViewDelegate?
        private var offsetObservation: NSKeyValueObservation?
        private var displayLink: CADisplayLink?
        private var loop = CoverFlowLoop(albumCount: 0, visibleSlotCount: 0)
        private var slotPitch: CGFloat = 1
        private var slotWidth: CGFloat = 1
        private var isRebasing = false
        private var pendingReleaseVelocity: CGFloat?
        private var settledSlot: Int?
        private var glide: Glide?
        private var trackingStartedAt: CFTimeInterval?
        private var pendingSlot: Int?
        private var lastReportedSlot: Int?
        var onCenteredSlot: ((Int) -> Void)?

        private struct Glide {
            var startX: CGFloat
            var destinationX: CGFloat
            var destinationSlot: Int
            let velocity: CGFloat
            var startedAt: CFTimeInterval
            let duration: CFTimeInterval
        }

        var scrollView: UIScrollView? {
            var ancestor = view?.superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView { return scrollView }
                ancestor = current.superview
            }
            return nil
        }

        func configure(view: UIView, loop: CoverFlowLoop, slotPitch: CGFloat, slotWidth: CGFloat) {
            if self.loop.slotCount != loop.slotCount || self.slotPitch != slotPitch { cancelMotion() }
            self.view = view
            self.loop = loop
            self.slotPitch = slotPitch
            self.slotWidth = slotWidth
            connect()
        }

        func center(on slot: Int) {
            cancelMotion()
            pendingSlot = slot
            applyPendingCenter()
        }

        private func applyPendingCenter() {
            guard let slot = pendingSlot, let scrollView = observedScrollView,
                  !scrollView.isTracking, !scrollView.isDragging,
                  let firstCenter = firstSlotCenter(in: scrollView),
                  scrollView.contentSize.width >= CGFloat(loop.slotCount) * slotPitch - 5 else { return }
            let targetX = firstCenter + CGFloat(slot) * slotPitch - scrollView.bounds.width / 2
            pendingSlot = nil
            stopNativeDeceleration(in: scrollView)
            settledSlot = slot
            scrollView.setContentOffset(CGPoint(x: targetX, y: scrollView.contentOffset.y), animated: false)
            rebase()
            reportCenteredSlot()
        }

        private func reportCenteredSlot() {
            guard let scrollView = observedScrollView, let firstCenter = firstSlotCenter(in: scrollView),
                  loop.slotCount > 0 else { return }
            let slot = min(max(Int(((scrollView.contentOffset.x + scrollView.bounds.width / 2 - firstCenter)
                                    / slotPitch).rounded()), 0), loop.slotCount - 1)
            guard lastReportedSlot != slot else { return }
            lastReportedSlot = slot
            // Selection is read-only: SwiftUI never writes a competing scroll target.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastReportedSlot == slot else { return }
                self.onCenteredSlot?(slot)
            }
        }

        func connect() {
            guard let scrollView else { return }
            // Native dragging remains intact; release momentum belongs to the custom glide.
            scrollView.decelerationRate = UIScrollView.DecelerationRate(rawValue: 0.99)
            guard observedScrollView !== scrollView else {
                installDelegate(on: scrollView)
                applyPendingCenter()
                return
            }
            disconnect()
            observedScrollView = scrollView
            installDelegate(on: scrollView)
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
            offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Only a native drag rebases here. The glide owns every release frame,
                    // including the final one; no observer corrects its resting offset later.
                    if self.observedScrollView?.isDragging == true { self.rebase() }
                    self.reportCenteredSlot()
                }
            }
            applyPendingCenter()
        }

        private func installDelegate(on scrollView: UIScrollView) {
            guard scrollView.delegate !== self else { return }
            downstreamDelegate = scrollView.delegate
            scrollView.delegate = self
        }

        nonisolated override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return MainActor.assumeIsolated { downstreamDelegate?.responds(to: selector) ?? false }
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            var target: Any?
            MainActor.assumeIsolated {
                if let downstreamDelegate, downstreamDelegate.responds(to: selector) {
                    target = downstreamDelegate
                }
            }
            return target ?? super.forwardingTarget(for: selector)
        }

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            downstreamDelegate?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity,
                                                           targetContentOffset: targetContentOffset)
            // Prevent UIKit from scheduling its own journey after release. Its target is
            // the release position; the display link alone carries the cover to its slot.
            targetContentOffset.pointee = scrollView.contentOffset
        }

        func cancelMotion() {
            pendingReleaseVelocity = nil
            settledSlot = nil
            stopGlide()
        }

        func disconnect() {
            cancelMotion()
            observedScrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
            if let scrollView = observedScrollView, scrollView.delegate === self {
                scrollView.delegate = downstreamDelegate
            }
            downstreamDelegate = nil
            offsetObservation?.invalidate()
            offsetObservation = nil
            observedScrollView = nil
        }

        @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
            guard let scrollView = observedScrollView else { return }
            switch pan.state {
            case .began:
                pendingSlot = nil
                pendingReleaseVelocity = nil
                settledSlot = nil
                stopGlide()
            case .ended, .cancelled:
                pendingReleaseVelocity = pan.state == .ended ? -pan.velocity(in: scrollView).x : 0
                settledSlot = nil
                // UIKit can still report dragging/tracking on the next run-loop turn.
                // Keep the release pending until a display-link frame sees the drag fully ended.
                startDisplayLink()
            default: break
            }
        }

        private func firstSlotCenter(in scrollView: UIScrollView) -> CGFloat? {
            guard let view, view.window != nil, scrollView.bounds.width > 0 else { return nil }
            return view.convert(CGPoint(x: slotWidth / 2, y: 0), to: scrollView).x
        }

        func step(direction: Int) -> Bool {
            guard let scrollView = observedScrollView, !scrollView.isTracking, !scrollView.isDragging,
                  let firstCenter = firstSlotCenter(in: scrollView) else { return false }
            let baseX = glide?.destinationX ?? scrollView.contentOffset.x
            let slot = Int(((baseX + scrollView.bounds.width / 2 - firstCenter) / slotPitch).rounded())
            pendingReleaseVelocity = nil
            startGlide(velocity: 0, in: scrollView, targetSlot: slot + direction)
            return true
        }

        private func startGlide(velocity: CGFloat, in scrollView: UIScrollView, targetSlot: Int? = nil) {
            stopGlide()
            settledSlot = nil
            guard loop.slotCount > 0, let firstCenter = firstSlotCenter(in: scrollView) else { return }
            // Writing the same contentOffset can leave UIKit's deceleration active on device.
            // End its scrolling transaction after release, then restore the release position.
            stopNativeDeceleration(in: scrollView)
            // Rebase before sampling the curve, never during or after its final frame.
            // The loop has a viewport of spare copies plus room for the seven-slot glide.
            let releaseX = scrollView.contentOffset.x
            rebase()
            let rebasedTargetSlot = targetSlot.map {
                $0 + Int(((scrollView.contentOffset.x - releaseX) / slotPitch).rounded())
            }
            let startX = scrollView.contentOffset.x
            let projection = abs(velocity) >= 2 * slotPitch
                ? min(max(velocity * 0.38, -7 * slotPitch), 7 * slotPitch) : 0
            var projectedSlot = Int(((startX + projection + scrollView.bounds.width / 2 - firstCenter)
                                     / slotPitch).rounded())
            if abs(velocity) >= 2 * slotPitch {
                let releaseSlot = Int(((startX + scrollView.bounds.width / 2 - firstCenter) / slotPitch).rounded())
                // A deliberate flick always carries to at least the next cover in its direction.
                projectedSlot = velocity > 0 ? max(projectedSlot, releaseSlot + 1)
                                             : min(projectedSlot, releaseSlot - 1)
            }
            let slot = min(max(rebasedTargetSlot ?? projectedSlot, 0), loop.slotCount - 1)
            let destinationX = firstCenter + CGFloat(slot) * slotPitch - scrollView.bounds.width / 2
            let duration = abs(velocity) >= 2 * slotPitch
                ? 0.62 + min(0.33, Double(abs(velocity)) / 12_000) : 0.42
            let travel = destinationX - startX
            // A monotone Hermite curve keeps release momentum without overshooting the centred cover.
            let launchVelocity = travel * velocity > 0
                ? (velocity > 0 ? 1.0 : -1.0) * min(abs(velocity), 3 * abs(travel) / CGFloat(duration)) : 0
            glide = Glide(startX: startX, destinationX: destinationX, destinationSlot: slot,
                          velocity: launchVelocity, startedAt: CACurrentMediaTime(), duration: duration)
            startDisplayLink()
        }

        private func stopNativeDeceleration(in scrollView: UIScrollView) {
            let releaseOffset = scrollView.contentOffset
            if scrollView.isScrollEnabled {
                scrollView.isScrollEnabled = false
                scrollView.isScrollEnabled = true
            }
            scrollView.setContentOffset(releaseOffset, animated: false)
        }

        private func startDisplayLink() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(advanceGlide(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func advanceGlide(_ link: CADisplayLink) {
            guard let scrollView = observedScrollView else { stopGlide(); return }
            // A release is never discarded merely because UIKit has not cleared isDragging yet.
            if scrollView.isDragging { return }
            if scrollView.isTracking {
                // A touch that never becomes a pan must not strand a half-centred
                // cover. Hold the curve until release; an actual pan cancels it.
                if trackingStartedAt == nil { trackingStartedAt = link.timestamp }
                return
            }
            if let trackingStartedAt {
                glide?.startedAt += link.timestamp - trackingStartedAt
                self.trackingStartedAt = nil
            }
            if let velocity = pendingReleaseVelocity {
                pendingReleaseVelocity = nil
                startGlide(velocity: velocity, in: scrollView)
                return
            }
            guard let glide else { stopGlide(); return }
            let t = CGFloat(min(1, max(0, (link.timestamp - glide.startedAt) / glide.duration)))
            if t == 1 {
                // Write the exact destination, not the last sampled curve point.
                settledSlot = glide.destinationSlot
                scrollView.setContentOffset(CGPoint(x: glide.destinationX, y: scrollView.contentOffset.y), animated: false)
                stopGlide()
                reportCenteredSlot()
                return
            }
            let eased = 3 * t * t - 2 * t * t * t
            let momentum = t * t * t - 2 * t * t + t
            let x = glide.startX + (glide.destinationX - glide.startX) * eased
                + glide.velocity * CGFloat(glide.duration) * momentum
            // Gently strengthen the final pull without changing release momentum or its destination.
            let snapPull: CGFloat = 0.12 * t * t
            let snappedX = x + (glide.destinationX - x) * snapPull
            scrollView.setContentOffset(CGPoint(x: snappedX, y: scrollView.contentOffset.y), animated: false)
        }

        private func stopGlide() {
            displayLink?.invalidate()
            displayLink = nil
            glide = nil
            trackingStartedAt = nil
        }

        private func rebase() {
            guard !isRebasing, glide == nil, loop.albumCount > 1, let scrollView = observedScrollView,
                  let firstCenter = firstSlotCenter(in: scrollView) else { return }
            let sourceX = scrollView.contentOffset.x
            let slot = Int(((sourceX + scrollView.bounds.width / 2 - firstCenter) / slotPitch).rounded())
            let realSlot = loop.realSlot(for: slot)
            guard realSlot != slot else { return }
            let offset = firstCenter + CGFloat(slot) * slotPitch - sourceX - scrollView.bounds.width / 2
            let translation = CGFloat(realSlot - slot) * slotPitch
            let targetX = sourceX + translation
            let targetOffset = offset + translation - (targetX - sourceX)
            guard loop.albumIndex(for: realSlot) == loop.albumIndex(for: slot),
                  abs(targetOffset - offset) < 0.000_001,
                  targetX >= -scrollView.adjustedContentInset.left,
                  targetX <= scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right else { return }
            isRebasing = true
            defer { isRebasing = false }
            // Only a drag or a new motion rebases; an active glide never shifts copies.
            if let settledSlot { self.settledSlot = settledSlot + realSlot - slot }
            // Bounds translation leaves the native pan gesture active. No animated scroll/snap is requested.
            var bounds = scrollView.bounds
            bounds.origin.x = targetX
            UIView.performWithoutAnimation { scrollView.bounds = bounds }
        }
    }

    final class ProbeView: UIView {
        weak var state: State?
        override func didMoveToSuperview() { super.didMoveToSuperview(); state?.connect() }
        override func didMoveToWindow() { super.didMoveToWindow(); state?.connect() }
        override func layoutSubviews() { super.layoutSubviews(); state?.connect() }
    }

    let state: State
    let loop: CoverFlowLoop
    let slotPitch: CGFloat
    let slotWidth: CGFloat
    let onCenteredSlot: (Int) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.state = state
        state.onCenteredSlot = onCenteredSlot
        state.configure(view: view, loop: loop, slotPitch: slotPitch, slotWidth: slotWidth)
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        state.onCenteredSlot = onCenteredSlot
        state.configure(view: uiView, loop: loop, slotPitch: slotPitch, slotWidth: slotWidth)
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) { uiView.state?.disconnect() }
}

@MainActor
struct CoverFlowView: View {
    let viewModel: PlayerViewModel
    let safeInsets: EdgeInsets
    @EnvironmentObject private var appearance: AppearanceSettings
    @State private var centeredAlbumID: String?
    @State private var centeredTrackID: String?
    @State private var centeredSlotID: Int?
    @State private var scrollProbe = CoverFlowScrollProbe.State()

    var body: some View {
        GeometryReader { geometry in
            let albums = viewModel.coverFlowAlbums
            let topInset = max(safeInsets.top, 8)
            let bottomInset = max(safeInsets.bottom, 8)
            let availableHeight = geometry.size.height - topInset - bottomInset
            let coverSide = min(200, max(100, (availableHeight - 62) / 1.65))
            let coverHeight = coverSide * 1.65
            let sideInset = max(20, safeInsets.leading, safeInsets.trailing)
            let slotWidth = coverSide * 0.78
            let loop = CoverFlowLoop(albumCount: albums.count,
                                     visibleSlotCount: Int(ceil(geometry.size.width / (slotWidth + 5))))

            ZStack {
                // The reflection fades into a full-page black surface in every theme.
                Color.black.ignoresSafeArea()

                if albums.isEmpty {
                    emptyState
                        .padding(.horizontal, sideInset)
                } else {
                    VStack(spacing: 14) {
                        covers(albums, loop: loop, viewportWidth: geometry.size.width,
                               side: coverSide, slotWidth: slotWidth, height: coverHeight)

                        if let album = albums.first(where: { $0.id == centeredAlbumID }) {
                            infoPanel(album)
                                .frame(maxWidth: 580)
                                .padding(.horizontal, sideInset)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .padding(.top, topInset)
                    .padding(.bottom, bottomInset)
                }
            }
            .foregroundStyle(Color.white)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onAppear { scrollProbe.connect(); reconcileSelection(albums, loop: loop) }
            .onChange(of: viewModel.coverFlowIdentity) { _, _ in reconcileSelection(albums, loop: loop) }
            .onChange(of: loop.slotCount) { _, _ in reconcileSelection(albums, loop: loop) }
            .onChange(of: centeredSlotID) { _, slot in
                selectSlot(slot, albums: albums, loop: loop)
            }
            .onDisappear { scrollProbe.disconnect() }
            .task(id: centeredAlbumID) {
                // Warm the whole visible ring, not just the two covers either side,
                // and start immediately after the wheel settles. Flicking used to
                // land on placeholders while the previous neighbours were still
                // queued behind six connections. The short debounce only exists so
                // a continuous spin does not queue every album it passes.
                do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
                guard !Task.isCancelled, let albumID = centeredAlbumID,
                      let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
                var urls: [URL] = []
                for offset in -4...4 {
                    let album = albums[loop.albumIndex(for: index + offset)]
                    if let url = album.artworkURL { urls.append(url) }
                }
                guard !urls.isEmpty else { return }
                await CachedImageLoader.shared.prefetch(urls)
            }
        }
    }

    private func covers(_ albums: [CoverFlowAlbum], loop: CoverFlowLoop, viewportWidth: CGFloat,
                        side: CGFloat, slotWidth: CGFloat, height: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 5) {
                ForEach(0..<loop.slotCount, id: \.self) { slot in
                    Color.clear
                        .frame(width: slotWidth, height: height)
                        .anchorPreference(key: CoverFlowSlotAnchors.self, value: .bounds) { [slot: $0] }
                        .id(slot)
                }
            }
            .scrollTargetLayout()
            .overlayPreferenceValue(CoverFlowSlotAnchors.self) { anchors in
                GeometryReader { geometry in
                    let contentX = geometry.frame(in: .named("coverFlow")).minX
                    // All covers are siblings: resolve their live anchors once for transforms AND z-order.
                    ZStack(alignment: .topLeading) {
                        ForEach(anchors.keys.sorted(), id: \.self) { slot in
                            if let anchor = anchors[slot] {
                                let album = albums[loop.albumIndex(for: slot)]
                                let bounds = geometry[anchor]
                                let offset = bounds.midX + contentX - viewportWidth / 2
                                let distance = offset / side
                                let scale = 1.3 - 0.44 * min(1, abs(distance))
                                let isCentered = centeredSlotID == slot
                                Button {
                                    guard centeredAlbumID == album.id, centeredSlotID == slot else { return }
                                    // A scrolling candidate must also have reached the centre.
                                    guard abs(distance) < 0.25 else { return }
                                    viewModel.playCoverFlowAlbum(album)
                                } label: {
                                    CachedArtwork(url: album.artworkURL) { image in
                                        VStack(spacing: 4) {
                                            artwork(image, side: side)
                                                .shadow(color: .black.opacity(Double(0.32 - 0.20 * min(1, abs(distance)))),
                                                        radius: 12 - 8 * min(1, abs(distance)), y: 7)
                                            // Mirror the same decoded image; reflection never loads a URL.
                                            artwork(image, side: side)
                                                .scaleEffect(x: 1, y: -1)
                                                .frame(height: side * 0.22, alignment: .top)
                                                .clipped()
                                                .mask(LinearGradient(colors: [.black.opacity(0.35), .clear],
                                                                     startPoint: .top, endPoint: .bottom))
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    .scaleEffect(scale)
                                    .rotation3DEffect(.degrees(Double(min(max(distance, -1), 1)) * -32),
                                                      axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                                    .opacity(max(0.55, 1 - abs(Double(distance)) * 0.18))
                                    .frame(width: side * scale, height: height)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                // The narrow scroll slot allows overlap; the centre stays above its neighbours.
                                .frame(width: slotWidth, height: height)
                                // Library names are user data, not app copy.
                                .accessibilityLabel(Text(verbatim: album.title + "，" + album.artist))
                                .accessibilityHint(viewModel.isCurrentCoverFlowAlbum(album)
                                                   ? "轻点暂停或继续播放"
                                                   : (album.tracks.count > 1 ? "轻点播放专辑中的歌曲" : "轻点播放这首歌曲"))
                                .accessibilityHidden(!isCentered)
                                .position(x: bounds.midX, y: bounds.midY)
                                .zIndex(-abs(distance))
                            }
                        }
                    }
                }
            }
            .background(CoverFlowScrollProbe(state: scrollProbe, loop: loop,
                                             slotPitch: slotWidth + 5, slotWidth: slotWidth,
                                             onCenteredSlot: { centeredSlotID = $0 }))
        }
        .contentMargins(.horizontal, max(0, (viewportWidth - slotWidth) / 2), for: .scrollContent)
        .coordinateSpace(name: "coverFlow")
        // The UIKit probe owns position; binding a SwiftUI scroll target here
        // could override the exact glide endpoint after selection or rebasing.
        .scrollClipDisabled()
        .frame(height: height)
        .accessibilityAdjustableAction { direction in
            guard !albums.isEmpty else { return }
            let current = centeredSlotID ?? loop.realSlot(for: 0)
            let delta: Int
            switch direction {
            case .increment: delta = 1
            case .decrement: delta = -1
            @unknown default: return
            }
            // Accessibility uses the same movable glide target, including while a copy rebases.
            if scrollProbe.step(direction: delta) { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                let slot = loop.steppedSlot(from: current, direction: delta)
                centeredSlotID = slot
                scrollProbe.center(on: slot)
            }
        }
    }

    private func artwork(_ image: Image?, side: CGFloat) -> some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(Color(white: 0.76))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.artworkRadius, style: .continuous))
    }

    private func infoPanel(_ album: CoverFlowAlbum) -> some View {
        let track = displayedTrack(in: album)
        return VStack(spacing: 3) {
            Text(verbatim: track?.title ?? "")
                .font(AppFont.body)
                .fontWeight(.semibold)
                .lineLimit(1)
            Text(verbatim: track?.artist ?? "")
                .font(AppFont.detail)
                .foregroundStyle(Color(white: 0.70))
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        // A floating glass capsule that hugs the title instead of a bare line of
        // text on the reflection. The page is black in every theme, so the glass is
        // forced to its dark variant — otherwise a light system setting would turn it
        // white under white text.
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .lcdGlass(in: Capsule(), fallback: .ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    private func displayedTrack(in album: CoverFlowAlbum) -> Track? {
        if let track = viewModel.currentTrack, album.contains(track) { return track }
        return album.tracks.first(where: { $0.id == centeredTrackID }) ?? album.tracks.first
    }

    private var emptyState: some View {
        // Neutral on the black page: a theme accent (mint, sunset) jumps out of it.
        LCDEmptyState(message: "暂无歌曲", symbol: "square.stack", tint: Color(white: 0.70))
    }

    private func selectSlot(_ slot: Int?, albums: [CoverFlowAlbum], loop: CoverFlowLoop) {
        guard let slot, !albums.isEmpty, (0..<loop.slotCount).contains(slot) else { return }
        let album = albums[loop.albumIndex(for: slot)]
        guard centeredAlbumID != album.id else { return }
        let hadSelection = centeredAlbumID != nil
        centeredAlbumID = album.id
        centeredTrackID = album.tracks.first?.id
        if hadSelection { HapticEngine.shared.tick() }
    }

    private func reconcileSelection(_ albums: [CoverFlowAlbum], loop: CoverFlowLoop) {
        scrollProbe.cancelMotion()
        // Keep focus when resolving a real track adds artwork and changes its album ID.
        let retained = albums.first { $0.id == centeredAlbumID }
        let remembered = albums.first { album in
            album.tracks.contains { $0.id == centeredTrackID }
        }
        let playing = albums.first { viewModel.isCurrentCoverFlowAlbum($0) }
        let album = retained ?? remembered ?? playing ?? albums.first
        centeredAlbumID = album?.id
        centeredTrackID = album?.tracks.first?.id
        if let index = albums.firstIndex(where: { $0.id == album?.id }) {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                let slot = loop.realSlot(for: index)
                centeredSlotID = slot
                scrollProbe.center(on: slot)
            }
        } else {
            centeredSlotID = nil
        }
    }
}
