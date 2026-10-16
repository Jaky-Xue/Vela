# 移植映射表

Aira Browser 3.7.4 → Vela 的逐模块对照。

**读法**：左列是上游 Aira 的路径（相对 `aira-browser-3.7.4/`），右列是 Vela 的路径。中间的说明写清楚这是**等价实现**、**部分实现**，还是**刻意偏离**。

---

## 总量

| | Aira 3.7.4 | Vela |
|---|---|---|
| 语言 | ArkTS (`.ets`) | Swift 5 |
| 文件数 | 1,727 | 47 |
| 代码行数 | 565,081 | 16,340 |
| UI 框架 | ArkUI（声明式） | SwiftUI |
| 状态管理 | `@State` / `@Provide` / `@Observed` + 模块级单例 | `@Published` / `@EnvironmentObject` + 组合根 |
| 持久化 | ArkData `relationalStore`（SQLite） | 系统 libsqlite3 |
| 配置存储 | ArkData Preferences | `UserDefaults` |
| 网页引擎 | ArkWeb（`@kit.ArkWeb`） | `WKWebView` |
| 网络 | 自建 curl + mbedtls（C++） | WebKit 内置 |
| 广告过滤 | Rust 核心（Brave adblock 引擎） | `WKContentRuleList` |
| 下载 | 自建 C++ 引擎（NAPI） | `WKDownload` |
| 用户脚本 | ArkWeb `runJavaScript` + 原生桥 | `WKUserScript` + `WKScriptMessageHandler` |

**行数差距不是"移植不完整"的直接度量**：Aira 的 ArkTS 里有大量显式的 view model、coordinator 和布局令牌类，是 ArkUI 的状态模型逼出来的样板；SwiftUI 的观察系统能把这些收进一个视图。但差距里也确实包含未移植的功能——下面分得清楚。

---

## 分层映射

### Core / Models（类型契约）

| Aira | Vela | 说明 |
|---|---|---|
| `common/models/BrowserModels.ets` (1368 行) | `Core/Models/BrowserModels.swift` | 等价实现。`BrowserProfileId`、`BrowserSessionPrivacyMode`、`BrowserDataScope`、`BrowserDataSource`、`SyncState`、`SitePermissionKind/Rule`、`ExternalNavigationAppOpenPolicy`、`TrackingProtectionLevel`、`BrowserWebSecuritySettings`、`SecureDnsSettings`、`BrowserPreferences`。枚举的原始值逐字照抄，两边可以 diff |
| 同上（搜索部分） | `Core/Models/SearchEngineCatalog.swift` | 等价实现。11 个内置引擎的名称、URL 模板、`availabilityProbeUrl`、`resultPageShape` 全部照抄；`DEFAULT_SEARCH_ENGINE_ID = 'bing'` 和默认启用的 5 个引擎也一致 |
| `common/models/HistorySyncModels.ets` | `Core/Models/HistoryModels.swift` | 等价实现。`HistoryTransition` 用 Chromium 的事件类型词汇表；`HistoryUrl` / `HistoryVisit` 字段对应 `history_urls` / `history_visits` 全部列。`HistoryUrlNormalizer` 是**刻意实现**：Aira 的归一并散落在写入路径里，Vela 抽成一个可测的纯函数，哈希用 FNV-1a 而不是 Swift 的 `hashValue`（后者按进程加盐，会让唯一索引失效） |
| 同上（书签部分） | `Core/Models/BookmarkModels.swift` | 等价实现。`BookmarkNodeType` / `BookmarkRootRole` / `BookmarkStorageScope` 照抄。**偏离**：多了 `reading_list` 这个 root role，原始值是 Aira 树里没有的，为的是将来导出时仍能从 `other` 根往返 |
| 同上（广告过滤部分） | `Core/Models/AdBlockModels.swift` | 等价实现。`AdBlockCustomRuleSourceType`、`AdBlockResourceType`、`AdBlockSiteException`、`AdBlockStats`、`AdBlockDailyProtectionActivity`、`ManualElementHide*` 全部对应。订阅目录照抄 `AdBlockThirdPartyRuleSourceCatalog.ets` |
| `common/models/OfflinePageModels.ets` | — | 类型未移植（表结构已移植，见下） |
| `common/models/NovelBookshelfSyncModels.ets` | — | 未移植（小说模式） |
| `common/models/MembershipModels.ets` | — | 未移植（会员是 Official 分发能力） |
| `common/models/WallpaperModels.ets` | — | 未移植（壁纸） |
| `core/tabs/TabManager.ets`（状态部分） | `Core/Models/TabModels.swift` | 等价实现。`BrowserTabState` 的用户可见字段全在：`title`、`url`、`isHome`、`pinned`、`muted`、`audible`、`lastGoodUrl`/`lastGoodTitle`、`lastDiscardReason`、`lastCrashReason`、`lastRestoreReason`、`scrollOffsetY`、`privacyMode`、`dataScope`、`openerTabId`、`openSource`。**偏离**：`TabRuntimeState` 从 Aira 的 7 态收到 5 态——ArkWeb 的 Web 节点必须显式创建和销毁，`WKWebView` 是普通对象，WebKit 自己管内容进程，所以 `materializing` / `discarding` 这类中间态没有对应物 |
| `features/userscripts/UserScriptMetadataModels.ets` | `Core/Models/UserScriptModels.swift` | 等价实现。`UserScriptRunAt` 的 6 个取值、`UserScriptGrant` 的 39 个权限名、`InstalledUserScriptState` 的全部字段照抄。**Vela 新增**：`UserScriptGrant.isSupportedByVela`，用来在详情页标注哪些权限在 iOS 上不可用（见下） |

