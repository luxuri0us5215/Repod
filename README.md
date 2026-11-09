# Repod (iPodPlayer)

**English** | [中文](#中文)

An iPod Classic–style music player for iOS, written in SwiftUI: a touch click wheel with haptics, Cover Flow, lock-screen / Now Playing controls and Dynamic Island. Two music sources:

- **NetEase Cloud Music** — through a [NeteaseCloudMusicApi](https://www.npmjs.com/package/NeteaseCloudMusicApi) server **that you deploy yourself**
- **Spotify** — controls the Spotify app via the Spotify iOS SDK, using **your own** Spotify developer Client ID

Requires iOS 17.0+.

> **This project does not provide any public server or service.** The app ships with an empty NetEase address and no Spotify Client ID; you deploy NeteaseCloudMusicApi yourself and enter your own address in Settings.

## Screenshots

<!-- Add images to docs/screenshots/ and reference them here, e.g.:
<img src="docs/screenshots/now-playing.png" width="260"> <img src="docs/screenshots/cover-flow.png" width="260"> -->

_Screenshots coming soon — see `docs/screenshots/`._

## Features

- Click wheel: scroll, select, menu, play/pause, previous/next, with haptic ticks
- Cover Flow album browsing in landscape
- Search, playlists, liked songs, albums, podcasts (NetEase)
- Spotify playback control via App Remote + Web API
- Lock screen / Control Center / Dynamic Island now-playing
- Themes and appearance settings; Simplified Chinese / English / Traditional Chinese UI

## Install the prebuilt .ipa (sideloading)

1. Download `iPodPlayer-x.y.z.ipa` (unsigned) from [Releases](../../releases).
2. Install it with [SideStore](https://sidestore.io) (My Apps → `+` → pick the `.ipa`), AltStore, or any re-signing tool. It will be signed with your own Apple ID.
3. Free Apple IDs need to refresh the app every 7 days in SideStore.

## Set up your own NeteaseCloudMusicApi

NetEase playback needs a NeteaseCloudMusicApi server run **by you** (default port **3000**). Use the original [NeteaseCloudMusicApi](https://www.npmjs.com/package/NeteaseCloudMusicApi) or the community-maintained [api-enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced).

**Node.js (18+)**

```sh
npx NeteaseCloudMusicApi@latest            # quick start, no clone
# or, if you want to apply the optional patch below:
git clone https://gitlab.com/Binaryify/NeteaseCloudMusicApi.git
cd NeteaseCloudMusicApi && npm install && PORT=3000 node app.js
```

**Docker**

```sh
docker run -d --name ncm-api --restart unless-stopped -p 3000:3000 binaryify/netease_cloud_music_api
# community image: moefurina/ncm-api
```

**Your phone must be able to reach that address** — same LAN (e.g. `http://192.168.1.10:3000`), a public host you control (put it behind a firewall / auth), or your own tunnel / VPN. Open the address in the phone's browser first to check.

Then in the app: **Settings → NetEase server address (网易云服务地址)** → enter e.g. `http://your-server:3000`, and optionally log in by scanning the QR code (needed for VIP tracks and scrobbling).

### Optional patch: working scrobbles

The stock `/scrobble` endpoint returns success but NetEase no longer records the play ("Recently played" / "Listening ranking" stay unchanged). [`patches/NeteaseCloudMusicApi/module/scrobble.js`](patches/NeteaseCloudMusicApi/module/scrobble.js) is a drop-in replacement that reports `startplay` + `play` via eapi to `clientlog.music.163.com` and returns real errors instead of fake success. Playback works without it; only play history is affected.

```sh
cd <your NeteaseCloudMusicApi directory>          # needs util/option.js (4.x / api-enhanced)
cp module/scrobble.js module/scrobble.js.bak
cp /path/to/Repod/patches/NeteaseCloudMusicApi/module/scrobble.js module/scrobble.js
node --check module/scrobble.js
# restart: pm2 restart <name> / systemctl restart <service> / re-run node app.js
```

For Docker, bind-mount the file (e.g. `-v $PWD/scrobble.js:/app/module/scrobble.js`; check your image's app path) and restart the container. The `npx` method cannot be patched — use a clone.

## Spotify (optional)

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) (iOS SDK + Web API).
2. Register the redirect URI `ipodplayer://spotify-login-callback` (and your bundle ID if asked).
3. Enter your Client ID in the app's Settings and log in (the Spotify app must be installed) — or bake a default in at build time, see below.

## Build from source

```sh
git clone <this repo> && cd <repo>
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # git-ignored
# edit Config/Secrets.xcconfig: DEVELOPMENT_TEAM, PRODUCT_BUNDLE_IDENTIFIER, optional SPOTIFY_CLIENT_ID
open iPodPlayer.xcodeproj
```

- `Config/Base.xcconfig` holds safe defaults (`com.example.repod`, empty team, empty Spotify ID) and optionally includes `Config/Secrets.xcconfig`. The project builds without the secrets file.
- `SPOTIFY_CLIENT_ID` is only a default; a value entered in Settings always takes precedence.
- The Spotify iOS SDK is fetched automatically by Swift Package Manager.

Unsigned `.ipa`:

```sh
xcodebuild -project iPodPlayer.xcodeproj -scheme iPodPlayer -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/iPodPlayer.xcarchive archive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
mkdir -p build/Payload && cp -R build/iPodPlayer.xcarchive/Products/Applications/*.app build/Payload/
(cd build && zip -qry iPodPlayer.ipa Payload)
```

## Disclaimer

This project is **not an official NetEase Cloud Music client** and is not affiliated with NetEase, Apple, or Spotify. NetEase support relies on the unofficial, third-party NeteaseCloudMusicApi. **Using unofficial APIs may get your account restricted or banned; you use it entirely at your own risk.** No public server is provided. Respect each platform's terms of service and only play content you are entitled to.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Issues and PRs are welcome.

## License

[MIT](LICENSE) © 2026 Haoyu Qiu

---

## 中文

一个 iPod Classic 风格的 iOS 音乐播放器（SwiftUI）：带触感反馈的转盘、Cover Flow、锁屏/灵动岛播放控制。支持两种音源：

- **网易云音乐**：通过**你自己部署**的 NeteaseCloudMusicApi 服务
- **Spotify**：通过 Spotify iOS SDK 控制 Spotify App，使用**你自己的** Client ID

要求 iOS 17.0+。

> **本项目不提供任何公共服务器或服务。** App 默认网易云地址为空，需要使用者自己部署 NeteaseCloudMusicApi，并在设置里填写自己的地址。

### 截图

截图放在 `docs/screenshots/`（待补充）。

### 安装 .ipa（侧载）

1. 在 [Releases](../../releases) 下载未签名的 `iPodPlayer-x.y.z.ipa`
2. 用 [SideStore](https://sidestore.io)（My Apps → `+` → 选择 `.ipa`）、AltStore 或其他自签工具安装，会用你自己的 Apple ID 签名
3. 免费 Apple ID 需每 7 天在 SideStore 里刷新一次

### 自建 NeteaseCloudMusicApi

网易云服务由使用者自己搭建（默认端口 **3000**），可用原版 NeteaseCloudMusicApi 或社区维护的 api-enhanced：

- **Node（18+）**：`npx NeteaseCloudMusicApi@latest`；如需打补丁，clone 后 `npm install && PORT=3000 node app.js`
- **Docker**：`docker run -d --name ncm-api --restart unless-stopped -p 3000:3000 binaryify/netease_cloud_music_api`（或社区镜像 `moefurina/ncm-api`）

**手机必须能访问该地址**：同一局域网、你自己的公网主机（建议加防火墙/认证），或你自己的隧道 / VPN 均可。先用手机浏览器打开确认能访问。

然后在 App「设置 → 网易云服务地址」填入地址（例如 `http://your-server:3000`），可选扫码登录（会员歌曲和听歌打卡需要登录）。

### 可选补丁：修复听歌打卡

原版 `/scrobble` 返回成功但网易云不入账。把 [`patches/NeteaseCloudMusicApi/module/scrobble.js`](patches/NeteaseCloudMusicApi/module/scrobble.js) 覆盖到你的 NeteaseCloudMusicApi 的 `module/` 目录（先备份原文件，`node --check` 检查语法），然后重启服务即可；Docker 部署请用 `-v` 挂载该文件后重启容器，`npx` 方式无法打补丁。不打补丁也能正常播放，只是听歌记录不入账。

### 从源码构建

复制 `Config/Secrets.example.xcconfig` 为 `Config/Secrets.xcconfig`（已被 git 忽略），填入你自己的 `DEVELOPMENT_TEAM`、`PRODUCT_BUNDLE_IDENTIFIER`，可选 `SPOTIFY_CLIENT_ID`（仅作默认值，设置页填写的值优先）。不建这个文件也能编译。Spotify SDK 由 SPM 自动拉取。

### 免责声明

本项目**不是网易云音乐官方客户端**，与网易云音乐、Apple、Spotify 无任何关联。网易云音源依赖第三方非官方接口，**使用非官方接口存在账号被限制或封禁的风险，后果由使用者自行承担**。本项目不提供任何公共服务。请遵守各平台服务条款，仅播放你有权收听的内容。

### 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。

### 许可证

[MIT](LICENSE) © 2026 Haoyu Qiu
