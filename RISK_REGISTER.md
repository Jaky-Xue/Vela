# Vela 风险与缺陷登记册

- 基线：`3ed4197`（`main`，工作区干净）
- 审计方式：只读静态分析（详见 `ARCHITECTURE_AUDIT.md` §1）
- **已复现缺陷：0 条**。本机无法运行 iOS 应用，所有条目都不应被当作“已在设备上观察到”。

## 分级定义

| 标记 | 含义 |
|---|---|
| **已复现缺陷** | 有明确复现步骤与观察结果 |
| **已确认缺陷** | 源码 + 平台契约/测试足以确认问题存在 |
| **潜在风险** | 存在明确代码路径，但未证明一定发生 |
| **架构改进建议** | 当前可工作，但有明确维护/扩展成本 |
| **产品体验建议** | 有具体操作场景支持的体验改进 |
| **待验证假设** | 证据不足，需要进一步测试 |

严重度：**S1** 数据丢失/崩溃/直接隐私泄露；**S2** 功能错误、显著资源占用、隐私边界；**S3** 中等性能或体验问题；**S4** 轻微。

---

## 摘要

| ID | 分类 | severity | 模块 | 一句话 |
|---|---|---|---|---|
| R-01 | 已确认缺陷 | S2 | 隐私 / WebKit | 每个私密标签页各有一个 ephemeral 数据存储，Cookie 不共享；结束私密会话的清理是空操作 |
| R-02 | 已确认缺陷 | S2 | 小说 / 隐私 | 章节/目录加载器用持久化存储，私密标签页的章节还写入持久化数据库 |
| R-03 | 已确认缺陷 | S2 | 用户脚本 / 生命周期 | GM XHR、GM 标签状态、脚本菜单命令在标签关闭后不清理；XHR 任务强持有 WebView |
| R-04 | 已确认缺陷 | S2 | 标签页 / 内存 | 活跃 WebView 上限只在 `activateTab` 执行，后台批量开标签可突破 |
| R-05 | 已确认缺陷 | S2 | 外壳 / 异步 | 阅读模式、广告开关的 `await` 后回写不校验活动标签 |
| R-06 | 已确认缺陷 | S3 | 标签页 / 持久化 | 最近关闭列表写 SQLite 但从不读取，重启后丢失 |
| R-07 | 已确认缺陷 | S3 | 设置 / 数据 | 清除缓存也会把“手动隐藏元素”设置重置 |
| R-08 | 已确认缺陷 | S4 | WebKit / 脚本 | 页面度量脚本每次加载都上报，原生端只读其中 find 字段 |
| R-09 | 已确认缺陷 | S3 | 用户脚本 / 性能 | 每次主框架导航把整组注入脚本重建 2–3 次，每次都查库 |
| R-10 | 潜在风险 | S2 | 广告过滤 / 主线程 | 规则解析与逐条 `NSRegularExpression` 校验在主 actor，订阅大时可能卡顿 |
| R-11 | 潜在风险 | S3 | 标签页 / 主线程 | 预览图缩放与 JPEG 编码在主 actor，每次 didFinish 与切换都做 |
| R-12 | 潜在风险 | S3 | 离线页面 / 主线程 | 多 MB 归档的写入与读取在主 actor |
| R-13 | 潜在风险 | S3 | 历史 / 导航路径 | 每次导航同步写库并执行保留期清理 |
| R-14 | 潜在风险 | S3 | 外壳 / SwiftUI | 进度 KVO 每次变化写 `@Observable` 标签，驱动整个外壳重算 |
| R-15 | 潜在风险 | S2 | 隐私 / 资源 | 私密预览图、下载记录、小说章节在异常终止后可能残留 |
| R-16 | 潜在风险 | S2 | 图标 / 网络 / 隐私 | 每个图标最多 5 个请求；无站点图标时向 Google favicon 服务外发 host，私密标签页也如此 |
| R-17 | 潜在风险 | S4 | 设置 | 每个设置文档整体解码，一个字段类型变化会重置整份设置 |
| R-18 | 待验证假设 | S3 | 多窗口 | 场景重建/Stage Manager 第二窗口的 `windowId` 与会话恢复行为 |
| R-19 | 架构改进建议 | — | App / 全层 | `AppEnvironment` 是服务定位器，Features 反向依赖 App |
| R-20 | 架构改进建议 | — | 标签页 / 外壳 | `BrowserTabState` 三层写者，缺少单一状态权威与关闭清理点 |
| R-21 | 架构改进建议 | — | 外壳 / WebKit | 导航动作与私密路由多处重复 |
| R-22 | 架构改进建议 | — | 全项目 | 死代码与指向不存在类型的注释 |
| R-23 | 产品体验建议 | S4 | 地址栏 | 重定向提交前地址栏不跟随（注释与实现不符） |
| R-24 | 待验证假设 | S1 | 稳定性 | 已知“重新打开崩溃”缺崩溃日志，无法定位 |
| R-25 | 待验证假设 | — | 性能 | 没有任何性能基线 |
| R-26 | 已确认缺陷 | S3 | 诊断 | 无崩溃/异常/日志通道，只有内存导航日志 |
| R-27 | 潜在风险 | S3 | 小说 / 隐私 | 私密阅读器与 B1 store 清理竞争（B2 后由代次守卫+关闭；顺序仍非严格） |
| R-28 | 已确认缺陷 | S2 | 小说 / 隐私 | 私密阅读器“在浏览器中打开”可能落到普通标签（C1-A 已实现，待验证） |
| R-29 | 潜在风险 | S3 | 隐私会话 / 小说 | `endPrivateSession` 无发起会话 token，迟到结束可能结束新会话（C1-B 已实现，待验证） |
| R-30 | 潜在风险 | S3 | 小说 / 资源 | 私密小说服务/内存库可能延迟释放 |
| R-31 | 潜在风险 | S3 | 隐私会话 / 小说 | 退出顺序非严格同步 |
| R-32 | 潜在风险 | S4 | 数据库 / 小说 | SQLite `deinit` 无锁、私密库错误静默 |
| R-33 | 潜在风险 | S4 | 测试 | B1/B2 测试平台假设与覆盖缺口 |

---

## R-01 私密标签页的数据存储彼此隔离，结束私密会话的清理是空操作

- **分类**：已确认缺陷 · **S2** · 模块：隐私 / WebKit 配置 / 会话结束
- **位置**
  - `Vela/Services/Web/BrowserWebCoordinator.swift:676-679`：`makeConfiguration` 中
    `configuration.websiteDataStore = tab.privacyMode == .private ? .nonPersistent() : .default()`
  - `Vela/App/AppEnvironment.swift:234-245`：`endPrivateSession` 新建 `WKWebsiteDataStore.nonPersistent()`
    后对它调用 `removeData`。
- **证据**
  - `makeConfiguration` 每个 WebView 调用一次（`TabManager.ensureWebView`），而
    `WKWebsiteDataStore.nonPersistent()` 的文档契约是“返回**一个新的**非持久化数据存储”。
    因此私密标签页 A、B 各自持有不同的 store。
  - 结束会话时新建的 store 与任何标签页使用的 store 都不是同一个对象，`removeData` 清的是一个空存储。
  - 仓库内使用 `nonPersistent` 的位置只有三处（配置、结束清理、阅读器显示 WebView），没有任何共享实例。
- **影响范围**
  - 私密模式下标签页之间不共享 Cookie/本地存储：在私密标签页登录后，从它打开的 `target=_blank`
    或 `window.open` 新私密标签页是未登录状态；OAuth/单点登录弹窗在私密模式基本不可用。
  - `endPrivateSession` 的“清空 ephemeral store”没有实际作用；数据最终随 WebView/store 释放而消失，
    但这不是代码所声称的机制。
  - 每个私密标签页还各自持有一份缓存，内存/磁盘开销随私密标签数线性增长。
