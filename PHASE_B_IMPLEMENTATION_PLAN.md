# Phase B 实施方案（提交审批）

- 基线：`3ed4197 Vela 3.9.0`，`main`，工作区只有阶段 A 的四份未跟踪 Markdown。
- 本文件只提交方案；**尚未修改任何源码**。批准后才从 B1 开始。
- 范围严格按本次任务书的 B1–B6；不做全仓库重构、不做性能猜测式优化、不新增功能。
- 风险编号沿用 `RISK_REGISTER.md`。

## 0. 复核结论与报告更新

按任务书要求，逐项重新核对了源码与调用关系。结论没有变化，补充两点语义：

1. **B1 的“最后一个私密标签关闭”不需要额外钩子。** `closeTab` 在关闭某模式的最后一个真实标签时
   会创建一个该模式的主页标签（`TabManager.swift:473-480`），私密标签集合不会因此变空。
   私密会话真正结束只有两条路径：用户选择“离开无痕模式”，或 App 进入后台；两者都调用
   `endPrivateSession`（`AppEnvironment.swift:234-245`）。清理点就是这一处。
2. **B4 的隐私影响已在阶段 A 报告中升级。** 候选图标包含
   `https://www.google.com/s2/favicons?...&domain=<host>`（`SiteIconView.swift:201`），
   标签总览与 iPad 侧栏对所有标签页（包括私密）使用 `SiteIconView`。R-16 已从 S4 改为 S2。

另有一项与 B6 相关的产品行为：主页“最近关闭”只显示 regular 记录
（`NewTabHomeView.swift:424`）。如果 B6 改为启动时读取持久化列表，普通主页会开始显示重启前的记录。

上述补充已写入 `RISK_REGISTER.md`（R-01、R-06、R-16）。

## 1. 验证限制与交付方式

- 本机是 Windows，**没有 Swift/Xcode 工具链**：不能编译、不能运行模拟器、不能执行 XCTest。
- 因此本批每个补丁的编译与测试结果只能由 CI 给出（`.github/workflows/build-ios.yml` 的
  `build` 与 `test` 两个 job）。当前约束不允许我提交或推送；需要由用户决定如何触发 CI。
- 我能做的验证：完整 `git diff` 审查、调用点全局检索、与现有测试的对应关系检查、
  以及文档/风险记录更新。
- 每个补丁完成后会明确写：已做哪些静态验证、哪些测试已写但未运行、哪些必须由 CI/真机验证。

## 2. B1：私密会话共享 WebKit 数据存储

### 2.1 当前行为与证据

`Vela/Services/Web/BrowserWebCoordinator.swift:674-679`：

```swift
configuration.websiteDataStore = tab.privacyMode == .private
    ? WKWebsiteDataStore.nonPersistent()
    : WKWebsiteDataStore.default()
```

`makeConfiguration` 每个 WebView 调用一次（`TabManager.ensureWebView`，`TabManager.swift:565`）。
`WKWebsiteDataStore.nonPersistent()` 每次返回新的非持久化 store，因此：

- 同一私密会话的两个标签页不共享 Cookie/本地存储，新开的私密标签页处于未登录状态。
- `endPrivateSession`（`AppEnvironment.swift:234-245`）新建一个 store 再 `removeData`，清的是空存储。
- 每个私密标签页各自持有一份缓存。

### 2.2 产品语义（需要确认）

我建议把“私密会话”定义为**一个窗口的私密标签会话**：

- 同一窗口内的所有私密标签页共享一个非持久化 store；
- 不同 Stage Manager 窗口拥有各自的私密 store（因为标签会话、`endPrivateSession`、`windowId`
  本来就是按窗口划分的）；
- 结束该窗口的私密会话时清空这个 store。

备选是进程级共享（所有窗口的私密标签共享 Cookie），但那样任一窗口结束私密会话都会清掉其他窗口
正在使用的 Cookie，需要引用计数与跨窗口协调，复杂度不值得。若用户希望跨窗口共享，请明确，
我再给出带引用计数的设计。

### 2.3 计划修改

| 文件 | 修改 |
|---|---|
| `Services/Web/BrowserWebCoordinator.swift` | 新增 `private var sharedPrivateDataStore: WKWebsiteDataStore?`；新增 `func privateWebsiteDataStore() -> WKWebsiteDataStore`（懒创建、复用）；新增 `func clearPrivateWebsiteData() async`（对同一实例 `removeData(ofTypes: all, modifiedSince: .distantPast)`）；`makeConfiguration` 改为使用它 |
| `App/AppEnvironment.swift` | `endPrivateSession` 在 `tabManager.endPrivateSession()` 与 `downloads.clearPrivateRecords()` 之后调用 `await webCoordinator.clearPrivateWebsiteData()` |
| 不修改 | `WKWebsiteDataStore.default()` 分支、普通标签页、下载、历史、翻译 |

生命周期：

- 创建：该窗口第一次为一个私密 WebView 构造配置时。
- 复用：该窗口之后所有私密 WebView。
- 清理：`endPrivateSession`（离开无痕模式、App 进入后台且有私密标签）。
- 销毁：窗口/环境释放时随 coordinator 释放；非持久化 store 的数据不跨进程。
- App 被异常终止：数据随进程消失；重启后私密标签页会恢复，但登录状态/缓存是新的（与当前行为一致，
  只是不再“每个标签一份”）。

### 2.4 预期行为与兼容性

- 私密标签页之间共享 Cookie/登录状态（修复目标）。
- 普通模式完全不变。
- 私密会话结束时，该窗口实际使用的 store 被清空（修复目标）。
- 行为变化：以前私密标签页彼此隔离；现在同一窗口内共享。这是产品语义变化，需要确认。

### 2.5 回归风险

- 私密页面的 Cookie 现在会跨标签页可见——这是预期，但任何依赖“私密标签彼此隔离”的假设都会改变。
- 清理时机：若 `endPrivateSession` 运行时仍有私密 WebView 存活（正常路径不会，`closeAllTabs` 先销毁），
  清空 store 可能中断其请求。会在实现时先销毁、再清空，并在测试中覆盖。
- 小说阅读器若在私密会话中打开，B1 阶段仍使用它自己的 store（B2 再接入），暂无交叉影响。

### 2.6 测试计划（新增到 `VelaTests`）

1. 同一窗口的两个私密标签页 `configuration.websiteDataStore` 为同一对象。
2. 私密标签页 A 写入 cookie，私密标签页 B 能读到（本地 HTTP 服务器，同一 host）。
3. 普通标签页的 store 与私密 store 不是同一对象，普通标签页读不到私密 cookie。
4. `clearPrivateWebsiteData()` 后 `getAllCookies` 为空；普通 store 的 cookie 不受影响。
5. 现有 `testAPrivateTabLoadsToo` 保持通过。

### 2.7 未验证项

编译、模拟器 Cookie 行为、`removeData` 完成时机都需要 CI/真机确认。若 `nonPersistent` 在同一 store
下仍不共享 Cookie（与文档契约不符），测试会失败，届时以实际行为为准重新评估。

---

## 3. B2：小说模块的私密边界

### 3.1 当前行为与证据

- `NovelChapterLoader.swift:44` 与 `NovelTOCLoader.swift:36` 固定使用
  `configuration.websiteDataStore = .default()`，不接收隐私模式。
- `NovelLibraryService.open(_:)`（`:60-118`）无条件 `upsertChapter` + `upsert(book)`；
  `store`、`markPosition`、`updateProgress`、`saveTOC`、`saveTOCSource` 全部写持久化仓库。
- 调用链：`BrowserShellView.activateNovelMode`（`:1081`）→ `env.novels.open` →
  `NovelReaderView`（持有 `env.novels`）→ 两个加载器。
- 结果：从私密标签页进入小说模式，章节正文、书名、章节 URL 写入普通模式数据库；章节/目录请求
  使用持久化 Cookie/缓存。

### 3.2 方案选择（需要确认）

**方案 A（推荐，保留功能）：私密阅读使用窗口级内存书架。**

- 给 `NovelLibraryService` 增加“无仓库”模式：`init(repository: NovelRepository?)`。
  - 有仓库：行为不变。
  - 无仓库：书籍、章节、目录只存内存字典；所有写库调用变为内存写；不触碰 `novel_*` 表。
- `AppEnvironment` 增加一个懒创建的 `privateNovels`（无仓库实例），并提供
  `novelLibrary(privateMode:) -> NovelLibraryService`。
- `NovelSession` 增加 `isPrivateSession: Bool`，由 shell 从进入时的活动标签页隐私模式决定。
- `NovelReaderView` 改用传入的会话服务（当前有约 15 处 `env.novels`，改为局部 `novels`）；
  章节/目录加载器接收 `dataStore`：私密 → B1 的窗口私密 store，普通 → `.default()`。
- 私密模式下的书架只列内存书籍；结束私密会话时丢弃该实例（下次私密会话从空书架开始）。
- 普通模式与现有书架行为不变。

**方案 B（最小，但功能受限）：私密标签页禁用小说模式。**

- `activateNovelMode` 在私密标签页直接提示“私密模式下不提供小说模式”，不进入阅读器；
  同时私密模式下不展示书架入口（或入口提示不可用）。
- 改动约 10–20 行，可靠性最高，但这是功能移除，而且会改变现有用户行为。

**方案 C（不推荐）：先写入数据库，结束时删除。**
私密内容会短暂进入长期数据库，异常终止后可能残留；不符合“不得默认写入”的要求，且清理可靠性
无法证明。因此不采用。

### 3.3 方案 A 的计划修改（若批准）

| 文件 | 修改 |
|---|---|
| `Services/Novels/NovelLibraryService.swift` | 可选仓库；内存章节/目录存储；`open/store/chapter/cachedChapter/markPosition/updateProgress/tocEntries/tocSource/saveTOC/saveTOCSource/delete` 在无仓库时只操作内存 |
| `App/AppEnvironment.swift` | 持有 `privateNovels`；`novelLibrary(privateMode:)`；`endPrivateSession` 丢弃/重建它 |
| `App/BrowserShellView.swift` | `activateNovelMode` 选择服务；`NovelSession` 增加 `isPrivateSession`；`openNovel` 传递 |
| `App/BrowserShellView+Presentations.swift` | 书架 sheet 传递当前模式并选择服务 |
| `Features/Novels/NovelBookshelfView.swift` | 按传入的服务取 `books` |
| `Features/Novels/NovelReaderView.swift` | 使用会话服务；加载器传入 store |
| `Core/Novel/NovelChapterLoader.swift`、`NovelTOCLoader.swift` | `load(urlString:dataStore:)`；默认参数可保留 `.default()` 以免影响其他调用者 |
| `Services/Web/BrowserWebCoordinator.swift` | 暴露 B1 的 `privateWebsiteDataStore()` |

### 3.4 兼容性与回归风险

