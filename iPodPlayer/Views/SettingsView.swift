import SwiftUI
import UIKit

@MainActor
struct SettingsView: View {
    let viewModel: PlayerViewModel
    let screen: AppScreen
    @EnvironmentObject private var appearance: AppearanceSettings
    @AppStorage("neteaseBaseURL") private var neteaseBaseURL = ""
    @AppStorage("spotifyClientID") private var spotifyClientID = ""
    @AppStorage("spotifyRedirectURI") private var spotifyRedirectURI = "ipodplayer://spotify-login-callback"
    @FocusState private var focusedField: SettingsField?
    @State private var showsColorPicker = false

    private enum SettingsField: Hashable {
        case neteaseAddress, spotifyClientID, spotifyRedirectURI
    }

    var body: some View {
        // Both rebuild the menu; read them once per pass rather than three times per row.
        let entries = viewModel.menuEntries
        let selectedIndex = viewModel.selectedIndex
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if entry.action == .setting(.logoutNetEase) {
                            neteaseQRCode
                        }
                        Button(role: destructiveRole(for: entry)) {
                            viewModel.selectMenuEntry(at: index)
                        } label: {
                            rowLabel(entry, selected: index == selectedIndex)
                        }
                        .buttonStyle(SettingsLCDRowStyle(selected: index == selectedIndex,
                                                         height: rowHeight(for: entry)))
                        .id(index)
                        .accessibilityAddTraits(index == selectedIndex ? [.isSelected] : [])

                        if entry.action == .setting(.neteaseAddress) {
                            status(viewModel.neteaseLoginStatus)
                        } else if entry.action == .setting(.spotifyRedirectURI) {
                            status(viewModel.spotifyStatus)
                        }
                    }
                }
                .foregroundStyle(appearance.theme.lcdText)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
            // The menu and track lists already fade at their edges; these pages
            // were the one list on the LCD that still cut a row off at the line.
            .lcdEdgeFade(appearance.theme.lcdBackground)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: selectedIndex) { _, index in
                proxy.scrollTo(index, anchor: .center)
            }
            .onAppear { proxy.scrollTo(selectedIndex, anchor: .center) }
        }
        .onReceive(viewModel.settingsActions, perform: activate)
        .onChange(of: focusedField) { _, field in
            guard let field else { return }
            let action: SettingsAction
            switch field {
            case .neteaseAddress: action = .neteaseAddress
            case .spotifyClientID: action = .spotifyClientID
            case .spotifyRedirectURI: action = .spotifyRedirectURI
            }
            selectField(action)
        }
        .sheet(isPresented: $showsColorPicker) {
            SettingsColorPicker(selection: $appearance.customAccent)
        }
        .onDisappear { viewModel.settingsChanged() }
    }

    private func destructiveRole(for entry: MenuEntry) -> ButtonRole? {
        entry.action == .setting(.logoutNetEase) || entry.action == .setting(.logoutSpotify) ? .destructive : nil
    }

    /// A row that carries an editable field is a two-line row (title over field),
    /// so it takes the same 60pt as any menu row with a subtitle. Every other
    /// settings row is one line and keeps 50pt.
    private func rowHeight(for entry: MenuEntry) -> CGFloat {
        guard case .setting(let action) = entry.action else { return Metrics.singleLineRowHeight }
        switch action {
        case .neteaseAddress, .spotifyClientID, .spotifyRedirectURI: return Metrics.doubleLineRowHeight
        default: return Metrics.singleLineRowHeight
        }
    }

    private func selectField(_ action: SettingsAction) {
        if let index = viewModel.menuEntries.firstIndex(where: { $0.action == .setting(action) }),
           index != viewModel.selectedIndex {
            viewModel.selectMenuEntry(at: index)
        }
    }

    private func rowLabel(_ entry: MenuEntry, selected: Bool) -> some View {
        HStack(spacing: 6) {
            if case .setting(.theme(let preset)) = entry.action {
                Circle()
                    .fill(preset.palette.lcdBackground)
                    .frame(width: 14, height: 14)
                    // The classic swatch is nearly the same white as the LCD, so it
                    // needs a rim to be visible at all — and again on the blue
                    // selection bar it may sit on.
                    .overlay(Circle().strokeBorder(selected ? Color.black.opacity(0.30)
                                                            : appearance.theme.divider,
                                                   lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 1) {
                // MenuEntry already holds display text, localized at construction.
                Text(verbatim: entry.title)
                    .font(AppFont.title)
                field(for: entry, selected: selected)
            }
            Spacer(minLength: 3)
            if let switchValue = entry.switchValue {
                LCDSlideLock(isOn: switchValue)
            } else if let detail = entry.detail {
                Text(verbatim: detail)
                    .font(AppFont.detail)
                    .foregroundStyle(selected ? Color.black : appearance.theme.lcdSecondaryText)
            }
            if entry.marked {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
            } else if case .setting(.theme(let preset)) = entry.action {
                if appearance.selectedTheme == preset {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                }
            } else if entry.action == .setting(.customAccentColor) {
                Circle().fill(appearance.customAccent).frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(selected ? Color.black : appearance.theme.lcdSecondaryText, lineWidth: 1))
            } else if entry.showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(selected ? Color.black : appearance.theme.lcdSecondaryText)
            }
        }
    }

    @ViewBuilder
    private func field(for entry: MenuEntry, selected: Bool) -> some View {
        Group {
            switch entry.action {
            case .setting(.neteaseAddress):
                TextField("http://your-server:3000", text: $neteaseBaseURL,
                          prompt: Text("http://your-server:3000").foregroundStyle(selected ? Color.black : appearance.theme.lcdSecondaryText))
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .focused($focusedField, equals: .neteaseAddress)
                    .simultaneousGesture(TapGesture().onEnded { selectField(.neteaseAddress) })
                    .accessibilityLabel("网易云服务地址")
            case .setting(.spotifyClientID):
                TextField("客户端标识", text: $spotifyClientID,
                          prompt: Text("客户端标识").foregroundStyle(selected ? Color.black : appearance.theme.lcdSecondaryText))
                    .keyboardType(.asciiCapable)
                    .focused($focusedField, equals: .spotifyClientID)
                    .simultaneousGesture(TapGesture().onEnded { selectField(.spotifyClientID) })
                    .accessibilityLabel("Spotify 客户端标识")
            case .setting(.spotifyRedirectURI):
                TextField("回调地址", text: $spotifyRedirectURI,
                          prompt: Text("回调地址").foregroundStyle(selected ? Color.black : appearance.theme.lcdSecondaryText))
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .spotifyRedirectURI)
                    .simultaneousGesture(TapGesture().onEnded { selectField(.spotifyRedirectURI) })
                    .accessibilityLabel("Spotify 回调地址")
            default:
                EmptyView()
            }
        }
        .font(AppFont.detail)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit { viewModel.settingsChanged() }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(AppFont.detail)
            .foregroundStyle(appearance.theme.lcdSecondaryText)
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private var neteaseQRCode: some View {
        if let qrImage = viewModel.neteaseQRImage {
            Image(uiImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 164, height: 164)
                .padding(10)
                // A white code block needs a soft edge on a dark LCD, or it cuts the
                // screen like a hole.
                .background(Color.white, in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.14), lineWidth: 1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("网易云登录二维码，请用网易云音乐扫码")
        }
    }

    private func activate(_ action: SettingsAction) {
        guard viewModel.currentScreen == screen else { return }
        switch action {
        case .followSystem: appearance.followsSystem.toggle()
        case .theme(let preset): appearance.selectedTheme = preset
        case .customAccentEnabled: appearance.useCustomAccent.toggle()
        case .customAccentColor:
            focusedField = nil
            showsColorPicker = true
        case .neteaseAddress: focusedField = .neteaseAddress
        case .spotifyClientID: focusedField = .spotifyClientID
        case .spotifyRedirectURI: focusedField = .spotifyRedirectURI
        case .saveNetEase:
            viewModel.settingsChanged()
            viewModel.checkNetEaseLogin()
        case .generateNetEaseQR:
            viewModel.settingsChanged()
            viewModel.startNetEaseQRLogin()
        case .cancelNetEaseQR: viewModel.cancelNetEaseQRLogin()
        case .logoutNetEase: viewModel.logoutNetEase()
        case .loginSpotify:
            viewModel.settingsChanged()
            viewModel.loginSpotify()
        case .logoutSpotify: viewModel.logoutSpotify()
        }
    }
}