- **根因**：把“非持久化”误当成“一个共享的非持久化会话”；store 的生命周期没有归属对象。
- **最小方案**
  1. 在 `AppEnvironment`（或 `AppServices`）持有一个 `privateDataStore = WKWebsiteDataStore.nonPersistent()`，
     `makeConfiguration` 由配置提供者取这个实例（给 `BrowserWebViewConfigurationProviding` 增加数据存储来源，
     或在构造 coordinator 时注入）。
  2. `endPrivateSession` 清理**同一个**实例，再把它置空/重建。
  3. 增加测试：两个私密标签页的 `webView.configuration.websiteDataStore ===` 相等；结束会话后
     `getAllCookies` 为空。
- **验证状态**：源码与 API 契约确认；**未在模拟器/真机上复现**。修复后需在 CI 模拟器测试中验证。
- **回滚**：改动局限在配置来源与结束清理；恢复每配置新建 store 即可。
- **实施状态（2026-10-21，B1）**：窗口级共享 store 已实现；`endPrivateSession` 清理同一实例；
  新增 3 个集成测试。**未编译/未运行**，等待 CI。详见 `PHASE_B_IMPLEMENTATION_PLAN.md` §11。
- **补充（阶段 B 复核）**：`closeTab` 在关闭某模式的最后一个真实标签时会创建一个该模式的主页标签
  （`TabManager.swift:473-480`），因此私密标签集合不会因“关闭最后一个标签”而变空。私密会话真正结束只有两条路径：
  用户选择“离开无痕模式”（shell 菜单）与应用进入后台（`VelaApp.swift:161-166`），两者都调用 `endPrivateSession`。
  所以 B1 不需要额外的“最后标签关闭”钩子，清理点就是 `endPrivateSession`。
- **B1 验收补充（2026-10-21）**：清理时序保证目前**不成立**——两个调用方都 fire-and-forget，
  `clearPrivateWebsiteData` 又复用同一个 store，新私密标签页可能在清理完成前拿到它；后台挂起也可能中断清理。
  最小修正是清理开始时轮换 store（`shared = nil` 后再清旧实例），未实施，等待批准。
  测试缺口：普通标签读不到私密 Cookie（仅间接）、跨窗口隔离、清理后新会话、重启/后台、环境接线均未覆盖。
  验收状态：静态检查已做；构建/测试/设备验证均未执行。
- **B1 生命周期修正（阶段一，2026-10-21）**：已实施 store 轮换——`takePrivateWebsiteDataStoreForCleanup()`
  先同步取出旧实例并置空共享属性，`clearPrivateWebsiteData(_:)` 只清该实例；新会话会创建新 store。
  新增 3 个测试覆盖新会话新 store、旧清理不影响新会话、重复清理 no-op。**未构建/未运行**。
  明确限制：后台 Task 未启动则清理不发生；挂起/终止在 `removeData` 完成前不保证严格擦除；
  迟到的重复结束可能结束新会话；阅读器关闭留待 B2（当前阅读器未使用 B1 store）。详见 plan §14。

## R-02 小说加载器与章节存储绕过私密边界

- **分类**：已确认缺陷 · **S2** · 模块：小说 / 隐私
- **位置**
  - `Vela/Core/Novel/NovelChapterLoader.swift:44`：`configuration.websiteDataStore = .default()`
  - `Vela/Core/Novel/NovelTOCLoader.swift:36`：同上（文件头注释还声称使用非持久化存储）
  - `Vela/Services/Novels/NovelLibraryService.swift:60-118`：`open(_:)` 无条件 `upsertChapter` + `upsert(book)`
  - 调用链：`BrowserShellView.activateNovelMode`（`:1081`）→ `NovelReaderView` → 两个加载器
- **证据**
  - 加载器没有接收隐私模式或数据边界参数；无论从普通还是私密标签页进入，都使用默认（持久化）store。
  - `NovelLibraryService.open` 没有 `BrowserDataBoundary` 参数，章节正文、书 URL、章节 URL 写入
    `novel_books/novel_chapters` 持久化表。
- **影响范围**
  - 私密标签页中阅读小说会把 Cookie/缓存写入常规 profile 的持久化存储。
  - 章节内容与书目写入磁盘数据库，并在书架上出现；结束私密会话不会删除这些记录。
- **根因**：小说模块在数据边界抽象之后移植，没有接入 `BrowserDataBoundary`。
- **最小方案**
  1. 给两个加载器增加 `dataStore: WKWebsiteDataStore` 参数；shell 从活动标签页的隐私模式解析
     （私密 → 共享 ephemeral store，普通 → `.default()`）。
  2. 私密模式下的 `NovelLibraryService.open/store` 不写库，章节只保存在阅读器内存中；或明确提示
     “私密模式下不会加入书架”。
- **验证状态**：源码确认，未运行验证。
- **回滚**：参数化数据存储向后兼容；数据库写入策略可单独回滚。
- **B2 调查（2026-10-21，只读）**：确认私密章节/目录加载器使用 `.default()`，且 `NovelLibraryService`
  把章节正文、书目、目录、进度全部写入持久化 `novel_*` 表；服务是进程级单例，常规书架立即可见。
  当前模块无法区分普通/私密。推荐最小方案改为：为私密阅读创建独立的 `SQLiteDatabase(path: ":memory:")`
  + `NovelLibraryService`，不改服务内部、不改 schema；详情见 `PHASE_B_B2_INVESTIGATION.md`。
  未修改 Swift，等待批准。
- **B2 实施状态（2026-10-21）**：已实施独立 `:memory:` SQLite 私密服务、loader store 注入、
  会话代次守卫、阅读器显示 WebView 私密 store；普通模式 schema/数据/书架不变。新增 8 个测试，
  **未构建/未运行**。剩余：SwiftUI 关闭时序、后台任务、完整 loader 抽取链路未自动化。详见 plan §15。
- **B1+B2 只读验收审查（2026-10-21）**：发现 F-01（私密阅读器“在浏览器中打开”可能落到普通标签）、
  F-02（`endPrivateSession` 无发起会话 token）、F-03/F-04（释放/顺序）、F-05~F-08（DB/测试/性能/API）。
  未修复；详见 `PHASE_B_ACCEPTANCE_REVIEW.md`。

## R-03 标签页关闭后，用户脚本的异步任务与状态不释放

- **分类**：已确认缺陷 · **S2** · 模块：用户脚本 / 标签页生命周期
- **位置**
  - `Vela/Services/Web/BrowserWebCoordinator.swift:64-66`：`userScriptXHRTasks`、`userScriptTabStates`
  - `Vela/Services/Web/BrowserWebCoordinator+UserScripts.swift:299-431`：`handleUserScriptXHR` 的
    `Task { @MainActor [weak self] in ... }` 闭包直接捕获 `webView`
  - `Vela/Services/Web/BrowserWebCoordinator+UserScripts.swift:57-77`：菜单命令写入 overlays
  - `Vela/Core/Tabs/TabManager.swift:438-483`：`closeTab` 只处理预览图与 WebView，不通知 coordinator
- **证据**
  - `userScriptXHRTasks` 只在三种情况移除：请求完成（`:429`）、同一 `scriptId|requestId` 重启（`:298`）、
    页面脚本调用 `xhrAbort`。**关闭标签不取消**，导航也不取消。
  - 任务闭包以强引用捕获 `webView`；请求最长 120 秒，期间该 WebView 及其内容进程无法释放。
  - `userScriptTabStates` 以 tab id 为键，只在 `saveTab` 时写入，从不清除。
  - `overlays.userScriptMenuCommands` 只在 `beginNavigation` 里按 tab 清理（`+Navigation.swift:406`）；
    关闭一个未再导航的标签会留下它的命令。