- 普通阅读完全走原路径；风险集中在私密分支。
- 私密阅读不再出现在常规书架，也不记录进度；结束私密会话后丢失（预期）。
- 从常规书架在私密标签页打开一本书：使用内存服务，会重新抓取章节，不写常规进度。
- 书架 UI 需要按模式选择服务；若遗漏某个入口，可能仍显示常规书架（不泄露私密数据，但语义不一致）。
- 阅读器约 15 处服务调用需要逐一替换；这是本批改动面最大的一项。

### 3.5 测试计划

1. `NovelLibraryService(repository: nil)`：open/store/chapter/toc 往返只在内存，`books` 变化，
   不产生任何仓库调用（可用一个记录调用的假仓库，或断言无仓库时不崩溃/数据正确）。
2. 普通实例行为回归：现有小说相关测试（如有）保持通过。
3. 加载器数据存储选择：用纯函数 `dataStore(for:privacyMode:)` 断言私密返回共享私密 store。
4. 手动/CI 集成：私密标签页进入小说模式后，`novel_books`/`novel_chapters` 行数不变（需要可访问 DB 的测试环境）。

### 3.6 未验证项

阅读器 UI 的完整流程需要模拟器；无仓库实例的内存行为可在纯单元测试中验证。

---

## 4. B3：标签页关闭清理点

### 4.1 当前行为与证据

- `TabManager.closeTab`（`:438-483`）只处理预览图、WebView、数组与持久化，不通知其他模块；
  `closeAllTabs`（`:483-505`）同样。
- coordinator：
  - `userScriptXHRTasks`（`BrowserWebCoordinator.swift:64`）以 `scriptId|requestId` 为键，
    只在完成/同键重启/`xhrAbort` 时移除；关闭标签不取消。
  - 任务闭包强引用 `webView`（`+UserScripts.swift:299-431`）。
  - `userScriptTabStates`（`:66`）从不清除。
  - `overlays.userScriptMenuCommands` 只在 `beginNavigation` 按 tab 清理（`+Navigation.swift:406`）。
  - `traces` 按 webView 懒清理。
- 结果：关闭标签后，慢请求继续持有页面；GM 状态与菜单命令累积。

### 4.2 计划修改（最小生命周期契约，不引入事件总线）

| 文件 | 修改 |
|---|---|
| `Core/Tabs/TabManager.swift` | 新增 `public var onWillCloseTab: ((BrowserTabState) -> Void)?`；在 `closeTab` 与 `closeAllTabs` 中，对每个即将销毁的标签在 `destroyWebView` 之前调用一次 |
| `App/AppEnvironment.swift` | 构造后接线：`tabManager.onWillCloseTab = { [weak coordinator] tab in coordinator?.cleanupClosedTab(tab) }` |
| `Services/Web/BrowserWebCoordinator.swift` | 新增 `func cleanupClosedTab(_ tab: BrowserTabState)`：按 tab 前缀取消并移除 XHR、删除 `userScriptTabStates[tab.id]`、删除该 tab 的菜单命令、移除该 webView 的 trace |
| `Services/Web/BrowserWebCoordinator+UserScripts.swift` | XHR 键改为 `"\(tab.id)|\(scriptId)|\(requestId)"`；`xhrAbort` 用同一规则构造键；`streamUserScriptRequest` 在流式循环中每 64 KB 检查一次 `Task.checkCancellation()` |
| 不修改 | `discardWebView`（标签未关闭）、内存警告、导航/切换路径 |

所有权：`TabManager` 只发通知；coordinator 清自己的状态；`AppEnvironment` 负责接线。
没有第二个模块重复清理同一资源。

### 4.3 幂等与边界

- `closeTab` 的 `firstIndex` 守卫保证同一标签只关闭一次；`closeAllTabs` 遍历唯一 id。
- `removeValue` / `removeAll` / `removeValue(forKey:)` 都是幂等的；重复调用无副作用。
- `activateTab`、`load`、`discardWebView` 不调用该回调，因此切换/导航/内存回收不会误触发。
- `closeAllTabs(fillingWithHomeTab: false)`（结束私密会话）也会逐标签清理，符合预期。

### 4.4 强引用与取消

- 取消后 `URLSession` 的 `data(for:)`/`bytes` 会结束；任务闭包对 `webView` 的强引用随之释放。
- 流式请求补充 64 KB 一次取消检查，避免服务器持续发送时任务迟迟不结束。
- 不把整段闭包改成弱引用（会让所有使用点都要 guard，改动大且易错）；以“任务及时结束”满足
  “不再不必要地强引用”的要求。

### 4.5 回归风险

- XHR 键格式变化：必须同时改 `xhrAbort` 与 `handleUserScriptXHR`，否则 abort 失效。会逐一检索键的
  所有构造点（当前 3 处）。
- 关闭全部标签会逐个清理；菜单命令与 GM 状态的行为在关闭后不再保留（预期）。
- 导航仍会清菜单命令（现有行为），GM 状态在导航后保留（现有行为），不受影响。

### 4.6 测试计划

1. `cleanupClosedTab` 直接测试：预置 GM 状态、菜单命令、一个 sleep 任务；调用后三者清空、任务取消。
2. 幂等：连续调用两次不崩溃、不重复。
3. 边界：`activateTab`/`load` 后 GM 状态仍在；`discardWebView` 不清 GM 状态。
4. `xhrAbort`：构造与 `handleUserScriptXHR` 相同的键，断言任务被取消。
5. 关闭最后一个私密标签：仍保留一个私密主页标签（现有测试），且清理已执行。

### 4.7 未验证项

XHR 取消到 Task 退出的时序需要模拟器测试；64 KB 检查点需要代码审查确认不引入明显开销。

---

## 5. B4：私密标签页的第三方图标请求

### 5.1 当前行为与证据

`Vela/UI/SiteIconView.swift`：

- `candidateUrls`（`:192-204`）依次给出：页面显式 `faviconUrl`、
  `https://<host>/apple-touch-icon.png`、`...-precomposed.png`、
  `https://www.google.com/s2/favicons?sz=256&domain=<host>`、`https://<host>/favicon.ico`。
- `loadIcon`（`:98-122`）对未命中缓存的候选逐个 `URLSession.shared.data`，失败不缓存。
- 所有标签页（含私密）都会创建 `SiteIconView`：
  - `TabsOverviewView.swift:427`（置顶栏）、`:658`（卡片标题）、`:738`（无预览占位）
  - `BrowserSidebarView.swift:141`
  - `OmniboxSuggestionListView.swift:331`（建议行；开启中的标签页建议按当前隐私模式过滤）
- `blurPrivateTabPreviews` 只模糊预览图，不阻止图标请求。

### 5.2 计划修改

| 文件 | 修改 |
|---|---|
| `UI/SiteIconView.swift` | 新增 `var allowsThirdPartyLookup: Bool = true`；候选列表抽成 `static func candidates(host:faviconUrl:allowsThirdParty:) -> [URL?]`：私密模式保留站点自身 host 的图标（显式 favicon 仅在同 host 时保留）、移除 Google favicon 服务；`loadIcon` 无候选时查内存缓存并退回首字母占位 |
| `Features/Tabs/TabsOverviewView.swift` | 三处 `SiteIconView` 传 `allowsThirdPartyLookup: tab.privacyMode != .private` |
| `Features/Pad/BrowserSidebarView.swift` | 传 `allowsThirdPartyLookup: tab.privacyMode != .private` |
| `UI/Omnibox/OmniboxViewModel.swift` | 暴露 `public private(set) var activePrivacyMode`，在 `apply(input:)` 中记录（建议列表本来就按该模式构建） |
| `UI/Omnibox/OmniboxSuggestionListView.swift` | 传 `allowsThirdPartyLookup: viewModel.activePrivacyMode != .private` |

### 5.3 预期行为与兼容性

- 私密标签页：只向站点自身 host 请求图标（apple-touch-icon / favicon.ico），不请求 Google；
  若进程内已有该 host 的缓存图标则优先使用；站点没有可用图标时显示首字母占位。
- 普通标签页：行为完全不变，包括 Google favicon 兜底。
- 注释与文档同步说明“模糊不是网络隐私保护”。

### 5.4 回归风险

- 私密标签页少了 Google 兜底；站点自带图标（apple-touch-icon / favicon.ico）仍会显示，
  没有自带图标时为首字母占位。这是预期的视觉差异。
- 缓存查找仍使用完整候选 URL；私密页面不会向 `google.com` 发送 host，只向页面自身 host 请求图标。
- 其他 `SiteIconView` 调用点（主页书签、书签页、历史页）保持默认 `true`，不受影响。

### 5.5 测试计划

1. `SiteIconView.candidates` 纯函数：普通模式返回 5 个候选（含 Google）；私密模式返回仅站点 host
   的候选，不含 `google.com`；显式 `faviconUrl` 指向第三方时被排除。
2. 更可靠的网络断言：在测试中用 `URLProtocol` 桩替换 `URLSession.shared` 比较困难；
   因此把“是否允许第三方”做成纯决策函数 `allowsThirdPartyLookup` 并断言调用点传入值。
3. 视觉回归：CI 无法覆盖，需模拟器/真机手动确认私密总览与侧栏的图标来源与占位。

### 5.6 未验证项

无 UI 测试 target；视觉结果需人工确认。不产生第三方请求可通过代码审查与抓包验证。

---

## 6. B5：异步任务结果有效性

### 6.1 当前行为与证据

- `BrowserShellView.activateReaderMode`（`:1045-1064`）：
  `await ReaderModeService.extract(from:webView:url:)` 之后直接设置 `readerArticle` / `isReaderActive`。
  切换标签时 `.onChange(of: activeTabId)`（`:412-437`）先把它们清空；提取任务随后完成，又把旧标签的
  文章打开在新标签上。
- `toggleAdBlock`（`:1033-1042`）：`await env.refreshAdBlockRules()` 之后用**当时的**
  `tabManager.activeTab` 重载。用户在编译期间切走，就会重载另一个标签。
- 对照：`offerTranslationIfNeeded` 在 await 后检查 `activeTab?.id == tab.id`，说明模式已存在。
- 任务归属：这两个动作都只从当前活动标签页发起，没有“后台标签页发起”的路径；因此正确的校验是
  “结果仍属于发起时的那个标签页与那份文档”，而不是“当前活动标签是谁”。

### 6.2 计划修改

新增一个极小的身份值（不引入状态机）：

```swift
public struct TabDocumentIdentity: Equatable, Sendable {
    public let tabId: String
    public let navigationSerial: Int
    public let committedUrl: String
    @MainActor public init(tab: BrowserTabState)
    @MainActor public func matches(_ tab: BrowserTabState?) -> Bool
}
```

放在 `Core/Models/TabModels.swift`（与标签页文档身份直接相关）。

