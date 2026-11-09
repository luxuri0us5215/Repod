import UIKit

/// The software keyboard runs out of process. The first presentation in a
/// session has to start that process and measure its layouts, which blocks the
/// main thread long enough to read as a hitch. That hitch used to land on the
/// first tap of the search field, and — while Search focused itself on entry
/// before 1.82 — on the Search screen's own transition.
///
/// Becoming first responder and resigning in the same turn starts the keyboard
/// while the boot screen still covers the UI. The throwaway field never
/// renders — the show and the hide cancel out before a frame is committed —
/// so nothing flashes and the boot screen is already the thing on screen.
@MainActor
enum KeyboardWarmup {
    private static var hasWarmed = false
    private static var isScheduled = false
    private static let delay: TimeInterval = 0.12

    /// Safe to call more than once; only the first successful attempt does work.
    /// Search raises the keyboard as it opens, so a warmup that silently failed
    /// would put the stall back on that transition.
    static func warmUpIfNeeded() {
        warmUp(attemptsLeft: 3)
    }

    private static func warmUp(attemptsLeft: Int) {
        guard !hasWarmed, !isScheduled else { return }
        isScheduled = true
        // The key window does not exist while the view model is being built, and
        // focusing in `init` would run before any UI could cover it. The short
        // delay lets the boot screen paint once before the main thread is handed
        // to the keyboard, so the freeze happens behind a drawn screen instead of
        // in front of a black one.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            isScheduled = false
            guard !hasWarmed else { return }
            // A field of the user's owns the focus already: the keyboard is either
            // up or about to be, and stealing it would dismiss what they are
            // typing into. Done either way.
            guard !hasActiveTextInput() else {
                hasWarmed = true
                return
            }
            guard let window = keyWindow() else {
                // The window server was not ready yet or the scene was still
                // inactive. A couple of retries keep the first tap cheap without
                // running this after the boot screen can have lifted.
                if attemptsLeft > 0 { warmUp(attemptsLeft: attemptsLeft - 1) }
                return
            }
            hasWarmed = true

            // Off-screen rather than hidden: a hidden or interaction-disabled
            // field cannot become first responder, and without that the keyboard
            // process never starts.
            let field = UITextField(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.textColor = .clear
            field.tintColor = .clear
            field.accessibilityElementsHidden = true
            field.isAccessibilityElement = false
            window.addSubview(field)
            field.becomeFirstResponder()
            field.resignFirstResponder()
            field.removeFromSuperview()
        }
    }

    private static func hasActiveTextInput() -> Bool {
        for window in UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows) where hasTextInput(in: window) {
            return true
        }
        return false
    }

    /// A nested function does not inherit the enclosing type's main-actor
    /// isolation, so walking the view tree inline made `isFirstResponder` and
    /// `subviews` reads look nonisolated to the compiler. As a method on this
    /// `@MainActor` enum the walk is isolated, which is also correct: the whole
    /// check runs from the main queue and only reads UIKit state.
    private static func hasTextInput(in view: UIView) -> Bool {
        if view.isFirstResponder, view is UITextField || view is UITextView { return true }
        for subview in view.subviews where hasTextInput(in: subview) { return true }
        return false
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // A launch into the background has no active scene yet, but its window is
        // still the one the keyboard would attach to.
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let scene else { return nil }
        return scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first(where: { !$0.isHidden })
    }
}
