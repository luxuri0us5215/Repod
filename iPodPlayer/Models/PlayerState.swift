import Foundation
import ObjectiveC
import SwiftUI

enum AudioSource: String, CaseIterable, Identifiable, Hashable {
    case netease, spotify
    var id: String { rawValue }
    var displayName: String { self == .netease ? L10n.text("网易云") : "Spotify" }
    /// The screen that configures this source. Settings → 音源 is its only entry,
    /// so a source is configured by selecting it there and pressing centre again.
    var settingsScreen: AppScreen {
        self == .netease ? .neteaseSettings : .spotifySettings
    }
}

struct Track: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let source: AudioSource
    var spotifyURI: String? = nil
    var streamURL: URL? = nil
    var artworkURL: URL? = nil
    /// NetEase album ID. Search results, charts and recommendations arrive without a
    /// playlist origin, and the album is the only truthful `sourceid` those plays have.
    var albumID: String? = nil
    /// A podcast episode plays like a song but is not a likeable one: its id names the
    /// DJ audio asset, so a heart would write a podcast into 我喜欢的音乐.
    var isPodcastEpisode = false
    /// The DJ program the episode's audio belongs to. Podcast plays are reported as a
    /// `djprogram` keyed by this id; the track id above is only the underlying song.
    var podcastProgramID: String? = nil
    /// The show (radio) the program belongs to, which is the episode's playback source.
    var podcastRadioID: String? = nil

    private static let spotifyIDCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// Web API library routes take the bare Spotify track ID, never its playback URI.
    var spotifyTrackID: String? {
        guard source == .spotify else { return nil }
        let uriID = spotifyURI.flatMap { uri in
            uri.hasPrefix("spotify:track:") ? String(uri.dropFirst("spotify:track:".count)) : nil
        }
        let allowed = Self.spotifyIDCharacters
        for candidate in [uriID, Optional(id)].compactMap({ $0 }) {
            if !candidate.isEmpty && candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                return candidate
            }
        }
        return nil
    }
}

struct SearchPage {
    let tracks: [Track]
    let hasMore: Bool
    let nextOffset: Int
}

enum SearchNotice: Equatable {
    case noResults
    case failed(String)
}

struct MusicPlaylist: Identifiable, Hashable {
    let id: String
    let title: String
    let trackCount: Int?
    let source: AudioSource
    /// NetEase exposes 我喜欢的音乐 as an ordinary playlist tagged `specialType == 5`.
    /// 歌单 pins it above the alphabetical list instead of burying it in it.
    var isLiked = false
}

/// One subscribed podcast (NetEase calls it 电台节目). Episodes are played as
/// tracks, so only the show itself needs its own model.
struct PodcastShow: Identifiable, Hashable {
    let id: String
    let title: String
    let author: String
    let episodeCount: Int?
    let artworkURL: URL?
    let source: AudioSource
}

enum AppScreen: Hashable {
    case home, music, settings, sources, search, appearance
    case neteaseSettings, spotifySettings, nowPlaying, languages
    case dailyRecommendations, radio, songs, playlists, artists, albums
    case podcasts
    case podcastEpisodes(id: String, name: String)
    case playlistTracks(MusicPlaylist)
    case artistTracks(id: String?, name: String)
    case albumTracks(id: String?, name: String, artist: String?)

    /// Screens only the NetEase backend can fill: Personal FM, Daily
    /// Recommendations and the DJ/podcast endpoints.
    var requiresNetEase: Bool {
        switch self {
        case .dailyRecommendations, .radio, .podcasts, .podcastEpisodes: return true
        default: return false
        }
    }

    var isTrackList: Bool {
        switch self {
        case .dailyRecommendations, .radio, .songs, .podcastEpisodes,
             .playlistTracks, .artistTracks, .albumTracks: return true
        default: return false
        }
    }

    var loadsLibrary: Bool {
        switch self {
        case .dailyRecommendations, .radio, .songs, .playlists, .podcasts, .podcastEpisodes,
             .playlistTracks, .artistTracks, .albumTracks: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .home: return "iPod"
        case .languages: return L10n.text("语言")
        case .music: return L10n.text("音乐")
        case .settings: return L10n.text("设置")
        case .sources: return L10n.text("音源")
        case .search: return L10n.text("搜索")
        case .appearance: return L10n.text("外观")
        case .neteaseSettings: return L10n.text("网易云设置")
        case .spotifySettings: return L10n.text("Spotify 设置")
        case .nowPlaying: return L10n.text("正在播放")
        case .dailyRecommendations: return L10n.text("每日推荐")
        case .radio: return L10n.text("电台")
        case .songs: return L10n.text("歌曲")
        case .playlists: return L10n.text("歌单")
        case .artists: return L10n.text("歌手")
        case .albums: return L10n.text("专辑")
        case .podcasts: return L10n.text("播客")
        case .podcastEpisodes(_, let name): return name
        case .playlistTracks(let playlist): return playlist.title
        case .artistTracks(_, let name): return name
        case .albumTracks(_, let name, _): return name
        }
    }
}

enum MenuAction: Equatable {
    case open(AppScreen)
    case playbackMode
    case language(AppLanguage)
    case setting(SettingsAction)
}

