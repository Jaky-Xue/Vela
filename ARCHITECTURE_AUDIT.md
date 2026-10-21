# Vela 架构审计（阶段 A）

- 审计日期：2026-10-21
- 基线提交：`3ed4197 Vela 3.9.0`（`main`，工作区干净，无未提交修改、无 stash）
- 版本：`CFBundleShortVersionString = 3.9.0`，`IPHONEOS_DEPLOYMENT_TARGET = 17.0`，Swift 5 语言模式
- 审计性质：**只读静态审计**。未修改任何应用源码、工程配置或用户数据。

> 本报告只描述源码中能够证明的事实。凡是没有运行证据的结论，都标注了“潜在风险”或“待验证假设”，
> 不把推断写成已发生的崩溃或已测得的性能数字。缺陷分级定义见 `RISK_REGISTER.md`。

---

## 1. 审计方法与限制

本轮实际做了：

1. 检查 Git 状态、分支、最近提交，确认工作区干净（`git status --porcelain` 为空）。
2. 通读全部 130 个应用 Swift 文件与 15 个测试文件中的核心路径，共 43,083 + 3,989 行。
3. 按“入口 → 组合根 → 标签页 → WebKit 委托 → 业务服务 → 持久化”顺序追踪调用链。
4. 对跨模块写入、异步回调、闭包捕获、资源释放点做定向检索（`Task`、`try?`、KVO、通知、单例、全表查询）。
5. 将 `ARCHITECTURE.md`、`PORTING.md`、`README.md` 的声明与源码逐条对照。

本轮**没有**做、也不能做：

- 没有编译、没有运行 App、没有跑单元测试。本机是 Windows，没有 Swift/Xcode 工具链；可编译性只能由
  `.github/workflows/build-ios.yml` 在 macOS runner 上验证（构建与测试是两个独立 job）。
- 没有真机或模拟器性能数据、内存曲线、卡顿采样、崩溃日志。
- 没有联网验证任何第三方站点行为。

因此本报告中的“缺陷”均指**源码与平台契约足以确认**的问题；“风险”指有明确代码路径但未在设备上观察到的
问题。**已复现缺陷数量为 0**——这不是说系统没有缺陷，而是本轮没有可复现的运行环境。

---

## 2. 项目事实

| 项目 | 实测值 |
|---|---|
| 应用源码 | 130 个 `.swift`，43,083 行 |
| 测试源码 | 15 个 `.swift`，227 个 `test` 方法，626 条断言，3,989 行 |
| 最大文件 | `BrowserShellView.swift` 1,348 行；`DownloadService.swift` 1,160；`NovelReaderView.swift` 1,006；`TabManager.swift` 1,002；`UserScriptInjector.swift` 999；`WebPageScripts.swift` 991 |
| 分层体量 | App 3,682；Core 11,053；Data 3,264；Services 10,034；Features 10,144；UI 4,906（行） |
| 依赖 | 仅系统框架：SwiftUI/UIKit/WebKit/SQLite3/NaturalLanguage/LocalAuthentication/Security/Network/CryptoKit。无第三方 Swift 依赖 |
| 构建 | Xcode 16 文件系统同步组（objectVersion 77），新增文件无需改 `project.pbxproj` |
| 测试目标 | 仅有 `VelaTests`，**无 UI 测试 target** |

工程文档：`ARCHITECTURE.md`（分层说明）、`PORTING.md`（Aira 3.7.4 → Vela 映射）、
`NAVIGATION_FIX_REPORT.md`、`BUILD_WITHOUT_MAC.md`、`README.md`。

---

## 3. 实际分层与声明差异

`ARCHITECTURE.md` 声明：

> 依赖方向只有一个：**App → Features/Services → Core/Data → UI**……没有跨层回调，也没有全局单例，
> 除了 `BrowserDatabase.shared` 这一个数据库连接入口。

源码实测与该声明有四处不一致：

| 声明 | 实测 | 证据 |
|---|---|---|
| Features 依赖 Core/Services，不反向依赖 App | `Features/` 中 27 个文件通过 `@Environment(AppEnvironment.self)` 依赖 App 层的组合根，320 处 `env.*` 引用 | `grep -rl AppEnvironment Vela/Features`；`env.settings` 174 次 |
| Core 是“纯逻辑”，不出现视图/单例状态 | `Core/Tabs/TabManager.swift`、`TabPreviewStore.swift`、`NovelChapterLoader.swift`、`NovelTOCLoader.swift`、`NovelModeService.swift`、`ReaderModeService.swift`、`AdBlockEngine.swift`、`UserScriptInjector.swift` 均导入 WebKit 或 UIKit | 文件头 import |
| Core 不依赖 Data | `TabManager` 直接持有 `TabSessionRepository`（Data 层类型） | `Vela/Core/Tabs/TabManager.swift:87` |
| 只有一个 `.shared` | 另有 `BackgroundDownloadRegistry.shared` | `Vela/Core/Downloads/BackgroundDownloadRegistry.swift:21` |

