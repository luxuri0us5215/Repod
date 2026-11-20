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
private struct LCDLensAnchor {
    let id: AnyHashable?
    let bounds: Anchor<CGRect>
}

private struct LCDLensAnchorKey: PreferenceKey {
    static var defaultValue: LCDLensAnchor? { nil }
    static func reduce(value: inout LCDLensAnchor?, nextValue: () -> LCDLensAnchor?) {
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
///
/// 3.2.23: inside a list driven by `lcdWheelFollow` (iOS 18+) the bar is placed on
/// screen by the follow engine instead (see "Wheel follow" below); before iOS 18
/// it rides the content exactly as in 3.2.21.
@MainActor
struct LCDLensHost: ViewModifier {
    /// The bar rides in the content, so the list carries it and the two can never
    /// drift apart; the animation is what makes the row-to-row move a glide.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lcdFollowState) private var follow

    @ViewBuilder
    func body(content: Content) -> some View {
        if let follow {
            followed(content, follow)
        } else {
            content
                .environment(\.lcdLensHosted, true)
                .backgroundPreferenceValue(LCDLensAnchorKey.self) { anchor in
                    GeometryReader { proxy in
                        if let anchor {
                            let rect = proxy[anchor.bounds]
                            LCDSelectionBar()
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .animation(reduceMotion ? nil : LCDFollowPace.lens, value: rect)
                        }
                    }
                }
        }
    }

    /// With a follow engine the selected row only reports its frame; the engine
    /// decides where the bar is (`LCDFollowState`). Until the engine has seen the
    /// scroll view, the bar simply sits on its row.
    private func followed(_ content: Content, _ follow: LCDFollowState) -> some View {
        content
            .environment(\.lcdLensHosted, true)
            .backgroundPreferenceValue(LCDLensAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    Color.clear.preference(key: LCDLensRectKey.self, value: anchor.map { LCDLensReport(id: $0.id, rect: proxy[$0.bounds]) })
                }
                .allowsHitTesting(false)
            }
            .backgroundPreferenceValue(LCDLensRectKey.self) { reported in
                GeometryReader { _ in
                    if let rect = follow.ready ? follow.row : reported?.rect {
                        LCDSelectionBar()
                            .frame(width: rect.width, height: rect.height)
                            // 50 ↔ 60 pt rows: the bar's height eases on its own.
                            .animation(reduceMotion ? nil : LCDFollowPace.lens, value: rect.size)
                            // Before `.position`, so the placement measures the bar
                            // itself (a positioned view fills the whole reader).
                            .modifier(LCDBarPlacement(screenY: follow.barY,
                                                      contentY: follow.ready ? follow.focusY : rect.midY,
                                                      pinned: follow.ready && follow.pinned))
                            // Laid out with its centre on content y 0; the placement
                            // moves it from there.
                            .position(x: rect.midX, y: 0)
                    }
                }
                .allowsHitTesting(false)
            }
    }
}

extension View {
    /// One gliding selection lens for every row under this view.
    func lcdLensHost() -> some View {
        modifier(LCDLensHost()).coordinateSpace(name: LCDInkSpace.content)
    }
}

// MARK: Follow pace

/// Shared curves for ink, standalone lenses and the iOS 17 scroll path.
/// The iOS 18 follow engine animates one focus coordinate at the wheel's pace.
enum LCDFollowPace {
    static let resting = Animation.spring(response: 0.24, dampingFraction: 1.0)
    static let lens = Animation.spring(response: 0.32, dampingFraction: 1.0)
    static var glide: Animation { lens }
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
            // 3.2.21: the scroll rides `resting` (0.24 s), never `glide`. Since 3.2.18
            // `glide` is the bar's 0.32 s spring, and on that curve the list falls
            // behind a fast spin and stops a row or more below the selection.
            withAnimation(LCDFollowPace.resting) { scrollTo(id, anchor: anchor) }
            // iOS 18's engine owns subsequent wheel moves. A delayed legacy
            // follow here would pull Search back to its input after re-entry.
            if !LCDWheelFollow.isActive { settleFollow(id, anchor: anchor) }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollTo(id, anchor: anchor) }
        }
    }

    /// Re-asks for the row once the move has had time to finish.
    ///
    /// The list is scrolled with an animated `scrollTo` per wheel step. Requests
    /// that arrive while the previous one is still running are not all honoured:
    /// spinning a long list to its end and back and stopping left the rows 1–3
    /// rows away from the selection (measured 60–180 pt on the simulator), and
    /// they stayed there — the list looked "dropped" against the centred bar.
    /// A `scrollTo` issued while nothing is moving is exact, so once the last step
    /// has settled the same target is asked for once more. When the list did land
    /// correctly this is a no-op.
    @MainActor
    private func settleFollow<ID: Hashable>(_ id: ID, anchor: UnitPoint?) {
        LCDFollowSettle.generation &+= 1
        let generation = LCDFollowSettle.generation
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard LCDFollowSettle.generation == generation else { return }
            withAnimation(LCDFollowPace.resting) { scrollTo(id, anchor: anchor) }
        }
    }
}

