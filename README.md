# Vela — Aira Browser 的 iOS 移植

这是把 **Aira Browser 3.7.4（鸿蒙 NEXT 客户端）** 重写成 iOS 原生应用的工程。

**Vela 不是 Aira 的官方产品**，也不是 Aira 项目赞助或认证的版本。它是一个独立的移植，按 Aira 的商标政策使用了自己的名称、包名和视觉标识，并按 GPL-3.0 保留上游署名。

---

## 先说清楚这是什么

`aira-browser-3.7.4.zip` 里**没有**任何可以直接转成 iOS 应用的东西。它是：

| 项目 | 事实 |
|---|---|
| 内容 | Aira Browser 3.7.4 完整源码，GPL-3.0 |
| 技术栈 | 鸿蒙 ArkTS / ArkUI，hvigor 构建，产物是 HAP |
| 体量 | 1727 个 `.ets` 文件，565,081 行 ArkTS |
| 原生层 | C++ 自建 curl + mbedtls 网络栈、NAPI 模块、Rust 广告过滤核心 |
| 平台绑定 | `@kit.ArkWeb`、`@kit.AbilityKit`、`@kit.ArkData`、华为 AccountKit 等 |

鸿蒙的 ArkTS/ArkUI 和 iOS 的 Swift/SwiftUI 之间不存在转换器。**Vela 是重写**：保留 Aira 的分层结构、数据表结构和功能语义，在 iOS 上重新实现。可对照的功能写了逐文件映射（见 `PORTING.md`）。

一个绕不开的架构差异：**iOS 不允许第三方浏览器内核**。Aira 在鸿蒙上跑自己的网络栈和过滤引擎，Vela 只能用 WebKit（`WKWebView`）。所以 Vela 的广告过滤换成了 `WKContentRuleList`，用户脚本换成了 `WKUserScript`，下载交给 `WKDownload`。这不只是换 API，它决定了哪些功能能移植、哪些不能——`PORTING.md` 里逐条列了。

---

## 已实现的功能

**浏览**
- 多标签：新建、关闭、切换、固定、拖拽排序、最近关闭、会话恢复
- 后台标签页内存回收（超过 6 个 live `WKWebView` 时按 LRU 回收，钉住的最后回收）
- 地址栏：URL 与搜索词自动判别、直接网址、局域网地址（`localhost`、IPv4、IPv6 字面量）
- 地址栏建议：网址 → 已打开标签页 → 书签 → 搜索记录 → 历史记录 → 搜索，按此优先级合并
- 自定义主页（原生新标签页：搜索、常用网站、最近关闭）
- 页面内查找（自己实现的 DOM 遍历高亮，不依赖 `window.find`）

**隐私与安全**
- 无痕模式：独立 `WKWebsiteDataStore`，退出时清空；可要求生物识别解锁
- 跟踪保护：三级，映射到 WebKit 的第三方 Cookie 策略
- 安全 DNS：模式与服务器目录（含 5 个内置 DoH 服务商）
- 网站权限：相机 / 麦克风 / 位置 / 运动方向 / 剪贴板，默认行为 + 站点级覆盖
- 外部应用跳转控制：阻止 / 询问 / 允许，带站点例外（这是网页拉起 App 的常见骚扰源）
- 清除浏览数据：分项可控

**网页能力**
- 广告与内容过滤：Adblock Plus 语法 → `WKContentRuleList` 编译器，支持内置规则 + 远程订阅 + 自定义规则 + 站点白名单 + 元素隐藏
- 手动隐藏页面元素：元素选择器（生成稳定的 CSS 选择器，会跳过 `css-1x2y3z` 这类每次发版都变的类名）
- 用户脚本：元数据块解析、`@match` / `@include` 双语法匹配、GM_* 值存储、菜单命令、元数据编辑
- 阅读模式：可读性评分提取正文，原生阅读界面
- 网页标识：桌面版 / 手机版 / 自定义 User-Agent
- 网页翻译的正文提取脚本已移植（接口层未接翻译服务，见下）

**数据**
- SQLite，表结构照抄 Aira：书签（节点 + 顺序分离）、历史（URL + 访问分离）、搜索记录、离线页面、标签会话、最近关闭、站点图标
- 书签：文件夹树、软删除墓碑、拖动排序、移动、搜索、文件夹选择器（排除自身的子树）
- 历史：按天分组、三种删除范围（单条 / 整站 / 整天）、撤销、保留期自动清理