enum SettingsAction: Equatable {
    case followSystem, theme(AppThemePreset), customAccentEnabled, customAccentColor
    case neteaseAddress, saveNetEase, generateNetEaseQR, cancelNetEaseQR, logoutNetEase
    case spotifyClientID, spotifyRedirectURI, loginSpotify, logoutSpotify
}

struct MenuEntry: Identifiable {
    let id: String
    let title: String
    let detail: String?
    let action: MenuAction
    let switchValue: Bool?
    let marked: Bool

    var showsChevron: Bool {
        if switchValue != nil { return false }
        switch action {
        case .playbackMode, .language: return false
        default: return true
        }
    }

    /// `translates` stays true for the app's own labels. Rows built from the user's
    /// library or account pass false: a song or artist called "Home" must never be
    /// replaced by a menu string that happens to translate to the same word.
    init(_ title: String, id: String? = nil, detail: String? = nil, switchValue: Bool? = nil,
         marked: Bool = false, translates: Bool = true, action: MenuAction) {
        self.id = id ?? title
        self.title = translates ? L10n.text(title) : title
        self.detail = translates ? detail.map(L10n.text) : detail
        self.switchValue = switchValue
        self.marked = marked
        self.action = action
    }
}

struct NavigationFrame {
    let screen: AppScreen
    var selectedIndex: Int
}

// Stage 1.38 keeps preferences and the translation catalog in an existing model file.
/// The one playback mode setting: shuffle, repeat one and repeat all are mutually
/// exclusive. Two independent switches said "shuffle AND repeat one" was a state,
/// which has no meaning on a queue — and left the user guessing which one wins.
enum PlaybackMode: String, CaseIterable {
    case shuffle, repeatOne, repeatAll

    var next: PlaybackMode {
        switch self {
        case .shuffle: return .repeatOne
        case .repeatOne: return .repeatAll
        case .repeatAll: return .shuffle
        }
    }

    var displayName: String {
        switch self {
        case .shuffle: return L10n.text("随机播放")
        case .repeatOne: return L10n.text("单曲循环")
        case .repeatAll: return L10n.text("列表循环")
        }
    }

    /// The header glyph that reports this mode. All three are drawn by the same
    /// renderer at the same ink height, so switching between them cannot resize
    /// the status row.
    var symbolName: String {
        switch self {
        case .shuffle: return "shuffle"
        case .repeatOne: return "repeat.1"
        case .repeatAll: return "repeat"
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case traditionalChinese = "zh-Hant"
    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        }
    }
    static var current: AppLanguage {
        // Bundle lookups reach this from any thread; only main-thread reads can be
        // a view body, and keeping the revision main-only keeps it race-free.
        if Thread.isMainThread { _ = LanguageRevision.shared.value }
        return AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .simplifiedChinese
    }

    @MainActor static func select(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
        LanguageRevision.shared.value &+= 1
    }
}

/// Text is translated while a body runs, from a language stored outside any
/// observable object. Every body that translates reads this, so switching the
/// language repaints exactly the views that show words, wherever they sit.
@Observable
private final class LanguageRevision: @unchecked Sendable {
    static let shared = LanguageRevision()
    var value = 0
}