- **影响范围**：长时间使用后，已关闭标签的页面内存被 XHR 任务拖住；GM 状态与菜单命令缓慢累积；
  用户脚本在关闭标签后仍可能发请求。
- **根因**：没有“标签页生命周期结束”的统一钩子（见 R-20）。
- **最小方案**
  1. `TabManager` 增加 `onWillCloseTab` / `onDidCloseTab` 回调（单一闭包即可，不需要事件总线）。
  2. coordinator 在关闭时：取消该 tab 的所有 XHR 任务（键需要包含 tabId，或维护 tabId → keys 索引）、
     删除 `userScriptTabStates[tabId]`、删除该 tab 的菜单命令。
  3. 任务闭包改为弱持有 WebView，或至少在所有 await 返回后检查 tab 是否仍在 `TabManager.tabs`。
- **验证状态**：源码确认。建议增加测试：慢速本地 XHR + 关闭标签，断言任务取消、WebView 释放
  （用 `weak` 引用断言）。
- **回滚**：新增回调与清理逻辑是局部的；回滚删除回调即可。

## R-04 WebView 池上限只在激活时执行

- **分类**：已确认缺陷 · **S2** · 模块：标签页 / 内存
- **位置**：`Vela/Core/Tabs/TabManager.swift:281-320`（`openTab`，`activate: false` 时不激活）、
  `:356-389`（`activateTab` 唯一调用 `enforceLiveWebViewCap`，`:386`）、`:863-878`（池上限实现）
- **证据**
  - `openTab` 无条件 `ensureWebView` + `load`；只有 `activate == true` 才走 `activateTab`，进而执行上限。
  - 后台打开路径真实存在：`openNewTabsInBackground`（`+Navigation.swift:88-94`）、
    `GM_openInTab` 的 `active=false`（`+UserScripts.swift:80-86`）、书签/历史的批量打开。
  - 现有测试 `testLiveWebViewPoolIsCapped` 全部用默认 `activate: true`，没有覆盖后台批量打开。
- **影响范围**：一次“在后台打开多个链接”的操作可以把活跃 WebView 数推到 8 以上；每个 WebView 都有
  独立内容进程与页面内存。上限的承诺（注释 `:63-69`）在这种情况下不成立。
- **根因**：把“上限”实现成了“激活时的副作用”，而不是“池增长时的约束”。
- **最小方案**：在 `ensureWebView` 新建后或 `load`/`openTab` 末尾调用 `enforceLiveWebViewCap()`；
  需要把新 tab 显式排除在受害者之外，或先加入 `activationOrder`。最安全的调用点是 `load` 返回前。
- **验证状态**：源码确认。补一条 `activate: false` 的批量打开测试即可复现。
- **回滚**：单行调用点。

## R-05 异步动作回写时不校验活动标签

- **分类**：已确认缺陷 · **S2** · 模块：外壳 / 异步
- **位置**
  - `Vela/App/BrowserShellView.swift:1045-1064`：`activateReaderMode` 在 `await ReaderModeService.extract`
    之后直接 `readerArticle = article; isReaderActive = true`。
  - `Vela/App/BrowserShellView.swift:1033-1042`：`toggleAdBlock` 在 `await refreshAdBlockRules()` 之后
    用**当时的** `tabManager.activeTab` 重新加载。
  - 对照：`BrowserShellView+TranslationAndOffline.swift:100-110` 在 await 后检查了 `activeTab?.id == tab.id`
    ——该模式已存在，只是没有推广。
- **证据**
  - 标签切换时 `.onChange(of: activeTabId)` 会先把 `isReaderActive` 置 false（`:400-402`）；
    提取任务在切换之后完成，又把旧标签的文章打开在新标签上。
  - 广告开关的编译可能包含磁盘读取与大量规则解析，用户完全有时间切走。
- **影响范围**：用户看到“另一篇文章”或“另一个标签被重载”；阅读内容与地址栏/标签不一致。
  不是数据损坏，但属于明确的功能错误。
- **根因**：异步动作没有携带“发起时的标签/代次”并在回写前校验；与翻译服务已有的 `generation`
  模式不一致。
- **最小方案**：为每个动作捕获 `tabId` 与 `navigationSerial`，await 后
  `guard activeTab?.id == tabId, tab.navigationSerial == serial else { return }`。不需要新建状态机。
- **验证状态**：源码确认，未运行。
- **回滚**：每个 guard 独立。

## R-06 最近关闭列表只写不读

- **分类**：已确认缺陷 · **S3** · 模块：标签页 / 持久化
- **位置**：`Vela/Core/Tabs/TabManager.swift:76`（内存列表）、`:444-454`（写库）、`:514-533`（重开）；
  `Vela/Data/Repositories/TabSessionRepository.swift:186-206`（读方法）
- **证据**：`TabSessionRepository.recentlyClosed(privacyMode:limit:)` 在应用与测试中**没有任何调用者**
  （全局检索只命中定义）。`TabManager.recentlyClosed` 每次启动从空数组开始。
- **影响范围**：重启后“重新打开关闭的标签页”与主页的“最近关闭”区块为空；数据库行仍持续写入
  （包括私密记录，直到结束私密会话）。
- **根因**：持久化写路径已接，读路径遗漏；或者该表当初是为别的用途准备的。
- **最小方案**：在 `TabManager` 初始化时（或 `AppEnvironment.bootWindow`）调用
  `recentlyClosed(privacyMode:)` 装入列表，并遵守 `tabsNotRetained`；否则停止写这张表，避免“看似持久化”。
- **验证状态**：源码确认。补一条“关闭 → 新建 manager → 重开”的测试。
- **回滚**：读取逻辑可单独移除。
- **补充（阶段 B 复核）**：主页的“最近关闭”区块只显示 regular 记录（`NewTabHomeView.swift:424`）。
  若在启动时加载持久化列表，普通主页会开始显示重启前的记录；私密主页仍不会显示私密记录。
  这是 B6 需要用户确认的产品行为变化。

## R-07 清除缓存会重置“手动隐藏元素”

- **分类**：已确认缺陷 · **S3** · 模块：设置 / 数据
- **位置**：`Vela/App/AppServices.swift:298-315`（`clearAllBrowsingData` 末尾
  `settings.updateManualElementHide { $0 = .default }`）；`Vela/Features/Settings/SettingsSubpages.swift:597-620`
- **证据**：`performClear` 中 `clearCookies || clearCache` 成立就调用 `env.clearAllBrowsingData(...)`；
  即使 `includeWebKitData: false`，方法末尾仍重置 element-hide 文档。
- **影响范围**：用户针对站点手工挑选的隐藏元素规则被无提示删除；这是用户设置，不是浏览数据。
- **根因**：清理方法把“浏览数据”和“站点定制”混在一个函数里。
- **最小方案**：把 `updateManualElementHide` 从 `clearAllBrowsingData` 移出，只在用户明确勾选
  “站点定制”时清除；或在清除页提供独立开关。
- **验证状态**：源码确认。
- **回滚**：删除该行即可。

## R-08 页面度量脚本上报的数据无人消费

- **分类**：已确认缺陷 · **S4** · 模块：WebKit / 注入脚本
- **位置**：`Vela/Services/Web/WebPageScripts.swift:612-651`（`pageMetricsReporter`）；
  `Vela/Services/Web/BrowserWebCoordinator.swift:253-261`（`handlePageMetricsMessage` 只读 `findResult`）；
  挂载点 `BrowserWebCoordinator.swift:585-591`
- **证据**：脚本在加载、resize、DOMContentLoaded 时上报 `scrollHeight`、`viewportHeight`、
  `viewportWidth`、`hasViewportFitCover`、`colorScheme`；原生端只处理 `findResult`，
  其余字段在整个仓库中没有读取者。
