import SwiftUI
import UIKit

/// `@State` would evaluate `PlayerViewModel()` on every `ContentView` init (each
/// scene phase change re-runs the app body), registering remote commands and
/// restoring playback for an instance it then throws away. `@StateObject` builds
/// its value once; this holder publishes nothing, so it never repaints anything.
@MainActor
private final class PlayerViewModelHolder: ObservableObject {
    let viewModel = PlayerViewModel()
}

@MainActor
struct ContentView: View {
    @StateObject private var holder = PlayerViewModelHolder()
    private var viewModel: PlayerViewModel { holder.viewModel }
    @StateObject private var appearance = AppearanceSettings()
    /// The boot lock screen owns its own dismissal: it stays up until the unlock
    /// animation ends, not merely until the library is ready.
    @State private var showsBoot = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private var displayCornerRadius: CGFloat {
        // Private API is intentional for this personal, non-App-Store app.
        guard let radius = UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat,
              radius.isFinite, radius > 0 else { return 55 }
        return radius
    }

    private var panelCornerRadius: CGFloat {
        // Concentric with the device's own corner: the panel sits `panelInset` in
        // from the edge, so its radius is the device radius less that inset. The
        // clamp keeps it sane on devices that report no radius or a huge one.
        min(50, max(24, displayCornerRadius - Metrics.panelInset))
    }