enum L10n {
    // Native language names and the locked MENU / Repod names are never translated.
    static let untranslated = ["MENU", "Repod", "简体中文", "English", "繁體中文", "Spotify", "iPod"]
    static let catalog: [String: (english: String, traditional: String)] = [
        "专辑加载失败，请稍后重试。": ("Unable to load the album. Try again later.", "專輯載入失敗，請稍後重試。"),
        "正在加载专辑…": ("Loading Album…", "正在載入專輯…"),
        "音乐": ("Music", "音樂"),
        "正在播放": ("Now Playing", "正在播放"),
        "设置": ("Settings", "設定"),
        "音源": ("Music Source", "音源"),
        "搜索": ("Search", "搜尋"),
        "外观": ("Appearance", "外觀"),
        "网易云设置": ("NetEase Settings", "網易雲設定"),
        "Spotify 设置": ("Spotify Settings", "Spotify 設定"),
        "每日推荐": ("Daily Recommendations", "每日推薦"),
        "推荐": ("Recommended", "推薦"),
        "先听几首歌，推荐会按最近在听的艺人找还没放进歌单的歌。": ("Play a few songs first. Recommendations use artists you just listened to, and skip songs already in a playlist.", "先聽幾首歌，推薦會按最近在聽的藝人找還沒放進歌單的歌。"),
        "最近在听的艺人，歌单里已经有这些歌了。": ("Songs by the artists you just played are already in your playlists.", "最近在聽的藝人，歌單裡已經有這些歌了。"),
        "电台": ("Radio", "電台"),
        "播客": ("Podcasts", "播客"),
        "暂无播客": ("No Podcasts", "暫無播客"),
        "请先在网易云音乐中订阅播客。": ("Subscribe to podcasts in NetEase Cloud Music first.", "請先在網易雲音樂中訂閱播客。"),
        "正在载入播客…": ("Loading Podcasts…", "正在載入播客…"),
        "该播客近期没有节目。": ("This podcast has no recent episodes.", "該播客近期沒有節目。"),
        "我喜欢的音乐": ("Liked Music", "喜歡的音樂"),
        "请先在“歌单”中打开一个含歌曲的歌单，以建立歌曲索引。": ("Open a playlist with songs in Playlists first to build your music index.", "請先在「歌單」中開啟一個含歌曲的歌單，以建立歌曲索引。"),
        "部分专辑加载失败，已使用已有歌曲": ("Some albums could not be loaded. Existing songs are being used.", "部分專輯載入失敗，已使用已有歌曲"),
        "最近播放": ("Recently Played", "最近播放"),
        "歌手": ("Artists", "歌手"),
        "专辑": ("Albums", "專輯"),
        "歌单": ("Playlists", "歌單"),
        "语言": ("Language", "語言"),
        "随机播放": ("Shuffle", "隨機播放"),
        "播放模式": ("Playback Mode", "播放模式"),
        "列表循环": ("Repeat All", "列表循環"),        "单曲循环": ("Repeat One", "單曲循環"),
        "关": ("Off", "關"),
        "歌曲": ("Songs", "歌曲"),
        "跟随系统": ("Follow System", "跟隨系統"),
        "使用自定强调色": ("Use Custom Accent", "使用自訂強調色"),
        "自定强调色": ("Custom Accent", "自訂強調色"),
        "经典白": ("Classic White", "經典白"),
        "午夜黑": ("Midnight Black", "午夜黑"),
        "薄荷绿": ("Mint Green", "薄荷綠"),
        "落日橙": ("Sunset Orange", "落日橙"),
        "网易云": ("NetEase", "網易雲"),
        "网易云音乐": ("NetEase Music", "網易雲音樂"),
        "网易云服务地址": ("NetEase Service URL", "網易雲服務位址"),
        "保存并检查登录": ("Save and Check Login", "儲存並檢查登入"),
        "重新生成二维码": ("Generate New QR Code", "重新產生 QR 碼"),
        "生成登录二维码": ("Generate Login QR Code", "產生登入 QR 碼"),
        "取消": ("Cancel", "取消"),
        "退出网易云登录": ("Log Out of NetEase", "登出網易雲"),
        "Spotify 客户端标识": ("Spotify Client ID", "Spotify 用戶端識別碼"),
        "客户端标识": ("Client ID", "用戶端識別碼"),
        "回调地址": ("Redirect URI", "回呼位址"),
        "Spotify 回调地址": ("Spotify Redirect URI", "Spotify 回呼位址"),
        "退出 Spotify 登录": ("Log Out of Spotify", "登出 Spotify"),
        "登录 Spotify": ("Log In to Spotify", "登入 Spotify"),
        "当前语言": ("Current Language", "目前語言"),
        "当前音源": ("Current Source", "目前音源"),
        "音量": ("Volume", "音量"),
        "暂停": ("Pause", "暫停"),
        "播放": ("Play", "播放"),
        "播放中": ("Playing", "播放中"),
        "已暂停": ("Paused", "已暫停"),
        "音源：": ("Source: ", "音源："),
        "正在搜索": ("Searching", "正在搜尋"),
        "正在载入": ("Loading", "正在載入"),
        "正在准备曲库…": ("Preparing your library…", "正在準備曲庫…"),
        "正在启动": ("Starting", "正在啟動"),
        "正在搜索…": ("Searching…", "正在搜尋…"),
        "正在载入…": ("Loading…", "正在載入…"),
        "正在加载…": ("Loading…", "正在載入…"),
        "正在加载电台…": ("Loading Radio…", "正在載入電台…"),
        "输入歌名或艺人，搜索当前音源": ("Enter a song or artist to search this source", "輸入歌名或藝人，搜尋目前音源"),
        "输入歌曲或艺人": ("Enter a song or artist", "輸入歌曲或藝人"),
        "搜索歌曲或艺人": ("Search songs or artists", "搜尋歌曲或藝人"),
        "清除搜索内容": ("Clear Search", "清除搜尋內容"),
        "按中键重试": ("Press the center button to retry", "按中鍵重試"),
        "按中键前往设置": ("Press the center button to open Settings", "按中鍵前往設定"),
        "加载失败，按中键重试": ("Load failed. Press center to retry.", "載入失敗，按中鍵重試"),
        "还没有播放歌曲": ("No Song Playing Yet", "尚未播放歌曲"),
        "暂无歌曲": ("No Songs", "暫無歌曲"),
        "暂无歌单": ("No Playlists", "暫無歌單"),
        "暂无专辑": ("No Albums", "暫無專輯"),
        "在设置中配置服务并登录，然后搜索歌曲": ("Configure a service and log in under Settings, then search for music", "在設定中配置服務並登入，然後搜尋歌曲"),
        "播放进度": ("Playback Progress", "播放進度"),
        "已播放": ("Elapsed ", "已播放"),
        "，剩余时间": (", remaining ", "，剩餘時間"),
        "专辑封面占位图": ("Album Artwork Placeholder", "專輯封面預留圖"),
        "专辑封面": ("Album Artwork", "專輯封面"),
        "已喜欢": ("Liked", "已喜歡"),
        "未喜欢": ("Not Liked", "未喜歡"),
        "已取消喜欢": ("Removed from Liked Music", "已取消喜歡"),
        "点按式转盘": ("Click Wheel", "點按式轉盤"),
        "向上轻扫选择下一项，向下轻扫选择上一项。": ("Swipe up for the next item and down for the previous item.", "向上輕掃選擇下一項，向下輕掃選擇上一項。"),
        "上一首": ("Previous Track", "上一首"),
        "下一首": ("Next Track", "下一首"),
        "确认": ("Confirm", "確認"),
        "喜欢 / 取消喜欢": ("Like / Unlike", "喜歡 / 取消喜歡"),
        "轻点暂停或继续播放": ("Tap to pause or resume", "輕點暫停或繼續播放"),
        "轻点播放专辑中的歌曲": ("Tap to play songs from this album", "輕點播放專輯中的歌曲"),
        "轻点播放这首歌曲": ("Tap to play this song", "輕點播放這首歌曲"),
        "提示": ("Notice", "提示"),
        "好": ("OK", "好"),
        "http://your-server:3000": ("http://your-server:3000", "http://your-server:3000"),
        "网易云登录二维码，请用网易云音乐扫码": ("NetEase login QR code. Scan it with NetEase Music.", "網易雲登入 QR 碼，請用網易雲音樂掃碼"),
        "尚未登录；会员歌曲需要扫码登录": ("Not logged in; scan the QR code for subscription tracks", "尚未登入；會員歌曲需要掃碼登入"),
        "请在设置中登录 Spotify": ("Log in to Spotify in Settings", "請在設定中登入 Spotify"),
        "无法读取本地曲库，请检查设备存储空间。": ("Unable to read your local library. Check device storage.", "無法讀取本機曲庫，請檢查裝置儲存空間。"),
        "请先前往“设置”登录 Spotify，再搜索或播放歌曲。": ("Log in to Spotify in Settings before searching or playing music.", "請先前往「設定」登入 Spotify，再搜尋或播放歌曲。"),
        "没有找到歌曲，请尝试其他歌名或艺人。": ("No songs found. Try another song or artist.", "找不到歌曲，請嘗試其他歌名或藝人。"),
        "本地曲库保存失败，请检查设备存储空间。": ("Unable to save your local library. Check device storage.", "本機曲庫儲存失敗，請檢查裝置儲存空間。"),
        "无法恢复播放，请检查音频输出后重新选择歌曲。": ("Unable to resume playback. Check the audio output and select the song again.", "無法恢復播放，請檢查音訊輸出後重新選擇歌曲。"),
        "服务地址已更新，请重新检查登录或扫码": ("Service URL updated. Check your login or scan the QR code again.", "服務位址已更新，請重新檢查登入或掃碼"),
        "正在生成二维码…": ("Generating QR Code…", "正在產生 QR 碼…"),
        "二维码生成失败，请重试。": ("Unable to generate the QR code. Try again.", "QR 碼產生失敗，請重試。"),
        "请用网易云音乐扫码并在手机上确认登录": ("Scan with NetEase Music and confirm login on your phone", "請用網易雲音樂掃碼並在手機上確認登入"),
        "已扫码，请在网易云音乐中确认登录": ("QR code scanned. Confirm login in NetEase Music.", "已掃碼，請在網易雲音樂中確認登入"),
        "二维码已过期，请重新生成。": ("QR code expired. Generate a new one.", "QR 碼已過期，請重新產生。"),
        "已退出登录，会员歌曲需要重新扫码": ("Logged out. Scan the QR code again for subscription tracks.", "已登出，會員歌曲需要重新掃碼"),
        "网络播放中断，请检查网络后重新选择歌曲。": ("Streaming was interrupted. Check your connection and select the song again.", "網路播放中斷，請檢查網路後重新選擇歌曲。"),
        "无法播放此歌曲。请确认服务在线、歌曲有播放权限，并重新获取播放地址。": ("Unable to play this song. Check the service and playback permission, then try again.", "無法播放此歌曲。請確認服務在線、歌曲有播放權限，並重新取得播放位址。"),
        "歌曲没有可用的网络播放地址。": ("No streaming URL is available for this song.", "歌曲沒有可用的網路播放位址。"),
        "已登录 Spotify": ("Logged In to Spotify", "已登入 Spotify"),
        "无法恢复 Spotify 登录，请在设置中重新登录。": ("Unable to restore Spotify login. Log in again in Settings.", "無法恢復 Spotify 登入，請在設定中重新登入。"),
        "设置已更新，请重新登录 Spotify": ("Settings updated. Log in to Spotify again.", "設定已更新，請重新登入 Spotify"),
        "无法显示 Spotify 登录窗口，请回到应用后重试。": ("Unable to show Spotify login. Return to the app and try again.", "無法顯示 Spotify 登入視窗，請回到應用程式後重試。"),
        "正在打开 Spotify 登录…": ("Opening Spotify Login…", "正在開啟 Spotify 登入…"),
        "Spotify 登录已取消，请重试。": ("Spotify login was canceled. Try again.", "Spotify 登入已取消，請重試。"),
        "Spotify 授权被拒绝，请重新登录并点同意。": ("Spotify authorization was denied. Log in again and allow access.", "Spotify 授權被拒絕，請重新登入並點選同意。"),
        "登录会话已过期，请重新登录。": ("Your login session expired. Log in again.", "登入工作階段已過期，請重新登入。"),
        "未收到 Spotify 授权码，请重新登录。": ("No Spotify authorization code was received. Log in again.", "未收到 Spotify 授權碼，請重新登入。"),
        "已登录 Spotify，搜索后选择歌曲即可播放": ("Logged in to Spotify. Search and select a song to play.", "已登入 Spotify，搜尋後選擇歌曲即可播放"),
        "无法启动 Spotify 登录，请回到应用后重试。": ("Unable to start Spotify login. Return to the app and try again.", "無法啟動 Spotify 登入，請回到應用程式後重試。"),
        "请先登录": ("Please Log In First", "請先登入"),
        "请先在 Spotify 里创建一个歌单，再回来点红心。": ("Create a playlist in Spotify first, then return and tap the heart.", "請先在 Spotify 建立歌單，再回來點選愛心。"),
        "此歌单不是你创建或参与的，Spotify 不开放查看。": ("Spotify only allows viewing playlists you own or collaborate on.", "此歌單並非由你建立或參與，Spotify 不開放檢視。"),
        "这首歌曲没有有效的 Spotify 播放地址。": ("This song has no valid Spotify playback URI.", "這首歌曲沒有有效的 Spotify 播放位址。"),
        "尚未安装 Spotify。请安装并登录 Spotify 应用，再回来播放。": ("Install Spotify and log in, then return to play music.", "尚未安裝 Spotify。請安裝並登入 Spotify 應用程式，再回來播放。"),
        "请先搜索并选择一首 Spotify 歌曲。": ("Search and select a Spotify song first.", "請先搜尋並選擇一首 Spotify 歌曲。"),
        "Spotify 应用未授予远程播放权限，请重新登录后再试。": ("Spotify has not granted remote playback access. Log in again and retry.", "Spotify 應用程式未授予遠端播放權限，請重新登入後再試。"),
        "Spotify 未连接": ("Spotify Disconnected", "Spotify 未連線"),
        "正在连接 Spotify 应用…": ("Connecting to Spotify…", "正在連線至 Spotify 應用程式…"),
        "无法连接 Spotify。请打开 Spotify 播放一首歌，再回到此应用重试。": ("Unable to connect to Spotify. Play a song in Spotify, then return and retry.", "無法連線至 Spotify。請開啟 Spotify 播放歌曲，再回到此應用程式重試。"),
        "请在 Spotify 中允许连接，然后返回此应用": ("Allow the connection in Spotify, then return to this app", "請在 Spotify 允許連線，然後返回此應用程式"),
        "无法打开 Spotify。请安装并登录 Spotify 应用后重试。": ("Unable to open Spotify. Install it and log in, then retry.", "無法開啟 Spotify。請安裝並登入 Spotify 應用程式後重試。"),
        "Spotify 连接超时。请确认 Spotify 已安装、已登录且可播放，然后重试。": ("Spotify connection timed out. Check that Spotify is installed, logged in, and able to play, then retry.", "Spotify 連線逾時。請確認 Spotify 已安裝、已登入且可播放，然後重試。"),
        "Spotify 未能播放所选歌曲。请确认会员和歌曲可用，然后重试。": ("Spotify could not play this song. Check your subscription and the song's availability, then retry.", "Spotify 無法播放所選歌曲。請確認會員資格和歌曲可用，然後重試。"),
        "Spotify 尚未连接，请打开 Spotify 后重新选择歌曲。": ("Spotify is not connected. Open Spotify and select the song again.", "Spotify 尚未連線，請開啟 Spotify 後重新選擇歌曲。"),
        "Spotify 播放操作失败。请确认会员和歌曲可用，并在 Spotify 中重试。": ("Spotify playback failed. Check your subscription and the song's availability, then retry in Spotify.", "Spotify 播放操作失敗。請確認會員資格和歌曲可用，並在 Spotify 重試。"),
        "Spotify 正在播放": ("Spotify Playing", "Spotify 正在播放"),
        "Spotify 已暂停": ("Spotify Paused", "Spotify 已暫停"),
        "无法访问 Spotify 服务，请检查网络连接后重试。": ("Unable to reach Spotify. Check your network connection and retry.", "無法存取 Spotify 服務，請檢查網路連線後重試。"),
        "请先在设置中填写 Spotify 开发者应用的客户端标识，再登录。": ("Enter your Spotify developer app's Client ID in Settings before logging in.", "請先在設定中填寫 Spotify 開發者應用程式的用戶端識別碼，再登入。"),
        "请填写已在 Spotify 开发者后台登记的应用回调地址。": ("Enter the redirect URI registered in your Spotify developer dashboard.", "請填寫已在 Spotify 開發者後台登記的應用程式回呼位址。"),
        "此回调协议尚未在应用中登记。请使用默认回调地址，或先在应用工程中登记对应协议再构建。": ("This callback scheme is not registered in the app. Use the default URI or register the scheme in the project and rebuild.", "此回呼協定尚未在應用程式登記。請使用預設回呼位址，或先在專案登記對應協定再建置。"),
        "无法安全创建 Spotify 登录请求，请重新打开应用后再试。": ("Unable to securely create Spotify login. Reopen the app and retry.", "無法安全建立 Spotify 登入請求，請重新開啟應用程式後再試。"),
        "Spotify 操作失败，请稍后重试。": ("Spotify operation failed. Try again later.", "Spotify 操作失敗，請稍後重試。"),
        "请先前往设置登录 Spotify，再搜索或播放。": ("Log in to Spotify in Settings before searching or playing.", "請先前往設定登入 Spotify，再搜尋或播放。"),
        "Spotify 授权已失效，请检查客户端标识与回调地址后重新登录。": ("Spotify authorization expired. Check the Client ID and redirect URI, then log in again.", "Spotify 授權已失效，請檢查用戶端識別碼與回呼位址後重新登入。"),
        "Spotify 返回了无法读取的数据，请稍后重试。": ("Spotify returned unreadable data. Try again later.", "Spotify 傳回無法讀取的資料，請稍後重試。"),
        "Spotify 登录已过期，请前往设置重新登录。": ("Spotify login expired. Log in again in Settings.", "Spotify 登入已過期，請前往設定重新登入。"),
        "Spotify 拒绝访问。请确认开发者应用已允许此账号，且会员与歌曲可用。": ("Spotify denied access. Check that your developer app allows this account and that your subscription and song are available.", "Spotify 拒絕存取。請確認開發者應用程式已允許此帳號，且會員資格與歌曲可用。"),
        "Spotify 请求过于频繁，请稍后重试。": ("Too many Spotify requests. Try again later.", "Spotify 請求過於頻繁，請稍後重試。"),
        "Spotify 服务暂时不可用，请稍后重试。": ("Spotify is temporarily unavailable. Try again later.", "Spotify 服務暫時無法使用，請稍後重試。"),
        "Spotify 已连接": ("Spotify Connected", "Spotify 已連線"),
        "Spotify 已断开": ("Spotify Disconnected", "Spotify 已中斷連線"),
        "请选择网易云歌曲。": ("Select a NetEase song.", "請選擇網易雲歌曲。"),
        "这首歌没有可播放地址。会员歌曲请先在设置中扫码登录；也可能受版权或地区限制。": ("No playback URL is available. Scan the QR code in Settings for subscription tracks; copyright or region restrictions may also apply.", "這首歌沒有可播放位址。會員歌曲請先在設定中掃碼登入；也可能受版權或地區限制。"),
        "服务只返回了试听片段。请在设置中扫码登录会员账号后重试，或选择有完整播放权限的歌曲。": ("The service returned only a preview. Scan the QR code in Settings with a subscriber account or choose a song with full playback permission.", "服務僅傳回試聽片段。請在設定中掃碼登入會員帳號後重試，或選擇可完整播放的歌曲。"),
        "网易云用户": ("NetEase User", "網易雲使用者"),
        "加入「我喜欢的音乐」歌单失败，请稍后重试。": ("Unable to add this song to Liked Music. Try again later.", "加入「喜歡的音樂」歌單失敗，請稍後重試。"),
        "移出「我喜欢的音乐」歌单失败，请稍后重试。": ("Unable to remove this song from Liked Music. Try again later.", "移出「喜歡的音樂」歌單失敗，請稍後重試。"),
        "听歌打卡失败。": ("Unable to submit your listening activity.", "聽歌打卡失敗。"),
        "未找到「我喜欢的音乐」歌单，请在网易云 App 里确认。": ("Liked Music playlist not found. Check it in the NetEase app.", "找不到「喜歡的音樂」歌單，請在網易雲 App 確認。"),
        "请选择网易云歌单。": ("Select a NetEase playlist.", "請選擇網易雲歌單。"),
        "服务未返回二维码密钥，请检查服务版本后重试。": ("No QR code key was returned. Check the service version and retry.", "服務未傳回 QR 碼金鑰，請檢查服務版本後重試。"),
        "服务未返回二维码地址，请稍后重试。": ("No QR code URL was returned. Try again later.", "服務未傳回 QR 碼位址，請稍後重試。"),
        "扫码已确认，但服务未返回登录凭据。请检查服务版本并重新扫码。": ("QR login was confirmed but no credentials were returned. Check the service version and scan again.", "掃碼已確認，但服務未傳回登入憑證。請檢查服務版本並重新掃碼。"),
        "无法识别扫码状态，请重新生成二维码。": ("Unrecognized QR login status. Generate a new QR code.", "無法辨識掃碼狀態，請重新產生 QR 碼。"),
        "请先到“设置 → 网易云设置”填写自己的服务地址。": ("Enter your service URL in Settings → NetEase Settings first.", "請先到「設定 → 網易雲設定」填寫自己的服務位址。"),
        "服务地址无效，请填写完整的网页服务地址，不要包含账号、密码或查询参数。": ("Invalid service URL. Enter the full web service URL without credentials or query parameters.", "服務位址無效，請填寫完整的網頁服務位址，且勿包含帳號、密碼或查詢參數。"),
        "服务地址无效。": ("Invalid Service URL.", "服務位址無效。"),
        "网易云服务请求失败，请检查服务运行状态和网络连接。": ("NetEase request failed. Check the service and your network connection.", "網易雲服務請求失敗，請檢查服務執行狀態和網路連線。"),
        "网易云暂时限流，正在后台自动重试。": ("NetEase is rate limiting briefly; retrying in the background.", "網易雲暫時限流，正在背景自動重試。"),
        "服务返回格式无效，请确认地址指向兼容的网易云接口服务。": ("Invalid service response. Check that the URL points to a compatible NetEase API service.", "服務傳回格式無效，請確認位址指向相容的網易雲 API 服務。"),
        "网易云登录已失效，请在设置中重新扫码登录。": ("NetEase login expired. Scan the QR code again in Settings.", "網易雲登入已失效，請在設定中重新掃碼登入。"),
        "无法连接网易云服务。请确认手机可以访问服务地址、网络已连通并允许局域网访问。": ("Unable to connect to NetEase. Check that your phone can reach the service and has network and local network access.", "無法連線至網易雲服務。請確認手機可存取服務位址、網路已連線且允許區域網路存取。"),
        "未知艺人": ("Unknown Artist", "未知藝人"),
        "未知专辑": ("Unknown Album", "未知專輯"),
        "无法读取或保存 Spotify 登录凭据，请解锁设备后重试。": ("Unable to read or save Spotify credentials. Unlock your device and retry.", "無法讀取或儲存 Spotify 登入憑證，請解鎖裝置後重試。"),
        "无法读取或保存网易云登录凭据，请解锁设备后重试。": ("Unable to read or save NetEase credentials. Unlock your device and retry.", "無法讀取或儲存網易雲登入憑證，請解鎖裝置後重試。"),
        "无法加载完整专辑。": ("Unable to load the complete album.", "無法載入完整專輯。"),
        "操作失败，请稍后重试。": ("Operation failed. Try again later.", "操作失敗，請稍後重試。"),
        "已连续 3 首播放失败，已停止。": ("Three tracks in a row failed to play. Playback stopped.", "已連續 3 首播放失敗，已停止。"),
        "服务地址已更新，登录凭据已保留；请检查登录": ("Service URL updated. Your login is kept; check it now.", "服務位址已更新，登入憑證已保留；請檢查登入"),
        "已登录": ("Logged In", "已登入"),
        "未登录": ("Not Signed In", "未登入"),
        "按中键配置": ("Press center to configure", "按中鍵設定"),
        "按中键切换音源": ("Press center to switch source", "按中鍵切換音源"),
        "正在唤醒 Spotify…": ("Waking Spotify…", "正在喚醒 Spotify…"),
        "设置已更新，请登录 Spotify": ("Settings updated. Log in to Spotify.", "設定已更新，請登入 Spotify"),
        "Spotify 登录已失效，请在设置中重新登录后恢复播放。": ("Spotify login expired. Log in again in Settings to resume playback.", "Spotify 登入已失效，請在設定中重新登入後恢復播放。"),
        "Spotify 未能恢复播放，请再按中心键重试。": ("Spotify could not resume. Press the center button to retry.", "Spotify 未能恢復播放，請再按中鍵重試。"),
        "Spotify 尚未连接。请打开 Spotify 后，再按播放重试。": ("Spotify is not connected. Open Spotify and press play again.", "Spotify 尚未連線。請開啟 Spotify 後，再按播放重試。"),
        "Spotify 令牌刷新超时，请检查网络。": ("Spotify token refresh timed out. Check your network.", "Spotify 權杖重新整理逾時，請檢查網路。"),
        "Spotify 登录未完成，请重试。": ("Spotify login did not finish. Try again.", "Spotify 登入未完成，請重試。"),
        "Spotify 没有可用于点赞的自建歌单，请先在 Spotify 创建一个属于自己的歌单": ("No Spotify playlist of your own is available for likes. Create one in Spotify first.", "Spotify 沒有可用於按讚的自建歌單，請先在 Spotify 建立一個屬於自己的歌單"),
        "请先登录 Spotify 后再点赞": ("Log in to Spotify before liking songs.", "請先登入 Spotify 後再按讚"),
        "Spotify 登录已过期，请退出后重新登录再点赞": ("Spotify login expired. Log out and log in again before liking.", "Spotify 登入已過期，請登出後重新登入再按讚"),
        "Spotify 拒绝修改歌单：账号可能缺少 playlist-modify-public / playlist-modify-private 权限，请退出 Spotify 登录后重新登录授权，并确认歌单属于自己": ("Spotify refused the playlist edit. The account may lack the playlist-modify-public / playlist-modify-private scopes; log out, log in again and allow them, and make sure the playlist is yours.", "Spotify 拒絕修改歌單：帳號可能缺少 playlist-modify-public / playlist-modify-private 權限，請登出 Spotify 登入後重新登入授權，並確認歌單屬於自己"),
        "Spotify 点赞歌单不存在或已删除，请重试以重新选择本人的歌单": ("The Spotify likes playlist is missing or deleted. Retry to choose your own playlist again.", "Spotify 按讚歌單不存在或已刪除，請重試以重新選擇本人的歌單")
    ]