此外：

- `UI/Omnibox/OmniboxViewModel.swift` 直接依赖 `TabManager`（Core）与 `SearchHistoryRepository`（Data），
  是 UI → Core/Data 的反向边。
- `PORTING.md` 的统计已过期：写的是 47 个文件 / 16,340 行，实测 130 / 43,083；写 `maximumLiveWebViews = 6`，
  源码是 8（`TabManager.swift:69`）。
- 源码注释引用了不存在的类型：`BrowserLoadingProgressCoordinator`（`TabModels.swift:435`）、
  `BrowserPrivateSessionCleanupCoordinator`（`TabModels.swift:626`、`DownloadRepository.swift:195`）。
- `Vela/CLAUDE_CODE_TASK_VelaBrowser.md`（仓库根）是 0 字节空文件。

**结论**：实际架构是“组合根 + 服务对象 + SwiftUI 观察”的合理结构，但不是文档描述的严格分层。
`AppEnvironment` 是事实上的服务定位器；Core 是“纯逻辑 + WebKit 运行时”的混合层。两者都不是缺陷本身，
但会让依赖边界随时间继续模糊（见 `RISK_REGISTER.md` R-19）。

---

## 4. 模块地图（按源码核实）

> “拥有状态”只列该模块**写**的状态。“不负责”列出容易被误放进去的职责。

### 4.1 应用入口与会话根

| 项 | 内容 |
|---|---|
| 文件 | `App/VelaApp.swift`、`App/VelaAppDelegate.swift`、`App/AppServices.swift`、`App/AppEnvironment.swift`、`App/BrowserCommands.swift` |
| 职责 | 场景生命周期；进程级服务构造一次（`AppServices.bootOnce`）；每窗口环境构造；外观、场景相位、入站 URL、内存警告；硬件键盘菜单 |
| 不负责 | 页面导航规则、SQL、页面脚本 |
| 拥有状态 | `AppServices.startupError`、`allocatedWindowCount`；每窗口 `windowId` |
| 生命周期 | `AppServices` 与进程同寿；`AppEnvironment` 与场景同寿，由 `WindowEnvironmentStore` 懒构造 |
| 协作 | 通过 SwiftUI `environment` 注入；`BrowserCommandCenter` 把 App 菜单命令转给当前窗口的 shell（`BrowserShellView.swift:372-377`） |

### 4.2 浏览器外壳

| 项 | 内容 |
|---|---|
| 文件 | `App/BrowserShellView.swift`（1,348）、`+Chrome.swift`（558）、`+PadLayout.swift`（382）、`+Presentations.swift`（245）、`+TranslationAndOffline.swift`（179） |
| 职责 | 决定当前显示哪一层（页面 / 主页 / 阅读 / 错误 / 小说 / 总览 / 扫描器）；命令栏与 iPad 顶部栏；全部 sheet/alert；地址栏提交；后退/主页/返回页面；阅读、小说、广告过滤、离线保存等动作的入口 |
| 不负责 | 不应拥有页面加载状态机、SQL、WebKit 委托 |
| 拥有状态 | 17 个 `@State` 布尔/可选值（`showTabsOverview`…`translationBarDismissed`）、阅读会话、小说会话、查找状态、滚动/键盘/安全区测量、`omnibox` |
| 生命周期 | 场景级；`.onChange(of: activeTabId)` 重置阅读、查找、chrome（`BrowserShellView.swift:412-437`） |
| 协作 | 读 `AppEnvironment` 的全部服务；调用 `TabManager`、`BrowserWebCoordinator`、`TranslationService` |

注意：外壳同时承担“显示哪一层”和一部分**业务决策**（`goHome`、`returnToPage`、`toggleAdBlock`、
`activateReaderMode`、`activateNovelMode`、`saveOfflinePage`）。这是 R-20/R-21 的来源。

### 4.3 标签页