    /// The simulator cannot rotate its window from the command line, so a fixture
    /// lays the landscape composition out sideways inside the portrait canvas; the
    /// screenshot is rotated back for review. DEBUG only.
    /// The outermost hairline of the LCD's black bezel (`LCDBezel`). It is the same
    /// all the way round. The silver body gets a thin steel frame instead; on the
    /// other bodies it is just enough contrast to keep the panel's silhouette.
    private var lcdBezelRim: AnyShapeStyle {
        if appearance.effectiveThemePreset == .silver {
            return AnyShapeStyle(LinearGradient(
                colors: [Color(white: 0.84), Color(white: 0.56)],
                startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(appearance.theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.30))
    }

    private var forcesLandscapeForScreenshots: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["REPOD_FORCE_LANDSCAPE"] == "1"
        #else
        false
        #endif
    }

    @ViewBuilder
    private func landscapeCanvas(_ geometry: GeometryProxy) -> some View {
        ZStack {
            Color.black
            CoverFlowView(viewModel: viewModel, safeInsets: EdgeInsets())
        }
        .frame(width: geometry.size.height, height: geometry.size.width)
        .rotationEffect(.degrees(90))
    }

    var body: some View {
        // The alert reads its binding outside this body; reading the state here
        // is what makes a new message repaint it.
        let showsAlert = viewModel.alertMessage != nil && viewModel.isLibraryReady
        // Capture the notch inset before expanding the inner canvas to the edges.
        GeometryReader { safeGeometry in
            GeometryReader { geometry in
                let isLandscape = geometry.size.width > geometry.size.height
                let availableHeight = geometry.size.height
                let screenHeight = availableHeight * 0.50
                let remainingHeight = availableHeight - screenHeight
                let wheelDiameter = min(geometry.size.width * 0.82, remainingHeight * 0.92, 340)
                let isNowPlaying = viewModel.currentScreen == .nowPlaying
                // Optional: Now Playing takes the whole phone and the wheel turns to glass.
                let immersive = isNowPlaying && appearance.immersiveNowPlaying && !isLandscape
                // The black glass the LCD is set into.
                let bezel: CGFloat = 4

                ZStack {
                    if forcesLandscapeForScreenshots {
                        landscapeCanvas(geometry)
                    } else if isLandscape {
                        // Keep rotation gaps black independently of Cover Flow's geometry.
                        Color.black.ignoresSafeArea()
                        CoverFlowView(viewModel: viewModel, safeInsets: safeGeometry.safeAreaInsets)
                    } else {
                        LinearGradient(colors: [appearance.theme.bodyBackground, appearance.theme.bodyBackground.opacity(0.85)],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea()

                        // Key light at the top, shade at the bottom: the body gets a
                        // little volume without leaving its one lacquer colour.
                        BodyLighting(palette: appearance.theme)
                            .ignoresSafeArea()

                        // The polycarbonate bodies caught a diagonal sheen across the
                        // top-left. Kept off the midnight body, where it would only
                        // grey the black.
                        if !appearance.theme.isDark {
                            LinearGradient(stops: [
                                .init(color: Color.white.opacity(0.22), location: 0),
                                .init(color: Color.white.opacity(0.08), location: 0.34),
                                .init(color: Color.white.opacity(0), location: 0.58)
                            ], startPoint: .topLeading, endPoint: .bottomTrailing)
                                .ignoresSafeArea()
                                .allowsHitTesting(false)
                        }

                        // The screen's own light: while a song is up, its cover's colour
                        // spills from the LCD's lower edge onto the body.
                        ZStack {
                            if isNowPlaying, !immersive, let url = viewModel.currentTrack?.artworkURL {
                                CachedArtwork(url: url) { image in
                                    if let image {
                                        image.resizable().scaledToFill()
                                            .frame(width: geometry.size.width * 0.82, height: screenHeight * 0.5)
                                            .clipped()
                                            .blur(radius: 44)
                                            .saturation(1.7)
                                            .opacity(appearance.theme.isDark ? 0.42 : 0.52)
                                    }
                                }
                                .position(x: geometry.size.width / 2, y: screenHeight * 0.94)
                                .transition(.opacity)
                            }
                        }
                        .animation(.easeInOut(duration: 0.5), value: isNowPlaying && !immersive)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                        if immersive {
                            ImmersiveNowPlayingView(viewModel: viewModel,
                                                    safeTop: safeGeometry.safeAreaInsets.top,
                                                    wheelSpace: remainingHeight)
                                .ignoresSafeArea()
                                .transition(.opacity)
                        }

                        VStack(spacing: 0) {
                            let screenRadius = panelCornerRadius - bezel
                            ScreenView(viewModel: viewModel, safeTop: max(0, safeGeometry.safeAreaInsets.top - 12 - bezel))
                                .frame(width: (geometry.size.width - Metrics.panelInset * 2 - bezel * 2).rounded(),
                                       height: (screenHeight - Metrics.panelInset - bezel * 2).rounded())
                                .clipShape(RoundedRectangle(cornerRadius: screenRadius, style: .continuous))
                                // 3.1.5: the bezel is a stroke of the screen's own outline,
                                // so it is exactly `bezel` wide on every side and round every
                                // corner, with one even hairline outside it.
                                .background {
                                    LCDBezel(screenRadius: screenRadius, width: bezel, rim: lcdBezelRim,
                                             rimWidth: appearance.effectiveThemePreset == .silver ? 1 : 0.75)
                                }
                                // The LCD's cover glass: a faint gloss and an even inner edge.
                                // Now Playing is always a dark screen, whatever the body is.
                                .overlay {
                                    LCDCoverGlass(cornerRadius: screenRadius,
                                                  isDarkScreen: appearance.theme.isDark
                                                      || viewModel.currentScreen == .nowPlaying)
                                }
                                .padding(bezel)
                                // A soft ambient shadow only. The old 1pt contact shadow sat
                                // 1pt low, which thickened the bottom edge of the bezel.
                                .shadow(color: .black.opacity(appearance.theme.isDark ? 0.34 : 0.12),
                                        radius: 12, y: 4)
                                .padding(.top, Metrics.panelInset)
                                .frame(width: geometry.size.width, height: screenHeight)
                                // Immersive: the LCD steps aside but keeps its place, so
                                // the wheel does not move.
                                .opacity(immersive ? 0 : 1)
                                .allowsHitTesting(!immersive)
                                .accessibilityHidden(immersive)

                            ClickWheelView(
                                diameter: wheelDiameter,
                                isPlaying: viewModel.isPlaying,
                                canToggleLike: viewModel.canToggleTrackLike,
                                onStep: { direction in
                                    let moved = viewModel.handleWheelRotation(by: direction)
                                    // 3.1.5: turning the wheel means browsing, not typing.
                                    // The keyboard starts down on the first step instead
                                    // of after the screen has redrawn.
                                    if moved { LCDKeyboard.dismiss() }
                                    return moved
                                },
                                onRotationEnded: { viewModel.volumeController.endWheelAdjustment() },
                                onMenu: {
                                    LCDKeyboard.dismiss()
                                    viewModel.goBack()
                                },
                                onMenuLongPress: {
                                    LCDKeyboard.dismiss()
                                    viewModel.goHome()
                                },
                                onPrevious: { viewModel.previous() },
                                onNext: { viewModel.next() },
                                onPlayPause: { viewModel.togglePlayPause() },
                                onSeekForward: { viewModel.seekBy(seconds: $0) },
                                onSeekBackward: { viewModel.seekBy(seconds: -$0) },
                                onConfirm: { viewModel.confirmSelection() },
                                onConfirmLongPress: { viewModel.toggleSelectedTrackLike() },
                                glass: immersive
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: remainingHeight)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .animation(.easeInOut(duration: 0.35), value: immersive)
                .statusBarHidden(isLandscape || forcesLandscapeForScreenshots
                                      || viewModel.currentScreen == .nowPlaying || showsBoot)
            }
            .ignoresSafeArea(.container)
        }
        .ignoresSafeArea(.keyboard)
        .background {
            // Only Now Playing replaces the system HUD with the app's volume bar.
            if viewModel.currentScreen == .nowPlaying {
                SystemVolumeView(controller: viewModel.volumeController)
                    .frame(width: 120, height: 24)
                    .offset(x: -1000)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .environmentObject(appearance)
        // 3.1.9: Chinese characters shared by Simplified and Traditional (Han
        // unification) are drawn in the forms of the app's own language, not the
        // phone's: 繁體中文 in the app gets PingFang TC even on a Simplified phone,
        // and the reverse. English leaves the system's choice alone. Reading
        // `AppLanguage.current` here repaints this when the language changes.
        .typesettingLanguage(AppLanguage.current.typesettingLanguage,
                             isEnabled: AppLanguage.current != .english)
        .tint(appearance.accent)
        .preferredColorScheme(appearance.followsSystem ? nil : (appearance.theme.isDark ? .dark : .light))
        .overlay {
            // The boot lock screen covers the player until its own unlock
            // animation finishes: the library being ready only triggers the
            // unlock, it does not dismiss the screen. The player underneath is
            // already interactive.
            ZStack {
                if showsBoot {
                    BootView(isReady: viewModel.isLibraryReady) {
                        showsBoot = false
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.35), value: showsBoot)
        }
        .task { await viewModel.loadLibraryIndex() }
        .onAppear { appearance.updateSystemColorScheme(colorScheme) }
        .onChange(of: colorScheme) { _, scheme in
            appearance.updateSystemColorScheme(scheme)
        }
        .onOpenURL { viewModel.handleURL($0) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.handleSceneActive() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            viewModel.handleApplicationWillTerminate()
        }
        .alert("提示", isPresented: Binding(
            get: { showsAlert },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { viewModel.alertMessage = nil }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }
}