    static func text(_ key: String) -> String {
        guard !untranslated.contains(key) else { return key }
        let base = catalog[key] != nil ? key : catalog.first {
            $0.value.english == key || $0.value.traditional == key
        }?.key ?? key
        if let entry = catalog[base] {
            switch AppLanguage.current {
            case .simplifiedChinese: return base
            case .english: return entry.english
            case .traditionalChinese: return entry.traditional
            }
        }
        return dynamicText(key) ?? key
    }

    private static func dynamicText(_ key: String) -> String? {
        // Runtime values remain intact; only app-owned templates are translated.
        let templates: [(patterns: [String], values: [String])] = [
            ([#"^([0-9]+) 首$"#, #"^([0-9]+) songs$"#], ["$1 首", "$1 songs", "$1 首"]),
            ([#"^([0-9]+) 集$"#, #"^([0-9]+) episodes$"#], ["$1 集", "$1 episodes", "$1 集"]),
            ([#"^已登录：(.+)$"#, #"^Logged in: (.+)$"#, #"^已登入：(.+)$"#],
             ["已登录：$1", "Logged in: $1", "已登入：$1"]),
            ([#"^快进至 (.+)$"#, #"^Seek forward to (.+)$"#, #"^快轉至 (.+)$"#],
             ["快进至 $1", "Seek forward to $1", "快轉至 $1"]),
            ([#"^快退 (.+)$"#, #"^Seek back to (.+)$"#, #"^倒轉 (.+)$"#],
             ["快退 $1", "Seek back to $1", "倒轉 $1"]),
            ([#"^已播放(.+)，剩余时间(.+)$"#, #"^Elapsed (.+), remaining (.+)$"#, #"^已播放(.+)，剩餘時間(.+)$"#],
             ["已播放$1，剩余时间$2", "Elapsed $1, remaining $2", "已播放$1，剩餘時間$2"]),
            ([#"^网易云接口返回错误（(.+)），请检查登录、版权和服务版本。$"#,
              #"^NetEase API error \((.+)\)\. Check login, copyright restrictions, and service version\.$"#,
              #"^網易雲 API 傳回錯誤（(.+)），請檢查登入、版權和服務版本。$"#],
             ["网易云接口返回错误（$1），请检查登录、版权和服务版本。",
              "NetEase API error ($1). Check login, copyright restrictions, and service version.",
              "網易雲 API 傳回錯誤（$1），請檢查登入、版權和服務版本。"]),
            ([#"^回调地址不匹配（收到 (.+)），请检查设置中的回调地址。$"#,
              #"^Redirect URI mismatch \(received (.+)\)\. Check the redirect URI in Settings\.$"#,
              #"^回呼位址不符（收到 (.+)），請檢查設定中的回呼位址。$"#],
             ["回调地址不匹配（收到 $1），请检查设置中的回调地址。",
              "Redirect URI mismatch (received $1). Check the redirect URI in Settings.",
              "回呼位址不符（收到 $1），請檢查設定中的回呼位址。"]),
            ([#"^Spotify 修改点赞歌单失败（HTTP ([0-9]+)），请稍后重试$"#,
              #"^Spotify could not update your liked playlist \(HTTP ([0-9]+)\)\. Try again later\.$"#,
              #"^Spotify 修改按讚歌單失敗（HTTP ([0-9]+)），請稍後重試$"#],
             ["Spotify 修改点赞歌单失败（HTTP $1），请稍后重试",
              "Spotify could not update your liked playlist (HTTP $1). Try again later.",
              "Spotify 修改按讚歌單失敗（HTTP $1），請稍後重試"])
        ]
        let languageIndex = AppLanguage.allCases.firstIndex(of: AppLanguage.current) ?? 0
        for template in templates {
            for pattern in template.patterns where key.range(of: pattern, options: .regularExpression) != nil {
                return key.replacingOccurrences(of: pattern, with: template.values[languageIndex], options: .regularExpression)
            }
        }
        for prefix in ["音源：", "已播放", "，剩余时间"] where key.hasPrefix(prefix) {
            return text(prefix) + String(key.dropFirst(prefix.count))
        }
        return nil
    }

    static func error(_ message: String) -> String {
        let translated = text(message)
        if translated != message || catalog[message] != nil || catalog.values.contains(where: {
            $0.english == message || $0.traditional == message
        }) || dynamicText(message) != nil { return translated }
        // Keep the caller's own wording: a generic "operation failed" hides the
        // reason the user needs (which service, which permission, which limit).
        return message
    }

    static func install() {
        // LocalizedStringKey used by untouched SwiftUI views (including alerts,
        // search, Cover Flow and wheel accessibility) resolves through this bundle.
        object_setClass(Bundle.main, AppLocalizedBundle.self)
    }
}

private final class AppLocalizedBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        let translated = L10n.text(key)
        if translated != key || L10n.catalog[key] != nil || L10n.untranslated.contains(key) { return translated }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

// String-specific overloads route existing dynamic SwiftUI labels through the same
// catalog; verbatim initialization prevents a second lookup or metadata mutation.
extension Text {
    init(_ content: String) {
        self.init(verbatim: L10n.text(content))
    }
}

extension View {
    func accessibilityLabel(_ label: String) -> some View {
        accessibilityLabel(Text(verbatim: L10n.text(label)))
    }
    func accessibilityValue(_ value: String) -> some View {
        accessibilityValue(Text(verbatim: L10n.text(value)))
    }
    func accessibilityHint(_ hint: String) -> some View {
        accessibilityHint(Text(verbatim: L10n.text(hint)))
    }
}

extension Button where Label == Text {
    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Text(verbatim: L10n.text(title)) }
    }
}

extension TextField where Label == Text {
    init(_ title: String, text: Binding<String>, prompt: Text? = nil) {
        self.init(text: text, prompt: prompt) { Text(verbatim: L10n.text(title)) }
    }
}