| 项 | 内容 |
|---|---|
| 文件 | `Core/Tabs/TabManager.swift`（1,002）、`TabPreviewStore.swift`（117）、`Core/Models/TabModels.swift`（661）、`Data/Repositories/TabSessionRepository.swift`（224） |
| 职责 | 创建/关闭/激活/排序/固定标签页；最近关闭列表；WebView 池与 LRU 回收；会话快照读写；每个标签页的页面图片 |
| 不负责 | 导航策略、脚本注入、历史记录 |
| 拥有状态 | `tabs`、`activeTabId`、`webViews`、`activationOrder`、`recentlyClosed`、`previews`、`persistsSession`、`newPagePrivacyMode` |
| 生命周期 | 每窗口一个；`webViews` 上限 8（`TabManager.swift:69`），仅在 `activateTab` 中执行上限（`:386`） |
| 协作 | 通过 `BrowserWebViewConfigurationProviding` 协议向 coordinator 要配置；持有 `TabSessionRepository` |

`BrowserTabState` 是 `@Observable` 引用类型，字段分为两类：运行时状态（`runtimeState`、`loadState`、
`estimatedProgress`、`canGoBack`…）与持久化字段（`TabRecord`）。设计上是合理的，但写入者分散（见 §6）。

### 4.4 WebKit 引擎

| 项 | 内容 |
|---|---|
| 文件 | `Services/Web/BrowserWebCoordinator.swift`（872）、`+Navigation.swift`（853）、`+UIDelegate.swift`（241）、`+UserScripts.swift`（661）、`WebViewHost.swift`、`WebPageOverlays.swift`、`NavigationLog.swift`、`WebPageScripts*.swift`（约 1,990） |
| 职责 | 构造 `WKWebViewConfiguration`；全部导航/UI/脚本消息委托；外部 scheme、应用链接、下载接管、权限、JS 对话框、文件上传；导航代次与陈旧回调判定；每页脚本集合；诊断日志 |
| 不负责 | 标签页池（由 `TabManager` 拥有）、业务规则（翻译/阅读/小说） |
| 拥有状态 | `traces`（按 webView 的导航轨迹）、`nextNavigationSerial`、`pendingAppLinkReloads`、`pendingIdentityReloads`、`userScriptXHRTasks`、`userScriptTabStates` |
| 生命周期 | 每窗口一个，被 `AppEnvironment` 强持有；对 `TabManager` 是弱引用（`attach`） |
| 协作 | 直接调用 history / downloads / bookmarks / userScripts / searchHistory / sessionRepository / adBlock / navigationLog；通过闭包回环境（翻译、开标签页） |

### 4.5 广告过滤

| 项 | 内容 |
|---|---|
| 文件 | `Core/AdBlock/AdBlockEngine.swift`、`AdBlockRuleCompiler.swift`、`AdBlockBuiltInRules.swift`、`Core/Models/AdBlockModels.swift` |
| 职责 | 把 ABP 语法编译成 `WKContentRuleList`；合并所有启用源；统计无表达力的规则；按 host 注入 cosmetic CSS |
| 不负责 | 网络请求拦截（由 WebKit 声明式规则完成） |
| 拥有状态 | `attachedList`、`ruleCount`、`cosmeticSelectors`、各项统计、`lastPageHiddenCount` |
| 生命周期 | 进程级；启动时编译一次，设置变更时重编译 |
| 协作 | `AppServices.refreshAdBlockRules` 读磁盘/内置规则后调用 `compile`；coordinator 在 `makeConfiguration` 同步挂载 |

### 4.6 页面翻译

| 项 | 内容 |
|---|---|
| 文件 | `Services/Translation/TranslationService.swift`（868）、`Core/Models/TranslationModels.swift`、`Features/Web/TranslationBar.swift`、`Services/Web/WebPageScripts+Translation.swift` |
| 职责 | 语言识别、段落提取、批量请求、写回、MutationObserver 增量翻译、按标签页记录已应用译文 |
| 不负责 | 页面加载、阅读模式 |
| 拥有状态 | `phase`、`appliedTarget/Url`、`detected`、`records[tabId]`、`generation`、`dynamicWork` |
| 生命周期 | 每窗口一个；`generation` 在切换页面/标签时递增，旧任务在下一个边界停止 |
| 协作 | 由 shell 调用；增量内容经 coordinator 的 `dynamicTranslationHandler` 回流 |

### 4.7 阅读模式 / 小说模式

