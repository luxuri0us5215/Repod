// 听歌打卡
//
// 默认实现（weapi → music.163.com/api/feedback/weblog，只发 play）从 2025 年起被网易云
// 静默丢弃：HTTP 200 {"data":"success"}，但「最近播放」「听歌排行」都不入账。
// 有效组合是 clientlog.music.163.com + eapi + cookie 注入 os=osx，并且 startplay 与
// play 必须分别发送：startplay 驱动「最近播放」，play 驱动「听歌排行」计数。
//
// 可直接替换原版 module/scrobble.js。
//
// 参数：
//   id       必填  歌曲 id；type=djprogram 时是节目 id
//   time     必填  播放秒数（整数）
//   sourceid 可选  歌单/专辑 id；type=djprogram 时是电台 id
//   type     可选  song（默认）| djprogram
//   cookie   必填  必须含 MUSIC_U，否则返回 401（原版此处也会假成功）

const createOption = require('../util/option.js')

const DEFAULT_DOMAIN = 'https://clientlog.music.163.com'

// 桌面客户端身份。缺了这几个字段，request.js 会按 osMap['pc'] 补齐 Windows 身份，
// 服务端随即丢弃整条日志。
const DESKTOP_IDENTITY = {
  os: 'osx',
  appver: '3.1.10.5100',
  osver: '15.5',
  channel: 'netease',
}

const fail = (status, msg) => ({ status, body: { code: status, msg }, cookie: [] })

module.exports = async (query, request) => {
  const id = String(query.id || '').trim()
  const sourceId = String(query.sourceid || query.sourceId || '').trim()
  const playedSeconds = Math.floor(Number(query.time) || 0)
  const type = String(query.type || 'song').toLowerCase() === 'djprogram' ? 'djprogram' : 'song'

  // 原版对这些情况照样返回 200，调用方永远看不到失败。这里先挡住，让问题在客户端可见。
  if (!id || !/^\d+$/.test(id)) return fail(400, '缺少有效的歌曲 id')
  if (playedSeconds <= 0) return fail(400, '缺少有效的 time（播放秒数）')

  query.cookie = typeof query.cookie === 'object' && query.cookie !== null ? query.cookie : {}
  // 没有登录令牌时 clientlog 依然回 200，但什么都不记——这种「假成功」必须暴露出来。
  if (!query.cookie.MUSIC_U) return fail(401, '缺少 MUSIC_U 登录令牌')

  Object.assign(query.cookie, DESKTOP_IDENTITY)

  const option = createOption(query, 'eapi')
  option.domain = query.domain || DEFAULT_DOMAIN

  const content = sourceId ? `id=${sourceId}` : ''
  const common = { mainsite: '1', mainsiteWeb: '1', content }

  const startplay = {
    logs: JSON.stringify([
      { action: 'startplay', json: { id, type, ...common } },
    ]),
  }
  const play = {
    logs: JSON.stringify([
      {
        action: 'play',
        json: {
          type,
          wifi: 0,
          download: 0,
          id,
          time: playedSeconds,
          end: 'playend',
          source: 'list',
          sourceId,
          ...common,
        },
      },
    ]),
  }

  const started = await request('/api/feedback/weblog', startplay, option)
  const ranked = await request('/api/feedback/weblog', play, option)

  // 两条日志都 200 才算真的提交了；任何一条非 200 都往上抛，别让客户端以为成功了。
  const failed = [started, ranked].find((answer) => answer.status !== 200)
  if (failed) {
    return {
      status: failed.status,
      body: { ...failed.body, startplay: started.body, play: ranked.body },
      cookie: failed.cookie || [],
    }
  }

  return {
    status: 200,
    body: { code: 200, data: 'success', startplay: started.body, play: ranked.body },
    cookie: ranked.cookie || [],
  }
}