- **影响范围**：每页一次到数次的 JSON 桥接开销；注释声称的“页面是否可滚动决定工具栏隐藏”并未实现。
- **根因**：功能演进后遗留的脚本；注释与实现脱节。
- **最小方案**：删除脚本与挂载，或真正使用 `scrollHeight > viewportHeight` 来抑制不可滚动页面的工具栏隐藏。
- **验证状态**：源码确认。
- **回滚**：删除是纯简化。

## R-09 用户脚本集合每次导航重建 2–3 次

- **分类**：已确认缺陷 · **S3** · 模块：用户脚本 / 导航性能
- **位置**
  - `BrowserWebCoordinator+Navigation.swift:125`（策略回调中 `refreshUserScripts`）
  - `BrowserWebCoordinator+Navigation.swift:416`（`beginNavigation` 再调一次）
  - `BrowserWebCoordinator.swift:502-505`（`refreshUserScripts` = `removeAllUserScripts` + `attachPageScripts`）
  - `BrowserWebCoordinator.swift:521-650`（`attachPageScripts` 中 `enabledScripts()`、
    每个匹配脚本 `allValues(scriptId:)`）
  - `BrowserWebCoordinator.swift:690`（`makeConfiguration` 中首次 `attachPageScripts`）
- **证据**：`enabledScripts()` 是全表查询（`UserScriptRepository.swift:160-168`），`allValues` 每个脚本
  一次查询（`:251-259`）。一次新标签页首次导航至少执行 3 次脚本装配（配置、策略、didStart），
  后续导航至少 2 次。`beginNavigation` 的注释自称是“belt to suspenders”，但装配发生在文档已开始之后，
  对当前文档通常已无作用。
- **影响范围**：安装脚本越多，主线程在每次导航前的 SQLite 查询与字符串拼接越多；可测量、可消除的重复工作。
- **根因**：WebKit 没有单脚本移除 API，于是用“全量重建”换正确性；重建次数没有收敛。
- **最小方案**
  1. 保留策略回调中的一次装配（它是文档开始前的最后时机）。
  2. `beginNavigation` 只在没有策略回调覆盖的路径装配，或用 `navigationSerial`/URL 标记避免同一导航重复。
  3. 在 `UserScriptService` 内缓存启用脚本与 GM 值快照，安装/编辑/删除时失效。
- **验证状态**：源码确认；性能影响未测量。
- **回滚**：逐个删除调用点即可。

## R-10 广告规则编译在主线程，且没有合并

- **分类**：潜在风险 · **S2** · 模块：广告过滤 / 主线程
- **位置**：`Vela/Core/AdBlock/AdBlockEngine.swift:86-158`（`compile` 是 `@MainActor` 方法，
  在函数体内同步遍历所有规则）；`Vela/Core/AdBlock/AdBlockRuleCompiler.swift:144-203`（逐行解析）、
  `:480`（`isAcceptable`）、`:499-502`（每条规则编译一次 `NSRegularExpression`）；
  `Vela/App/AppServices.swift:190-225`（收集规则文本）；`Features/Settings/SettingsSubpages.swift`
  有 10 处 `Task { await env.refreshAdBlockRules() }`
- **证据**：内置规则只有约 5 KB（`AdBlockBuiltInRules.swift`），但远程订阅可下载到数 MB（`updateAdBlockSource`
  直接读 `URLSession.shared.data` 并把全文写盘，未限制大小）。解析、正则校验、JSON 编码全部发生在主 actor；
  用户快速切换多个开关会排队多次完整重编译。
- **影响范围**：安装大订阅后，启动或任意广告设置变更可能冻结 UI 数百毫秒到数秒（**未测量**）；
  期间页面滚动、输入、动画都会停。
- **根因**：编译器是纯函数，但被放在 `@MainActor` 的 engine 里；没有任务合并/防抖。
- **建议**
  1. 先把 `AdBlockRuleCompiler.compile` 标成 `nonisolated`（它只依赖参数），在 `Task.detached(priority: .utility)`
     中执行解析，再回主 actor 安装。
  2. `refreshAdBlockRules` 增加“单飞 + 合并”语义：已有编译在跑时只记录“需要再来一次”，结束后跑最后一次。
  3. 给 `updateAdBlockSource` 增加响应大小上限与状态码检查。
- **验证状态**：代码路径确认；性能影响未测量。测量方法见 `OPTIMIZATION_ROADMAP.md` §5。
- **回滚**：线程迁移与合并可分别回滚。

## R-11 预览图缩放与 JPEG 编码在主线程

- **分类**：潜在风险 · **S3** · 模块：标签页 / 主线程
- **位置**：`Vela/Core/Tabs/TabPreviewStore.swift:54-62`（`store`：`downscaled` + `jpegData` 同步执行，
  仅磁盘写入在 `Task.detached`）；`:105-120`（`downscaled` 用 `UIGraphicsImageRenderer`）；
  调用点 `TabManager.swift:184-191`（`capturePreview`）、`BrowserWebCoordinator+Navigation.swift:536`
  （每次 `didFinish`）、`TabManager.swift:361-363`（每次切换离开）
- **证据**：`TabPreviewStore` 是 `@MainActor` 类型；`store` 在 `takeSnapshot` 回调后的 `Task { @MainActor }`
  中调用，缩放与编码都在主 actor 上完成，之后才把 `Data` 交给后台写盘。
- **影响范围**：每次页面加载完成、每次切走标签都做一次全屏图像缩放 + JPEG 编码；大页面截图在
  ProMotion 设备上可能造成一帧以上的停顿（**未测量**）。
- **建议**：把 `downscaled` + `jpegData` 放进 `Task.detached(priority: .utility)`（`UIGraphicsImageRenderer`
  可离主线程使用），只把最终 `Data` 交回主 actor 写缓存；或降低截图分辨率。
- **验证状态**：源码确认；影响未测量。
- **回滚**：把编码移回主 actor。

## R-12 离线归档的读写主线程

- **分类**：潜在风险 · **S3** · 模块：离线页面 / 主线程
- **位置**：`Vela/Services/Offline/OfflinePageService.swift:48-150`（`save`：`archive.write` 在
  `@MainActor` 类型内同步执行）、`:156-161`（`archiveData` 用 `Data(contentsOf:)` 同步读取）、
  `:178-186`（`deleteAll` 逐个删除目录）
- **证据**：`createWebArchiveData` 是异步的，但返回后的多 MB `Data` 写入、`pngData()` 编码、
  manifest 写入都在主 actor；打开已保存页面时整份归档在打开标签页之前同步读入内存。
- **影响范围**：保存/打开大型页面（几十 MB 归档）时 UI 停顿；同时持有归档与 WebView 解码副本，
  峰值内存抬升。
- **建议**：把文件 I/O 与 PNG 编码移到后台任务（`Task.detached` 或一个小的 I/O 队列），主 actor 只负责状态；
  打开页面时异步读取归档后再交给 `loadOfflineArchive`。
- **验证状态**：源码确认；影响未测量。
- **回滚**：异步化可以按写入/读取分别回滚。

## R-13 历史写入与保留期清理在导航回调内同步执行

- **分类**：潜在风险 · **S3** · 模块：历史 / 导航路径
- **位置**：`BrowserWebCoordinator+Navigation.swift:197-210`（策略回调同步调用 `history.recordVisit`）→
  `HistoryService.swift:68-110` → `HistoryRepository.swift:79-232`（多次查询/写入，末尾
  `purgeIfNeeded`，`:462-490`）
- **证据**：每次主框架导航在 `decidePolicyFor` 的主 actor 分支里同步执行：URL 归一化、哈希、按 hash 查询、
  UPDATE/INSERT、写 visit、查前一条 visit 的 `visited_at`、更新 duration、再执行一次删除式清理事务。
  所有查询都有索引（`BrowserSchema.swift:151-157`、`:181-184`），因此单次成本可控，但导航路径上没有
  任何异步化。