| 项 | 内容 |
|---|---|
| 文件 | `Core/Reader/ReaderModeService.swift`、`Features/Reader/ReaderView.swift`；`Core/Novel/*`（4 个）、`Services/Novels/NovelLibraryService.swift`、`Data/Repositories/NovelRepository.swift`、`Features/Novels/*`（3 个） |
| 职责 | 正文/章节提取脚本；离屏加载章节与目录；书架与阅读进度；阅读器渲染 |
| 不负责 | 浏览标签页导航 |
| 拥有状态 | `NovelLibraryService.books`、`tocCache`；`NovelChapterLoader`/`NovelTOCLoader` 的 `webView/continuation/timeoutTask` |
| 生命周期 | 服务进程级；加载器由阅读器视图持有，`finish` 释放 WebView |
| 协作 | 阅读模式由 shell 直接 `await`；小说模式由 shell → 书架 → 阅读器 → 离屏加载器 |

### 4.8 用户脚本

| 项 | 内容 |
|---|---|
| 文件 | `Core/UserScripts/`（Parser 181、Matcher 213、Injector 999）、`Services/UserScripts/UserScriptService.swift`（670）、`Data/Repositories/UserScriptRepository.swift`、`Features/Settings/UserScriptsView.swift` |
| 职责 | 元数据解析、URL 匹配、GM API 桥、安装/编辑/更新、脚本存储 |
| 不负责 | 页面资源拦截 |
| 拥有状态 | `UserScriptService.scripts/updateStatus/isInstalling`；coordinator 侧的 `userScriptXHRTasks/userScriptTabStates`；overlay 的 `userScriptMenuCommands` |
| 生命周期 | 服务进程级；注入集合每次主框架导航重建 |
| 协作 | coordinator 在导航策略中读取 `enabledScripts()`，桥消息回到 coordinator |

### 4.9 下载

| 项 | 内容 |
|---|---|
| 文件 | `Services/Downloads/DownloadService.swift`（1,160）、`Core/Downloads/SegmentedDownloadSession.swift`（804）、`BackgroundDownloadRegistry.swift`、`Data/Repositories/DownloadRepository.swift`、`Features/Downloads/DownloadsView.swift` |
| 职责 | 队列、分片 Range 传输、后台 URLSession、WebKit 回退、暂停/续传、私有记录清理 |
| 不负责 | 页面导航 |
| 拥有状态 | `tasks`、`queued`、`segmentedSessions`、`activeGuids`、`downloads`、`progressObservations`、`sourceWebViews`、`preparedRequests` |
| 生命周期 | 进程级；分片 session 线程安全（锁 + 串行 delegate queue）；后台事件由 `BackgroundDownloadRegistry` 转交 |
| 协作 | coordinator 在响应策略里把不可渲染响应交给它；用户脚本 `GM_download` 也走它 |

### 4.10 离线页面 / 书签 / 历史 / 搜索历史 / 密码 / 设置

| 模块 | 文件 | 职责 | 拥有状态 |
|---|---|---|---|
| 离线页面 | `Services/Offline/OfflinePageService.swift`、`Data/Repositories/OfflinePageRepository.swift`、`Features/Offline/OfflinePagesView.swift` | Web archive 保存、预览图、打开、删除 | `pages`、`isSaving`、`lastError` |
| 书签 | `Services/Bookmarks/BookmarkService.swift`、`Data/Repositories/BookmarkRepository.swift` | 两棵根树、增删改、搜索 | `toolbarTree`、`otherTree`、`allBookmarks` |
| 历史 | `Services/History/HistoryService.swift`、`Data/Repositories/HistoryRepository.swift` | 访问链、标题回填、保留期清理 | `dayGroups`、`entryCount`、`currentVisitByTab` |
| 搜索历史 | `Data/Repositories/SearchHistoryRepository.swift` | 查询建议 | 无（按需查询） |
| 密码 | `Core/Passwords/KeychainStore.swift`、`Services/Passwords/PasswordVaultService.swift`、`Features/Passwords/PasswordVaultView.swift` | Keychain 存储、生物识别锁、填充/读取表单 | `credentials`、`isUnlocked`、`lastError` |
| 设置 | `Services/Settings/SettingsService.swift`、`Features/Settings/*`（14 个）、`Services/Settings/BackgroundImageStore.swift` | 六个 UserDefaults JSON 文档、背景图文件 | 各设置文档；`BackgroundImageStore.cached` |

### 4.11 基础设施与界面

