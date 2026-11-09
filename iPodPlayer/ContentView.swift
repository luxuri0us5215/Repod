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

                ZStack {
                    if isLandscape {
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

                        VStack(spacing: 0) {
                            ScreenView(viewModel: viewModel, safeTop: max(0, safeGeometry.safeAreaInsets.top - 12))
                                .frame(width: geometry.size.width - Metrics.panelInset * 2,
                                       height: screenHeight - Metrics.panelInset)
                                .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
                                // The LCD's cover glass: a rim that catches light plus a faint
                                // gloss, and a hairline so the silhouette never vanishes into the
                                // body (white screen on a white body, black on black). Now Playing
                                // is always a dark screen, whatever the body theme is.
                                .overlay {
                                    LCDCoverGlass(cornerRadius: panelCornerRadius,
                                                  isDarkScreen: appearance.theme.isDark
                                                      || viewModel.currentScreen == .nowPlaying)
                                }
                                // Contact shadow plus a wide ambient one: the panel sits in the
                                // body instead of floating on a single blur.
                                .shadow(color: .black.opacity(appearance.theme.isDark ? 0.50 : 0.10),
                                        radius: 1, y: 1)
                                .shadow(color: .black.opacity(appearance.theme.isDark ? 0.42 : 0.15),
                                        radius: 14, y: 8)
                                .padding(.top, Metrics.panelInset)
                                .frame(width: geometry.size.width, height: screenHeight)

                            ClickWheelView(
                                diameter: wheelDiameter,
                                isPlaying: viewModel.isPlaying,
                                canToggleLike: viewModel.canToggleTrackLike,
                                onStep: { viewModel.handleWheelRotation(by: $0) },
                                onRotationEnded: { viewModel.volumeController.endWheelAdjustment() },
                                onMenu: { viewModel.goBack() },
                                onMenuLongPress: { viewModel.goHome() },
                                onPrevious: { viewModel.previous() },
                                onNext: { viewModel.next() },
                                onPlayPause: { viewModel.togglePlayPause() },
                                onSeekForward: { viewModel.seekBy(seconds: $0) },
                                onSeekBackward: { viewModel.seekBy(seconds: -$0) },
                                onConfirm: { viewModel.confirmSelection() },
                                onConfirmLongPress: { viewModel.toggleSelectedTrackLike() }
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: remainingHeight)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .statusBarHidden(isLandscape || viewModel.currentScreen == .nowPlaying || !viewModel.isLibraryReady)
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
        .tint(appearance.accent)
        .preferredColorScheme(appearance.followsSystem ? nil : (appearance.theme.isDark ? .dark : .light))
        .overlay {
            // Covers the player until the saved library index has been read and
            // pre-sorted; the player itself is already interactive underneath.
            ZStack {
                if !viewModel.isLibraryReady {
                    BootView()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.35), value: viewModel.isLibraryReady)
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
