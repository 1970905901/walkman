# 随便听 (walkman)

原生 SwiftUI 打造的三端音乐播放器 —— **iPhone / iPad / Mac (Catalyst)**，是 [lx-music-mobile](https://github.com/lyswhut/lx-music-mobile)（洛雪音乐）的 iOS 生态复刻与再设计。核心思路一致：**App 本身不提供任何音频内容**，通过兼容 lx-music v4 用户脚本协议的自定义音源解析播放地址，聚合酷我、网易云、酷狗、QQ 音乐四大平台的搜索与歌单浏览。

- Bundle ID：`com.heartbeat.walkman`
- 显示名：中文「随便听」/ 英文「Walkman」（随系统语言）
- 平台：iOS / iPadOS（原生布局）+ macOS（Mac Catalyst，DMG 分发）

---

## 设计风格

**暗色主导的 HiFi 质感**（Liquid Glass + 封面驱动取色），定位是"成熟、有重量、不轻浮"，参考 Tidal HiFi / B&O 的视觉气质：

- 大标题用 32pt Heavy Rounded 圆体，卡片大圆角（8/12/18/28pt 四级），统一的间距/阴影 token（`DesignSystem.swift` 中的 `DS.Spacing / DS.Radius / DS.Typo / DS.Elevation`）
- 播放器页有黑胶唱片（`IPadVinylDisc`）与磁带等拟物元素，呼应 "Walkman" 之名
- 封面网格卡片带 hover 抬升动效（Mac/iPad 触控板）、来源色投影

### 主题色

| 用途 | 颜色 |
|---|---|
| 品牌渐变起点 | `#8B2440` 酒红 |
| 品牌渐变终点 | `#C18A4F` 古铜金 |
| 磁带米黄 | `#E8C99A` |

每个音源平台有品牌辨识色（酷我橙 / 酷狗蓝 / QQ 绿 / 网易红 / 咪咕橙黄），用于 chip、卡片投影和占位图；音质角标也有专属色阶（母带赤铜 / 全景声蓝 / Hi-Res 金 / 无损紫 / HQ 青绿）。

---

## 功能一览

**浏览与搜索**
- 四平台聚合搜索（全部 tab 汇总 + 单平台 tab），支持歌词搜索、搜索历史
- 歌单广场：各平台推荐流（最热/最新排序 + 平台专属标签筛选）、歌单关键字搜索
- 排行榜、发现页推荐流（带缓存）

**播放**
- 音质体系：128k → 320k → 无损 FLAC → Hi-Res 24bit → 臻品全景声 → 臻品母带，按"脚本能力声明 + 元数据"智能选档
- 多级降级兜底：URL 404/格式不支持时自动降档重试，AVFoundation 拒解的 Hi-Res FLAC 自动切内置 libFLAC 解码器；单曲失败还会跨平台搜同名歌换源
- 10 段 EQ 均衡器（MTAudioProcessingTap 实现，同时驱动音浪动画）、AirPlay、睡眠定时、后台播放 + 锁屏/控制中心控件
- 滚动歌词（多源解析 + 缓存）、MV 播放

**曲库**
- 歌单导入：粘贴四平台任意分享链接/纯 ID 即可整单导入（网易云走 v6 + 批量详情两步接口拿全量曲目，千首大歌单分批写入不卡 UI）
- 下载：文件名按 `歌手/专辑/曲目` 目录整理，内嵌歌名/歌手/专辑/封面/歌词等完整元数据；Mac 下载到 `~/Music/Walkman`
- 本地音乐文件夹导入、播放历史与统计、iCloud 多端同步（歌单/脚本）

**系统集成**
- Siri / App Shortcuts（"用随便听播放晴天"）、听歌识曲（ShazamKit）
- Mac 专属：状态栏 Now Playing（歌名-歌手滚动显示、播控按钮、应用内音量滑块）、Dock 右键播控菜单、红点关窗不退出 App
- 中英双语（String Catalogs）

---

## 技术架构

```
┌─ UI 层 ────────────────────────────────────────────┐
│  RootTabView (iPhone) │ iPad/IPad*View │ Mac/MacAppController │
├─ 播放层 ───────────────────────────────────────────┤
│  PlaybackEngine   AVPlayer + 降级链 + 锁屏控件        │
│  HiResFLACPlayer  libFLAC 解码 AVPlayer 拒收的流     │
│  EQAudioTap       MTAudioProcessingTap: EQ + RMS    │
├─ 音源层 ───────────────────────────────────────────┤
│  JSScriptRuntime  JavaScriptCore 沙箱运行用户脚本     │
│  user-api-preload.js  lx v4 协议桥（脚本↔host 分派）  │
│  SourceManager    脚本加载/能力协商/选档/换源          │
│  BuiltInResolver  酷我/网易直连兜底                   │
├─ 目录层（host 负责搜索,脚本只管 musicUrl/lyric/pic）─┤
│  Catalogs / KuwoCatalog / Songlists / Boards        │
├─ 数据层 ───────────────────────────────────────────┤
│  PlaylistStore / ScriptStore / DownloadStore / …    │
│  JSON 文件持久化 + CloudSync (iCloud KVS)            │
└────────────────────────────────────────────────────┘
```

几个关键设计：

- **lx v4 脚本协议**：脚本通过 `__lx_native_call__` 与 host 通信，HTTP 请求由 host 的 URLSession 代理执行（脚本无网络权限），host 注入 md5/aes/rsa/base64 等工具函数。脚本只负责 `musicUrl / lyric / pic` 三个动作，搜索/歌单/排行榜全部由 host 原生实现——所以浏览体验不依赖脚本质量。
- **音质可靠性**：脚本对不存在的高音质档也会拼出 URL（404），播放层把 404/403、解码失败都纳入降级链，每档只试一次、成功档位同曲复用，绝不落到比实际可用更低的音质。
- **并发模型**：Swift 6，`-default-isolation=MainActor` 全局主隔离；纯数据与网络解析类型显式 `nonisolated + Sendable`。
- **工程**：Xcode 16+ 的 `PBXFileSystemSynchronizedRootGroup`，`walkman/` 目录下增删文件自动同步，无需手改 pbxproj。

---

## 与原版 lx-music 相比的优势

1. **三端原生**：SwiftUI 一套代码，iPhone/iPad/Mac 各有针对性布局（iPad 侧栏 + 底栏、Mac 状态栏/Dock 集成），不是 RN 套壳
2. **Hi-Res 能力更强**：内置 libFLAC 解码器兜底 24bit FLAC，加上多级音质降级，比"播不了就报错"可靠得多
3. **歌单迁移零门槛**：四平台分享链接直接导入，含微信分享的新版链接形态
4. **下载即收藏级**：目录结构 + 完整内嵌元数据，脱离 App 也是一份规整的本地曲库
5. **苹果生态集成**：Siri 点歌、ShazamKit 识曲、AirPlay、iCloud 同步、锁屏/CarPlay 控件

---

## 构建与使用

### 构建

```bash
# iOS 模拟器
xcodebuild -project walkman.xcodeproj -scheme walkman \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Mac (Catalyst)
xcodebuild -project walkman.xcodeproj -scheme walkman \
  -destination 'platform=macOS,variant=Mac Catalyst' build
```

要求 Xcode 26（iOS 26 SDK）。`walkman/Resources/user-api-preload.js` 是脚本协议桥，**不可删改**。

### Mac DMG 打包

```bash
bash dmg/build-dmg.sh
```

优先使用放在 `build/dmg/walkman.app` 的 Developer ID 签名版，否则本地 Release 编译兜底；背景图/图标由 `dmg/make-background.swift`、`dmg/make-icns.swift` 生成。未做公证，接收方首次打开需在"系统设置 → 隐私与安全性"手动放行。

### 首次使用

1. **导入音源**：设置 → 自定义音源，支持 URL / 粘贴脚本 / 选择脚本文件三种方式导入 lx-music v4 兼容脚本（脚本需自备，App 不内置任何音源）
2. **搜歌即播**：搜索页输入歌名/歌手/歌词；或逛歌单广场、排行榜
3. **导入歌单**：资料库 → 导入歌单，粘贴酷我/酷狗/QQ/网易云的歌单分享链接
4. **偏好音质**：设置中选择（如"臻品母带"），实际按歌曲可用性自动就近匹配

历史下载文件如需迁移到新的目录/命名规则，运行 `scripts/migrate-downloads.swift`（仅 Mac 需要）。

---

## 目录速览

| 路径 | 说明 |
|---|---|
| `walkman/` | 主源码（iPhone UI + 全部业务逻辑） |
| `walkman/iPad/` | iPad 专属布局（侧栏、底栏、黑胶播放页…） |
| `walkman/Mac/` | Mac 状态栏/窗口控制（运行时 AppKit 桥接） |
| `walkman/Resources/` | lx 协议预加载 JS、多语言 String Catalogs |
| `docs/` | 各功能移植规格（对照 Android/TV 版行为） |
| `dmg/` | Mac DMG 打包脚本与素材 |
| `scripts/` | 一次性迁移脚本 |

---

## 免责声明

本项目仅供技术学习与研究。App 不内置、不存储、不分发任何受版权保护的音频内容；所有内容解析均由用户自行导入的第三方脚本完成，产生的版权责任由使用者自行承担。请支持正版音乐。
