# Contributing / 贡献指南

Thanks for your interest in Repod! / 感谢关注 Repod！

## Issues

- Bug reports: iOS version, device, app version (the Release tag you installed), steps to reproduce, and what you expected.
- **Never paste cookies, tokens, `MUSIC_U`, Spotify credentials, or your server address** in issues or logs.
- 提交问题请附 iOS 版本、机型、App 版本、复现步骤；**不要贴出 cookie、token、`MUSIC_U` 或你的服务器地址**。

## Pull requests

1. Fork, then create a branch from `main`.
2. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` for your own Team / Bundle ID (this file is git-ignored — never commit it).
3. Keep changes focused; match the existing SwiftUI style; build with zero warnings (`xcodebuild … -destination 'generic/platform=iOS'`).
4. Add a short entry to `CHANGELOG.md` describing the user-visible change (the file is Chinese; match the existing style).
5. Do not add hard-coded server addresses, API keys, tokens, cookies or personal identifiers (team IDs, bundle IDs, device IDs). The app must keep working with no gateway address, no Spotify Client ID and no embedded credentials: direct mode, QR login and a Client ID typed in Settings are the supported paths.
6. Run the unit tests (`xcodebuild test -project iPodPlayer.xcodeproj -scheme iPodPlayer -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`) before opening the PR.

## 中文简述

Fork → 新分支 → 用 `Config/Secrets.xcconfig` 配置自己的签名（不要提交）→ 保持改动聚焦、0 warning → 在 `CHANGELOG.md` 记一笔 → 发 PR。代码里不要写死任何服务器地址、密钥或个人信息。

By contributing you agree that your contributions are licensed under the MIT License. / 提交贡献即表示同意以 MIT 许可证授权。