| 模块 | 文件 | 说明 |
|---|---|---|
| 数据库 | `Data/BrowserDatabase.swift`、`Data/SQLite/SQLiteDatabase.swift`、`Data/BrowserSchema.swift` | 单连接；`NSRecursiveLock` 串行化；WAL；事务；表结构与索引 |
| 诊断 | `Services/Web/NavigationLog.swift`、`Features/Settings/NavigationDiagnosticsView.swift` | 120 条内存环形缓冲；URL 脱敏；不落盘 |
| 设计系统 | `UI/Theme.swift`、`BrowserSurfaces.swift`、`BrowserComponents.swift`、`ChromeBackdrop.swift`、`AmbientBackground.swift`、`SiteIconView.swift` | 颜色令牌、表面、组件、亮度采样、环境背景、图标 |
| 地址栏 | `UI/Omnibox/*`（5 个，1,899 行） | 建议引擎、会话状态、搜索页、建议列表、输入框 |
| 总览/侧栏 | `Features/Tabs/TabsOverviewView.swift`、`Features/Pad/*` | 标签页卡片、私有锁、iPad 侧栏与书签栏 |
| 命令 | `Core/Commands/BrowserCommandCenter.swift` | 窗口注册/注销硬件键盘命令处理器 |

---

## 5. 核心调用链

### 5.1 启动

1. `VelaApp.init`（`VelaApp.swift:40-45`）构造 `AppServices` 并 `bootOnce()`。
2. `bootOnce`（`AppServices.swift:134-172`）：reload 书签/历史/下载 → 安装后台下载重连器 →
   恢复中断任务 → reload 用户脚本 → 3 秒后异步检查脚本更新 → 合并内置广告源 →
   `Task { await refreshAdBlockRules() }` → 删除非 `window-main` 的会话。
3. `AppServices.init`（`:41-125`）打开数据库；失败时用 `try!` 建内存库并记录 `startupError`。
4. 每个 `WindowGroup` 场景创建 `WindowEnvironmentStore`；首次访问 `environment` 时构造
   `AppEnvironment`（`AppEnvironment.swift:49-95`），创建 overlays、NavigationLog、coordinator、
   TabManager、TranslationService，接线两个回调，再调 `bootWindow()`。
5. `bootWindow`（`:126-140`）同步无痕路由、按开关恢复 `window-main` 会话，空则建一个主页标签。
   **恢复不创建 WebView**，激活时才物化（`TabManager.swift:337-352` 的注释与实现一致）。

### 5.2 一次主框架导航

1. `TabManager.load`（`:600-643`）写 `url/pendingUrl/loadState=.requested`，必要时 `ensureWebView`，
   按 host 刷新 UA，`webView.load`。
2. WebKit → `decidePolicyFor navigationAction`（`+Navigation.swift:26-46`）→ 主 actor 上的 `resolvePolicy`：
   外部 scheme → 取消并交给系统；`targetFrame == nil` → 异步开新标签并取消；子框架 → 放行；
   主框架 → **`refreshUserScripts`**，视频站 UA 重发，应用链接重写，写 `pendingUrl`，记历史。
3. `didStartProvisionalNavigation` → `beginNavigation`（`:400-430`）：分配 `serial`、清用户脚本菜单命令、
   **再次 `refreshUserScripts`**、写 `loadState=.provisional`、记录 trace。
4. `decidePolicyFor navigationResponse`（`:264-313`）：不可渲染 → `DownloadService.handleWebDownload` + 取消；
   记录 HTTP 状态。
5. `didCommit`（`:438-471`）：非陈旧且非占位文档 → `loadState=.committed`，唯一一次写 `committedUrl`，
   刷新后退/前进。
6. `didFinish`：占位文档 → `.failed` + `emptyDocument`；否则 `.finished`、标题回填、滚动恢复、强制缩放、
   截图预览、持久化会话（`+Navigation.swift:473-542`）。
7. 失败：`handleLoadFailure`（`:691-745`）先用 `isStale` + `webView.isLoading` 过滤陈旧回调，
   再区分取消/失败；内容进程终止（`:652-673`）单独进入 `.crashed`，不自动重载。

### 5.3 标签页关闭、回收与内存警告

- `closeTab`（`TabManager.swift:438-483`）：记录最近关闭 → `previews.remove` → `destroyWebView`
  （停载、清委托、移出池）→ 从数组移除 → 选下一个激活 → 持久化会话。
- `discardWebView`（`:744-793`）：保存滚动位置并置 `pendingScrollRestore`、清后退/前进/加载状态、
  清 `committedUrl`、停载、清委托、移出池。
- `activateTab`（`:356-389`）：必要时取快照 → 设活动 → 冷标签确保 WebView 并按需重取页面 →
  `enforceLiveWebViewCap`。
- 内存警告（`VelaApp.swift:85-92`）→ `handleMemoryPressure` 丢弃所有非活动、非固定的后台 WebView，
  并清 WebKit 内存缓存。

