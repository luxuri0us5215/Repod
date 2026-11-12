import SwiftUI

@MainActor
struct SourceSwitcherView: View {
    let viewModel: PlayerViewModel
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
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
                                    .foregroundStyle(highlighted ? appearance.theme.selectionSecondaryInk : appearance.theme.lcdSecondaryText)
                            }
                            Spacer(minLength: 3)
                            if source == viewModel.selectedSource {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    // A checkmark is a hardware menu mark, not a theme call to
                                    // action: the mint or sunset accent must not tint it.
                                    .foregroundStyle(highlighted ? appearance.theme.selectionInk : appearance.theme.lcdText)
                            }
                        }
                        .lineLimit(1)
                        .padding(.horizontal, Metrics.horizontalInset)
                        .frame(height: Metrics.doubleLineRowHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(highlighted ? appearance.theme.selectionInk : appearance.theme.lcdText)
                        // 3.1.14: the lens is drawn once, by row index, under this stack
                        // (see below) instead of per row, so it can never be measured
                        // against a slide that is still in flight.
                        .lcdSelectionBackground(false)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LCDPressFeedbackStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(source == viewModel.selectedSource ? "当前音源" : "")
                    .accessibilityAddTraits(highlighted ? [.isSelected] : [])
                }
            }
            // 3.1.5: one lens for both rows. 3.1.14: laid out here by row index
            // rather than measured from the selected row.
            //
            // This screen pushes in on an entry slide. A measurement taken while
            // that slide was in flight came back one push-offset (72pt) to the
            // right, and nothing re-measured it until the slide ended — so the lens
            // appeared 72pt right of the row and then sprang back to it: the
            // "indicator jumps right when entering 音源" report. Laid out in the same
            // stack as the rows, the lens rides the slide with them from the first
            // frame, and still glides between the two rows when the selection moves.
            .background(alignment: .topLeading) {
                LCDSelectionBar()
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.doubleLineRowHeight)
                    .offset(y: CGFloat(viewModel.selectedIndex) * Metrics.doubleLineRowHeight)
                    .animation(reduceMotion ? nil : LCDLensHost.glide, value: viewModel.selectedIndex)
            }
            Spacer(minLength: 0)
            // The hint belongs to the foot of the screen, the way the iPod printed
            // its wheel hints under the list, not as a line floating after the rows.
            if let hint = viewModel.sourceHint {
                Text(hint)
                    .font(AppFont.micro)
                    .foregroundStyle(appearance.theme.lcdSecondaryText.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Metrics.horizontalInset)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