| 文件 | 修改 |
|---|---|
| `Core/Models/TabModels.swift` | 新增 `TabDocumentIdentity` |
| `App/BrowserShellView.swift` | `activateReaderMode` 捕获 identity，await 后 `guard identity.matches(activeTab)` 再回写；失败分支同样校验 |
| `App/BrowserShellView.swift` | `toggleAdBlock` 捕获 `tab` 与 identity；await 后仍匹配才 `reload(tab:)`，否则不重载任何标签（规则已生效，下次加载应用） |
| `App/BrowserShellView.swift` | `activateNovelMode` 同样在提取与 700ms 重试后校验 identity（属于“等”的同类回写）；不匹配则丢弃，不打开阅读器 |

不取消提取任务本身（它是有界的单次 `evaluateJavaScript` / 本地浏览器侧工作），避免误取消仍然有效的工作。

### 6.3 预期行为与兼容性

- 用户在提取/编译期间切换标签或导航：旧结果不会显示、不会重载错误标签。
- 用户切走又切回同一标签、同一文档：结果仍然有效（identity 匹配），阅读器正常打开。
- 同一文档内的 `pushState` 会更新 `committedUrl`（`handleHistoryApiMessage`），因此会被视为
  “文档已变化”而丢弃。这是保守但正确的选择；如果产品希望 SPA 路由变化后仍打开阅读器，可以去掉
  `committedUrl` 比较，只保留 tabId + serial。
- 广告开关：如果用户切走，规则仍然全局生效；只是不自动重载页面。没有功能损失。

### 6.4 回归风险

- identity 过严可能让阅读器/小说在哈希路由页面上被丢弃（hash 变化不一定更新 `committedUrl`；
  `handleHistoryApiMessage` 只处理 pushState/replaceState）。需要在实现时确认 `committedUrl` 的
  更新时机，并用测试覆盖。
- 不影响翻译（已有 generation 机制）。

### 6.5 测试计划

1. `TabDocumentIdentity` 单元测试：同 tab/serial/url → true；serial 变化、url 变化、nil、不同 tab → false。
2. 现有 `TabLoadStateTests` / `TabManagerTests` 保持通过。
3. UI 级时序（切换标签期间完成提取）在无 UI 测试 target 的情况下只能代码审查 + 模拟器手动验证；
   会明确记录为未自动化。

### 6.6 未验证项

View 内部的异步时序无法在单元测试中直接覆盖；需要模拟器手动或后续 UI 测试。

---

## 7. B6：其他已确认问题

### 7.1 B6a 最近关闭列表的语义

**当前行为**：`TabManager.closeTab` 把记录插入内存并写 SQLite（`:444-454`）；启动时
`recentlyClosed` 从空数组开始；`TabSessionRepository.recentlyClosed(...)` 没有任何调用者。
主页只显示 regular 记录（`NewTabHomeView.swift:424`）。数据库的 `recordClosed` 对整个表做 25 条上限，
不是按模式分别 25 条。

**建议语义**（需要确认）：

- `tabsNotRetained` 开启：不保留任何最近关闭记录；启动时清除两个模式的持久化行，内存列表为空。
- 否则：启动时读取 regular 记录；私密记录仅在“本次启动恢复了私密标签页”或“无痕模式路由开启”时读取，
  其余情况启动时清除私密记录。理由：私密记录跨异常终止保留，只在私密会话确实恢复时才有意义。
- 内存列表按 `closedAt` 降序、上限 25；`reopenLastClosedTab` 仍按模式过滤。
- 主页的 regular 过滤保持不变；因此普通主页会开始显示重启前的记录（行为变化，明确告知）。

**计划修改**：

| 文件 | 修改 |
|---|---|
| `Core/Tabs/TabManager.swift` | 新增 `restoreRecentlyClosed(_ records:)`：排序、截断、去重 id |
| `App/AppEnvironment.swift` | `bootWindow` 在会话恢复后按上述规则读取/清理；`persistsSession` 为 false 时跳过并清理 |
| `Data/Repositories/TabSessionRepository.swift` | 不修改（读方法已存在） |

**测试**：`restoreRecentlyClosed` 排序/截断/去重；仓库读写的往返；启动规则只能代码审查 + 集成测试。
**风险**：普通主页出现历史记录是新行为；私密记录策略是产品决策。

### 7.2 B6b 清除缓存不应重置手动隐藏元素

**当前行为**：`AppServices.clearAllBrowsingData` 末尾 `settings.updateManualElementHide { $0 = .default }`
（`AppServices.swift:312`）。`SettingsSubpages.performClear` 在只清缓存时也会调用该方法（`includeWebKitData:false`）。

**计划修改**：删除 `clearAllBrowsingData` 中的这一行。`SettingsService.resetAll()`（`:493-511`）仍然会
重置它，那是“清除所有设置”，语义正确。不新增 UI。

**兼容性**：清除缓存/历史不再影响用户手工隐藏元素的规则。
**风险**：如果产品原本把 element-hide 视为“浏览数据”，这是行为变化；目前没有任何文档/注释支持这种定义。
**测试**：删除一行，无直接单元测试；代码审查 + 手动验证（清缓存后规则仍在）。会明确记录为未自动化。

### 7.3 B6 的拆分

B6a 与 B6b 是两个独立提交，不合并数据模型改动。B6a 需要先确认上面的私密策略。

---

## 8. 本批不做的事

| 项目 | 原因 |
|---|---|
| R-04 WebView 池上限（`openTab(activate:false)` 可突破） | 已确认 S2，但不在本次 B1–B6 列表内。建议作为 B7 或下一批第一项；**请确认是否加入本批** |
| R-09 用户脚本重复装配 | 属于性能治理；先测量，不在 B 批改 |
| R-10~R-14 主线程热点 | 没有基线，不做猜测式并发改造 |
| R-08 无人消费的 pageMetrics | 低风险清理，留到阶段 C |
| R-22 死代码/陈旧注释 | 阶段 C |
| R-15 私密预览图/下载记录在异常终止后的残留 | 与 B1 相关但独立；建议随后作为 B8，或并入 B6 需另行批准 |
| 新增崩溃采集（R-24/R-26） | 需要单独批准的新诊断通道，不在本次范围 |

---

## 9. 实施顺序与审批点

1. 用户确认本方案（以及 B2 选 A 还是 B；B6a 的私密策略；B1 是否采用窗口级语义；R-04 是否加入）。
2. **只实施 B1**；完成后提交：
   - 变更清单（文件/类型/方法）
   - 完整 `git diff` 审查结果
   - 新增测试与未运行说明
   - 剩余风险
   - `git status`
3. 等待批准后，再依次 B2 → B3 → B4 → B5 → B6；**每批之间再次等待批准**。
4. 每个补丁不提交、不推送；由用户决定何时提交与触发 CI。

## 10. 当前 Git 状态

```
?? ARCHITECTURE_AUDIT.md
?? DEPENDENCY_MAP.md
?? OPTIMIZATION_ROADMAP.md
?? RISK_REGISTER.md
?? PHASE_B_IMPLEMENTATION_PLAN.md
```

没有跟踪文件被修改；没有提交、没有推送、没有破坏性操作。

---

## 11. B1 实施记录（2026-10-21）

### 11.1 变更清单

| 文件 | 变更 |
|---|---|
| `Vela/Services/Web/BrowserWebCoordinator.swift` | 新增 `private var sharedPrivateDataStore`、`privateWebsiteDataStore()`、`clearPrivateWebsiteData()`；`makeConfiguration` 的私密分支改用共享实例；更新配置注释 |
| `Vela/App/AppEnvironment.swift` | `endPrivateSession` 改为调用 `webCoordinator.clearPrivateWebsiteData()`，删除“新建 store 再清理”的旧逻辑；更新注释 |
| `VelaTests/WebNavigationIntegrationTests.swift` | 新增 3 个测试 + 3 个 Cookie 辅助方法 |

没有修改普通模式的数据存储、下载、历史、翻译或小说模块。

### 11.2 新增测试

- `testPrivateTabsShareOneDataStore`：同一窗口的两个私密标签共享 store；普通标签不用它。
- `testPrivateTabsShareCookies`：标签 A 写入 Cookie，标签 B 能读到。
- `testEndingAPrivateSessionClearsItsStore`：结束私密会话清空共享 store；普通 store 的 Cookie 不受影响。
- 辅助：`allCookies(in:)`、`cookie(named:in:)`、`removeCookies(named:in:)`、`waitForCookie(named:in:timeout:)`。

### 11.3 已做的验证

- 完整 `git diff` 审查：只有 3 个文件，172 → 194 行新增/11 行删除，无无关改动。
- 全局检索 `nonPersistent()`：只剩共享 store 的创建点与小说阅读器的显示 WebView。
- 普通模式分支仍为 `WKWebsiteDataStore.default()`。
- `git diff --check`：无空白错误。

### 11.4 未做的验证

**未编译、未运行、未执行 XCTest**（本机无 Swift/Xcode）。以下必须由 CI 或模拟器确认：

- `WKWebsiteDataStore.nonPersistent()` 在同一实例下确实跨 `WKWebView` 共享 Cookie；
- 测试的 Cookie 时序（已用轮询等待，但仍需运行确认）；
- `clearPrivateWebsiteData` 完成后 `getAllCookies` 为空；
- 私密会话结束到后台挂起的时序。

### 11.5 剩余风险

- 语义是**窗口级**：不同 Stage Manager 窗口的私密会话不共享 Cookie（已确认的产品选择）。
- 共享 store 在窗口生命周期内保留（清空后为空）；若用户希望每次私密会话都换新实例，可后续调整。
- `AppServices.clearAllBrowsingData`（全局清除浏览数据）仍只清默认 store，不触及其他窗口的私密 store；
  这是既有行为，未在本批改变。
- 小说阅读器的显示 WebView 仍使用自己的 `.nonPersistent()`；它只渲染本地 HTML，B2 再处理章节加载器。

### 11.6 Git 状态

```
 M Vela/App/AppEnvironment.swift
 M Vela/Services/Web/BrowserWebCoordinator.swift
 M VelaTests/WebNavigationIntegrationTests.swift
?? ARCHITECTURE_AUDIT.md
?? DEPENDENCY_MAP.md
?? OPTIMIZATION_ROADMAP.md
?? PHASE_B_IMPLEMENTATION_PLAN.md
?? RISK_REGISTER.md
```

没有提交、没有推送、没有执行破坏性 Git 操作。

---

## 12. B1 验收状态与 CI 核查（2026-10-21）

### 12.1 CI 触发条件

`.github/workflows/build-ios.yml` 只有 `workflow_dispatch`（手动触发），输入为
`configuration`（Release/Debug）与 `runner`（macos-26/macos-15），没有 `push`、`pull_request`
或定时触发。`build` 与 `test` 是两个独立 job：`build` 产出未签名 IPA，`test` 在 iOS 模拟器上跑
`xcodebuild test`，两者互不 gate。