### 5.4 翻译

`offerTranslationIfNeeded`（`+TranslationAndOffline.swift:88-113`）在页面 finished 后识别语言；
自动提示由 `.task(id: "\(tab.id)|\(tab.url)")` 驱动（`BrowserShellView.swift:430-435`）。
`translate`（`TranslationService.swift:251-372`）先递增 `generation`，安装提取脚本、提取段落、分批请求、
逐批写回；每次 `await` 后检查 `run == generation`。切换标签/页面时 `sync`/`pageWillNavigate` 递增代次并清空
`dynamicWork`。增量内容经 `handleDynamicUnits` 串行消费。

### 5.5 广告过滤

设置变更或启动 → `AppServices.refreshAdBlockRules`（`:190-225`）收集内置/已下载/本地规则 →
`AdBlockEngine.compile`（`AdBlockEngine.swift:86-158`）在主 actor 上逐行解析、校验、编码 →
`WKContentRuleListStore` 编译并替换 → 下一次 `makeConfiguration` 同步挂载。
失败时保留上一份规则（`:216-220`）。

### 5.6 用户脚本

安装：`UserScriptService.install` 解析元数据、下载 `@require/@resource`、写库、`reload`。
注入：`attachPageScripts`（`BrowserWebCoordinator.swift:521-650`）按 URL 匹配脚本，读取 GM 值，
`UserScriptInjector.makeUserScripts` 生成 `WKUserScript`。
运行时：脚本 `GM_*` → `handleUserScriptMessage`（`+UserScripts.swift:11-140`）→ 同步操作或启动
`userScriptXHRTasks` → 以 `window.__velaUserScriptBridge.resolve` 回到发起帧。

### 5.7 下载

WebKit 响应不可渲染 → `handleWebDownload` → 队列 → `startQueued` 探测 Range → 生成 manifest →
`SegmentedDownloadSession`（后台 URLSession，任务 `taskDescription` 记录段号）→ 进度/完成回调回
`DownloadService` → 合并分片 → 写库。失败或明文 http 回退 `WKDownload`。
App 被后台事件唤醒时 `VelaAppDelegate` → `BackgroundDownloadRegistry` → 重连器 → `reattach`。

### 5.8 小说与离线

小说：菜单 → `activateNovelMode`（`BrowserShellView.swift:1081-1107`）在**活动 WebView** 上提取；
失败时 700ms 后重试一次 → `NovelLibraryService.open` 写书/章节 → `NovelReaderView`；
翻页/目录由 `NovelChapterLoader` / `NovelTOCLoader` **离屏 WebView** 加载并轮询提取。
离线：`OfflinePageService.save` 取快照 + `createWebArchiveData` → 写 archive/preview/manifest → 写库；
打开时把 archive 直接交给新标签页。

### 5.9 私密会话

- 路由：`BrowserPreferences.privateBrowsingMode` → `AppEnvironment.syncPrivateBrowsingRouting` →
  `TabManager.newPagePrivacyMode`。每个新建入口（菜单、快捷键、`target=_blank`、`window.open`、
  入站 URL、扫码）都经过 `createTab`/`openTab` 解析该路由。
- 数据边界：`BrowserDataBoundary.persists == (dataScope == .profilePersistent)`；历史/搜索写入据此抑制。
- WebKit：私密标签页的配置使用 `WKWebsiteDataStore.nonPersistent()`（`BrowserWebCoordinator.swift:676-679`）。
- 结束：`endPrivateSession`（`AppEnvironment.swift:234-245`）关闭私密标签、清下载私有记录、
  再对一个**新建的** ephemeral store 调 `removeData`。

该流程的缺陷见 `RISK_REGISTER.md` R-01/R-02/R-15。

---

## 6. 状态权威来源

