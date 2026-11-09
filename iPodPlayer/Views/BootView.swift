import SwiftUI

/// Shown until the saved library index has been read and pre-sorted.
/// Black replaces the system launch image without a visible seam, and the LCD
/// progress line mirrors the player's own visual language.
@MainActor
struct BootView: View {
    @State private var sweep = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                VStack(spacing: 2) {
                    Text(verbatim: "iPod")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.white)
                    // The build's own marketing version, so a packaged snapshot
                    // identifies itself without opening Settings.
                    Text(verbatim: Self.marketingVersion)
                        .font(AppFont.micro)
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                .accessibilityElement(children: .combine)
                .accessibilityHidden(true)

                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 132, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: 44, height: 3)
                            .offset(x: sweep ? 88 : 0)
                    }
                    .clipShape(Capsule())
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: sweep)
                    .accessibilityHidden(true)

                Text("正在准备曲库…")
                    .font(AppFont.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .onAppear { sweep = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在启动")
    }

    private static var marketingVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }
}