- **影响范围**：历史量很大且保留期触发清理时，导航前会有一次数据库事务；在慢存储上可能延迟页面开始。
- **建议**：先测量（signpost 包住 `recordVisit`）；若确认有影响，把写入放到串行后台队列，保持
  “先记访客、后回填标题”的顺序，避免改变语义。
- **验证状态**：潜在风险；未测量。
- **回滚**：后台化可退回同步。

## R-14 进度 KVO 每帧写可观察标签状态

- **分类**：潜在风险 · **S3** · 模块：外壳 / SwiftUI
- **位置**：`Vela/Services/Web/WebViewHost.swift:185-196`（KVO → `Task { @MainActor in onProgress(progress) }`）；
  `Vela/App/BrowserShellView+PadLayout.swift:348-350`（闭包写 `tab.estimatedProgress`）；
  读取点 `BrowserShellView+Chrome.swift:157`、`+PadLayout.swift:126`
- **证据**：WebKit 的 `estimatedProgress` 在加载期间高频变化；每次变化都会写 `@Observable` 的
  `BrowserTabState`，任何在 body 中读过该标签的视图都会重新求值。整个外壳（命令栏、覆盖层、WebViewHost）
  都在同一个 body 树里。
- **影响范围**：页面加载期间的外壳重算次数远高于必要；在低端设备上可能表现为加载时滚动/动画掉帧。
  `WebViewHost` 的注释已经意识到“每帧写 `@State` 会掉帧”，但进度仍然逐次写模型。
- **建议**：先测量（Instruments 的 SwiftUI 更新计数 / 主线程 trace）。若确认，把进度节流到
  ~10 Hz 或让进度条单独观察一个小的 `ProgressModel`，不驱动整个标签状态。
- **验证状态**：潜在风险；未测量。
- **回滚**：节流/拆分可单独回滚。

## R-15 私密会话的落盘残留

- **分类**：潜在风险 · **S2** · 模块：隐私 / 资源
- **位置**
  - 预览图：`TabManager.capturePreview`（`:184-191`）对所有标签页生效，`TabPreviewStore.store`
    写入 `Application Support/Vela/TabPreviews/<tabId>.jpg`（`TabPreviewStore.swift:54-63`）。
  - 下载记录：`DownloadRepository` 没有边界判断；`clearPrivateRecords` 只在
    `AppEnvironment.endPrivateSession`（`:236`）调用。
  - 小说章节：见 R-02。
- **证据**：私密标签页的预览图与下载行在正常路径下会由 `closeAllTabs`/`endPrivateSession` 删除；
  但两者都依赖 App 进入 `.background` 并执行清理（`VelaApp.swift:147-158`）。iOS 可因内存压力、
  看门狗或用户强制退出直接终止进程，此时没有清理机会；启动路径也没有扫描/清除残留
  （`AppServices.bootOnce` 只 `reconcileInterruptedTasks`）。
- **影响范围**：异常终止后，私密页面的截图与下载元数据可能留在磁盘上，直到被下一次关闭/80 文件裁剪
  或用户手动删除。属于隐私残留，不是“立即泄露”。
- **建议**
  1. 启动时清理不属于当前会话的私密下载记录与私密预览文件（或给它们加“会话 id”标记）。
  2. 预览图按是否私密分目录/加后缀，结束时整目录删除。
  3. 明确产品决策：私密标签页本身是“重启后恢复”的（现有设计），下载/截图是否也应恢复？现状是
     不一致的。
- **验证状态**：潜在风险；“强制终止后是否真的留下文件”需设备验证。
- **回滚**：清理策略可单独调整。

## R-16 站点图标请求放大

- **分类**：潜在风险 · **S2** · 模块：图标 / 网络 / 隐私
- **位置**：`Vela/UI/SiteIconView.swift:98-125`（`loadIcon`：依次尝试显式 URL、`/apple-touch-icon.png`、
      favicon 服务等候选）、`:111`（`URLSession.shared.data`）
- **证据**：每个图标最多 5 次网络请求；只缓存成功解码的图片，失败不缓存；`task(id:)` 在视图重新出现时
  会重跑。主页收藏网格与标签页总览会同时创建大量 tile。
- **影响范围**
  - 首屏/总览可能产生数十个并发请求；失败站点会在每次出现时重试。
  - **隐私**：候选列表包含 `https://www.google.com/s2/favicons?...&domain=<host>`
    （`SiteIconView.swift:201`）。`TabsOverviewView` 的标签卡片与 `BrowserSidebarView` 对**所有**
    标签页（包括私密标签页）创建 `SiteIconView`，因此在私密模式打开总览/侧栏、或地址栏列出私密标签页时，
    页面 host 会被发送给 Google。`blurPrivateTabPreviews` 只模糊预览图，不阻止图标请求。
- **建议**
  1. 私密标签页不使用第三方候选：只保留站点自身 host 的图标、本地缓存或首字母占位，
     移除 Google favicon 服务；若用户要求“私密模式零外部请求”，再收紧为纯缓存+占位；
  2. 加负缓存（按 host + TTL）与最多 2–4 个并发；
  3. 评估移除以第三方 favicon 服务作为兜底，或改为用户可关闭的选项。
- **验证状态**：潜在风险；未测量。
- **回滚**：缓存策略独立。

## R-17 设置文档整体解码

- **分类**：潜在风险 · **S4** · 模块：设置
- **位置**：`Vela/Services/Settings/SettingsService.swift:113-116`（`load` 用 `try? JSONDecoder().decode`）、
  `:32-34`（`preferences` 的 `didSet` 同步持久化）
- **证据**：任一字段类型变化导致整份 `BrowserPreferences` 解码失败，`?? .default` 静默重置全部设置。
  代码注释明确要求“新增字段必须是 optional”，这是靠约定维持的。
- **影响范围**：未来一次不谨慎的字段变更会让老用户丢掉全部偏好（历史保留期、菜单布局、工具栏顺序等）。
- **建议**：为每个文档记录一个 schema 版本并在解码失败时尝试逐字段迁移；至少在解码失败时保留原
  `Data` 并写入诊断，而不是直接覆盖。
- **验证状态**：设计风险；现有代码未违反约定。
- **回滚**：版本化迁移是增量改动。

## R-18 场景重建与窗口标识

- **分类**：待验证假设 · **S3** · 模块：多窗口 / 会话
- **位置**：`Vela/App/VelaApp.swift:60-195`、`:265-282`（`WindowEnvironmentStore.environment` 懒构造）、
  `AppServices.swift:127-132`（`allocateWindowId`）
- **证据**：`windowId` 在环境首次构造时分配；第一个窗口得到 `window-main`，其余得到随机 id。
  启动时 `removeSessions(except: [window-main])`。
- **不确定点**：iPad Stage Manager 关闭一个窗口再重新打开、或系统重建场景时，SwiftUI 是否复用
  `WindowEnvironmentStore`？若不复用，新窗口得到随机 id，旧会话不会被恢复，且会在下次启动被删除。
- **建议**：在设备上验证“关闭 iPad 窗口 → 重新打开 → 标签是否恢复”；若不复用，考虑用
  `UISceneSession` 标识派生 `windowId`，而不是进程内计数。
- **验证状态**：待验证假设。

---

## R-19 `AppEnvironment` 是服务定位器，Features 反向依赖 App

- **分类**：架构改进建议 · 模块：App / 全层
- **证据**：27 个 Feature 文件使用 `@Environment(AppEnvironment.self)`；`env.settings` 出现 174 次，
  `env.tabManager` 45 次；`AppEnvironment` 提供 14 个转发属性（`AppEnvironment.swift:103-116`）。
  `ARCHITECTURE.md` 声称依赖方向是 App → Features。
- **成本**：任何新服务都要改组合根并暴露给所有 Feature；视图很难只依赖它实际需要的接口；
  测试一个 Feature 需要构造整个环境。
