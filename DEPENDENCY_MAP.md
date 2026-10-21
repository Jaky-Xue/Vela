# Vela 依赖与调用关系图

- 基线：`3ed4197`（`main`，工作区干净）
- 方法：源码静态分析。箭头 `A → B` 表示“A 的类型或方法直接引用 B”。
- 本图只画**真实存在**的边；`ARCHITECTURE.md` 里声明但代码中不成立的边单独列出。

---

## 1. 模块级依赖矩阵

行依赖列（`●` 直接引用，`○` 仅通过协议/闭包间接引用，空表示无引用）：

| ↓ 依赖 → | App | Features | UI | Services | Core | Data |
|---|---|---|---|---|---|---|
| **App** | — | ● | ● | ● | ● | ● |
| **Features** | ● | ● | ● | ○ | ● | ○ |
| **UI** |  | ● | ● |  | ● | ● |
| **Services** |  |  |  | ● | ● | ● |
| **Core** |  |  |  | ○ | ● | ● |
| **Data** |  |  |  |  | ● | ● |

说明：

- **App** 是组合根：`VelaApp`/`AppServices`/`AppEnvironment` 引用全部层。
- **Features** 对 App 的边是 `@Environment(AppEnvironment.self)`：27 个文件、320 处 `env.*`。
  对 Services 的边主要是直接持有具体服务类型（`BookmarkService`、`HistoryService`…），
  不是协议。对 Data 的边经由 `AppEnvironment` 转发（`env.searchHistory`）。
- **UI** 基本只依赖 Core 值类型与自身；`OmniboxViewModel` 是例外，直接依赖 `TabManager` 与
  `SearchHistoryRepository`（`Vela/UI/Omnibox/OmniboxViewModel.swift:45,307,327`）。
- **Core** 对 Data 的边只有 `TabManager → TabSessionRepository`（`TabManager.swift:87`）。
- **Data** 只依赖 Core 的值类型与 `SQLiteDatabase`，不引用 UI/WebKit，是分层最干净的一层。

---

## 2. 关键类型与协作者

### 2.1 组合根

```
VelaApp
 ├─ AppServices（进程级，bootOnce 一次）
 │   ├─ BrowserDatabase.shared → SQLiteDatabase
 │   ├─ SettingsService（UserDefaults ×6 文档）
 │   ├─ BookmarkService → BookmarkRepository
 │   ├─ HistoryService → HistoryRepository
 │   ├─ DownloadService → DownloadRepository
 │   │      └─ BackgroundDownloadRegistry.shared
 │   ├─ AdBlockEngine → WKContentRuleListStore
 │   ├─ UserScriptRepository / UserScriptService
 │   ├─ TabSessionRepository
 │   ├─ NovelLibraryService → NovelRepository
 │   ├─ PasswordVaultService → KeychainStore
 │   ├─ OfflinePageService → OfflinePageRepository
 │   ├─ SearchHistoryRepository
 │   └─ BrowserCommandCenter
 └─ WindowEnvironmentStore（每场景）
     └─ AppEnvironment（懒构造）
         ├─ WebPageOverlays
         ├─ NavigationLog
         ├─ BrowserWebCoordinator
         ├─ TabManager（provider = coordinator）
         └─ TranslationService
```

`AppEnvironment` 对共享服务提供 14 个只读转发属性（`AppEnvironment.swift:103-116`），
因此每个 Feature 视图拿到的不是“它需要的那个服务”，而是整个组合根。

### 2.2 引擎与外部协作者

`BrowserWebCoordinator` 直接持有 9 个协作者（`BrowserWebCoordinator.swift:28-39`）：

| 协作者 | 用途 | 调用点 |
|---|---|---|
| `SettingsService` | UA、外链策略、缩放、权限、翻译/脚本开关 | 全文件 |
| `AdBlockEngine` | 规则挂载、cosmetic CSS、隐藏计数 | `makeConfiguration`、`attachPageScripts`、`handleAdBlockReport` |
| `HistoryService` | 访问记录、标题回填 | `resolvePolicy`、`didCommit`、`apply(title:)`、History API |
| `DownloadService` | 不可渲染响应、`WKDownload` 回退 | `decidePolicyFor navigationResponse` |
| `BookmarkService` | 无直接调用（构造参数注入） | — |
| `UserScriptRepository` | 每次导航读取启用脚本与 GM 值 | `attachPageScripts` |
| `SearchHistoryRepository` | 无直接调用（构造参数注入） | — |
| `TabSessionRepository` | 无直接调用（构造参数注入） | — |
| `NavigationLog` | 每条导航事件 | `log(...)` |