/// The last follow request wins: an older settle must not pull the list back.
@MainActor
private enum LCDFollowSettle {
    static var generation = 0
}

// MARK: Wheel follow (iOS 18+)
//
// One animated content coordinate owns the focus. Each frame derives both the
// scroll (clamped at the ends) and the bar's screen position from that coordinate.
// There is no second spring to cancel out and no hard correction of its output.
// LCDBarPlacement compensates the real scroll offset in the frame being drawn;
// ScrollPosition can deliver a request one layout pass after it was submitted.
//
// ScrollGeometry.containerSize is the list below the title strip. Its resting
// contentOffset is -contentInsets.top; scrollTo(y:) uses distance from that rest.

struct LCDLensReport: Equatable {
    let id: AnyHashable?
    let rect: CGRect
}

/// The selected row's frame, in the list content's own coordinates.
struct LCDLensRectKey: PreferenceKey {
    static var defaultValue: LCDLensReport? { nil }
    static func reduce(value: inout LCDLensReport?, nextValue: () -> LCDLensReport?) {
        value = value ?? nextValue()
    }
}

/// What the engine tells the lens host inside its scroll view.
struct LCDFollowState: Equatable {
    /// The engine has seen the scroll view's geometry.
    var ready = false
    /// The bar is placed on screen at `barY`. False while a finger or a system
    /// scroll moves the list; then it rides its row in the content.
    var pinned = false
    /// The bar's centre on screen, measured down from the title strip.
    var barY: CGFloat = 0
    /// The selected row's frame in the content; nil when nothing here is selected.
    var row: CGRect?
    /// The animated focus in content coordinates, also used during handoff.
    var focusY: CGFloat = 0
    /// Actual scroll offset, shared with ink so a delayed scroll frame cannot
    /// whiten the destination before it reaches the bar.
    var scrolled: CGFloat = 0
}

private struct LCDFollowStateKey: EnvironmentKey {
    static var defaultValue: LCDFollowState? { nil }
}

extension EnvironmentValues {
    /// Set by `lcdWheelFollow` on its scroll view; nil everywhere else.
    var lcdFollowState: LCDFollowState? {
        get { self[LCDFollowStateKey.self] }
        set { self[LCDFollowStateKey.self] = newValue }
    }
}

/// Puts the bar's centre at `screenY` on screen (pinned), or at `contentY` in the
/// content (while the content is being dragged).
private struct LCDBarPlacement: ViewModifier, Animatable {
    var screenY: CGFloat
    let contentY: CGFloat
    let pinned: Bool

    var animatableData: CGFloat {
        get { screenY }
        set { screenY = newValue }
    }

    func body(content: Content) -> some View {
        let screenY = screenY
        let contentY = contentY
        let pinned = pinned
        return content.visualEffect { effect, proxy in
            // Where content y 0 (the bar's laid-out centre) is on screen in this
            // very frame, measured down from the title strip.
            let laidOut = proxy.frame(in: .scrollView(axis: .vertical)).midY
            return effect.offset(y: pinned ? screenY - laidOut : contentY)
        }
    }
}

/// Hands every frame of `value`'s animation to `apply`.
private struct LCDScrollDriver: View, Animatable {
    var value: CGFloat
    let apply: (CGFloat) -> Void

