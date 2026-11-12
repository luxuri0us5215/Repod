import SwiftUI

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
                .onAppear { HapticEngine.shared.setActive(scenePhase == .active) }
                .onChange(of: scenePhase) { _, phase in
                    HapticEngine.shared.setActive(phase == .active)
                }
        }
    }
}
