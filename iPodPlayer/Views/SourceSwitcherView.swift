import SwiftUI

@MainActor
struct SourceSwitcherView: View {
    let viewModel: PlayerViewModel
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(AudioSource.allCases.enumerated()), id: \.element.id) { index, source in
                let highlighted = index == viewModel.selectedIndex
                Button {
                    // Touch mirrors the centre button: the active source opens its
                    // configuration, any other row becomes the active source.
                    if source == viewModel.selectedSource { viewModel.open(source.settingsScreen) }
                    else { viewModel.selectSource(source) }
                } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.displayName)
                                .font(AppFont.title)
                            // The second line is the account state, not the service
                            // name: choosing a source is the only place it matters.
                            Text(viewModel.isSignedIn(source) ? "已登录" : "未登录")
                                .font(AppFont.detail)
                                .foregroundStyle(highlighted ? Color.black : appearance.theme.lcdSecondaryText)
                        }
                        Spacer(minLength: 3)
                        if source == viewModel.selectedSource {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                // A checkmark is a hardware menu mark, not a theme call to
                                // action: the mint or sunset accent must not tint it.
                                .foregroundStyle(highlighted ? Color.black : appearance.theme.lcdText)
                        }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, Metrics.horizontalInset)
                    .frame(height: Metrics.doubleLineRowHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(highlighted ? Color.black : appearance.theme.lcdText)
                    .lcdSelectionBackground(highlighted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(LCDPressFeedbackStyle())
                .accessibilityElement(children: .combine)
                .accessibilityValue(source == viewModel.selectedSource ? "当前音源" : "")
                .accessibilityAddTraits(highlighted ? [.isSelected] : [])
            }
            if let hint = viewModel.sourceHint {
                Text(hint)
                    .font(AppFont.caption)
                    .foregroundStyle(appearance.theme.lcdSecondaryText)
                    .multilineTextAlignment(.center)
                    .padding(10)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