    var animatableData: CGFloat {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Color.clear
            .onChange(of: value) { _, new in apply(new) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct LCDFollowGeometry: Equatable {
    var offset: CGFloat = 0
    var top: CGFloat = 0
    /// The list below the title strip.
    var container: CGFloat = 0
    var content: CGFloat = 0

    /// How far the list is scrolled from its resting top.
    var scrolled: CGFloat { offset + top }
    var maxScrolled: CGFloat { max(0, content - container) }
}

/// Bookkeeping that must not redraw anything when it changes.
@MainActor
private final class LCDFollowModel {
    var geometry = LCDFollowGeometry()
    var proxy: ScrollViewProxy?
    /// The selected row's frame as last reported; nil while it is not built.
    var row: CGRect?
    var rowID: AnyHashable?
    /// The selection as of the last body pass, and the one the list was last
    /// moved for. They differ while a step is still owed.
    var currentID: AnyHashable?
    var steppedID: AnyHashable?
    /// The frame the list was last moved for.
    var steppedRow: CGRect?
    var pendingToken = 0
    var fetching = false
    /// A finger or a system scroll is moving the list.
    var external = false
    var fingerDown = false
    /// A coast has been asked to stop for a wheel step.
    var haltAsked = false
    /// The focus target and the scroll requested by the last animation frame.
    var target: CGFloat = 0
    var scrollTarget: CGFloat = 0
    var settled = true
    /// The actual presented focus, distinct from the @State animation target.
    var spring: CGFloat = 0
    var lastStep: TimeInterval = 0
    var animation: Animation?
    /// False after a finger scroll: a late driver sample must not recenter it.
    var driving = false
    /// A jump by identity was asked for and its row has not reported yet.
    var landing = false
    /// For a short while after opening, moves are jumps, not glides.
    var jumpPending = false
    var jumpToken = 0
}

/// One list's follow engine. Put on the `ScrollView` (`lcdWheelFollow`).
@available(iOS 18.0, *)
@MainActor
private struct LCDWheelFollowEngine: ViewModifier {
    let followID: AnyHashable?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var position = ScrollPosition(edge: .top)
    @State private var follow = LCDFollowState()
    /// Selected row centre in content coordinates; the only animated position.
    @State private var drive: CGFloat = 0
    @State private var model = LCDFollowModel()

    func body(content: Content) -> some View {
        // Not state: nothing is redrawn by it. It lets a callback that runs later
        // in this same update see the selection this pass was built for.
        let _ = (model.currentID = followID)
        ScrollViewReader { proxy in
            // Kept from the first pass on: a list that opens on a row far down
            // needs it before `onAppear` has run.
            let _ = (model.proxy = proxy)
            content
                .environment(\.lcdFollowState, follow)
                .scrollPosition($position)
                // Rows are built a little beyond both edges of the list: the scroll
                // view is that much taller than what is shown (the LCD clips it),
                // and its content keeps the same margins, so nothing visible moves.
                // On a fast spin the selection runs ahead of the scroll by a few
                // rows; its row has to exist for the list to glide to it.
                .contentMargins(.vertical, LCDWheelFollow.overscan, for: .scrollContent)
                .padding(.vertical, -LCDWheelFollow.overscan)
                .onScrollGeometryChange(for: LCDFollowGeometry.self) { geometry in
                    LCDFollowGeometry(offset: geometry.contentOffset.y,
                                      top: geometry.contentInsets.top,
                                      container: geometry.containerSize.height,
                                      content: geometry.contentSize.height)
                } action: { _, new in
                    geometryChanged(new)
                }
                .onScrollPhaseChange { _, phase in
                    phaseChanged(phase)
                }
                .onPreferenceChange(LCDLensRectKey.self) { report in
                    // The iOS 18 SDK types this closure as @Sendable; it is still
                    // called on the main thread.
                    MainActor.assumeIsolated { rowChanged(report) }
                }
                .onChange(of: followID) { _, _ in
                    reconcile()
                }
                .background { LCDScrollDriver(value: drive, apply: apply) }
        }
    }

    // MARK: Events

    private func geometryChanged(_ new: LCDFollowGeometry) {
        model.geometry = new
        guard new.container > 0 else { return }
        guard follow.ready else { start(); return }
        var presented = follow
        presented.scrolled = new.scrolled
        setFollow(presented, animation: nil)
        guard !model.external, !model.landing else { return }
        if model.jumpPending, model.rowID == model.currentID, let row = model.row {
            move(to: row, animation: nil)
        } else if model.driving {
            // Geometry can trail a scroll request by a layout pass. Reassert the
            // current sample; never reinterpret that temporary lag as an origin
            // change or cancel a spring that has just reached its destination.
            apply(model.spring)
        } else {
            adopt()
        }
    }

    private func phaseChanged(_ phase: ScrollPhase) {
        model.fingerDown = phase == .tracking || phase == .interacting
        if phase != .idle {
            guard !model.external else { return }
            model.external = true
            model.landing = false
            // Stop driving; the bar rides its row.
            setDrive(model.spring, animation: nil, scroll: false)
            var new = follow
            new.pinned = false
            new.focusY = new.row?.midY ?? model.spring
            setFollow(new, animation: nil)
        } else if model.external {
            model.external = false
            model.haltAsked = false
            adopt()
            // A wheel step taken while the list was moving is made now.
            reconcile()
        }
    }

    private func rowChanged(_ report: LCDLensReport?) {
        // Geometry and identity travel together. A late preference from an older
        // selection must never mark the current selection as already followed.
        guard let report, report.id == model.currentID else { return }
        let rect = report.rect
        model.row = rect
        model.rowID = report.id
        guard follow.ready else { start(); return }
        guard model.currentID == model.steppedID else { reconcile(); return }
        if model.landing {
            model.landing = false
            model.steppedRow = rect
            adopt()
        } else if model.external {
            var new = follow
            new.row = rect
            new.focusY = rect.midY
            setFollow(new, animation: nil)
        } else if let previous = model.steppedRow,
                  abs(previous.midY - rect.midY) > 0.5 ||
                  abs(previous.width - rect.width) > 0.5 ||
                  abs(previous.height - rect.height) > 0.5 {
            // Anchor resolution has subpixel noise. A real lazy-layout refinement
            // retargets the current spring rather than teleporting the focus.
            if model.driving {
                move(to: rect, animation: reduceMotion || model.jumpPending ? nil :
                     (model.animation ?? LCDFollowPace.lens))
            } else {
                model.steppedRow = rect
                adopt()
            }
        }
    }

    /// Moves the list for a selection it has not been moved for yet.
    ///
    /// Selection and geometry may arrive in either order. Both call here, but a
    /// move is committed only when the reported row carries the current identity.
    private func reconcile() {
        guard follow.ready, model.currentID != model.steppedID else { return }
        guard let id = model.currentID else {
            // Nothing in this list is selected (the Search input, say).
            hideBar()
            // Search input is outside the list. Use the same driver to return to
            // its top, so a new wheel step can interrupt this move immediately.
            guard !model.external else { return }
            model.steppedID = nil
            model.steppedRow = nil
            model.target = model.geometry.container / 2
            setDrive(model.target, animation: reduceMotion ? nil : LCDFollowPace.resting)
            return
        }
        if model.external {
            // A finger holds the list, or it is still coasting from one: a jump
            // made now is overridden by the coast (measured), so the step is owed
            // until the list is idle. Meanwhile the bar goes to its row with the
            // content, and a coast is asked to stop where it is.
            if model.rowID == id, let row = model.row {
                var new = follow
                new.row = row
                new.focusY = row.midY
                setFollow(new, animation: nil)
            }
            if !model.fingerDown, !model.haltAsked {
                model.haltAsked = true
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { position.scrollTo(y: model.geometry.scrolled) }
            }
            return
        }
        guard model.rowID == id, let row = model.row else {
            // Fetch on a fixed deadline, using the latest selection. Debouncing
            // every step would postpone an offscreen fetch for an entire spin.
            guard !model.fetching else { return }
            model.fetching = true
            model.pendingToken &+= 1
            let token = model.pendingToken
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                guard model.pendingToken == token else { return }
                model.fetching = false
                guard let latest = model.currentID, model.steppedID != latest,
                      follow.ready, !model.external else { return }
                model.steppedID = latest
                jump()
            }
            return
        }
        model.pendingToken &+= 1
        model.fetching = false
        model.steppedID = id
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - model.lastStep
        model.lastStep = now
        // Retarget the same spring, preserving its velocity. At speed it settles
        // just after the next step, so movement stays continuous without trailing
        // several rows. Blending stiffness avoids a jerk on acceleration/braking.
        // A short menu has no scrolling to catch up with. Its lens keeps the
        // longer glide even through a burst of wheel steps.
        let response = model.geometry.maxScrolled < 0.5 ? 0.32 :
            min(0.32, max(0.028, gap * 1.4))
        let animation = Animation.spring(response: response, dampingFraction: 1,
                                         blendDuration: 0.06)
        let far = abs(row.midY - model.spring) > max(model.geometry.container, 1) * 1.5
        move(to: row, animation: reduceMotion || model.jumpPending || far ? nil : animation)
    }

    // MARK: Moves

    private func start() {
        let geometry = model.geometry
        guard geometry.container > 0, !follow.ready else { return }
        // The first row is placed, never glided in from the top.
        armJump()
        model.scrollTarget = geometry.scrolled
        model.target = model.row?.midY ?? 0
        model.settled = true
        model.spring = model.target
        drive = model.target
        var new = LCDFollowState()
        new.ready = true
        new.pinned = true
        setFollow(new, animation: nil)
        model.steppedID = model.currentID
        if model.rowID == model.currentID, let row = model.row {
            move(to: row, animation: nil)
        } else if model.currentID != nil {
            // Opening a list on a row far down (not built yet).
            jump()
        }
    }

    /// Retarget the focus. Scroll and bar placement are derived together in apply.
    private func move(to row: CGRect, animation: Animation?) {
        model.external = false
        model.landing = false
        model.steppedRow = row
        model.target = row.midY
        model.animation = animation
        let appears = follow.row == nil || !follow.pinned
        var new = follow
        new.row = row
        new.pinned = true
        setFollow(new, animation: nil)
        setDrive(row.midY, animation: appears ? nil : animation)
    }

    /// The selected row is not built: let the scroll view find it by identity.
    /// When it reports its frame, `rowChanged` takes the position over.
    private func jump() {
        guard let id = model.currentID, let proxy = model.proxy else { return }
        model.external = false
        model.landing = true
        model.steppedRow = nil
        setDrive(model.spring, animation: nil, scroll: false)
        // `scrollTo` matches the identity by its own type: an `AnyHashable` box
        // around the row's `Int` or `String` finds nothing (measured), so the box
        // is opened first.
        func reach<ID: Hashable>(_ id: ID) {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(id, anchor: .center) }
        }
        if let base = id.base as? any Hashable { reach(base) } else { reach(id) }
    }

    /// Takes the list as it is: the bar is pinned where its row is on screen now.
    private func adopt() {
        let real = model.geometry.scrolled
        let row = model.rowID == model.currentID ? model.row : follow.row
        let focus = row?.midY ?? (real + model.geometry.container / 2)
        model.target = focus
        model.scrollTarget = real
        setDrive(focus, animation: nil, scroll: false)
        var new = follow
        new.pinned = true
        new.row = row
        new.focusY = focus
        new.scrolled = real
        new.barY = focus - real
        setFollow(new, animation: nil)
    }

    private func hideBar() {
        model.pendingToken &+= 1
        model.fetching = false
        guard follow.row != nil else { return }
        var new = follow
        new.row = nil
        setFollow(new, animation: nil)
    }

    /// Only the lens host reads the presented focus; no implicit animation is added.
    private func setFollow(_ new: LCDFollowState, animation: Animation?) {
        guard new != follow else { return }
        withTransaction(Transaction(animation: animation)) { follow = new }
    }

    private func setDrive(_ value: CGFloat, animation: Animation?, scroll: Bool = true) {
        // drive is the destination, not where the presentation currently is.
        model.settled = abs(model.spring - value) < 0.01
        model.driving = scroll
        var transaction = Transaction(animation: animation)
        transaction.disablesAnimations = animation == nil
        withTransaction(transaction) { drive = value }
        if animation == nil || model.settled {
            model.spring = value
            model.settled = true
            if scroll { apply(value) }
        }
    }

    /// One animation sample drives both scroll and bar, without clipping the spring.
    private func apply(_ focus: CGFloat) {
        guard follow.ready, model.driving, !model.external, !model.landing else { return }
        model.spring = focus
        model.settled = abs(focus - model.target) < 0.01
        let scrolled = target(for: focus)
        model.scrollTarget = scrolled
        var new = follow
        new.focusY = focus
        new.scrolled = model.geometry.scrolled
        new.barY = focus - scrolled
        setFollow(new, animation: nil)
        guard abs(scrolled - model.geometry.scrolled) > 0.01 else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.scrollTo(y: scrolled) }
    }