### Core / 逻辑

| Aira | Vela | 说明 |
|---|---|---|
| `core/tabs/TabManager.ets` (1178 行) | `Core/Tabs/TabManager.swift` | 等价实现。新建/关闭/切换/移动/固定、钉住的标签页排在最前、关闭最后一个标签时建一个新的 home 标签（对应 `BrowserHomeTerminalBackPlan`）、最近关闭列表上限 25、按 `openerTabId` 决定关闭后选哪个标签（对应 `BrowserParentTerminalBackPlan`）。**偏离**：Web 视图池策略——Aira 用 `BrowserMaterializationPolicy` 管 ArkWeb 节点，Vela 用 `maximumLiveWebViews = 6` + LRU 回收（钉住的最后回收）+ `didReceiveMemoryWarning` 全清后台 |
| `core/browser/BrowserWebTabsController.ets` | 同上 | 合并进 `TabManager`（Web 视图池的 `ensureWebView` / `discardWebView`） |
| `core/browser/BrowserMemoryPressureCoordinator.ets` | `TabManager.handleMemoryPressure()` | 等价实现 |
| `core/web/BrowserHistoryApiBridge.ets` | `Services/Web/WebPageScripts.historyApiBridge` | **逐行移植**。注入脚本钩 `pushState` / `replaceState` / `popstate` / `hashchange` 并回传原生；"URL 没变就不报" 的守卫也照抄了——SPA 每次渲染都归一化 URL，少了这个守卫会每帧触发一次假导航 |
| `services/web/*`（60+ 个 Service） | `Services/Web/BrowserWebCoordinator.swift` | **合并**。Aira 因为 ArkWeb 的回调粒度把网页控制拆成 60 多个 service；`WKNavigationDelegate` + `WKUIDelegate` 两个协议就覆盖了同一片面积，所以合成一个协调器。覆盖面见下表 |
| `BrowserWebNavigationInterceptionCoordinator.ets` | 同上，`decidePolicyFor navigationAction` | 等价实现 |
| `BrowserNewWindowCoordinator.ets` | 同上，`createWebViewWith` + `target == nil` 分支 | 等价实现（`target="_blank"` 与 `window.open` 都变成新标签页） |
| `ExternalNavigationPolicyService.ets` + `BrowserUnifiedLinkApplicationCoordinator.ets` | 同上，`handleExternalScheme` | 等价实现。阻止/询问/允许三级 + 站点例外 + "记住" |
| `BrowserWebCapabilityPromptApplicationCoordinator.ets` | 同上，`requestMediaCapturePermissionFor` | 等价实现。按 `SitePermissionDefaultSettings` 自动应答或弹窗 |
| `BrowserFaultClassifier.ets` | 同上，`describe(error:)` + `handleLoadFailure` | 等价实现。区分"取消"（不报错）和真实失败；区分内容进程崩溃（重载）和加载失败（报错页） |
| `BrowserUserAgentService.ets` | `TabManager` 的 `BrowserUserAgent` | **偏离**：Aira 从鸿蒙 `deviceInfo` 拼 UA；iOS 侧不能这样拼。默认**不给 web view 设置 `customUserAgent`**，也就是让 WebKit 发系统自己的串（和 Safari 完全一致）。早先的实现自己拼串，把 `Version/17.0` 和 `Mobile/15E148` 写死，于是在更新的 iOS 上每个网站被告知这是 Safari 17，会检查版本的网站就直接回「浏览器版本太低」——引擎是新的，只有标签是旧的。桌面版是刻意的例外：为了让按平台标识分流的网站给桌面布局，平台标识必须是 Mac；但它由当前系统的版本号拼出，`Version/` 和 `AppleWebKit/` 都描述真实运行的引擎，只有平台标识和 `Mobile/` 标记是假的 |
| `BrowserFaviconCoordinator.ets` + `data/siteicons` | `UI/Theme.swift` 的 `SiteIconView` | **刻意偏离**。`site_icons` 表已移植，但 iOS 上读不到页面的 favicon，所以在拿到真图标前用域名首字母 + FNV-1a 派生的稳定颜色。用 FNV-1a 而不是 `hashValue` 的理由和上面一样：站点颜色不该每次启动都变 |