| 状态 | 应当的权威 | 实际写入者 | 风险 |
|---|---|---|---|
| 活动标签页 | `TabManager.activeTabId` | `TabManager.activateTab` | 单一，良好 |
| 当前显示的 URL | `BrowserTabState.url`（请求）/ `committedUrl`（文档） | `TabManager.load`、coordinator `didCommit/didFinish/fail`、shell `goHome/returnToPage`、`handleHistoryApiMessage` | 多写者；语义分两个字段，基本清晰 |
| 加载状态 | `BrowserTabState.loadState` | `TabManager`、coordinator、shell 只改 `isLoading/progress` | 多写者，但 coordinator 是事实权威 |
| 加载进度 | WebView 的 `estimatedProgress` | `WebViewHost` KVO → shell 闭包 → `tab.estimatedProgress` | 视图回写模型；每帧驱动观察者（R-14） |
| 后退/前进可用 | WebKit | coordinator `syncNavigationAvailability`、`didFinish`、`didCommit`、`discardWebView` | 单一逻辑，良好 |
| 页面标题 | WebKit + 历史 | coordinator `apply(title:)`、`readTitleFromDocument`、`loadOfflineArchive`、`restoreSession` | 可接受 |
| 翻译状态 | `TranslationService`（每窗口） | service；shell 只重置 | 代次保护良好 |
| 阅读模式显示 | shell `isReaderActive` | shell（异步回写不校验标签，R-05） | 窗口级而不是标签级 |
| 小说会话 | shell `novelSession` | shell | 窗口级；关闭标签不影响阅读器 |
| 下载任务 | `DownloadService.tasks` + 仓库 | service | 单一，良好 |
| 广告规则 | `AdBlockEngine.attachedList` | engine | 单一，良好 |
| 书签/历史 | Repository + Service 缓存 | service 每次写后 re-read | 单一，良好 |
| 私密标签页 | `TabManager.tabs` + 会话表 | manager | 与数据存储分离（R-01） |
| 用户脚本 GM 值 | SQLite | coordinator 消息 → repository | 单一 |
| GM 标签状态（`GM_getTab`） | coordinator 内存 | coordinator | **无清理**（R-03） |
| 最近关闭 | `TabManager.recentlyClosed` | manager；另写 SQLite | DB 只写不读（R-06） |
| “显示哪一层” | shell 的 17 个布尔 | shell | 分散但可枚举 |

**结论**：导航状态机（`TabLoadState` + `WKNavigation` 身份校验 + `committedUrl`）是全项目质量最高的部分，
单一权威明确，测试覆盖也最厚。真正分散的是 **窗口级 UI 状态** 与 **标签页附属资源**（脚本任务、GM 状态、
预览图、翻译记录），它们没有统一的“标签页关闭”清理点。这是阶段 B/C 最值得先解决的结构问题。

---

## 7. 对象与任务生命周期

| 对象/任务 | 创建 | 持有者 | 取消/释放 | 问题 |
|---|---|---|---|---|
| `AppServices` | `VelaApp.init` | App | 进程结束 | 无 |
| `AppEnvironment` | `WindowEnvironmentStore` 懒构造 | 场景 | 场景销毁 | 场景重建会重新分配 `windowId`（R-18） |
| `TabManager` / coordinator | `AppEnvironment.init` | 环境（manager 强持有 provider 协议，coordinator 弱持有 manager） | 环境释放 | 无环 |
| `BrowserTabState` | `createTab/openTab/restoreSession` | `TabManager.tabs` | `remove` | 关闭标签后仍被异步任务强持有（R-03） |
| `WKWebView` | `ensureWebView` | `TabManager.webViews`（视图层弱引用） | `discardWebView/destroyWebView` | 上限只在一处执行（R-04） |
| 导航 trace | `beginNavigation` | coordinator `traces` | `pruneTraces`（>8 时） | 小型字典，可接受 |
| 翻译任务 | shell 的 `Task` | SwiftUI 状态 | `generation` 逻辑取消 | 无真实 `Task.cancel`，靠代次；网络请求会继续到批次结束 |
| GM XHR | `handleUserScriptXHR` | `userScriptXHRTasks` | 完成/同 key 重启/超时 | 标签关闭不取消；强持有 WebView（R-03） |
| GM 菜单命令 | 页面消息 | `WebPageOverlays` | 下一次该标签导航 | 关闭标签不清（R-03） |
| 进度/滚动 KVO | `WebViewHost.updateUIView` | Coordinator | `stopObserving` | 每帧一次 `Task`（R-14） |
| 预览图 | `capturePreview` | `TabPreviewStore` 内存 + 磁盘 | 关闭标签删除；80 文件上限 | 编码在主线程（R-11）；私密图落盘（R-15） |
| 分片下载 session | `beginSegmented` | `DownloadService.segmentedSessions` | `stopSegmented/remove` | 线程安全，良好 |
| 小说离屏 WebView | `NovelChapterLoader.load` | 阅读器视图 | `finish` 移除并释放 | 轮询任务不随 `finish` 取消，最多空转 7s |
| 历史访问链 | `HistoryService.recordVisit` | `currentVisitByTab` | `clearTabChain`（**无调用者**） | 每标签一条，随进程增长（R-22） |
| 场景外观广播 | `VelaApp` | 进程 | — | 每次系统外观变化通知所有窗口，合理 |