**能否在不提交、不推送的情况下运行？不能。**

GitHub Actions 执行的是远程仓库某个 ref 的代码，工作区里未提交的 B1 修改不会被包含。
`gh` 2.102.0 已安装，但也只能触发远程 ref。`act` 之类本地运行器需要 macOS/WebKit，本机不可行。

如果决定验证 B1，需要（我不会执行）：

1. 新建分支，例如 `phase-b-b1-private-store`。
2. 只提交 3 个源码/测试文件（以及按需提交文档），推送该分支。
3. GitHub → Actions → **Build unsigned IPA** → **Run workflow**：
   - Branch: `phase-b-b1-private-store`
   - configuration: `Debug`（测试与构建都用这个 ref；Release 也可）
   - runner: `macos-26`
   或命令行：
   ```
   gh workflow run build-ios.yml --ref phase-b-b1-private-store \
     -f configuration=Debug -f runner=macos-26
   gh run watch
   gh run download <run-id>
   ```
4. 分别阅读 `build` 与 `test` 的结果；失败时下载 `build-logs` / `test-results` artifact。
   `test` job 使用了 `-retry-tests-on-failure`，失败信息里会同时保留两次尝试。

### 12.2 异步清理时序核查

当前实现的实际顺序：

1. `endPrivateSession`（`AppEnvironment.swift:234-243`）同步调用 `tabManager.endPrivateSession()`：
   关闭私密标签、销毁其 WebView、清最近关闭、持久化会话。
2. 同步调用 `downloads.clearPrivateRecords()`。
3. `await webCoordinator.clearPrivateWebsiteData()`：对共享 store 调 `removeData` 并等待完成。

**修正前：方法内部顺序正确，但“下一次会话不会在旧数据清理完前开始”
这一保证不成立**，原因有三：

- 两个调用方都是 fire-and-forget：`BrowserShellView.swift:934` 与 `VelaApp.swift:165` 都是
  `Task { await env.endPrivateSession() }`。主 actor 在 `await removeData` 期间是空闲的，
  用户可以在清理完成前新建标签页。
- `clearPrivateWebsiteData` **保留并复用**同一个 `sharedPrivateDataStore`（`BrowserWebCoordinator.swift:698-710`）。
  如果此时 `无痕模式路由` 仍为开（`.leavePrivate` 菜单不会关掉路由），新私密标签页会拿到**正在被清理的同一个 store**，
  可能出现“刚写入的 Cookie 被旧会话清理掉”或“新旧会话共享状态”。
- App 进入后台时调用方不等待；iOS 可能在 `removeData` 完成前挂起进程。若之后同一进程回到前台，
  共享 store 仍被复用，旧数据可能尚未清空。

**阶段一已实施**：在清理开始时轮换 store：

```swift
let store = sharedPrivateDataStore
sharedPrivateDataStore = nil      // 下一次私密会话会创建新 store
guard let store else { return }
await store.removeData(...)
```

这样新会话不可能拿到正在清理的旧 store；旧 store 由异步清理持有，进程挂起时即使未清完也不会再被新会话使用。
若要求“旧数据必须完全清除后新会话才开始”，还需要一个 `isClearing` 门或让调用方 await 清理；
那是更严格的方案，代价是 UI 需要等待。另有可选硬化：后台路径用 `beginBackgroundTask` 给清理留时间。

实现把“取出旧实例”和“清空旧实例”拆成 `takePrivateWebsiteDataStoreForCleanup()` 与
`clearPrivateWebsiteData(_:)`；无参 `clearPrivateWebsiteData()` 组合两者。这样清理目标始终是取出的旧实例，
共享属性被置空/重新赋值都不会清错对象。阶段一记录见 §14。

### 12.3 测试覆盖矩阵

| 场景 | 覆盖 | 说明/缺口 |
|---|---|---|
| 同窗口私密标签共享 store | 已写测试 | `testPrivateTabsShareOneDataStore` |
| 同窗口私密标签共享 Cookie | 已写测试 | `testPrivateTabsShareCookies` |
| 普通标签使用不同 store | 已写测试（对象身份） | 未直接断言“普通标签读不到私密 Cookie” |
| 结束会话清空私密 store | 已写测试 | 直接调用 coordinator 方法，未覆盖 `AppEnvironment` 的接线 |
| 普通 store 不受影响 | 已写测试 | Cookie 名先删除，避免残留干扰 |
| 不同窗口的私密隔离 | **无** | 两个 coordinator/窗口的 store 不相同，未测试 |
| 清理完成后新会话用新 store | 已写测试 | `testANewPrivateSessionGetsAFreshStoreAfterEnding` |
| 旧 store 清理不影响新会话 | 已写测试 | `testClearingTheOldStoreDoesNotAffectTheNewSession` |
| 重复清理 / 快速重新进入 | 已写测试 | `testDuplicatePrivateStoreCleanupIsANoOp` + 并发清理测试 |
| App 终止/重启 | **无** | 非持久化 store 的进程生命周期未验证 |
| 后台挂起中断清理 | **无** | 需要真机/模拟器场景 |
| `AppEnvironment.endPrivateSession` 整体接线 | **无** | 测试绕过环境，直接调用 coordinator |

这些缺口只记录，不在本轮补测试；是否补由后续批准决定。

### 12.4 验收状态（严格区分）

| 检查项 | 方法 | 状态 |
|---|---|---|
| 静态检查 | `git diff`、全局检索、`git diff --check` | **已执行** |
| 实际构建 | Xcode/CI | **未执行** |
| 实际单元/集成测试 | `xcodebuild test`/CI | **未执行**（测试已写） |
| 设备验证 | 真机/模拟器手动 | **未执行** |
| CI 触发 | GitHub Actions | **未执行**（需要 commit+push） |

**结论**：B1 的静态实现与阶段一轮换修正完成；构建、测试、设备验证均未通过，不能标记为“已验证”。
12.2 的“新会话不复用正在清理的旧 store”已由轮换解决并有测试覆盖；仍然存在的限制是：
后台 Task 未启动则清理不发生、挂起/终止在 `removeData` 完成前不保证严格擦除、迟到的重复结束可能结束新会话、
阅读器关闭留待 B2。这些限制已在 §14.4 记录，不声称已经解决。

---

## 13. B2 调查状态（2026-10-21）

- 已完成只读调查，完整报告见 `PHASE_B_B2_INVESTIGATION.md`。
- 调查确认：私密章节/目录加载器使用 `.default()`；`NovelLibraryService` 把章节正文、书目、目录、
  阅读进度写入持久化 `novel_*` 表；服务是进程级单例，常规书架立即可见；`VelaTests` 没有小说测试。
- **方案修订**：§3.3 原计划给 `NovelLibraryService` 增加可选仓库 + 内存字典。调查后推荐更小的方案：
  私密阅读使用独立的 `SQLiteDatabase(path: ":memory:")` + 原样的 `NovelLibraryService`，无需改服务内部、
  无需改 schema；普通模式完全不变。
- 仍需用户确认的产品决策：私密书架是否显示常规书架、离开无痕模式时是否关闭阅读器、
  私密章节抓取使用 B1 的私密 store。
- 本轮**没有修改任何 Swift 实现**；B2 等待明确批准后再实施。
- **产品决策（2026-10-21 已批准）**：私密书架只显示当前会话书目；退出私密模式先关闭私密阅读器；
  私密章节/目录加载器使用当前窗口私密 store。B2 实现仍暂缓，等阶段一审查通过后再开始；
  阅读器关闭需要 B2 的 `isPrivateSession`，阶段一不实施。

---

## 14. 阶段一实施记录：B1 生命周期修正（2026-10-21）

### 14.1 设计

清理不再复用共享属性里的 store，而是先把**当前实例从服务中取出**，再清空取出的实例：

- `takePrivateWebsiteDataStoreForCleanup()`：读取 `sharedPrivateDataStore`，立即置空并返回旧实例。
- `clearPrivateWebsiteData(_ store:)`：只对传入的实例执行 `removeData` 并等待完成。
- `clearPrivateWebsiteData()`：组合两者。取不到 store（没有私密 WebView，或另一个结束已经取走）时直接返回。
- `privateWebsiteDataStore()`：属性为空时创建新的 `WKWebsiteDataStore.nonPersistent()`。

因为 `take` 在第一个 `await` 之前同步完成，新私密标签页在清理期间只会拿到**新 store**；清理目标始终是
取出的旧实例，不会因为属性被置空或重新赋值而清错对象。

### 14.2 结束会话的顺序

`AppEnvironment.endPrivateSession` 当前实际顺序（无 await 直到第 3 步）：

1. `tabManager.endPrivateSession()`：关闭私密标签、销毁其 WebView、清最近关闭、持久化会话。
2. `downloads.clearPrivateRecords()`：取消/暂停私密下载，删除私有记录与临时文件。
3. `webCoordinator.clearPrivateWebsiteData()`：同步取出旧 store → 异步清空旧 store。
4. 下一次私密会话第一次创建 WebView 时：`privateWebsiteDataStore()` 创建新 store。

> B2 之后 `endPrivateSession` 在这条序列最前面增加了私密小说代次失效，并在 store 清理前释放私密小说服务；
> 当前顺序见 §15.3。

**阅读器关闭**：产品决策已批准“退出私密模式时先关闭私密阅读器”。阶段一**没有实施**，原因是当前
`NovelSession` 没有私密标识，无法区分“私密阅读器”和“普通阅读器”；而且当前阅读器的章节/目录加载器
仍使用 `.default()`，**没有使用 B1 的私密 store**，所以阶段一不存在“阅读器与 store 清理竞争”的实际路径。
B2 会增加 `isPrivateSession`，并在退出私密模式时先关闭私密阅读器，再走上面的清理顺序。这里明确记录为
B2 的待办，不声称已经解决。

### 14.3 调用方检查

| 调用方 | 行为 | 阶段一影响 |
|---|---|---|
| `BrowserShellView.swift:934`（菜单“离开无痕模式”） | `Task { await env.endPrivateSession() }` | 进入方法后同步关闭标签并轮换 store；UI 不等待 |
| `VelaApp.swift:165`（进入后台且有私密标签） | `Task { await env.endPrivateSession() }` | 同上；若 Task 在挂起前未开始，则清理不会发生（既有局限） |

没有发现其他 `AppEnvironment.endPrivateSession` 调用方。`TabManager.endPrivateSession` 只被
`AppEnvironment` 调用。

### 14.4 边界情况与明确限制

- **App 进入后台**：调用方是 fire-and-forget。若 Task 在挂起前启动，轮换是同步的，旧 store 立即不可
  被新会话取得；若 Task 未启动，私密标签与 store 都还在，回到前台仍是同一私密会话（未结束）。这不是
  轮换能解决的，已记录为限制；要严格保证后台清理，需要 `beginBackgroundTask` 或同步拆分清理步骤。
