import SwiftUI
import UIKit

@main
@MainActor
struct iPodPlayerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // Screenshot aid: lets a simulator launch pick a theme through the
        // environment instead of walking 设置 -> 外观 with taps simctl cannot do.
        if let theme = ProcessInfo.processInfo.environment["REPOD_THEME_OVERRIDE"] {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: "appearanceFollowSystem")
            defaults.set(theme, forKey: "appearanceTheme")
            defaults.set(theme, forKey: "appearanceEffectiveTheme")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // The wheel reaches into the system gesture region below it. Defer
                // that edge at the hosting-controller root so a swipe that starts
                // there belongs to the app first.
                .defersSystemGestures(on: .bottom)
                .onAppear { HapticEngine.shared.setActive(scenePhase == .active) }
                .task { SystemGestureGate.releaseWheelTouches() }
                .onChange(of: scenePhase) { _, phase in
                    HapticEngine.shared.setActive(phase == .active)
                    if phase == .active { SystemGestureGate.releaseWheelTouches() }
                }
        }
    }
}

/// 3.2.31: the play key sits where iOS keeps its system-gesture gate.
///
/// UIKit installs `_UISystemGestureGateGestureRecognizer`s on the window to judge
/// whether a touch is the start of a Home swipe. A touch that lands in the lower
/// band is withheld from the view hierarchy until that judgement settles — and a
/// thumb that lands and stays put never settles it, so the wheel only receives
/// the touch when the gate times out. Measured on iPhone 16 Pro: every play-key
/// press reached the wheel 752–754 ms after the touch, while MENU arrived in
/// 97 ms and the centre key in 47–63 ms. The pause is before SwiftUI sees
/// anything, which is why changing the press animation (3.2.26), gesture
/// priority (3.2.28) or `defersSystemGestures` (3.2.29) never moved it.
///
/// 3.2.30 tried turning the gate's `delaysTouchesBegan` off; the property was
/// already off when the finger landed and the 753 ms stayed. Removing the gate
/// recognizer from the window instead dropped the same presses to 1 ms. These
/// are recognizers UIKit owns on its own window, so the pass looks for them by
/// class name, removes them, and repeats for a few seconds after launch, when a
/// window becomes key and when the app comes back — a rebuilt window can attach
/// fresh ones. Nothing else is touched: `defersSystemGestures`, the 0.75 s hold,
/// the four keys' press and release animation and the cancel rules are unchanged.
@MainActor
enum SystemGestureGate {
    private static var keyWindowObserver: NSObjectProtocol?

    /// `_UISystemGestureGateGestureRecognizer` and
    /// `_UIHomeAffordanceGateGestureRecognizer` are the two UIKit puts on the
    /// window; both withhold touches in the lower band.
    private static func isGestureGate(_ recognizer: UIGestureRecognizer) -> Bool {
        String(describing: type(of: recognizer)).contains("Gate")
    }

    static func releaseWheelTouches() {
        if keyWindowObserver == nil {
            keyWindowObserver = NotificationCenter.default.addObserver(
                forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in releaseWheelTouches() }
            }
        }
        removeGates()
        Task { @MainActor in
            // The window finishes attaching its gates after the first frame.
            for delay in [500, 2_000] {
                try? await Task.sleep(for: .milliseconds(delay))
                removeGates()
            }
        }
    }

    private static func removeGates() {
        for window in UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows) {
            let gates = (window.gestureRecognizers ?? []).filter(isGestureGate)
            guard !gates.isEmpty else { continue }
            #if DEBUG
            let names = gates.map { String(describing: type(of: $0)) }.joined(separator: ",")
            NSLog("[Gate] removing %d recognizer(s): %@", gates.count, names)
            #endif
            for gate in gates {
                window.removeGestureRecognizer(gate)
            }
        }
    }
}