---

## 8. 会话、隐私与故障隔离现状

### 8.1 会话持久化

- 标签页会话：全量替换写（`TabSessionRepository.saveSession`），每次导航完成、关闭、切换、进入后台都会写。
  小表、事务、WAL，成本可控。
- 读：启动恢复 `window-main`；非主窗口会话在启动时删除。
- 最近关闭：写库但**从不读**（R-06）。
- 私密标签页按设计写入同一张会话表，结束私密会话时重写。

### 8.2 隐私

- 历史/搜索写入由 `BrowserDataBoundary.persists` 抑制，正确。
- 私密标签页使用 ephemeral WebKit 存储，方向正确，但**每个 WebView 一个 store**（R-01）。
- 小说加载器使用持久化 store 与持久化章节表（R-02）。
- 下载记录、预览图、小说章节、离线归档在私密模式下仍可能落盘（R-02/R-15）。
- 私密标签页的站点图标会请求第三方 favicon 服务并携带 host（R-16）。
- 密码只进 Keychain（`ThisDeviceOnly`），正确。

### 8.3 故障隔离

- 导航失败有独立错误面；内容进程崩溃单独成态且不自动重载（`+Navigation.swift:652-673`），正确。
- 广告编译失败保留旧规则，正确。
- 翻译失败只改翻译栏状态，不影响页面，正确。
- 阅读模式失败显示“无法提取正文”而不是静默，正确。
- 用户脚本异常被记录后丢弃（`+UserScripts.swift:52-56`），不打断浏览，正确。
- 下载失败只影响该任务，正确。
- **没有**崩溃/异常采集、没有 `os_log`/`Logger`、没有 MetricKit（R-24/R-26）。

---

## 9. 文档与实现差异汇总

| 位置 | 声明 | 实际 |
|---|---|---|
| `ARCHITECTURE.md` 分层 | 单向依赖，Core 纯逻辑，仅一个 shared | 见 §3 四处差异 |
| `PORTING.md` 统计 | 47 文件 / 16,340 行；池上限 6 | 130 / 43,083；上限 8 |
| `TabModels.swift:435` | 注释引用 `BrowserLoadingProgressCoordinator` | 类型不存在 |
| `TabModels.swift:626` | 注释引用 `BrowserPrivateSessionCleanupCoordinator` | 类型不存在 |
| `+Navigation.swift:345-380` | 注释称地址栏“跟随重定向立即更新” | 无任何视图读取 `pendingUrl`；地址栏只随 `tab.url` 变化（R-23） |
| `NovelTOCLoader.swift:10` | 注释称两个加载器都用非持久化存储 | 两者都用 `.default()`（R-02） |
| `BrowserSidebarView.swift:9` | 注释称侧栏“总是可见” | `padRoot` 把它作为抽屉呈现 |
| `WebPageScripts.swift:623-641` | 注释称页面是否可滚动决定工具栏隐藏 | 上报的 `scrollHeight` 等字段无人读取（R-08） |
| 根目录 `CLAUDE_CODE_TASK_VelaBrowser.md` | — | 0 字节 |

---

## 10. 审计结论摘要

1. **导航核心是可靠的**：陈旧回调判定、占位文档识别、取消与失败区分、崩溃状态，都有代码与测试证据。
2. **最紧急的问题集中在“标签页关闭后的资源与状态”**：WebView 池上限、GM XHR、GM 状态表、菜单命令、
   预览图、阅读模式回写，各自依赖不同机制，缺少一个统一的关闭清理点。
3. **隐私边界在四处地方被绕过**：私密标签页的数据存储不是共享的、小说加载器走持久化存储、
   私密预览图/下载记录依赖一次可能不执行的清理、站点图标会向第三方 favicon 服务外发私密页面的 host。
4. **没有崩溃诊断能力**。已知的“重新打开崩溃”在没有崩溃日志的情况下无法定位；任何稳定性治理都应先补
   最小可用的崩溃采集，再谈修复。
5. **主线程工作量有几个明确的热点**：广告规则编译、预览图编码、离线归档读写、历史写入。
   它们都需要先测量再改，不能凭感觉迁移线程。
6. **架构问题不是“需要重写”**，而是两处边界：`AppEnvironment` 作为服务定位器，以及 Core 层混入 WebKit
   运行时。先用最小改动收紧，不要为此做大规模重构。

详细条目、证据与建议见 `RISK_REGISTER.md`；依赖关系见 `DEPENDENCY_MAP.md`；实施顺序见
`OPTIMIZATION_ROADMAP.md`。