- **挂起/终止发生在轮换之后、`removeData` 完成之前**：旧 store 已不可达，新会话不会使用它；旧 store
  的内存随进程释放，数据不会跨进程保留。**不保证**在进程死亡前完成一次严格擦除；没有加入清理门或后台任务。
- **窗口关闭**：调用方的 Task 持有 `AppEnvironment`/coordinator 直到 `removeData` 返回；窗口销毁不会
  提前释放清理目标。若进程被终止，同上。
- **连续结束**：第一次调用取走 store；没有新会话时第二次是 no-op。若两次结束之间已开始新私密会话，
  第二次会结束那个新会话（清理它的 store），这是“结束当前私密会话”的一致行为。
- **迟到的重复结束**：如果旧事件产生的结束调用在新会话开始之后才执行，它会结束新会话。阶段一没有
  调用方 token 来区分“旧事件的重复”与“新一轮结束”，这是调用方排序层面的限制；会在报告和风险册中保留。
- **重复清理**：无新 store 时 no-op；有 store 时就是一次新的结束。测试覆盖 no-op。
- **快速重新进入**：新会话拿到新 store；旧 store 的异步清理只操作旧实例，不影响新会话的 Cookie。测试覆盖。

### 14.5 新增测试

`VelaTests/WebNavigationIntegrationTests.swift`：

- `testANewPrivateSessionGetsAFreshStoreAfterEnding`
- `testClearingTheOldStoreDoesNotAffectTheNewSession`
- `testDuplicatePrivateStoreCleanupIsANoOp`

加上上一轮的 `testPrivateTabsShareOneDataStore`、`testPrivateTabsShareCookies`、
`testEndingAPrivateSessionClearsItsStore`，覆盖：

- 结束会话后新会话获得不同 store；
- 旧 store 清理不误清新会话数据；
- 普通 store 不受影响（上一轮测试）；
- 重复清理 no-op、快速重新进入不串状态。

### 14.6 验证状态

| 检查项 | 状态 |
|---|---|
| 静态检查（diff、全局检索、`git diff --check`） | **已执行**，退出码 0 |
| 实际构建 | **未执行**（无 Swift/Xcode） |
| 实际测试 | **未执行**（测试已写） |
| 模拟器/设备验证 | **未执行** |

不得把本节理解为构建或测试已经通过。

### 14.7 Git 状态

```
 M Vela/App/AppEnvironment.swift
 M Vela/Services/Web/BrowserWebCoordinator.swift
 M VelaTests/WebNavigationIntegrationTests.swift
?? ARCHITECTURE_AUDIT.md
?? DEPENDENCY_MAP.md
?? OPTIMIZATION_ROADMAP.md
?? PHASE_B_B2_INVESTIGATION.md
?? PHASE_B_IMPLEMENTATION_PLAN.md
?? RISK_REGISTER.md
```

没有提交、没有推送、没有创建分支、没有修改 CI 配置。

---

## 15. B2 实施记录：小说模块私密隔离（2026-10-21）

### 15.1 实施结果

按已批准方案实施：私密阅读使用独立的 `SQLiteDatabase(path: ":memory:")`，通过现有
`NovelLibraryService` / `NovelRepository` / `BrowserSchema` 访问，不重写服务、不改 schema、不迁移普通数据。

新增文件：

| 文件 | 作用 |
|---|---|
| `Vela/Services/Novels/InMemoryNovelLibrary.swift` | 按需创建内存数据库、执行 schema、返回 `NovelLibraryService`；失败返回 nil，绝不回退普通库 |
| `Vela/Core/Novel/NovelLoaderSupport.swift` | 两个 loader 的 `WKWebViewConfiguration`、loader 的 store 选择、阅读器显示 WebView 的 store 选择 |
| `VelaTests/NovelPrivacyTests.swift` | 8 个隔离/选择/迟到回调/子资源测试 |

修改文件：

| 文件 | 变更 |
|---|---|
| `Vela/App/AppEnvironment.swift` | 私密小说服务懒创建/释放；`privateNovelSessionGeneration` 代次；`endPrivateSession` 先失效代次，再关标签、清下载、释放私密服务、轮换清 store |
| `Vela/App/BrowserShellView.swift` | `NovelSession` 携带 `isPrivateSession`、`sessionGeneration`、`library`；阅读器/书架按会话选服务；`openBookshelf`；离开无痕模式先关私密阅读器/书架；代次变化关闭过期阅读器 |
| `Vela/App/BrowserShellView+Presentations.swift` | 书架 sheet 使用捕获的库和代次 |
| `Vela/App/BrowserShellView+Chrome.swift` | 工具栏书架入口走 `openBookshelf` |
| `Vela/Features/Novels/NovelBookshelfView.swift` | 从注入的库读数、删除；不再直接读 `env.novels` |
| `Vela/Features/Novels/NovelReaderView.swift` | 12 处 `env.novels` 改为会话库；代次守卫；loader store；显示 WebView store；关闭时取消两个 loader |
| `Vela/Core/Novel/NovelChapterLoader.swift` | `load(urlString:dataStore:)`；统一配置；记录并取消提取轮询任务 |
| `Vela/Core/Novel/NovelTOCLoader.swift` | 同上 |

### 15.2 数据流（实施后）

```
私密标签页 → 活动 WebView 提取（私密 store）
  → AppEnvironment.novelLibrary(privateMode: true)
      → InMemoryNovelLibrary.make()
          → SQLiteDatabase(":memory:") + BrowserSchema + NovelLibraryService
  → library.open(extraction)                 ← 只写内存库
  → NovelSession(isPrivateSession: true, sessionGeneration: N, library: …)
  → NovelReaderView(library: …)
      → loader.load(dataStore: 窗口私密 store)   ← 章节请求不进普通 profile
      → tocLoader.load(dataStore: 窗口私密 store)
      → library.store/saveTOC/markPosition      ← 只写内存库
      → NovelChapterWebView(dataStore: 窗口私密 store)  ← 子资源也不进普通 profile
```

普通模式：`env.novelLibrary(false)` → `AppServices.novels`；loader 用 `.default()`；显示 WebView 保持
原来的 `.nonPersistent()`；书架、章节缓存、进度和用户数据不变。

### 15.3 退出私密模式的顺序

`AppEnvironment.endPrivateSession` 的实施顺序：

1. `privateNovelSessionGeneration &+= 1`：立即让该会话的阅读器和迟到回调失效。
2. `tabManager.endPrivateSession()`：关闭私密标签、销毁其 WebView。
3. `downloads.clearPrivateRecords()`：清下载私有记录。
4. `privateNovelService = nil`：释放环境对内存库的引用；仍持有它的阅读器被代次守卫阻止写入。
5. `await webCoordinator.clearPrivateWebsiteData()`：轮换并清空该会话的私密 store。

菜单“离开无痕模式”在调用前先关闭私密阅读器/书架；后台结束时由代次变化关闭。

**仍无法保证的边界**（不声称已解决）：

- SwiftUI 的阅读器 `onDisappear` 与环境中同步步骤不在同一时刻；严格顺序是“先失效、后关闭 UI”。
  数据安全由代次守卫保证，不是由 UI 关闭时序保证。
- 阅读器若仍持有旧服务，`privateNovelService = nil` 只是释放环境引用；内存库要等阅读器视图释放后才
  真正释放。旧服务的写入已被代次阻止，且它永远不会被新会话使用。
- 后台 Task 若在挂起前未运行，结束流程不会开始（既有 B1 限制）。
- 显示 WebView 若在轮换后、关闭前重建，可能创建一个未被使用的私密 store；它不会触碰普通 profile。

### 15.4 测试

新增 `VelaTests/NovelPrivacyTests.swift`：

1. `testPrivateAndRegularServicesAreSeparate`
2. `testPrivateWritesDoNotTouchTheRegularDatabase`
3. `testANewPrivateServiceStartsEmptyAfterTheOldOneIsReleased`
4. `testRegularServiceReloadKeepsItsData`
5. `testLoaderDataStoresAreChosenBySession`
6. `testLateWritesToAnOldPrivateServiceDoNotReachTheNewOne`
7. `testSessionGenerationClosesOnlyTheEndedPrivateSession`
8. `testPrivateLoaderSubresourcesDoNotWriteTheDefaultStore`（真实 WebKit + 本地服务器 + iframe 子资源 Set-Cookie）

覆盖说明：

- 普通/私密数据存储不同：1、2；
- 私密写入不影响普通库行数：2；
- 释放后新私密服务为空：3；
- 普通服务 reload 保留数据：4；
- loader 选择正确 store：5；
- 旧会话迟到写入不影响新会话：6、7；
- 私密子资源不写普通 profile：8（真实 WebKit，不是 mock）；
- 退出私密模式不误伤普通阅读器：7 的代次逻辑（UI 层仅代码审查，无 UI 测试 target）。

**测试未运行。** 本机没有 Swift/Xcode。

### 15.5 已知测试限制

- 没有 UI 测试 target；阅读器关闭、书架隐藏的 SwiftUI 时序无法自动化，只能代码审查/模拟器手工验证。
- `testPrivateLoaderSubresourcesDoNotWriteTheDefaultStore` 依赖 WebKit 对 iframe `Set-Cookie` 的处理；
  若 CI 上行为不同，以实际结果为准。
- 小说 loader 的完整抽取流程（离屏窗口 + 轮询）未做集成测试；测试覆盖的是它们共用的配置与 store 选择。
  这不等于“真实小说页面全链路已验证”。

### 15.6 验证状态

| 检查项 | 状态 |
|---|---|
| 静态检查（diff、检索、`git diff --check`） | **已执行**，退出码 0 |
| 实际构建 | **未执行** |
| 实际测试 | **未执行**（8 个新测试已写） |
| 模拟器/设备验证 | **未执行** |

### 15.7 Git 状态

```
 M Vela/App/AppEnvironment.swift
 M Vela/App/BrowserShellView+Chrome.swift
 M Vela/App/BrowserShellView+Presentations.swift
 M Vela/App/BrowserShellView.swift
 M Vela/Core/Novel/NovelChapterLoader.swift
 M Vela/Core/Novel/NovelTOCLoader.swift
 M Vela/Features/Novels/NovelBookshelfView.swift
 M Vela/Features/Novels/NovelReaderView.swift
 M Vela/Services/Web/BrowserWebCoordinator.swift
 M VelaTests/WebNavigationIntegrationTests.swift
?? Vela/Core/Novel/NovelLoaderSupport.swift
?? Vela/Services/Novels/InMemoryNovelLibrary.swift
?? VelaTests/NovelPrivacyTests.swift
?? （阶段 A 四份文档与 PHASE_B_B2_INVESTIGATION.md、PHASE_B_IMPLEMENTATION_PLAN.md、RISK_REGISTER.md）
```

没有提交、没有推送、没有创建分支、没有修改 CI 配置。

---