### Core / 广告过滤

| Aira | Vela | 说明 |
|---|---|---|
| `services/adblock/AdBlockNativeAuthorityEngineService.ets` + `cpp/rust/aira_adblock_core` | `Core/AdBlock/AdBlockEngine.swift` | **架构性偏离**。Aira 在自己的网络栈里评估每条子资源请求；iOS 上拦截必须表达成 `WKContentRuleList`，由 WebKit 在自己的进程里执行。引擎不同，**规则来源和设置模型相同** |
| `services/adblock/AdBlockPolicyService.ets` | `Core/AdBlock/AdBlockRuleCompiler.swift` | **新实现**。Adblock Plus 语法 → WebKit 规则 JSON 的编译器。支持 `||domain^`、`|url|`、子串、`@@` 例外、`##selector` 元素隐藏、`$script,image,third-party,domain=` 选项。不支持的语法（正则规则、`$csp`、`$rewrite`、`$removeparam`、`##+js(...)`、`:has-text()` 等扩展选择器）**会计数并上报**，不静默丢弃 |
| `features/adblock/AdBlockBuiltInRuleSource.ets` | `Core/AdBlock/AdBlockBuiltInRules.swift` | 等价实现。三个内置来源 id 照抄（`system-built-in-adblock-rules`、`system-smooth-mode-adblock-rules`、`system-app-promotion-banner-rules`）。**偏离**：Aira 从自己的引擎生成规则文本，Vela 内置一份精选规则体，因为内置列表要留出 WebKit 15 万条的上限给用户订阅 |
| `services/adblock/AdBlockCosmeticRuntimeScriptService.ets` | `Services/Web/BrowserWebCoordinator.makeConfiguration` | 等价实现（注入 `<style>` 而不是走规则列表，因为手动隐藏是按站点动态的） |
| `services/adblock/AdBlockNativeAuthorityMetrics.ets` + `AdBlockPingRuntimeScriptService.ets` | `AdBlockEngine.cosmeticCountingScript` | **刻意缩减**。WebKit **不报告**被拦截的请求数，也没有 API 能拿到。所以 Vela **不编造**这个数字：只显示规则条数和实际被隐藏的元素数（后者 Vela 自己注入，能精确统计）。这是有意的诚实妥协，设置页里写明了 |
| `services/adblock/ManualElementHideService.ets` + `ElementInspectionRuntimeScriptService.ets`（在 `core/web/`） | `WebPageScripts.elementPickerScript` | 等价实现。生成稳定选择器：优先 id，其次类名组合（**跳过 `css-1x2y3z` 这类构建产物类名**，因为每次发版都变），最后结构路径 |