    /// The distance scrolled that puts the focus in the middle of the list, clamped
    /// to the ends, with the resulting offset on the pixel grid.
    private func target(for focus: CGFloat) -> CGFloat {
        let geometry = model.geometry
        let desired = focus - geometry.container / 2
        let clamped = min(max(desired, 0), geometry.maxScrolled)
        let scale = max(displayScale, 1)
        return ((clamped - geometry.top) * scale).rounded() / scale + geometry.top
    }

    private func armJump() {
        model.jumpPending = true
        model.jumpToken &+= 1
        let token = model.jumpToken
        let model = model
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if model.jumpToken == token { model.jumpPending = false }
        }
    }
}

/// Whether lists are followed by `lcdWheelFollow` (iOS 18+). Before that they use
/// `ScrollViewProxy.lcdFollow` from their own `onChange`, as in 3.2.21.
enum LCDWheelFollow {
    /// How far past each edge of the list rows are kept built: four song rows.
    static let overscan: CGFloat = 240

    static var isActive: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }
}

extension View {
    /// 3.2.22, rebuilt in 3.2.23: put on a list's `ScrollView`. `id` is the selected row's identity
    /// (nil when nothing in this list is selected), used only to reach a row the
    /// lazy stack has not built yet. Does nothing before iOS 18.
    @ViewBuilder
    func lcdWheelFollow(_ id: AnyHashable?) -> some View {
        if #available(iOS 18.0, *) {
            modifier(LCDWheelFollowEngine(followID: id))
        } else {
            self
        }
    }
}