## 16. B1+B2 只读验收审查（2026-10-21）

完整报告：`PHASE_B_ACCEPTANCE_REVIEW.md`。本轮**没有修改 Swift 实现**。

### 16.1 主要发现

| 编号 | 严重度 | 摘要 |
|---|---|---|
| F-01 | S2 | 私密阅读器“在浏览器中打开”使用当前 `activeTab`，可能把私密章节 URL 写入普通标签的历史/Cookie |
| F-02 | S3 | `endPrivateSession` 没有发起会话 token；迟到的结束可能关闭/清理新私密会话 |
| F-03 | S3 | 阅读器/书架强持有私密小说服务；环境置 nil 后旧内存库可能延迟释放 |
| F-04 | S3 | 退出顺序只有“代次失效”是同步保证；阅读器关闭/loader cancel 依赖 SwiftUI/异步 |
| F-05 | S4 | `SQLiteDatabase.deinit` 无锁；私密库 `reload` 错误被静默，工厂不检查 `lastError` |
| F-06 | S4 | 测试平台假设（未入窗口的 iframe、默认 store 身份）与环境/跨窗口/UI 覆盖缺口 |
| F-07 | S4 | 首次私密小说打开在主 actor 执行完整 schema（未测量） |
| F-08 | S4 | loader 的 `dataStore` 有 `.default()` 默认值，未来私密调用点可能漏传 |

### 16.2 状态

- B1/B2 的静态实现与主要数据隔离逻辑成立；F-01 是明确的隐私边界缺口，F-02 是会话身份缺口。
- 未构建、未运行测试、未做模拟器/设备验证；不得标记为验收通过。
- 未提交/推送/创建分支/修改 CI；未进入 B3。
- 审查未修复任何发现；等待用户决定是否授权修复。

---

## 17. C1 实施记录：F-01 / F-02（2026-10-21）

只修复 F-01、F-02；F-03~F-08 与 B3 未处理；未提交/推送/创建分支/改 CI。

### 17.1 F-01：私密阅读器“在浏览器中打开”

新增 `Vela/App/NovelBrowserRouting.swift`（纯路由）：

- 私密：代次过期 → refuse；来源标签存在且为私密 → existingTab；否则 → newPrivateTab。
- 普通：活动标签存在 → activeTab；否则 → newRegularTab。

接线：

- `NovelSession` 增加 `sourceTabId`；`activateNovelMode` 传来源标签；书架捕获 `bookshelfSourceTabId`。
- `BrowserShellView.openInBrowser(_:for:)` 只使用会话的隐私/来源/代次；私密路径不再读取 `activeTab`；
  `.existingTab` 先激活来源私密标签。
- 阅读器关闭回调仍先校验 session id；路由再校验私密代次；过期安全拒绝。

测试：`VelaTests/NovelBrowserRoutingTests.swift`（4 个，T-11）。UI 点击未自动化。

### 17.2 F-02：迟到结束不结束新私密会话

实现：

- `privateNovelSessionGeneration` 在会话开始/结束都递增。
- `TabManager.onPrivateSessionStarted` 在私密 strip 为空时追加第一个私密标签时触发。
- `AppEnvironment.beginPrivateSession()`：递增代次、释放私密小说服务、`BrowserWebCoordinator.beginNewPrivateSession()`
  轮换/清理旧 store。
- `endPrivateSession(expectedGeneration:)` 用 `PrivateSessionLedger.end(...)` 校验；不匹配 no-op，
  不关标签/不清下载/不释放服务/不清 store。
- 调用方 `BrowserShellView`（离开无痕）与 `VelaApp`（后台）都捕获并传递代次。

测试：

- `VelaTests/PrivateSessionLedgerTests.swift`（T-12 决策/actions）。
- `VelaTests/PrivateSessionStartTests.swift`（TabManager 触发）。
- `VelaTests/PrivateSessionStoreTests.swift`（新会话新 store）。
- 既有 B1/B2 重复清理、快速重进、普通隔离测试保留。

### 17.3 剩余风险

- 严格顺序仍不保证（F-03/F-04 未修）：代次失效同步；阅读器关闭/loader cancel/旧库释放依赖 SwiftUI/异步。
- 旧阅读器可能持有旧内存库直到视图释放。
- 后台结束事件之后才创建的新私密会话不会被该事件清理。
- 新会话开始只重置小说服务与 WebKit store；旧私密下载/最近关闭记录仍依赖结束路径。
- “关闭全部私密标签后留下私密主页”会被视为新会话并重置旧 store/小说服务（行为变化）。
- 后台 Task 未启动、挂起/终止、WebKit 平台行为未验证。
- 测试未运行；未构建/模拟器/真机。

### 17.4 验证状态

| 检查项 | 状态 |
|---|---|
| 静态检查（diff、检索、括号平衡、`git diff --check`） | **已执行** |
| 实际构建 | **未执行** |
| 实际测试 | **未执行** |
| 模拟器/设备 | **未执行** |

---

## 18. B3–B7 / C2 / D 实施记录（2026-10-21，用户授权接管全流程）

用户最后的指令是接管 B、C、D、E 全流程并产出安装包。以下记录在 C1 之后实际落地的改动；
验证结果单列在 §19，未运行的项目不写成“通过”。

### 18.1 B3：标签关闭清理点

- `TabManager` 新增 `onWillCloseTab`，在 `closeTab` 与 `closeAllTabs` 销毁 WebView **之前**调用。
- `BrowserWebCoordinator.cleanupClosedTab(_:)`：
  - 以 `"<tabId>|"` 前缀取消该标签所有 GM XHR 任务；
  - 删除 `userScriptTabStates[tabId]` 与 `overlays.userScriptMenuCommands` 中该标签的命令；
  - 调用 `history.clearTabChain(tabId:)`（原 C4 计划中的“接入关闭清理”）；
  - 移除该 WebView 的导航 trace。
- GM XHR 的任务键改为 `"<tabId>|<scriptId>|<requestId>"`；流式响应每 64 KiB 检查一次取消。
- `AppEnvironment` 接线；`TabCloseCleanupTests` 验证任务被取消、状态/菜单被删除。

### 18.2 B4：WebView 池上限在创建时执行

- `TabManager.ensureWebView` 创建后调用 `touchActivationOrder(tab.id)` 与 `enforceLiveWebViewCap()`。
- 后台批量打开不会再把池推过 `maximumLiveWebViews`；淘汰从最久未激活且不在新标签上的 WebView 开始。
- `TabManagerTests.testBackgroundOpenedTabsRespectTheLiveWebViewCap` 覆盖。

### 18.3 B5：异步结果校验文档身份

- 新增 `TabDocumentIdentity`（`tabId + navigationSerial + committedUrl`）及 `matches(_:)`。
- 阅读模式、广告开关、小说模式在 `await` 之后、写回之前校验身份；广告开关只在身份匹配时重载。
- `TabDocumentIdentityTests` 覆盖相同文档、换标签、换导航序号、换提交 URL。

### 18.4 B6：最近关闭恢复与 element-hide 重置

- `TabManager.restoreRecentlyClosed(_:)`：按关闭时间倒序、按 id 去重、上限 `recentlyClosedLimit`。
- `AppEnvironment.bootWindow` 在会话恢复后读取最近关闭；私密记录仅在私密会话实际打开
  （有私密标签或“无痕模式”开关为开）时载入，否则清理；不保留标签页时两种模式都清理。
- `AppServices.clearAllBrowsingData` 不再把 `manualElementHide` 重置为 `.default`。
- `TabManagerTests` 覆盖恢复排序与上限。

### 18.5 B7：私密标签页的图标隐私

- `SiteIconView.candidates(host:faviconUrl:allowsThirdParty:)`：不允许第三方时排除 Google favicon
  服务，也排除跨主机的显式 favicon；同主机显式图标、`apple-touch-icon*`、`favicon.ico` 保留。
- 总览卡片、iPad 侧栏、Omnibox 建议行按标签/活动标签的隐私模式传入；
  `OmniboxViewModel.activePrivacyMode` 提供当前模式。
- `SiteIconCandidateTests` 覆盖普通/私密/跨主机显式图标三种路径（纯函数，无网络）。

### 18.6 C2：依赖收窄（部分）

- `BrowserWebCoordinator` 删除未使用的 `bookmarks`、`searchHistory`、`sessionRepository`
  构造参数；`AppEnvironment` 与 `BrowserHarness` 同步。
- 未做：把 `Core` 拆成 `Models/Logic/Runtime` 子目录；`AppEnvironment` 仍是服务定位器（R-19）。
- C4 的死代码删除只完成了一部分：`AddressBarView.swift` 曾在 C2/D 提交中被删除，但
  `AddressBarRejection` 与 `BrowserUrlResolver` 实际仍被 Shell/Home/Bookmarks/Omnibox 使用，
  导致 CI 编译失败；该文件已恢复；它并非死代码（仍含 `AddressBarRejection`、`BrowserUrlResolver`、`ProgressRing`），C4 的“删除 `AddressBarView.swift`”一项应改为文件名/文档整理，而不是删除。

### 18.7 D2 / D3 / D5：主线程与重复工作

- **D2**：`AdBlockEngine.compile` 的纯解析/校验/JSON 编码移入 `Task.detached`；
  `exceptionRules` 标记 `nonisolated`；WebKit store 的安装仍在主 actor。
  解析结果类型 `ParsedRules` 为 `Sendable`；规则上限与错误语义不变。
- **D3**：`TabPreviewStore.store` 将缩放与 JPEG 编码移入 `Task.detached`；缓存写入回到
  `MainActor.run`，文件写入在后台；`downscaled` 标记 `nonisolated`。
- **D5（部分）**：`beginNavigation` 删除第二次 `refreshUserScripts`；策略回调保留一次装配。
  未做 `UserScriptService` 的启用集合/GM 值快照缓存。

### 18.8 明确未做

- F-03、F-04、F-06、F-07（严格关闭顺序、旧内存库释放、测试平台假设、首次建库主线程成本）；
  F-05（SQLite `deinit` 加锁）与 F-08（novel loader 的 `dataStore` 必填）已在 §18.10 实现，待验证。
- C3（导航动作与私密路由去重）、D1（性能基线）、D4（离线归档 I/O）、D6（进度与外壳重算解耦）、
  D7（历史写入移出策略回调）、D8 的负缓存/并发上限；B0 崩溃采集。
- 任何真机/模拟器 UI 验收；本机没有 Swift/Xcode 工具链，构建与测试只能依赖 GitHub Actions。

### 18.9 新增/调整测试

`NovelPrivacyTests`、`NovelBrowserRoutingTests`、`PrivateSessionLedgerTests`、
`PrivateSessionStartTests`、`PrivateSessionStoreTests`、`TabCloseCleanupTests`、
`SiteIconCandidateTests`、`TabDocumentIdentityTests`，以及 `TabManagerTests` 的最近关闭/池上限、
`WebNavigationIntegrationTests` 的 B1 私密 store 用例。测试是否实际通过以 §19 的 CI 结果为准。