### Core / 用户脚本

| Aira | Vela | 说明 |
|---|---|---|
| `features/userscripts/UserScriptMetadataModels.ets`（解析部分） | `Core/UserScripts/UserScriptParser.swift` | 等价实现。元数据块解析，对未知 `@key` 宽容（为其他管理器写的脚本也该能装），对两件事严格：缺 `@name`、既无 `@match` 也无 `@include` |
| `features/userscripts/UserScriptRuntimeModels.ets` | `Core/UserScripts/UserScriptMatcher.swift` | 等价实现。**`@match` 和 `@include` 是两套语法，都实现了**——`@match` 走 Chrome 扩展的严格模式（`*.example.com` 匹配子域但不匹配裸域），`@include` 走宽松 glob 和 `/正则/`。glob 匹配是手写的两指针回溯，不用正则，避免用户提供的模式在每次导航上触发灾难性回溯 |
| `features/userscripts/UserScriptNativeBridgeModels.ets` | `Core/UserScripts/UserScriptInjector.swift` | **等价语义、不同机制**。`GM_getValue` 在脚本里是同步的，但 `WKScriptMessageHandler` 是异步的。解法是所有 iOS 用户脚本管理器都在用的那个：document-start 时把整个值存储快照进页面，读走快照，写穿透回原生。同一个 tick 里的写后读因此能拿到自己刚写的值 |
| 同上（权限部分） | 同上 + `Core/Models/UserScriptModels.swift` | **Vela 新增**：`isSupportedByVela`。可用的：值存储、样式、日志、剪贴板、通知、菜单命令、`unsafeWindow`。**不可用的**：`GM_xmlhttpRequest`、`GM_fetch`、`GM_download`、`GM_openInTab`、`GM_cookie*`、`GM_getTab`/`saveTab`/`getTabs`——WebKit 不给注入脚本任何特权网络或 Cookie 接口。这些接口仍然存在但会返回 null 并记一条日志，让脚本的 `feature detect` 走降级分支而不是抛 `ReferenceError`。详情页会明确标注 |
| `services/userscripts/*`（运行时调度） | 合并进 `BrowserWebCoordinator.makeConfiguration` | 等价实现 |
| `features/userscripts/UserScriptValueModels.ets` | `Data/Repositories/UserScriptRepository.swift` | 等价实现。**偏离**：Aira 存在 preferences 文档里（ADR 0038），Vela 用表，这样 `GM_setValue` 是单行写入而不是整文档读改写 |

### Core / 阅读模式

| Aira | Vela | 说明 |
|---|---|---|
| `third_party/mozilla-readability` + `services/reader/ReaderExtractionService.ets` | `Core/Reader/ReaderModeService.swift` | **重新实现**。上游那个 `third_party/mozilla-readability` 目录里**只有 LICENSE.md 和 README.md，没有脚本**——没有可搬运的代码。所以 Vela 自己实现了同一套评分算法：按文本长度、逗号数、链接密度给段落打分，分数记给父节点和祖父节点，选得分最高且为正的祖先。链接密度这一项是索引页不会胜出的原因 |
| `services/reader/ReaderEligibilityService.ets` | 同上，`isLikelyArticle` | 等价实现（按 URL 形态判断） |
| `core/browser/ReaderModeApplication.ets` | `Features/Reader/ReaderView.swift` | **刻意偏离**。Aira 用 ArkWeb 模板渲染；Vela 用 `WKWebView` + 按用户字号和配色生成的样式表渲染提取出的 HTML——保留标题、列表、图、表的结构，同时让动态字体和旁白可用 |