---

## 没实现的功能

诚实清单。这些是 Aira 有、Vela 没有的：

| 功能 | 原因 |
|---|---|
| 跨端同步（WebDAV / Personal Server） | 数据模型已移植（`sync_state`、`origin_id`、`device_id`、同步表结构都在），客户端的同步调度没写 |
| 网页翻译 | 正文提取脚本已移植；翻译服务商配置与调用未接 |
| 小说模式与书架 | 未移植 |
| 视频接管（`youtubeTakeover` / `videoAssistant`） | 未移植 |
| 离线页面保存 | 表结构已移植，保存与查看未实现 |
| 自定义主页（用户自己的 HTML） | 新标签页是原生的，没有 `customhome` 运行时 |
| 密码保险箱 | 未移植（iOS 上应直接用系统钥匙串 / `ASPasswordCredential`） |
| 应用代理 | 未移植（iOS 上应走 `NetworkExtension`，是独立工程） |
| 扩展同步（Chrome / Firefox） | 依赖 Personal Server，未移植 |
| 桌面模式（平板双栏、键盘快捷键、书签栏） | 只做了手机布局 |
| 底部工具栏自定义排序 | 动作目录与默认顺序已移植，排序界面未做 |
| 华为账号 / 华为云空间 / IAP | Official 分发能力，Community 源码树里本来就不包含 |

**另外一个平台限制**：iOS 上访问 `http://` 非 HTTPS 站点需要 `NSAllowsArbitraryLoads`，Vela 没有开这个开关。它跟随 WebKit 的默认策略，只在你显式导航到 HTTP 地址时才加载。

---

## 编译

**需要 macOS + Xcode 16 或更新版本**。iOS 应用只能在 macOS 上编译，这一步没有替代方案。

```bash
open VelaBrowserIOS/Vela.xcodeproj
```

在 Xcode 里：

1. 选中 `Vela` target → `Signing & Capabilities`
2. 勾选 `Automatically manage signing`，选择你的 Team
3. 如果 `org.vela.browser.ios` 已被占用，改成你自己的包名
4. 连上 iPhone，选为运行目标，⌘R

没有 Mac 的话见 **[`BUILD_WITHOUT_MAC.md`](BUILD_WITHOUT_MAC.md)** —— 有两种可行路径（GitHub Actions 的 macOS runner 出包，或租用云 Mac）。

工程用的是 Xcode 16 的**文件系统同步组**（`PBXFileSystemSynchronizedRootGroup`）：往 `Vela/` 目录里加 `.swift` 文件会自动被编译，不需要改 `project.pbxproj`。这样工程文件不容易因为手工维护 UUID 而损坏。

### 部署目标

iOS 17.0。用到的较新 API：`WKDownload.progress`（iOS 17）、`MainActor.assumeIsolated`（Swift 5.9）、`ContentUnavailableView`（iOS 17）、`.quickLookPreview`（iOS 14）。

---

## 工程结构

分层对齐 Aira，目录名尽量保持可对照：

```
Vela/
  App/          VelaApp、AppEnvironment（组合根）、BrowserShellView
  Core/
    Models/     类型定义，逐条对应 Aira 的 common/models/*.ets
    Tabs/       TabManager（对应 core/tabs/TabManager.ets）
    AdBlock/    规则编译器与引擎
    UserScripts/解析、匹配、注入、GM_ 桥
    Reader/     正文提取
  Data/
    SQLite/     轻量 SQLite 封装
    Repositories/  书签、历史、搜索记录、下载、用户脚本、会话
  Services/
    Web/        配置装配、导航委托、页面脚本、Web 视图宿主
    Bookmarks/ History/ Downloads/ Settings/
  Features/     各功能界面
  UI/           主题、地址栏、工具栏
```

`AppEnvironment` 是组合根，一次性构造所有服务并通过 SwiftUI 环境注入。Aira 用 HarmonyOS 的 `AppStorage` 和模块级单例做这件事；SwiftUI 没有等价容器，而且视图会被反复重建，隐式全局会让依赖关系在调用点不可见。

---

## 与上游的对应关系

`PORTING.md` 里有逐模块的映射表，包括每个 Swift 文件对应哪个 `.ets` 文件、哪些地方是等价实现、哪些地方是刻意偏离及原因。

## 许可

GPL-3.0。见 `LICENSE-NOTICE.md`。

上游项目：[Aira Browser](https://github.com/mason173/aira-browser)