> `bookmarks`、`searchHistory`、`sessionRepository` 被注入但 coordinator 内没有任何引用
> （只命中属性声明与初始化）。建议在阶段 C 删除或真正使用。

### 2.3 标签页与 WebView

```
TabManager ──strong──▶ BrowserWebViewConfigurationProviding（实际是 coordinator）
     ▲                             │
     └────────weak─────────────────┘  coordinator.attach(tabManager:)

TabManager ──strong──▶ TabSessionRepository
TabManager ──strong──▶ TabPreviewStore
TabManager.tabs ──▶ BrowserTabState（@Observable，引用类型）
TabManager.webViews[tabId] ──▶ WKWebView
WKWebView.navigationDelegate/uiDelegate ──weak──▶ coordinator
WKUserContentController ──strong──▶ MessageBridge ──weak──▶ coordinator
WebViewHost ──▶ WebViewContainerView ──weak──▶ WKWebView
```

所有 WebKit 对 App 的回调（delegate、message、KVO、完成回调）最终都汇聚到 coordinator；
`TabManager` 只拥有对象，不处理任何页面事件。这个边界是清晰的。

### 2.4 视图 → 服务

| 视图组 | 直接依赖 | 备注 |
|---|---|---|
| `BrowserShellView` 及其扩展 | `AppEnvironment` 全部成员、`TabManager`、`BrowserWebCoordinator`、`TranslationService`、`OmniboxViewModel` | 页面的所有动作都在这里汇总 |
| `TabsOverviewView` | `TabManager`、`TabPreviewStore`（经 manager）、`Passwords`（私有锁） | 也直接 `takeSnapshot` |
| `BookmarksView` / `HistoryView` / `DownloadsView` / `OfflinePagesView` / `NovelBookshelfView` / `PasswordVaultView` | 对应 Service + `AppEnvironment` | 打开链接时直接调 `tabManager.openTab` |
| `Settings/*` | `AppEnvironment`（主要是 `settings`；广告过滤页还调 `refreshAdBlockRules`） | 设置页直接触发编译 |
| `NewTabHomeView` | `BookmarkService`、`TabManager`，并用 `UserDefaults` 存主页收藏 id | 主页是书签的第二视图 |
| `TranslationBar` | `TranslationService` + WebView | |
| `Omnibox/*` | `OmniboxViewModel` → `TabManager` / 三个查询服务 | |

---

## 3. 运行期数据流

### 3.1 页面加载（简化）

```
用户动作（地址栏/链接/菜单）
  → shell.navigate / TabManager.openTab
    → TabManager.load
      → coordinator.makeConfiguration（脚本 + 规则 + 数据存储）
      → WKWebView.load
        → decidePolicyFor navigationAction（coordinator）
           → refreshUserScripts（DB 查询 ×N）
           → HistoryService.recordVisit（同步 SQLite 事务）
        → didStartProvisional → refreshUserScripts（再次 DB 查询 ×N）
        → didCommit → tab.loadState / committedUrl
        → didFinish → title、滚动恢复、preview 截图、persistSession
                    → shell 观察 tab → 重新渲染
```

### 3.2 关闭标签页

```
shell / overview / sidebar
  → TabManager.closeTab
      → TabSessionRepository.recordClosed（SQLite）
      → TabPreviewStore.remove（磁盘）
      → destroyWebView（委托置空、移出池）
      → tabs.remove
      → activateTab（可能建新 WebView / 触发池回收）
      → persistSession（SQLite）
  ✗ 不通知 coordinator / TranslationService / DownloadService / HistoryService
```

这条链没有“标签页生命周期结束”的广播点，是 R-03/R-05/R-15 的共同根因。

### 3.3 翻译增量