### Data

| Aira | Vela | 说明 |
|---|---|---|
| `data/database/BrowserDatabase.ets` (6877 行) | `Data/BrowserSchema.swift` + `Data/BrowserDatabase.swift` | **表结构照抄**。`browser_schema_state`、`bookmark_roots`、`bookmark_nodes`、`bookmark_orders`、`history_urls`、`history_visits`、`search_query_history`、`offline_pages`、`tab_sessions`、`recently_closed_tabs`、`site_icons` 的列名、类型、默认值、索引全部保留，schema 版本号也从 Aira 的 7 继续往上（Vela 是 8），这样将来要导入一份 Aira 数据库能直接比版本号 |
| 同上（同步相关表） | — | 未移植：`bookmark_sync_links_g2`、`history_sync_*`（6 张）、`huawei_history_remote_head_v1`、`shortcut_scenarios`、`shortcuts`、`import_batches`。这些服务于 Aira 的云端同步域，Community 源码树里本来就不包含 |
| ArkData `relationalStore` 配置 | `Data/SQLite/SQLiteDatabase.swift` | **新实现**。系统 libsqlite3 的轻量封装。WAL + `synchronous=NORMAL`，单串行队列——和 `relationalStore` 在默认安全级别下的行为一致 |
| `data/repositories/*`（书签） | `Data/Repositories/BookmarkRepository.swift` | 等价实现。**关键保留**：删除是盖 `deleted_at` 墓碑，从不删行——ADR 0009（"平台同步不拥有书签冲突"）依赖这个，墓碑必须活得比本地删除更久，同步端才能观察到 |
| 同上（历史） | `Data/Repositories/HistoryRepository.swift` | 等价实现。每次写入都接收 `BrowserDataBoundary` 而不是自己读标签页的隐私模式——这是 ADR 0065（"无痕浏览用效果策略"）的移植：无痕在仓库层抑制写入，调用方没法忘记检查。`from_visit_id` 链和访问时长回填也移植了 |
| 同上（搜索记录） | `Data/Repositories/SearchHistoryRepository.swift` | 等价实现。三种归一化（原样 / 小写 / 去空白）都存，让建议匹配不做逐次排序 |
| 同上（标签会话 + 最近关闭） | `Data/Repositories/TabSessionRepository.swift` | 等价实现。**偏离**：不存 `web_state_path`、`form_draft`、`page_runtime_signals`——`WKWebView` 没有可序列化的网页状态，iOS 靠重新导航恢复，存了也没有读者 |
| `data/downloadv2/DownloadV2RecordStore.ets` | `Data/Repositories/DownloadRepository.swift` | **偏离**：Aira 把任务记录序列化进 preferences 字符串，Vela 用表——`WKDownload` 的 resume data 是不透明二进制，preferences 是错的容器。记录字段本身（`DownloadV2TaskEntity`）对应 |
| `app/bootstrap/*` | `App/AppEnvironment.swift` | **重新组织**。Aira 在模块作用域里接线让协调器互相可达；Vela 显式传环境，因为 SwiftUI 视图会被反复重建，隐式全局会让依赖图在调用点不可见 |

### Services

| Aira | Vela | 说明 |
|---|---|---|
| `services/bookmarks/*` | `Services/Bookmarks/BookmarkService.swift` | 等价实现。每次改动后重读而不是打补丁——慢一点，但树不可能和数据库漂移，而同样的行正是 WebDAV / Personal Server 要推的东西 |
| `services/history/*` + `core/browser/BrowserHistoryVisitPersistenceCoordinator.ets` | `Services/History/HistoryService.swift` | 等价实现。按标签页维护"上一个访问 id"链，这样在两个标签间切换不会把时长算错 |
| `services/downloadv2/*` + `domain/downloadv2/*` + `cpp/download_core.cpp` | `Services/Downloads/DownloadService.swift` | **引擎替换**。状态机、状态值、失败文案、文件名去重（`report (1).pdf`）、断点续传全部移植；分片多连接和下载队列没有 iOS 对应物，未移植。`download_core.cpp`（54K）和 `download_napi.cpp` 整体不需要 |
| `app/pages/SettingsCenterPage.ets` + `core/settings/*`（74 个文件） | `Services/Settings/SettingsService.swift` + `Features/Settings/*` | **合并**。Aira 每个设置域一个 view model 和一个页面；Vela 一个设置服务 + 几个页面。已移植的域：搜索引擎、外观、广告过滤、用户脚本、跟踪保护、安全 DNS、网站权限、外部跳转、清除数据、通用、下载、网页标识、关于 |