- **建议**：不要求一次性重构。新增代码优先使用“窄依赖”（初始化参数、`@Environment` 自定义 key），
  逐步替换高频视图；核心服务保持组合根持有。
- **验收**：新增 Feature 不增加 `AppEnvironment` 的转发属性数量。

## R-20 `BrowserTabState` 多写者，缺少标签页关闭清理点

- **分类**：架构改进建议 · 模块：标签页 / 外壳
- **证据**：`loadState` 由 `TabManager` 与 coordinator 写；`url` 由 `TabManager.load`、coordinator
  `didCommit/didFinish/didFail`、shell `goHome/returnToPage`、History API 消息写；`estimatedProgress`
  由视图闭包写。`closeTab` 不通知任何其他模块。
- **成本**：任何“标签页结束”时应释放的资源（脚本任务、GM 状态、翻译记录、预览、下载来源）都要各自
  记得处理；目前漏了三处（R-03/R-05/R-15）。
- **建议**：定义一个最小的标签页生命周期契约：
  `TabManager.onWillCloseTab`（同步清理）与 `onDidCloseTab`（异步/持久化）；
  coordinator、translation、preview、history 各自订阅。状态写入方面，至少把 `tab.url` 的写入
  收敛到 coordinator + `TabManager.load`，shell 只发“意图”。
- **验收**：关闭标签后，coordinator 的 `userScriptTabStates`、`userScriptXHRTasks`、overlays 菜单命令
  均不再包含该 tab；可用测试断言。

## R-21 导航动作与私密路由多处重复

- **分类**：架构改进建议 · 模块：外壳 / WebKit
- **证据**：`reloadActiveTab`、`goBack`、`openHomeTab` 在菜单 action、工具栏 control、硬件命令三处分支；
  私密路由解析在 `TabManager.createTab/openTab`、`AppEnvironment.syncPrivateBrowsingRouting`、
  coordinator 的 `target=_blank` 与 `window.open`、`VelaApp.onChange` 共 4 处。
- **建议**：导航动作收敛到一个 `BrowserActions` 值类型/方法集合，UI 只调用它；私密路由只保留
  `TabManager` 中的解析，coordinator 直接调用 `openTab`，不再复制条件。
- **验收**：新增一个新建标签入口时，不需要再写隐私解析。

## R-22 死代码与指向不存在类型的注释

- **分类**：架构改进建议 · 模块：全项目
- **证据**
  - `Vela/UI/AddressBarView.swift`（340 行）无任何引用。
  - `BrowserTabMutationResult`（`TabModels.swift`）无引用。
  - `SyncProviderId`（`BrowserModels.swift:52`）无引用，同步调度未实现。
  - `HistoryService.clearTabChain` 无调用者（`HistoryService.swift:131`）。
  - `TabSessionRepository.recentlyClosed` 无调用者（见 R-06）。
  - 注释引用 `BrowserLoadingProgressCoordinator`、`BrowserPrivateSessionCleanupCoordinator`（类型不存在）。
- **建议**：阶段 C 删除确认无用的代码；保留的“未来接口”要写明计划与所有者，否则会继续误导。
- **注意**：删除 `AddressBarView` 前确认没有通过字符串/反射引用（已检索，无）。

## R-23 地址栏在重定向提交前不跟随

- **分类**：产品体验建议 · **S4** · 模块：地址栏
- **证据**：`+Navigation.swift:345-380` 的注释称“地址栏跟随重定向立即更新”，并在
  `didReceiveServerRedirectForProvisionalNavigation` 中写 `tab.pendingUrl`；
  但 `BrowserShellView.displayUrl`（`:604-607`）与 `OmniboxViewModel.currentPageUrl` 都只用 `tab.url`，
  而 `tab.url` 只在 `didCommit/didFinish` 更新。全局检索确认没有任何视图读取 `pendingUrl`。
- **影响**：重定向链卡住时，地址栏显示的是用户最初输入/点击的地址，而不是当前跳转目标。
- **建议**：要么让地址栏在加载中显示 `pendingUrl`（并保持“未提交”的视觉提示），要么修正注释，
  把 `pendingUrl` 明确为内部占位检测字段。
- **验证状态**：源码确认。

## R-24 已知“重新打开崩溃”缺少崩溃日志

- **分类**：待验证假设 · **S1** · 模块：稳定性
- **证据**：项目记忆中记录了该问题；本轮检索确认工程**没有**任何崩溃/异常采集
  （无 `NSSetUncaughtExceptionHandler`、无 MetricKit、无 `OSLog`/`Logger`），`NavigationLog` 只覆盖导航事件。
- **影响**：无法区分这是启动恢复、WebKit 内容进程、SwiftUI 布局还是数据库问题；任何“修复”都无法验证。
- **建议**：在阶段 B 之前或同时，先加入最小崩溃采集（MetricKit 的 `MXCrashDiagnostic` + 一个
  `NSSetUncaughtExceptionHandler` 写 JSON 到 Application Support，设置页可导出）。这是一个诊断能力，
  不是产品功能；需要用户批准后再实施。
- **验证状态**：无法验证。

## R-25 没有任何性能基线

- **分类**：待验证假设 · 模块：性能
- **证据**：仓库没有性能测试、没有 signpost、没有内存断言；CI 只跑功能测试。
- **影响**：R-10~R-14 都无法判断是否值得改；也无法证明改后更好。
- **建议**：先建立最小基线（见 `OPTIMIZATION_ROADMAP.md` §5），再实施任何性能改动。

## R-26 无崩溃/异常/日志诊断通道

- **分类**：已确认缺陷 · **S3** · 模块：诊断
- **证据**：全仓库检索 `print(`、`os_log`、`Logger(`、`MetricKit`、`NSSetUncaughtExceptionHandler`
  均无结果；错误大多被 `try?` 吞掉（220 处 `try?`）。
- **影响**：线上问题只能靠用户描述；R-24 就是直接后果。
- **建议**：见 R-24。若不愿引入 MetricKit，至少把关键失败点（数据库打开失败、会话保存失败、
  规则编译失败）记录到一个可导出的环形日志。

---

## R-27 私密小说阅读器与私密 store 清理的竞争

- **分类**：潜在风险 · **S3** · 模块：小说 / 隐私 / 会话结束
- **证据**：B2 推荐方案让私密章节/目录加载器使用 B1 的窗口私密 store；`endPrivateSession` 会清空该 store。
  阅读器是 shell 的层，`endPrivateSession` 不会关闭它（`AppEnvironment` 不持有 `novelSession`）。
  若用户在阅读器打开时离开无痕模式，正在进行的章节请求可能被清空，后续翻页也会失去站点会话。
- **影响**：私密阅读器在会话结束后继续存在，但登录态/缓存被清；可能出现“章节加载失败”或读到不完整内容。
- **建议**：离开无痕模式时先关闭阅读器（shell 已有 `novelSession`），或在阅读器打开期间延迟清理；
  不要用“保留旧 store”来规避，因为那会让私密数据跨会话存活。
- **验证状态**：待实现 B2 时处理；未运行验证。
- **B2 实施状态（2026-10-21）**：已加入 `privateNovelSessionGeneration`；阅读器在代次变化时取消两个 loader
  并关闭；旧阅读器捕获旧库，写入被代次守卫阻止；菜单路径先关闭阅读器/书架。剩余：SwiftUI `onDisappear`
  与清理不是同步的；旧服务要等视图释放；不声称严格串行。
- **验收审查（2026-10-21）**：F-03/F-04 证实释放与顺序仍不严格；F-01/F-02 另见新风险。未修复。

---

## R-28 私密阅读器“在浏览器中打开”可能落到普通标签