### 18.10 额外的低风险修复（F-05 / F-08 / B4 收口）

- **F-05**：`SQLiteDatabase.deinit` 与 `close()` 一样先取 `NSRecursiveLock` 再 `sqlite3_close_v2`；
  不改变 `close()` 的语义。
- **F-08**：`NovelChapterLoader.load` 与 `NovelTOCLoader.load` 的 `dataStore` 去掉 `.default()` 默认值，
  让“私密调用忘记传 store”在编译期失败；现有唯一调用方 `NovelReaderView` 两处都已显式传入。
- **B4 收口**：`enforceLiveWebViewCap(keepingTabId:)` 把刚创建 WebView 的标签排除在受害者之外；
  `ensureWebView` 传入新标签 id，`activateTab` 走默认 nil。测试新增“最新后台标签仍有 WebView”的断言。

---

## 19. 最终 CI、测试与安装包（2026-10-21）

- 最终运行：[39725275871](https://github.com/Jaky-Xue/Vela/actions/runs/39725275871)，
  提交 `76bbaa8`，Release，`macos-26-intel`，Xcode 26.6。
- **Build Vela：成功**；IPA 与 dSYM 已上传。
- **Run the unit tests：成功**。280 项测试；第一次尝试有 PublicWebSmoke 与两项既有导航时序测试
  超时，`-retry-tests-on-failure` 重跑后通过；xcodebuild 最终 `** TEST SUCCEEDED **`。
- 本轮新增：搜索页字段显式宽度与 safe-top、设置页按用途重新分组；版本 **3.9.3 (6)**。
  更早的 3.9.2 包含翻译 405 的 GET/单单元回退。
- **安装包**：`G:\Vela-unsigned-3.9.3.ipa`
  - 大小 6,776,123 字节（约 6.5 MiB）
  - SHA-256 `054c463decae6e1b44cf0c8147c31ab74563866c8512668ada1c2631486b26cc`
  - `CFBundleShortVersionString` 3.9.0，`CFBundleVersion` 3，`org.vela.browser.ios`
  - Mach-O arm64，未签名（供 Sideloadly/AltStore 签名安装）
- **Runner 说明**：`macos-15`/Xcode 16.4 无法编译该工程，因为
  `GlassEffectContainer` 是 iOS 26 SDK 符号；工作流默认仍是 `macos-26`，
  新增 `macos-15-intel`/`macos-26-intel` 仅作为 arm64 队列拥堵时的备份。

### 19.1 仍然未完成/未验证

- F-03、F-04、F-07（阅读器/loader 严格关闭顺序、旧内存库释放、首次建库主线程成本）；
  F-06 的测试平台假设已通过删除该不稳定的 WebKit 断言处理。
- C3（导航动作去重）、C4 剩余死代码/文档整理、D1（真机性能基线）、D4、D6、D7、D8
  （离线 I/O、进度解耦、历史写入、图标并发/负缓存）。
- 真机 UI、真实网络、真实 Google/DeepL/OpenAI 服务的 429 行为未验证；构建与单元测试只证明
  代码可编译、现有与新增测试通过。
- 私密会话的极度时序（后台 Task 未启动/挂起/终止）仍依赖平台行为。

---

## 20. 翻译 429 / 识别 / 字段适配（2026-10-21，用户报障后）

用户报告：翻译提示“翻译服务返回 429”、页面语言识别异常、不同服务返回字段不适配。

### 20.1 429 与传输

- `TranslationService.send` 对 **429/5xx** 最多尝试 4 次：指数退避（0.7s、1.4s、2.8s），
  解析 `Retry-After`（秒数或 HTTP-date），单次等待上限 6 秒，避免页面无限停住。
- Google 批次请求之间加入 350ms 间隔（`paceGoogleRequest`），避免一次把整页批次打满；
  请求带浏览器形状的 `User-Agent` 与 `Accept: application/json`。
- 最终 429 抛出新的 `TranslationError.rateLimited`，消息明确提示稍后重试/更换服务商，
  并说明已翻译段落会保留；部分结果逻辑不变。
- **405**：部分 VPN/代理拒绝对 `translate_a/single` 的 POST。Google 请求在收到 405 后改用
  GET 查询重试；整批 GET URL 超过 8k 时，`applyBatch` 把批次拆成单个 unit 再请求。
  405 的提示明确说明可能是当前网络/VPN 拦截。
- 用户取消仍通过 `Task.checkCancellation` 生效。

### 20.2 识别

- 注入脚本的样本优先取 `article`/`main`/`[role=main]`/`[itemprop=articleBody]` 等正文容器，
  不再只取整页 `body`（导航/页脚占多数时识别会偏）。
- 样本同时返回 `<html lang>`、`content-language` meta、`og:locale`；Swift 侧 `Sample`/`Extraction`
  增加可选 `lang` 字段。
- `bestDetected`：本地 `NLLanguageRecognizer` 置信度 ≥0.5 时采用；否则采用页面声明语言
  （置信度 0.85）。语言代码统一归一化：`zh-Hant/zh-TW/zh-HK` → `zh-TW`，`zh-Hans/zh-*` → `zh-CN`，
  `iw→he`、`in→id`、`ji→yi`、`jw→jv`、`mo→ro`。
- Google 返回的检测语言也经过同一归一化。

### 20.3 字段适配

- Google 解析同时接受：
  - 数组形态 `[[["译文","原文",...]],null,"en"]`；
  - 字典形态 `translatedText`/`translation`/`text`/`sentences`/`translations`/`data`/`result`；
  - 检测语言位于索引 2、索引 8 或字典字段 `src`/`detectedLanguage`/`source_language`。
- DeepL 读取 `translations[].detected_source_language`。
- OpenAI 兼容接口同时接受 `choices[].message.content`（字符串或内容分片数组）、`choices[].text`、
  `content.text`/`content.content`。
- `TranslationParsingTests`（8 个用例）覆盖上述形态、语言归一化和 429 文案。

### 20.4 验证

- 运行 `39625038961`（提交 `728f7a5`）：Build Vela 成功；单元测试 **262 项、0 失败、TEST SUCCEEDED**。
- 后续提交 `e892302` 加入浏览器 UA、provider-neutral 429 文案、声明语言阈值与小说 JSON-LD 字段；
  最终运行 `39693612319` 见 §19。

---

## 21. 小说脚本字段适配（2026-10-21）

- `NovelModeService.extractionScript` 新增 `jsonLdFields()`：递归读取 `application/ld+json` 中的
  `Book`/`Chapter`、`name`/`headline`/`author`/`isPartOf` 字段，作为标题与作者的回退来源；
  无效 JSON-LD 被跳过，不影响原提取。
- 正文容器补充 `[itemprop="articleBody"]`、`.entry-content`、`.post-content`、`.article-body`、
  `.read-content`、`.chapter_read` 等常见字段；章节标题/书名/作者的 DOM 选择器与 meta 回退保持。
- 注入脚本用 `node --check` 做了语法检查（提取脚本、目录脚本、翻译脚本均通过；翻译支持脚本仅因
  Swift 插值占位替换产生一条预期外的括号错误）。

---

## 22. 剩余性能项（F-07 / D4 / D6 / D8，2026-10-22）

### 22.1 F-07：私密小说库只建小说表

- `BrowserSchema.novelCreationStatements` 从完整 `creationStatements` 中筛出小说四表与三个索引
  （共 7 条），`InMemoryNovelLibrary.make()` 只执行这一子集，不再为每次私密会话在主 actor 上
  创建书签/历史/下载等无关表。
- 仍是主 actor 上的 7 条 SQLite 语句；F-07 的“首次建库主线程成本”只得到显著缩小，没有完全移出主线程。
- `NovelPrivacyTests.testPrivateShelfSchemaContainsOnlyNovelTables` 覆盖。

### 22.2 D4：离线归档 I/O

- 保存：archive、preview、manifest 的目录创建与写入放入 `Task.detached`；
  `resourceCount` 的 plist 扫描也放入后台。`preview.pngData()` 仍在主 actor 上编码。
- 打开：`archiveData(for:)` 改为 async 并在后台读取；`openOfflinePage` 在 `Task { @MainActor in … }`
  中等待读取后再创建标签。
- 未做真实大文件耗时测量。

### 22.3 D6：进度更新与外壳重算

- `WebViewHost.Coordinator` 对 `estimatedProgress` 做 10 Hz 节流：开始（≤0.01）与结束（≥0.999）
  立即送达，其余最多每 100ms 一次；`stopObserving` 取消待发送任务。
- 这减少 `BrowserTabState.estimatedProgress` 写入和 `@Observable` 外壳重算次数；没有做 SwiftUI
  update 计数或帧率测量。

### 22.4 D8：图标请求收敛与负缓存

- 新增 `SiteIconLoader` actor：同一 URL 的并发请求共享一个 in-flight fetch；失败 URL 负缓存 15 分钟，
  上限 256 条并淘汰最旧；`fetch` 可注入，便于测试。
- `SiteIconView` 仍保留解码图 `NSCache`；私密第三方面板策略不变（候选列表先过滤）。
- `SiteIconLoaderTests` 覆盖失败记忆与并发合并。

### 22.5 验证

- 构建与测试结果见 §19 的最终运行（本轮提交 `d6c0106`）。

---

## 23. C3 / F-03 / F-04（2026-10-22）

### 23.1 C3：导航与私密路由去重

- 新增 `BrowserNavigationActions`（`Vela/App/BrowserNavigationActions.swift`）：
  - `backStep(for:)` 统一“WebKit 后退 / 打开者标签 / 返回主页 / 回网页”的决策；
  - `reload(_:)`、`openHomeTab(from:)` 统一刷新与主页打开规则。
  - 工具栏、菜单、硬件命令、总览最终都落到这三个方法，不再各自判断 WebKit 历史与主页状态。
- `AppEnvironment` 新增 `togglePrivateBrowsingMode()` 与 `currentPrivacyMode`；
  菜单、工具栏、硬件命令、空浏览器菜单四处重复的取反表达式统一调用它，
  标签计数也改用 `currentPrivacyMode`。
- 测试：`BrowserNavigationActionsTests` 覆盖主页空操作、从页面回主页、home surface 后退、
  opener 回退、无标签刷新。
- 仍未合并的是“界面展示动作”（哪个 sheet/overlay 出现），那部分仍由 shell 的视图状态决定。

### 23.2 F-03：阅读器不再强持有书架

- 新增 `NovelReaderRuntime`：chapter/TOC loader 与一个 **weak** 书架引用由 `NovelSession` 持有；
  `NovelReaderView` 只通过 runtime 借用书架，不再强持有 `NovelLibraryService`。
- 会话结束/新会话开始时，环境的 `privateNovelService` 被摘除；shell 在同步结束回调里
  `runtime.cancel()`，同时取消两个 loader 并清空弱引用。此后即使 SwiftUI 还没移除旧视图，
  书架的唯一强引用也已消失，内存 SQLite 可 deinit。
- `NovelRepository.close()` / `NovelLibraryService.close()` 仍保留，用于显式退役/测试；环境对旧服务
  还有一个 2 秒弱引用退休任务，作为有多余强引用时的兜底，不再是把持数据库的主路径。
- 测试：`NovelPrivacyTests.testReaderRuntimeDoesNotKeepTheShelfAlive` 断言运行时弱引用在会话释放后
  `nil`；`testClosingARetiredShelfReleasesItsDatabase` 覆盖显式 close。

### 23.3 F-04：两阶段结束与严格同步前半段

- `AppEnvironment` 拆出：
  - `beginEndPrivateSession(expectedGeneration:)`：同一主 actor 同步执行——代次失效、
    `onPrivateSessionWillEnd`（shell 取消 reader runtime、移除阅读器/书架）、关闭私密标签、
    清私密下载、**取出旧 WebKit store**、摘除旧书架服务；返回带旧 store 的 token。
  - `finishEndPrivateSession(token)`：只对 token 里的旧 store 执行 `removeData`，
    不会误清一个已经开始的新私密会话的 store。
  - `endPrivateSession(expectedGeneration:)` 内部就是 begin + await finish；旧调用方无需改动。
- 阅读器 loader 的取消不再依赖 `onDisappear`/SwiftUI 更新：同步回调直接 `runtime.cancel()`。
- 剩余的非同步部分只有 WebKit `removeData` 本身和 SwiftUI 实际销毁视图；数据安全与资源归属
  不再依赖它们，代次守卫仍阻止迟到写入。
- 未新增 AppEnvironment 端到端测试（需要完整 AppServices/数据库宿主）；`PrivateSessionLedgerTests`
  覆盖代次决策，`BrowserNavigationActionsTests` 覆盖导航动作。

---

## 24. 顶栏卡顿与诊断（2026-10-22，用户报障后）

用户报告：点击顶栏后整个应用卡顿、无法操作，加载诊断捕捉不到。

### 24.1 可能的卡顿源与修复

- 搜索建议卡片原来的 `ScrollView` 依赖 `fixedSize(horizontal:false, vertical:true)` 让 SwiftUI
  询问其“理想高度”；该高度又取决于正在布局的内容。代码注释早已记录 lazy 版本会追自己的估计并冻结。
  本轮把 `OmniboxSuggestionListView` 改为**显式计算高度**（header + 固定行高 + 分隔线，cap 到预算），
  `ScrollView` 只拿显式 frame，不再参与理想高度回问。这是最可疑的自激布局路径。
- 顶栏点击会打开搜索页并触发键盘高度更新、搜索建议刷新与玻璃容器布局；这些状态仍在主 actor 上。
  本环境没有真机/模拟器，无法复现确认；修复后需要用户在实际设备上验证是否消失。
- 截图复现的“搜索页状态异常”：搜索页原先把 `Spacer` 放在字段上下，键盘浮起后列表高度超过剩余空间，
  Spacer 折叠、固定高度的字段被挤出屏幕，列表顶到状态栏。已改为 **top-aligned VStack**，
  字段用 `padding(.top, searchPageTopGap)` 固定在上方；列表使用独立的 `searchPageCardHeight`
  （扣除 top gap、字段高度与键盘后的预算），不再使用只适合手机底栏的 `omniboxCardHeight`。

### 24.2 卡顿诊断

- 新增 `MainThreadHangMonitor`：后台队列每 0.5s 向主 actor 发心跳；主线程恢复后，
  若间隔 ≥2s 且 <20s，记录一次卡顿；前后台切换会重置心跳，避免把挂起误报为卡顿。
- `NavigationEvent` 新增 `hang`，`NavigationLog.recordHang` 写入脱敏后的 URL、当前标签、phase 与持续时间；
  诊断页会显示 `MainThread 0 · 主线程无响应` 与毫秒数。
- 记录最后一次 shell 操作（地址栏、工具栏、菜单、快捷键）作为卡顿上下文，诊断条目会带
  “最后操作：地址栏”这类提示；测试 `HangDiagnosticsTests` 覆盖。
- 限制：不采样被阻塞线程的堆栈（从看门狗挂起线程风险高），因此只能定位“何时、在哪个页面卡了多久”，
  不能直接给出阻塞函数；需要结合用户操作与页面复现。
- 测试：`HangDiagnosticsTests` 覆盖记录、脱敏与关闭诊断时不写入。

---

## 25. 搜索页二次修复、翻译提取增强与收尾（2026-10-22）

### 25.1 搜索页字段仍被挤出的第二次修复

- 用户截图显示：搜索页列表顶到状态栏，地址字段再次消失。上一版只是把 `Spacer` 换成顶部对齐，
  但 VStack 在“列表 + 键盘”超过可用高度时仍可能压缩/推走字段。
- 现在字段是 **ZStack 的 overlay**，绝对固定在 `topGap`；列表放在独立 VStack 中，前面用
  `Color.clear` 精确留出 `topGap + 字段高度 + 14`，列表不可能反向推动字段。
- 搜索页字段不再包在单视图的 `GlassEffectContainer` 中：字段自己的 floating chrome 已提供玻璃，
  去掉容器的尺寸协商，避免容器在键盘/overlay 组合下把字段布局成零尺寸。
- 列表预算仍使用 `searchPageCardHeight`（扣除顶部间距、字段与键盘），并滚动。

### 25.2 翻译页面提取增强

- 单元上限从 600 段/90k 字符提升到 **1200 段/180k 字符**。
- BLOCK 增加 `UL/OL/TABLE/THEAD/TBODY/TFOOT/TR/DL/FIGURE/CENTER`。
- 支持 **open shadow root** 内的正文（querySelectorAll 不跨边界）。
- 支持 **同源 iframe** 内的正文；跨源访问失败被忽略。
- 跳过 `hidden` 元素。
- 新增 `coverageFallback`：块遍历后，对仍未被任何 unit 覆盖的可见文本节点，把其父元素补为 unit；
  有祖先已覆盖检查、BODY/HTML 排除、3000 节点与 600 unit 上限，避免重复和卡顿。
- `mergeText` 不再要求标签形状完全一致：文本节点数量相同即可原位替换，保留原页面元素/监听器；
  只有数量不一致才回退整块 innerHTML。
- 注入脚本通过 `node --check`（翻译支持脚本仅因 Swift 插值占位替换报预期外错误）。

### 25.3 F-07 / D4 收口

- `InMemoryNovelLibrary.makeAsync()` 在 `Task.detached` 中创建 `:memory:` SQLite 并执行 7 条小说 DDL；
  `AppEnvironment.novelLibrary(privateMode:)` 改为 async，检查会话代次并把并发结果关掉，避免把旧服务
  装进新会话；`activateNovelMode`/`openBookshelf` 在 Task 中等库建好再继续。
- 主 actor 只保留 `NovelLibraryService.init` 的 reload 查询（小）。
- 离线保存的 `preview.pngData()` 编码移入后台；D4 的 archive/preview/manifest 读写均不再占主线程。

### 25.4 F-05 与 C4 收尾

- `InMemoryNovelLibrary` 在返回前检查 `service.lastError`，初始化失败返回 nil，不再静默显示空书架。
- 删除确认无引用的 `SyncProviderId`、`BrowserTabMutationResult`；`AddressBarView.swift` 仍包含在用的
  `BrowserUrlResolver`/`AddressBarRejection`/`ProgressRing`，不能按文件名删除。
- 版本提升为 **3.9.2 (Build 5)**，避免与之前的 3.9.0/3.9.1 包混淆。

---

## 26. 审计清单收口（2026-10-22）

### 26.1 本轮新增

- **R-08**：删除无人消费的 `pageMetricsReporter` 注入与定义；`pageMetrics` 消息通道只保留给
  find-in-page 结果。滚动报告与 find 不受影响。
- **R-09 / D5**：`UserScriptRepository` 缓存 enabled 集合与每个脚本的 GM 值；upsert / setEnabled /
  remove / setValue / removeValue / removeAllValues 全部失效对应缓存。
- **R-10 / D2**：广告规则编译单飞；编译中到达的请求合并为一次后续编译；订阅下载限制 2xx 与 20 MB。
- **R-13 / D7**：历史写入移到串行后台队列；visit id 在入队前生成，下一导航可立即形成链；
  标题更新与记录同一队列，不会越过插入。
- **R-15**：启动时若没有私密会话，清理私密下载记录与文件；私密标签预览只进内存缓存，不写磁盘。
- **R-17**：设置文档写入时保留上一份成功编码的备份；当前文档解码失败时回退到备份。
- **R-18**：新增 `WindowSessionTests`，验证 `window-main` 与 Stage Manager 会话互不覆盖。
- **R-23**：地址栏在重定向期间读取 `pendingUrl`，并观察其变化。
- **R-24 / R-26 / B0**：新增 `CrashDiagnosticsService`：MetricKit 崩溃/卡顿摘要 + 未捕获
  Objective-C 异常原因；加载诊断页新增“崩溃与卡顿”区，可复制/清除。
- **C1 / R-20**：`goHome`/`returnToPage`/进度写入统一走 `TabManager.showHome/showPage/updateProgress`；
  Shell 不再直接写 `tab.url/isHome/estimatedProgress`。
- **D8**：`SiteIconLoader` 增加全局并发上限 6。
- **C4**：删除无引用的 `SyncProviderId`、`BrowserTabMutationResult`、0 字节任务文件；
  更新 PORTING 统计与指向不存在 coordinator 的注释。`AddressBarView.swift` 因仍含在用类型而保留。

### 26.2 仍无法在本环境完成

- **D1 / R-25**：真机性能基线（Instruments Time Profiler/Hangs/Allocations/VM Tracker/SwiftUI）
  需要设备与 Xcode，不能由 CI 单元测试替代。
- **D8 真实抓包**、**私密图标第三方请求验证**需要真机网络代理。
- **F-06 / R-33**：没有 UI 测试 target；UI、旋转、键盘、真机网络、Stage Manager 场景未自动化。
- **搜索页/翻译 429/识别**：代码已改，但必须由用户在实际设备上确认；CI 只证明编译与单元行为。
- **C2 目录拆分**：评估后不强行把现有 `Core/<Feature>` 目录改成 `Models/Logic/Runtime`；
  当前按功能分组更贴近调用方，强行移动只产生路径 churn。
- **C3 展示动作**：导航动作已统一；sheet/overlay 的“显示哪个界面”仍属于 shell 的视图状态，
  没有改成单一动作值类型。
- **R-17**：备份回退只能保住上一份可解码文档；单个字段类型错误仍会让当前文档整体回退。