### UI

| Aira | Vela | 说明 |
|---|---|---|
| `app/pages/BrowserShellPage.ets` + `BrowserShellViewModel.ets` + `BrowserShell*Coordinator.ets`（约 20 个） | `App/BrowserShellView.swift` | **合并**。ArkUI 的观察系统扛不住一个组件里放这么多状态，所以 Aira 拆了；SwiftUI 的 `@Published` 扛得住。但**组合规则保留了**：外壳拥有"哪个界面可见"，工具栏/地址栏/浮层是那个状态的纯函数 |
| `BrowserBottomPanelActionCatalog.ets` 等 | `UI/BottomToolbarView.swift` | 等价实现。动作身份和默认顺序照抄；ADR 0064（"底部工具栏使用设备本地交互配置"）里的排序界面未做，但存下来的顺序会生效，所以将来加排序页不需要数据迁移 |
| `BrowserSearchSuggestionCoordinator.ets` + `BrowserAddressDisplayCoordinator.ets` + `AddressDisplayFormatter.ets` + `BrowserRootAddressInputSessionCoordinator.ets` | `UI/AddressBarView.swift` | 等价实现。建议按固定优先级合并四路来源，顺序和 Aira 一致：直接网址 → 已打开标签页 → 书签 → 历史/搜索记录。远程建议默认关闭（Aira Community 不把按键发给搜索服务商，Vela 也不） |
| `BrowserBottomChromeScrollCoordinator.ets` | `BrowserShellView.handleScroll` | 等价实现。向上滚无条件恢复（按距离成比例地恢复会让折叠工具栏感觉是坏的）。**偏离**：用对 `contentOffset` 的 KVO 而不是页面注入脚本——偏移是视图的属性，直接观察更简单，也不受"页面吞掉滚动事件"影响 |
| `BrowserPageFindCoordinator.ets` | `WebPageScripts.findInPageScript` | **重新实现**。用 `TreeWalker` 遍历文本节点，不用 `window.find()`——WebKit 的 JS 上下文里没暴露 `window.find`，而且选区在长页面上滚动后不保留 |
| `core/browser/tabsOverview/*` | `Features/Tabs/TabsOverviewView.swift` | **偏离**。Aira 用 `BrowserTabPreviewCaptureService` 抓页面预览；Vela 用标题卡片，因为每个标签页抓一次快照等于一次完整渲染，而 iOS 的标签切换器被期望是瞬间打开的——迟一秒到的预览比立刻就在的标题更糟。隐私分离保留：普通和无痕永不出现在同一个列表 |
| `features/newtab/*` + `BrowserHomePresentationViewModel.ets` | `Features/Home/NewTabHomeView.swift` | **部分**。原生新标签页（搜索 + 常用网站 + 最近关闭）已做。ADR 0044（"主页快捷方式独立于书签"）用另一种方式满足：快捷方式从历史按访问次数派生，省掉整个第二存储。ADR 0046（自定义主页）未移植——没有 `customhome` 运行时 |
| `ThemePaletteSettingsPage.ets` + `features/theme/palettes/*` | `UI/Theme.swift` | 等价实现（色板是值不是资源目录颜色，所以能在运行时换）。色板从 Aira 的目录收敛到 4 个在两种动态字体极值下都成立的 |
| `app/pages/BookmarkManagerPage.ets` 等约 84 个页面 | `Features/*/` | 部分。已做：书签、历史、下载、设置及其子页、标签页、阅读、用户脚本。未做：小说书架、离线页面、密码、同步、翻译、代理、跨端标签、法律文档 |