@MainActor
private struct SettingsLCDRowStyle: ButtonStyle {
    let selected: Bool
    let height: CGFloat
    @EnvironmentObject private var appearance: AppearanceSettings

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.title)
            .lineLimit(1)
            .foregroundStyle(selected ? Color.black : appearance.theme.lcdText)
            .padding(.horizontal, Metrics.horizontalInset)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lcdSelectionBackground(selected)
            .overlay {
                // Same pressed state as every other LCD row; the selection bar is
                // the wheel's signal and does not move for a touch.
                if configuration.isPressed {
                    LCDSelectionFootprint()
                        .fill(Color.black.opacity(appearance.theme.isDark ? 0.22 : 0.10))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
    }
}

/// Present the system colour editor directly from either a centre press or a row tap.
@MainActor
private struct SettingsColorPicker: UIViewControllerRepresentable {
    @Binding var selection: Color
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let controller = UIColorPickerViewController()
        controller.supportsAlpha = false
        controller.selectedColor = UIColor(selection)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIColorPickerViewController, context: Context) {
        context.coordinator.parent = self
        let color = UIColor(selection)
        if controller.selectedColor != color { controller.selectedColor = color }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: SettingsColorPicker
        init(parent: SettingsColorPicker) { self.parent = parent }

        func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
            parent.selection = Color(viewController.selectedColor)
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            parent.dismiss()
        }
    }
}
