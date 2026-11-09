import SwiftUI

@main
@MainActor
struct iPodPlayerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Optional build-time default (Config/*.xcconfig -> Info.plist SpotifyClientID).
        // Registered defaults never override a value the user entered in Settings.
        let clientID = (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !clientID.isEmpty, !clientID.hasPrefix("$(") {
            UserDefaults.standard.register(defaults: ["spotifyClientID": clientID])
        }
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