---

## 刻意偏离清单

这些是**有意**和上游不同的地方，不是遗漏。

| 偏离 | 原因 |
|---|---|
| 广告过滤引擎：Rust 核心 → `WKContentRuleList` | iOS 不允许第三方浏览器内核，也无法拦截子资源请求。规则**语法**是子集，不支持的条目会计数上报而不是静默丢弃 |
| 用户脚本执行：ArkWeb 原生桥 → `WKUserScript` | 同上。导致特权 GM_ 接口不可用，已在类型层标注并在界面说明 |
| 下载：自建 C++ 引擎 → `WKDownload` | ArkWeb 没有下载 API 才需要自建；iOS 有。分片多连接无对应物，断点续传有 |
| 拦截计数：不显示 | WebKit 不报告。宁可显示一个准确的小数字（实际隐藏的元素数）也不显示一个编造的大数字 |
| 阅读模式：ArkWeb 模板 → 原生 `WKWebView` + 生成样式表 | 保留 HTML 结构，同时让动态字体、旁白、文本选择工作 |
| 标签页预览：截图 → 标题卡片 | 快照成本 vs 切换器的瞬间感 |
| favicon：站点图标缓存 → 首字母 + 稳定派生色 | iOS 读不到页面的 favicon |
| 删除书签：软删除墓碑 | **这条和 Aira 完全一致**，单独列出是因为它容易被误当成"没删干净" |
| 无痕写入：`BrowserDataBoundary` 参数 | **和 ADR 0065 一致**。列出是因为 Vela 把检查从调用方移到了仓库层，比 Aira 更强制 |
| 新增表：`downloads`、`user_scripts`、`user_script_values`、`adblock_rule_sources` | Aira 把这些放 preferences；Vela 放表，因为涉及二进制 blob 和需要按键原子写 |
| 新增 root role：`reading_list` | 用 Aira 树里没有的原始值，保证将来导出仍能从 `other` 根往返 |

---

## 未移植清单

按原因分类。

**平台能力缺失（iOS 上做不成或应换实现）**

- 应用内代理（`AppProxy*`）：iOS 上要走 `NetworkExtension`，是独立的工程和签名流程
- 密码保险箱（`arkweb_official_vault`）：应直接用系统钥匙串 / `ASPasswordCredential`
- 华为账号 / 华为云空间 / IAP：Official 分发能力，Community 源码树不含

**体量或优先级**

- 跨端同步（WebDAV / Personal Server / Aira-sync 扩展）：**数据模型全部移植了**（`sync_state`、`origin_id`、`device_id`、`last_modified_by` 都在），缺的是客户端同步调度
- 小说模式与书架（`core/novel`、`features/novel`）
- 网页翻译（`services/translation`）：正文提取脚本已移植，服务商配置与调用未接
- 视频接管（`features/youtubeTakeover`、`features/videoAssistant`）
- 离线页面保存与查看（表已移植）
- 自定义主页运行时（ADR 0046）
- 桌面/平板形态：双栏设置、键盘快捷键、书签栏、纵向标签、窗口管理（`BrowserLargeScreen*` 约 40 个文件）
- 底部工具栏自定义排序界面
- 站点图标抓取与缓存维护

**按 ADR 本来就该分开的**

- ADR 0017/0018 的华为空间同步域
- `import_batches`：Chrome 书签导入的批次记录

---

## 一句话总结

结构、数据契约和功能语义是**照着 Aira 移植**的，可以逐文件对照。网页引擎、过滤引擎和下载引擎是**照着 iOS 重写的**，因为 iOS 只允许 WebKit——这也直接决定了哪些功能根本搬不过来。凡是做不到的，都在 `README.md` 和应用的「关于」页里写明了，没有藏起来。