```
页面 MutationObserver
  → webkit.messageHandlers.translation
  → coordinator.handleTranslationMessage
  → environment.dynamicTranslationHandler（闭包）
  → TranslationService.handleDynamicUnits
  → dynamicWork 串行队列 → requestBatch → evaluateJavaScript 写回
```

### 3.4 广告规则

```
启动 / 设置开关 / 订阅更新
  → AppServices.refreshAdBlockRules
      → 读内置 + 磁盘订阅 + 本地规则
      → AdBlockEngine.compile（主 actor，逐行解析）
      → WKContentRuleListStore.compileContentRuleList
      → 保存 attachedList
  → 下一次 makeConfiguration 同步挂载
```

### 3.5 下载

```
coordinator 响应策略（不可渲染）
  → DownloadService.handleWebDownload
  → 队列 → startQueued
      → preparedRequest（复制 WebView cookies/UA/referer）
      → probe（Range 支持）
      → SegmentedDownloadSession（后台 URLSession）
          → onProgress / onManifest / onComplete / onFallback
  → finishSegmented → 合并分片 → 仓库
```

### 3.6 用户脚本 GM 调用

```
页面脚本 → __velaUserScriptBridge → webkit.messageHandlers.userScript
  → coordinator.handleUserScriptMessage
      ├─ 同步：setValue/deleteValue/clipboard/menu/tab state
      └─ 异步：xhr / cookie / download
          → Task（强持有 webView）
          → URLSession 或 WKHTTPCookieStore
          → evaluateJavaScript(in: frame) 回到原帧
```

---

## 4. 耦合度量（静态计数）

| 类型 | 引用它的文件数 | 说明 |
|---|---|---|
| `TabManager` | 11 | 标签页、总览、侧栏、地址栏、外壳、coordinator、command |
| `BrowserWebCoordinator` | 6 | 外壳、总览、翻译栏、环境、测试桩 |
| `SettingsService` | 9（另有 174 处 `env.settings`） | 几乎所有功能读设置 |
| `DownloadService` | 6 | 环境、coordinator、下载页、脚本桥 |
| `HistoryService` | 6 | 环境、coordinator、地址栏、历史页 |
| `BookmarkService` | 6 | 环境、coordinator、地址栏、书签页、主页 |
| `AdBlockEngine` | 4 | 环境、services、coordinator、设置页 |
| `TranslationService` | 3 | 环境、外壳、翻译栏 |
| `AppEnvironment` | 27 个 Feature 文件 + 5 个 App 文件 | 服务定位器 |

**高耦合点**：

1. `AppEnvironment`（27 个消费者）。任何新服务都要加到它的 14 个转发属性上，所有 Feature 都看得到它。
2. `BrowserShellView`（1,348 行 + 4 个扩展 1,364 行）。它同时是状态机、动作层、布局层。
3. `BrowserWebCoordinator`（9 个协作者，2,627 行含扩展）。WebKit 委托的合并是合理的，但业务服务
   注入面偏大，其中 3 个协作者当前无调用。

---

## 5. 循环与双向依赖

### 5.1 类型级环

- **无**。`TabManager ↔ coordinator` 是协议 + 弱引用的单向环，运行时安全：
  manager 强持有 provider（coordinator），coordinator 弱持有 manager（`attach`）。
- `MessageBridge → coordinator` 是弱引用；`WKUserContentController` 强持有 bridge，不构成环。

### 5.2 逻辑上的双向依赖

| 边 | 方向 A | 方向 B | 影响 |
|---|---|---|---|
| 标签页 ↔ 环境 | `AppEnvironment` 创建并持有 `TabManager` | `TabManager` 通过 provider 调回 coordinator | 可接受，已用协议隔开 |
| Features ↔ App | Feature 读 `AppEnvironment` | `AppEnvironment` 在 App 层构造 | 违反文档方向，编译期无隔离（同 target） |
| UI ↔ Core/Data | `OmniboxViewModel → TabManager/Repository` | `TabManager` 不依赖 UI | 单向但跨层 |
| coordinator ↔ 业务服务 | coordinator 调 history/downloads | 服务通过闭包/环境回调 coordinator | 翻译、开标签是闭包，未形成环 |