- **分类**：已确认缺陷 · **S2** · 模块：小说 / 隐私
- **证据**：`NovelReaderView.swift:630-636` → `BrowserShellView.swift:322-326` → `openInBrowser`
  （`BrowserShellView.swift:1202-1209`）使用当前 `activeTab`；阅读器打开时 `handleBrowserCommand`
  仍处理切标签（`:1018-1043`），私密阅读器可与普通活动标签同时存在。
- **影响**：私密章节 URL 写入常规历史/WebKit Cookie；隐私边界泄漏。
- **建议**：打开动作携带 `isPrivateSession`；私密时使用来源私密标签或新建私密标签，禁止使用普通 `activeTab`。
- **验证状态**：源码确认；未运行。置信度高（代码路径）/中（触发需切标签）。
- **C1-A 修复（2026-10-21）**：新增 `NovelBrowserRouting`，会话携带 `sourceTabId`；私密只允许来源私密标签或新私密标签，
  过期拒绝；普通行为不变。T-11 路由测试已写；**未构建/未运行**。UI 点击未自动化。

## R-29 `endPrivateSession` 不识别发起会话

- **分类**：潜在风险 · **S3** · 模块：隐私会话 / 小说
- **证据**：`AppEnvironment.swift:261-276` 无参数、无 token；调用方 `VelaApp.swift:161-166` 与
  `BrowserShellView.swift:954-969` 都是 fire-and-forget Task；代次只在结束时递增。
- **影响**：迟到的结束 Task 若在新私密会话开始后执行，会关闭新标签、释放新私密小说服务、清空新 store。
  不写普通库，但会丢失新私密会话数据。
- **建议**：私密会话开始时分配 id，结束调用携带 id 并不匹配时 no-op；或串行化结束请求。
- **验证状态**：源码确认无 token；触发概率未测。
- **C1-B 修复（2026-10-21）**：代次在会话开始/结束递增；TabManager 触发新会话；`endPrivateSession(expectedGeneration:)`
  经 `PrivateSessionLedger` 校验，旧代次 no-op。T-12 决策/触发/store 轮换测试已写；**未构建/未运行**。
  `AppEnvironment` 真实接线为代码审查，未端到端测试。
  新会话开始只重置小说服务/store，不清理旧私密下载/最近关闭记录；“关闭全部私密标签后留下主页”会触发新会话。

## R-30 私密小说服务/内存库可能延迟释放

- **分类**：潜在风险 · **S3** · 模块：小说 / 资源
- **证据**：`NovelSession.library`（`BrowserShellView.swift:1401`）、`NovelReaderView.library`（`:37`）
  强引用；环境只置 nil（`AppEnvironment.swift:271`）；SwiftUI `onDisappear` 异步。
- **影响**：旧内存库/DB 在会话结束后可能仍被阅读器/任务持有；无新会话写入（代次守卫），但释放不即时。
- **建议**：环境持唯一强引用、阅读器/书架持弱/可选；或在代次变化时显式释放。
- **验证状态**：所有权代码确认；释放时序未测。

## R-31 退出顺序不是严格同步的

- **分类**：潜在风险 · **S3** · 模块：隐私会话 / 小说
- **证据**：`AppEnvironment.endPrivateSession` 同步做失效/关标签/清下载/释放服务/取 store，
  `removeData` 异步；阅读器/书架关闭与 loader cancel 由 SwiftUI `onChange`/`onDisappear` 驱动；
  后台调用是 fire-and-forget。
- **影响**：在途加载可能被 store 清理中断；阅读器关闭略滞后；后台挂起可能使清理未开始。
  数据安全由代次守卫保证，不是由严格顺序保证。
- **建议**：同步 “will end” 钩子/两阶段结束；或明确记录限制。
- **验证状态**：结构确认；时序未测。

## R-32 SQLite `deinit` 无锁与私密库错误静默

- **分类**：潜在风险 · **S4** · 模块：数据库 / 小说
- **证据**：`SQLiteDatabase.swift:267-271` 无锁 close；`NovelLibraryService.swift:30-43` reload 吞错；
  `InMemoryNovelLibrary.swift:23-33` 不检查 `lastError`。
- **影响**：理论关闭竞态；私密书架可能静默为空。
- **建议**：deinit 调用加锁 close；检查 `lastError` 并提示。
- **验证状态**：源码确认；竞态未复现。

## R-33 B1/B2 测试设计与覆盖缺口

- **分类**：潜在风险 · **S4** · 模块：测试
- **证据**：`NovelPrivacyTests.swift:223-252` 使用未入窗口的 WKWebView + iframe；`:149-171` 依赖
  `WKWebsiteDataStore.default()` 对象身份；B1/B2 测试绕过 `AppEnvironment`；无跨窗口/UI 测试；
  未覆盖 R-28/R-29。
- **影响**：可能假失败或假安全感。
- **建议**：入窗口/行为断言；补环境级、跨窗口、R-28/R-29 回归；保留 CI 真实验证。
- **验证状态**：设计审查；未运行。

---

## 测试缺口

| ID | 缺口 | 建议场景 |
|---|---|---|
| T-01 | 私密标签页共享 Cookie / 数据存储 | 两个私密标签页写入并读取同一 cookie；结束会话后为空 |
| T-02 | 标签关闭后的资源释放 | GM XHR、GM tab 状态、菜单命令、预览文件在关闭后不再存在 |
| T-03 | 跨标签异步回写 | 阅读模式/广告开关/翻译在切换标签后的行为 |
| T-04 | 后台批量打开与池上限 | `openTab(activate:false)` × N 后 `liveWebViewCount <= 8` |
| T-05 | 最近关闭的持久化 | 关闭 → 新 manager → 重开 |
| T-06 | 私密小说 | 私密标签页进入小说模式后不写 `novel_*` 表、不碰默认 store |
| T-07 | 清除数据的精确范围 | 只清缓存不重置 element-hide；只清历史不动书签（后者已有修复） |
| T-08 | UI 测试 | 目前没有 UI 测试 target；关键路径（标签切换、总览、设置）无自动化 |
| T-09 | 小说模块的普通/私密隔离 | 私密服务不触碰持久化 `novel_*` 表；普通库行数不变；退出后新私密服务为空 |
| T-10 | 私密阅读器/书架退出 | 离开无痕模式关闭阅读器；私密书架为空；常规书架不变 |
| T-11 | 私密阅读器打开到普通标签 | 私密阅读器 + 普通活动标签 → 打开动作不得写常规历史/Cookie（R-28） |
| T-12 | 迟到结束不结束新会话 | 旧会话延迟 endPrivateSession 不得关闭/清理新私密会话（R-29） |

`NovelPrivacyTests` 已覆盖 T-06/T-09 的主要项（服务隔离、普通库不变、新服务为空、loader store 选择、
迟到写入、子资源）；T-10 的 SwiftUI 关闭时序仍无自动化，只能代码审查/模拟器手工。

现有 227 个测试中，导航状态机、广告规则编译、地址栏解析、标签页池的覆盖是扎实的；
**标签页关闭后的跨模块资源、私密数据边界、异步 UI 回写**是明显空白。

---

## 已检查且未发现问题的项目（避免重复劳动）

以下点经过源码核对，结论是“当前实现正确”，不建议在没有新证据时改动：

1. 导航陈旧回调判定：`NavigationTrace` + `WKNavigation` 身份比较 + `isStale` 的“仍在加载才丢弃”规则
   （`+Navigation.swift:691-745`）考虑了 WebKit 不总返回同一对象的情况。
2. 占位文档识别：`isPlaceholderDocument` 只在 `pendingUrl` 是 http(s) 时成立（`:751-762`），
   不会误伤合法的 `about:blank`。
3. 标签页状态机语义：`isInFlight/isFailure/hasCommittedDocument/needsPageFetch` 集中在 `TabModels.swift`，
   测试覆盖 35 条。