/// The lens behind one row. Inside a hosted list the row only publishes its frame
/// (see `LCDLensHost`); anywhere else — the Search input row, say — it draws its
/// own lens. The ink changes on the same spring the lens moves on.
@MainActor
private struct LCDSelectionBackground: ViewModifier {
    let selected: Bool
    let id: AnyHashable?
    @Environment(\.lcdLensHosted) private var hosted
    @Environment(\.lcdFollowState) private var follow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Group {
            if hosted {
                content
                    .anchorPreference(key: LCDLensAnchorKey.self, value: .bounds) { selected ? LCDLensAnchor(id: id, bounds: $0) : nil }
            } else {
                content
                    .background {
                        if selected { LCDSelectionBar() }
                    }
            }
        }
        .transaction(value: selected) { transaction in
            transaction.animation = follow != nil || reduceMotion || LCDInkPace.isSpinning() ? nil : LCDFollowPace.glide
        }
    }
}

/// Each label measures its stable layout bounds in the list content. The colour
/// follows overlap with the presented bar, independent of logical selection.
private enum LCDInkSpace {
    static let content = "LCDInkContent"
}

@MainActor
private struct LCDSelectionInk: ViewModifier {
    let selected: Bool
    let secondary: Bool
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.lcdFollowState) private var follow
    @State private var bounds: CGRect?

    func body(content: Content) -> some View {
        content
            .foregroundStyle(ink)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(LCDInkSpace.content))
            } action: { bounds = $0 }
    }

    private var ink: Color {
        let normal = secondary ? appearance.theme.lcdSecondaryText : appearance.theme.lcdText
        let highlighted = secondary ? appearance.theme.selectionSecondaryInk : appearance.theme.selectionInk
        guard let follow else { return selected ? highlighted : normal }
        guard follow.ready, let row = follow.row, let bounds, bounds.height > 0 else { return normal }
        let centre = follow.pinned ? follow.barY + follow.scrolled : follow.focusY
        let halfHeight = max(0, row.height / 2 - Metrics.selectionVerticalInset)
        let overlap = max(0, min(bounds.maxY, centre + halfHeight) - max(bounds.minY, centre - halfHeight))
        let coverage = min(1, overlap / bounds.height)
        if #available(iOS 18.0, *) {
            return normal.mix(with: highlighted, by: coverage)
        }
        return selected ? highlighted : normal
    }
}

extension View {
    func lcdSelectionInk(_ selected: Bool, secondary: Bool = false) -> some View {
        modifier(LCDSelectionInk(selected: selected, secondary: secondary))
    }
}

/// Whether selections are changing too fast for the ink's 0.32 s fade.
///
/// On a fast spin a row is selected for a frame or two; fading its ink left the
/// text under the bar dark the whole time. Then the ink simply switches. The two
/// rows of one step (the one losing the bar and the one gaining it) ask within
/// the same update and get the same answer.
@MainActor
private enum LCDInkPace {
    private static var last: TimeInterval = 0
    private static var spinning = false

    static func isSpinning() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - last
        guard gap > 0.004 else { return spinning }
        last = now
        spinning = gap < 0.08
        return spinning
    }
}

extension View {
    /// The wheel's selection signal for one row: the lens behind it.
    func lcdSelectionBackground(_ selected: Bool, id: AnyHashable? = nil) -> some View {
        modifier(LCDSelectionBackground(selected: selected, id: id))
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