---

## 6. 重复实现的业务逻辑

| 逻辑 | 位置 | 问题 |
|---|---|---|
| 私密模式路由 | `TabManager.newPagePrivacyMode`、`AppEnvironment.syncPrivateBrowsingRouting`、coordinator 的两处 `target=_blank`/`window.open` 解析、`VelaApp.onChange` | 规则本身一致，但分散在 4 处；新增入口容易漏 |
| 导航动作 | shell 的 `goBack/openHomeTab/reloadActiveTab`、菜单 action、工具栏 control、硬件命令、总览/侧栏 | 同一动作 3–5 个入口，行为大体一致，但 `reload`/`find` 的分支各写一份 |
| 打开链接 | `TabManager.openTab`（正确单一入口），但书签/历史/主页/侧栏都各自决定 `activate` 与隐私参数 | 参数默认值不一致的风险 |
| 标签页标题/图标派生 | `BrowserTabState.displayTitle/displayHost`（单一），视图各自处理空值 | 基本无重复 |
| 设置持久化 | `SettingsService.update`（单一），但 `HomeBookmarkStore`、`OmniboxViewModel` 直接写 `UserDefaults` | 两套绕过设置服务的持久化路径 |
| 书签“主页收藏” | `HomeBookmarkStore` 用 `UserDefaults` 存 id，书签本体在 SQLite | 删除书签后 id 残留；主页需每次过滤 |
| 加载状态判定 | `TabLoadState.isInFlight/isFailure/hasCommittedDocument` + `needsPageFetch`（集中） | 良好，无重复 |
| 错误分类 | `TabNavigationFailure.make`（集中） | 良好 |

---

## 7. 隐式共享状态

| 状态 | 位置 | 共享方式 | 风险 |
|---|---|---|---|
| `BrowserTabState` | `TabManager.tabs` | 引用类型，被 shell、coordinator、overview、omnibox 同时读；3 层写 | 见 R-20 |
| `WebPageOverlays` | 每窗口 | 引擎写、shell 读；完成闭包由引擎暂存 | 关闭标签后对话框仍可显示（小型） |
| `userScriptTabStates` / `userScriptXHRTasks` | coordinator | 以 tab id / 脚本 id 为键，进程级 | 无关闭清理（R-03） |
| `NavigationLog` | 每窗口 | 所有导航写入；设置页读 | 120 条上限，安全 |
| `TranslationService.records` | 每窗口 | 按 tab id，弱持有 WebView | 代次保护，安全 |
| `HistoryService.currentVisitByTab` | 进程 | 按 tab id，无删除调用 | 缓慢增长（R-22） |
| `BackgroundImageStore.cached` | 进程 | 静态可变缓存 | 主 actor 访问，安全 |
| `SiteIconView.iconCache` | 进程 | 静态 `NSCache` | 线程安全，但无负缓存（R-16） |
| `SettingsService` 文档 | 进程 | 所有窗口共享 | 整体 JSON 解码（R-17） |

---

## 8. 依赖治理建议（摘要）

1. **不要**引入事件总线。当前项目只有一条真正需要广播的生命周期事件——**标签页即将关闭/已关闭**。
   用一个 `TabManager.onWillCloseTab: ((BrowserTabState) -> Void)?` 或让 `AppEnvironment` 在关闭后统一清理，
   比全局事件系统简单得多。
2. `AppEnvironment` 的 14 个转发属性可以保留，但 Feature 视图应尽量只取它实际需要的服务
   （通过初始化参数或更窄的环境值），不要让新代码继续依赖整个组合根。
3. 删除 coordinator 中未使用的 3 个协作者，或在真正需要时再加。
4. `OmniboxViewModel` 对 `TabManager` 的依赖可以收成一个“打开标签页建议”的小协议，使 UI 不直接依赖
   Core 的完整标签管理器；这是可选的，不是缺陷。
5. `Core` 目录应明确分成 `Core/Models`（纯值类型）、`Core/Logic`（纯函数）、`Core/Runtime`（WebKit 运行时）。
   这只是目录与命名调整，不改变类型；等阶段 C 再做。

具体风险编号见 `RISK_REGISTER.md`。