4. `discardWebView` 会清后退/前进、`committedUrl`、加载状态，并对 `activationOrder` 的 no-op 做了计数修正。
5. 历史/搜索的私密边界：`BrowserDataBoundary.persists` 抑制写入，私有访问不会进入历史。
6. 广告规则的自校验：`isAcceptable` 防止一条不可表达的规则毁掉整个规则列表，且有对应测试。
7. 下载分片：锁 + 串行 delegate queue + `taskDescription` 跨进程映射 + manifest 落盘，设计完整。
8. JS 对话框/文件上传：每个 completion handler 都会被调用（包括替换/取消路径），不会卡住页面。
9. 消息桥：`MessageBridge` 弱持有 coordinator，内容控制器不造成环；主线程假设用 `assumeIsolated`
   且失败路径有 `Task` 兜底。
10. 数据库：`NSRecursiveLock` + 事务 + WAL + 完整索引，没有发现 SQL 注入或并发写竞争。
11. 密码：Keychain `ThisDeviceOnly`，锁定时丢弃解码副本。
12. 翻译：代次计数在每次 await 后检查，切换页面会清空增量队列。

---

## 使用方式

- 阶段 B 只处理 **已确认缺陷中的 S2**（R-01~R-05），一次一组，每组附 diff 与测试。
- R-06/R-07 属于小而独立的数据正确性问题，可并入阶段 B 的第二组。
- R-10~R-14 在没有测量前**不要改**；先完成 `OPTIMIZATION_ROADMAP.md` 的基线。
- R-19~R-22 是阶段 C 的候选，按“关闭清理点 → 依赖收窄 → 死代码”顺序。
- R-24/R-26 需要用户明确批准，因为它会新增一个诊断通道。

---

## 状态更新（2026-10-21，B3–B7 / C2 / D 之后）

| 风险 | 当前状态 | 说明 |
|---|---|---|
| R-01 | 已修复（待验证） | 私密标签共享窗口内 `nonPersistent` store；结束/新会话轮换后清理；B1 集成测试 |
| R-02 | 已修复（待验证） | 私密小说库改为 `:memory:`；loader 注入同一 store；`NovelPrivacyTests` |
| R-03 | 已修复（待验证） | `onWillCloseTab` 清理 XHR/GM 状态/菜单/历史链/trace；`TabCloseCleanupTests` |
| R-04 | 已修复（待验证） | 创建时执行池上限；`TabManagerTests` |
| R-05 | 已修复（待验证） | `TabDocumentIdentity` 写回前校验；`TabDocumentIdentityTests` |
| R-06 | 已修复（待验证） | 启动恢复最近关闭；`TabManagerTests` |
| R-07 | 已修复（待验证） | 清除缓存不再重置手动隐藏 |
| R-09 | 已修复 | 重复装配删除；仓库缓存 enabled 集合与 GM 值并在写路径失效 |
| R-10 | 部分修复 | 解析/编码后台、单飞合并、订阅 2xx/20MB 限制已做；未真机 Hangs 测量 |
| R-11 | 部分修复 | 预览缩放/编码移出主线程；设备测量未做 |
| R-16 | 部分修复 | 候选过滤、in-flight 合并、负缓存、并发上限已做；未真实抓包 |
| R-19 | 部分修复 | coordinator 构造参数减少 3 个；目录拆分未做 |
| R-20 | 部分修复 | 已有关闭清理点；仍未建立单一状态权威 |
| R-22 | 部分修复 | 死类型/空文件清理、统计与注释更新；`AddressBarView.swift` 仍含在用符号，保留 |
| R-28 | 已实现（待验证） | 私密阅读器路由到来源/新私密标签；`NovelBrowserRoutingTests` |
| R-29 | 已实现（待验证） | 结束请求带代次；`PrivateSessionLedgerTests` |
| R-30/R-31 | 已由 F-03/F-04 修复 | reader 只持弱书架；两阶段结束同步取消 reader、取旧 store，异步只清旧 store |
| R-24/R-26 | 已修复（待设备验证） | MetricKit 崩溃/卡顿摘要 + 未捕获异常原因进入加载诊断；仍无阻塞堆栈采样 |
| R-25 | 未完成（设备） | 仍无真机性能基线 |
| R-32 | 已修复 | `deinit` 加锁；`InMemoryNovelLibrary` 检查 `lastError`，失败返回 nil |
| R-33 | 部分缓解 | 新增 8 个测试文件/用例组；UI、真机、真实网络未覆盖 |

“已修复（待验证）”指代码与静态检查完成，但构建/测试/设备验证以 CI 与真机结果为准；
本机没有 Swift/Xcode 工具链。F-03/F-04 见“生命周期与卡顿修复”，F-05/F-07 仍部分修复，
F-06/F-08 已处理或改写测试。

---

## 翻译报障修复（2026-10-21，用户反馈后）

| 问题 | 处理 | 状态 |
|---|---|---|
| 翻译服务返回 429 | `send` 对 429/5xx 重试 4 次并退避，解析 `Retry-After`，Google 批次间 350ms 间隔，浏览器 UA；最终提示更换服务商且保留已翻译段落 | 已实现；真实服务行为未验证 |
| 页面语言识别异常 | 样本优先取正文容器并读取 `<html lang>`/content-language/og:locale；本地识别置信度 <0.5 时采用声明语言；语言代码归一化 | 已实现；真实混合页面未验证 |
| 不同服务字段不适配 | Google 数组/字典/多位置检测字段；DeepL `detected_source_language`；OpenAI `message.content`/`text`/分片 | 已实现并有 `TranslationParsingTests` |
| 小说字段适配 | 提取脚本读取 JSON-LD Book/Chapter/author，补充正文/标题选择器 | 已实现；真实站点未逐一验证 |

---

## 性能修复状态（2026-10-22）

| 风险 | 状态 | 说明 |
|---|---|---|
| R-11 | 部分修复 | 预览缩放/编码已在后台；未做真机帧率测量 |
| R-12 | 已修复 | 离线 archive/preview/manifest 读写与 preview PNG 编码均在后台 |
| R-13 | 已修复 | 历史 visit id 入队前生成，记录/标题/清理在串行后台队列 |
| R-15 | 部分修复 | 启动清理私密下载、私密预览不写盘；异常终止的旧版本遗留文件未主动枚举 |
| R-17 | 部分修复 | 设置文档保留上一份成功备份并在解码失败时回退；字段级兼容未做 |
| R-18 | 已验证假设 | WindowSessionTests 覆盖 window-main 与 Stage Manager 会话隔离 |
| R-14 | 部分修复 | `WebViewHost` 进度 10 Hz 节流；未做 SwiftUI 更新计数 |
| R-16 | 部分修复 | 私密图标候选过滤（B7）+ in-flight 合并/失败负缓存；未做真实抓包 |
| F-07 | 已修复 | 私密小说库的 7 条 DDL 在 Task.detached 中执行；环境按代次安装服务 |

---

## 生命周期与卡顿修复（2026-10-22）

| 项 | 状态 | 说明 |
|---|---|---|
| F-03 | 已修复 | reader 只持弱书架；会话/环境是唯一强引用，结束回调取消 loader 并释放书架；测试覆盖弱引用释放 |
| F-04 | 已修复 | 两阶段 `beginEndPrivateSession`/`finishEndPrivateSession`：同步失效/取消阅读器/关标签/取旧 store，异步只清旧 store；SwiftUI 销毁视图不再承担顺序 |
| C3 | 部分修复 | back/reload/home 与私密开关已统一；界面展示动作仍在 shell |
| 顶栏卡顿 | 待验证 | 建议建议列表改为显式高度，去掉 self-sizing ScrollView；真机未复现/验证 |
| 卡顿诊断 | 已实现 | `MainThreadHangMonitor` 记录 ≥2s 卡顿、页面、持续时间与最后操作；不采样阻塞堆栈 |
