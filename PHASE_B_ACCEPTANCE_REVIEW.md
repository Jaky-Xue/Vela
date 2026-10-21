# Phase B 验收审查（B1 + B2，只读）

- 基线：`3ed4197` + 未提交的 B1/B2 工作区改动
- 性质：**只读审查**。未修改 Swift 实现，未进入 B3，未提交/推送/创建分支/修改 CI。
- 方法：完整源码阅读、调用点检索、所有权/释放链核对、测试设计审查。
- 限制：本机无 Swift/Xcode；**没有构建、没有运行测试、没有模拟器/真机验证**。
  以下“置信度”指代码证据强度，不代表运行已验证。

## 1. 发现（按严重程度排序）

### F-01（S2，隐私边界，置信度高）私密阅读器的“在浏览器中打开”会落到普通标签页

**位置**

- `Vela/Features/Novels/NovelReaderView.swift:630-636`：`openCurrentInBrowser()` 在 `guard isSessionCurrent` 后调用
  `onOpenInBrowser(url)`。
- `Vela/App/BrowserShellView.swift:322-326`：阅读器的 `onOpenInBrowser` 只检查会话 id，然后
  `novelSession = nil; openInBrowser(url)`。
- `Vela/App/BrowserShellView.swift:1202-1209`：`openInBrowser` **使用当前 `activeTab`**；没有标签页时
  `tabManager.createTab(openSource: .user)`（是否私密取决于路由，不取决于阅读器会话）。
- 阅读器是窗口级图层；`handleBrowserCommand`（`BrowserShellView.swift:1018-1043`）在阅读器打开时仍处理
  `nextTab/previousTab`（`TabManager.switchTab`），也可以用 `Cmd+W` 关闭当前标签。因此私密阅读器可以与一个
  普通活动标签同时存在。

**证据链**

1. 从私密标签进入小说模式 → `NovelSession.isPrivateSession == true`，`library` 是内存库。
2. 打开阅读器后用硬件键盘切到一个普通标签（或关闭私密标签使普通标签成为活动标签）。
3. 在阅读器里点“在浏览器中打开”（`NovelReaderView.swift:289` 或失败态的 `:125`）。
4. `openCurrentInBrowser` → shell `openInBrowser` → `navigate(to:url,in:activeRegularTab)`。
5. `navigate` → `TabManager.load`；导航代理用该标签的 `dataBoundary`（regular）写历史，WebKit 用普通
   profile 的 store 写 Cookie/缓存。

**影响**

- 私密章节 URL 写入常规历史记录、常规 WebKit Cookie/缓存；违反 B2 的私密边界。
- 不需要用户“主动同意泄漏”——“在浏览器中打开”本身是阅读器的正常动作；泄漏取决于当时的活动标签。
- 无标签页时，`createTab(openSource:.user)` 若路由为普通，也会得到普通标签，路径相同。

**最小建议**

- 让打开动作携带会话隐私：`openInBrowser(_ url: URL, isPrivateSession: Bool)`。
- 私密会话：优先使用仍然存在的私密来源标签；否则 `tabManager.openTab(url:privacyMode: .private, openSource:.user)`。
  不得使用当前的普通 `activeTab`。
- 若产品希望“在浏览器中打开”必须离开私密模式，需要显式确认并说明会写入常规历史；不能静默使用普通标签。
- 补一个测试：私密阅读器 + 普通活动标签 → 打开动作不得在普通标签/普通历史产生记录。

**本轮未修改。**

### F-02（S3，会话身份，置信度中高）`endPrivateSession` 不识别发起会话；迟到的结束可能清理新会话

**位置**

- `Vela/App/AppEnvironment.swift:261-276`：`endPrivateSession()` 没有参数；它递增
  `privateNovelSessionGeneration`，关闭**当前**私密标签，清下载，`privateNovelService = nil`，
  清**当前**私密 store。
- 调用方是 fire-and-forget：
  - `VelaApp.swift:161-166`：进入后台时 `Task { await env.endPrivateSession() }`。
  - `BrowserShellView.swift:954-969`：离开无痕模式时 `Task { await env.endPrivateSession() }`。

**证据/竞态**

- 代次只在**结束**时递增，不在私密会话**开始**时递增。旧事件产生的结束 Task 若在新私密会话开始后才执行，
  它看到的是新会话：会关闭新私密标签、`privateNovelService = nil`（新会话的内存库）、并清空新会话的 store。
- 这不是“旧阅读器回调写入新库”（那条已由阅读器 `sessionGeneration` 守卫阻止），而是**结束操作本身**
  没有会话 token。
- 触发需要调度窗口：后台 Task 被推迟、或“离开无痕模式”的 Task 在新私密标签创建后才运行。概率不高，
  但代码没有阻止。

**影响**

- 新的私密会话被意外结束：私密标签关闭、私密书架/阅读器消失、内存库与 store 被清。
- 不会写普通库；是私密会话数据丢失/行为错乱，不是普通数据泄漏。

**最小建议**

- 在私密会话**开始**时分配 `privateSessionId`（或在进入私密时递增一个 `privateSessionStartGeneration`），
  调用方在事件发生时捕获它；`endPrivateSession(expectedSessionId:)` 在当前 id 不匹配时 no-op。
- 或把结束请求排队/串行化到“当前私密会话”并在会话开始后取消旧请求。
- 补测试：旧会话的延迟结束不得关闭新会话、不得清空新会话的私密服务/store。

### F-03（S3，资源生命周期，置信度高）私密小说服务/内存库可能晚于会话结束才释放

**位置/所有权**

- `NovelSession.library`（`BrowserShellView.swift:1401`）与 `NovelReaderView.library`
  （`NovelReaderView.swift:37`）都是**强引用**；`BrowserShellView.bookshelfLibrary` 也是强引用。
- `AppEnvironment.endPrivateSession` 只把环境的 `privateNovelService` 置 nil（`:271`）。
- 阅读器由 SwiftUI 图层移除后才释放 `library`；`onDisappear` 还可能在异步任务之后才运行。

**影响**

- 旧内存库/`SQLiteDatabase` 在环境释放引用后仍被阅读器（以及其 `.task`/`load` 任务持有的视图结构）强持有；
  直到视图真正销毁。会话结束后可能继续占用内存。
- 写入安全：阅读器的 `isSessionCurrent` 守卫在 post-await 边界返回；旧库不会被新会话使用，也不会写普通库。
- “释放私密服务及内存数据库”在环境层面成立，在物理层面是延迟的；不声称已立即释放。

**最小建议**

- 让阅读器/书架对库持可选或弱引用，环境持有唯一强引用；会话结束时环境释放即让 DB deinit。
  阅读器所有调用需要处理 nil（但代次已保证不再写，nil 只是安全网）。
- 或在代次变化的 `onChange`/`onDisappear` 中显式把阅读器的 `library` 置 nil（需把 `private let` 改为
  `var`/可选），并先 cancel 两个 loader。
- 不必为本条引入新框架。

### F-04（S3，清理顺序，置信度高结构/中时序）严格顺序不是同步保证的

**当前实际顺序**

`AppEnvironment.endPrivateSession` 在主 actor 上同步执行：

1. `privateNovelSessionGeneration &+= 1`（失效）；
2. `tabManager.endPrivateSession()`（关私密标签、销毁 WebView）；
3. `downloads.clearPrivateRecords()`；
4. `privateNovelService = nil`；
5. `await webCoordinator.clearPrivateWebsiteData()`：同步取出旧 store，异步 `removeData`。

**依赖 SwiftUI/异步的部分**

- 阅读器/书架的 `.onChange(of: env.privateNovelSessionGeneration)`、`onDisappear` 由 SwiftUI 观察/生命周期驱动；
  它们可能在步骤 2–4 之后才运行。
- 阅读器 `onChange` 里 cancel `loader`/`tocLoader` 也是 SwiftUI 更新的一部分；loader 的轮询/超时任务在
  cancel 前仍可能运行（它们不写库）。
- `VelaApp` 后台结束是 fire-and-forget Task；Task 未启动则整个结束流程不开始（B1 既有局限）。
- 进程终止时，内存库/私密 store 随进程消失；没有持久化私密小说数据。

**影响**

- 在途章节/目录加载可能在 store 被清时被中断；阅读器关闭略滞后；UI 可能短暂显示旧阅读器。
- 数据安全由代次守卫保证（旧阅读器 post-await 写入被阻止）；**不是**由“先关阅读器再清库”的顺序保证。
- 不声称严格串行；如果产品要求严格顺序，需要同步的 “will end” 钩子/两阶段结束。

**最小建议**

- 增加一个同步的 `onPrivateSessionWillEnd` 回调（shell 注册），在环境执行步骤 1 后立即 cancel 阅读器
  loader、清空阅读器/书架状态；或把结束拆成 `beginEnd`（同步失效/关闭 UI）与 `finishEnd`（异步清 store）。
- 保持“不阻塞主线程”；只做 cancel/状态失效，不做 `removeData` 的同步等待。
- 明确记录后台 Task 未启动的限制。

### F-05（S4，数据库生命周期，置信度中）`deinit` 无锁、私密库错误被静默吞掉

**位置/证据**

- `Vela/Data/SQLite/SQLiteDatabase.swift:267-271`：`deinit` 直接 `sqlite3_close_v2(handle)`，没有获取
  `lock`；`close()`（`:273-280`）是加锁的。
- `Vela/Services/Novels/NovelLibraryService.swift:30-43`：`init` 调 `reload()`；`reload` 用
  `do/catch`，失败时 `books = []`、`lastError = ...`，不抛出。
- `Vela/Services/Novels/InMemoryNovelLibrary.swift:23-33`：只在建库/schema 失败时返回 nil；
  **不检查** `NovelLibraryService.lastError`。如果 schema 创建成功但后续查询失败，私密书架会静默为空。

**影响**

- `deinit` 与在途操作的竞态：当前所有小说库调用都在 `@MainActor` 的 `NovelLibraryService` 上同步执行，
  正常释放也在主 actor；竞态主要是理论性的。但如果未来有后台调用或最后一个引用在后台释放，缺少锁的
  `deinit` 不是安全的关闭路径。
- `reload` 失败时没有用户可见错误；私密书架为空看起来像“没有书”，而不是“存储失败”。

**最小建议**

- `deinit` 只调用加锁的 `close()`（避免与在途语句竞争）；或要求显式 `close()` 并断言。
- `InMemoryNovelLibrary.make` 在返回前检查 `service.lastError`，非空时返回 nil 或把错误传给 shell 提示。
- 不为这条做架构改造。

### F-06（S4，测试设计/覆盖，置信度高）测试存在平台假设与覆盖缺口

**证据**

- `VelaTests/NovelPrivacyTests.swift:223-252`（子资源测试）使用一个**未加入窗口**的 `WKWebView` 加载含
  iframe 的本地页面。WebKit 通常仍加载子帧，但没有窗口/可见性保证；该断言可能因平台调度而非产品问题失败。
- `VelaTests/NovelPrivacyTests.swift:149-171` 断言
  `NovelLoaderDataStore.resolve(false, ...) === WKWebsiteDataStore.default()`。`default` 在实际平台上通常是
  同一实例，但测试把“同一对象”当作契约；若 WebKit 返回包装对象，会出现假失败。
- B1 测试（`WebNavigationIntegrationTests.swift:857-950`）直接调用 `tabManager.endPrivateSession()` +
  coordinator 的轮转 API，不经过 `AppEnvironment.endPrivateSession`；环境接线没有覆盖。
- B2 测试直接调用 `InMemoryNovelLibrary.make()`，不经过 `AppEnvironment.novelLibrary(privateMode:)`；
  懒创建/释放、每窗口作用域没有覆盖。
- 没有跨窗口私密小说隔离测试；没有 UI 测试 target，阅读器关闭/书架隐藏只能手工。
- 没有覆盖 F-01（打开到普通标签）与 F-02（迟到结束结束新会话）。

**影响**

- 测试可能给出假失败（子资源/默认 store 身份）；也可能给出假安全感（环境接线/UI 时序/跨窗口未测）。
- 现有逻辑测试本身有价值；问题在“把未运行/未覆盖的部分当作已证明”。

**最小建议**

- 子资源测试把 web view 加入测试宿主窗口，或改用 `NovelChapterLoader` 的离屏宿主；仍失败则标记为平台相关。
- 默认 store 改为行为断言（普通选择不是私密 store，且配置的 store 是 `WKWebViewConfiguration` 的默认），
  或记录为平台契约假设。
- 增加 `AppEnvironment` 级测试（可用 `AppServices` 的测试替身/隔离数据库）覆盖懒创建、释放、代次；
  跨窗口用两个 coordinator/environment 测试。
- 为 F-01/F-02 各加一个回归测试（打开动作的目标标签/历史边界；延迟结束不结束新会话）。

### F-07（S4，性能，置信度高）首次私密小说打开在主 actor 执行完整 schema

- `InMemoryNovelLibrary.make()` 在主 actor 上执行 `BrowserSchema.creationStatements` 的全部 19 条
  CREATE TABLE/INDEX（`:27-29`），然后 `NovelLibraryService.init` 再 `reload()`。
- 一次性成本很小；但在低端设备上可能是一帧以上的停顿。**没有测量**，不应先优化。
- 建议：先测量首次“私密小说模式”打开的 main-thread hang；若明显，再考虑只建 novel 表或异步建库
  （需要处理 actor/UI 等待，不能盲目并发化）。

### F-08（S4，API 防误用，置信度高）loader 的 `dataStore` 有 `.default()` 默认值

- `NovelChapterLoader.load`（`:33-36`）与 `NovelTOCLoader.load`（`:26-30`）的 `dataStore` 默认
  `.default()`。当前唯一调用方 `NovelReaderView` 显式传值；未来新增私密调用点若忘记传，会静默写普通 profile。
- 建议：把 `dataStore` 改为必填（当前只有一个调用方），或在 Debug 断言调用方不是私密会话。
  这是防误用，不是当前泄漏。

## 2. A–E 问题的回答

### A. B2 数据库生命周期

1. **初始化/持有/释放**：`InMemoryNovelLibrary.make()` 创建 `SQLiteDatabase(":memory:")`，执行 schema，
   用同一个 database 构造 `NovelRepository`，再构造 `NovelLibraryService`。所有权链是
   `NovelLibraryService → NovelRepository → SQLiteDatabase`；工厂的局部 database 在返回后不再被引用。
   `AppEnvironment.privateNovelService` 是环境的强引用；`NovelSession.library`/`NovelReaderView.library`/
   `bookshelfLibrary` 是额外强引用。
2. **`:memory:` 连接复用**：每个私密服务只有一个 `SQLiteDatabase`；`NovelRepository` 的每个方法都使用
   构造时传入的同一个 `database`，没有新建连接。`SQLiteDatabase` 用 `NSRecursiveLock` 串行化
   execute/query/transaction。**代码证明**：连接复用、单连接、schema 创建路径；**运行假设**：
   `:memory:` + PRAGMA 在该 iOS 版本的行为（现有测试/harness 使用 `:memory:`，但 B2 的 schema 组合未运行）。
3. **异步任务写旧库**：`NovelLibraryService`/`NovelRepository` 没有 async/Task；所有写是同步调用。
   阅读器的 post-await 写入点前都有 `isSessionCurrent` guard（见 B）。环境级 `endPrivateSession`
   本身没有发起会话 token（F-02）；这是“结束操作”而不是“旧任务写库”。
4. **释放时的未完成操作**：`SQLiteDatabase` 操作同步、主 actor；正常路径没有未完成语句。`deinit` 不加锁
   （F-05）是理论风险。旧库可能因阅读器强引用延迟释放（F-03）。

### B. 异步任务与会话代次

| 入口 | 写入/状态 | 守卫 |
|---|---|---|
| `BrowserShellView.activateNovelMode` Task（`:1134-1165`） | `library.open` | 提取后 `generation == env.privateNovelSessionGeneration`；`openNovel` 再检查 |
| `NovelReaderView.prepare`（`:413`） | `tocEntries`、`saveNow`、load | 开头 guard；`load`/`loadTOC` 内部再 guard |
| `loadTOCIfNeeded`（`:446`） | `saveTOCSource`、`saveTOC` | 开头 + 两个 await 后 guard |
| `load`（`:486`） | `library.store`、chapter 状态 | 开头 + loader await 后 guard |
| `goNext/goPrevious`（`:573/582`） | 调 `load` | 开头 guard；`load` 再 guard |
| TOC sheet 选择（`:194`） | 调 `load` | `load` guard |
| `showTOC` onChange（`:181-183`） | 调 `loadTOCIfNeeded` | 方法 guard |
| `handleProgress`（`:640`） | `updateProgress` | 开头 guard |
| `saveNow`（`:658`） | `markPosition` | 开头 guard |
| `scenePhase` onChange（`:164`） | `saveNow` | `saveNow` guard |
| `onDisappear`（`:150`） | `saveNow`、cancel loaders | `saveNow` guard |
| 阅读器 `onChange(generation)`（`:155`） | cancel loaders、onClose | 会话代次比较 |
| shell `onChange(generation)`（`:447`） | 关闭 reader/shelf | `shouldClose` / shelf 代次 |
| `openNovel`（`:1158`） | 创建 reader | 私密代次检查 |
| `NovelChapterLoader` 轮询/超时（`:134/67`） | 只提取、不写库 | `finish` cancel；`webView` 身份 |
| `NovelTOCLoader` 轮询/超时（`:118/56`） | 只提取、不写库 | 同上 |
| `AppEnvironment.endPrivateSession`（`:261`） | 关标签/清下载/释放服务/清 store | **无发起会话 token（F-02）** |

结论：阅读器内的数据写入在 post-await 边界有代次守卫，未发现“检查后产生写入”的明确路径（main actor
上 guard 与同步写入之间没有 await）。仍存在的身份问题在**环境级结束操作**（F-02），以及
`openInBrowser` 的标签选择（F-01）。迟到的 `openNovel` 已被代次 guard 拒绝；迟到的 reader close 被
session id 拒绝。

### C. 网络数据边界

- 章节/目录：`NovelChapterLoader.swift:50`、`NovelTOCLoader.swift:43` 使用
  `NovelLoaderConfiguration.make(dataStore:)`；私密传窗口私密 store，普通 `.default()`。重定向在同一个
  WKWebView/store 内完成。
- 显示 WebView：`NovelReaderView.swift:97-106` 通过 `NovelReaderDisplayDataStore`；私密→窗口私密 store，
  普通→`.nonPersistent()`（保持原行为）。`loadHTMLString`（`:912/923`）的绝对图片/子资源使用该 store。
- 活动标签提取：`NovelModeService.extract` 在活动标签自己的 WebView 上执行；私密标签的 WebView 用私密 store。
- 小说模块中**没有** `URLSession`、`WKDownload`、下载服务或其它绕过 `WKWebsiteDataStore` 的网络入口；
  只有两处 `webView.load(URLRequest)` 和阅读器 `loadHTMLString`。
- 普通模式：`AppEnvironment.novelLibrary(false) → services.novels`；loader `.default()`；display `.nonPersistent()`；
  schema/数据不变。
- 私密模式：`InMemoryNovelLibrary` + 私密 store；没有发现调用普通 `services.novels` 的路径。
- **例外**：F-01 的“在浏览器中打开”不是小说 loader，但会把私密章节 URL 交给当前标签页（可能普通），
  因此网络边界在该用户动作上不完整。

### D. B1 与 B2 的退出交界

**同步保证（`AppEnvironment.endPrivateSession` 主 actor 内）**

1. 递增小说代次；
2. `tabManager.endPrivateSession()` 关私密标签、销毁 WebView；
3. `downloads.clearPrivateRecords()`；
4. `privateNovelService = nil`；
5. `clearPrivateWebsiteData()` 在第一个 `await` 前同步取出旧 store（置空共享属性），之后异步 `removeData`。

**依赖 SwiftUI/异步**

- 阅读器/书架的关闭与 loader cancel：`.onChange(generation)`、`onDisappear`，不是同步步骤。
- 旧小说库的物理释放：取决于阅读器/任务/视图何时释放强引用（F-03）。
- 后台结束：`Task` fire-and-forget；Task 未启动则步骤 1–5 都不发生（B1 既有局限）。
- 进程终止：内存库/私密 store 随进程消失；没有持久化私密小说数据。未完成清理不会留下普通库数据。

**明确不保证**

- “先关阅读器/cancel 任务，再释放服务/清 store”的严格串行；只有“先失效代次”是同步的。
- 后台挂起前完成 `removeData` 或物理释放旧内存库。
- 迟到的**环境级结束**不会结束新会话（F-02）。

### E. 测试与 CI

- 静态检查：完整 `git diff`、调用点检索、括号平衡（启发式）、`git diff --check`（退出码 0）。
- 新增测试：B1 私密区相关测试 7 个（其中 6 个为 B1 新增/轮换）；B2 8 个；**均未运行**。
- 未执行：`xcodebuild build`、`xcodebuild test`、模拟器、真机。
- CI：`.github/workflows/build-ios.yml` 只有 `workflow_dispatch`；GitHub Actions 执行远程 ref，
  未提交的本地改动无法被构建/测试。本轮没有提交/推送/创建分支。
- 测试设计问题与覆盖缺口见 F-06。
- 不能把本报告或测试清单当作“构建通过”或“测试通过”。

## 3. 验证矩阵

| 检查项 | 方法 | 状态 |
|---|---|---|
| 源码/调用链/所有权 | 只读阅读 + 检索 | **已执行** |
| `git diff --check` | shell | **已执行**，退出码 0 |
| 括号平衡（启发式） | 计数 | **已执行**，仅启发式 |
| 实际构建 | Xcode/CI | **未执行** |
| 实际测试 | XCTest/CI | **未执行** |
| 模拟器/设备 | 手工 | **未执行** |
| 子资源真实隔离 | 需要 CI/设备 | **未验证**（测试已写） |

## 4. 已由代码证明的正面结论

1. `:memory:` 私密服务只有一个 `SQLiteDatabase`，`NovelRepository` 所有操作复用它；没有第二个连接。
2. 小说模块没有 `URLSession`/下载/其它绕过 WebKit store 的网络路径；章节/目录/显示三层都使用注入的 store。
3. 普通模式仍走 `services.novels` + `.default()` loader + `.nonPersistent()` display；schema/数据未变。
4. 私密阅读器的 12 处服务调用都使用会话 `library`；没有 `env.novels` 残留。
5. 阅读器 post-await/异步写入点前都有会话代次守卫；`openNovel`/关闭回调有会话 id 守卫。
6. loader 的轮询/超时任务可被 `finish`/`cancel` 取消；新一次 `didFinish` 会取消旧轮询。
7. 私密书架只读私密会话库；普通书架不受影响。

## 5. 剩余限制（不声称解决）

- F-01 的私密 URL 到普通标签是当前最明确的隐私缺口；未修复。
- F-02 的环境级迟到结束可能结束新私密会话；无发起会话 token。
- F-03 旧内存库可能延迟释放；F-04 严格顺序不保证。
- 后台 Task 未启动、挂起/终止、SwiftUI 生命周期时序仍无法在本环境验证。
- 测试未运行；迁移/数据库/WebKit 平台行为仍需 CI 与真机确认。

---

# C1 修复状态（2026-10-21）

本轮只修复 **F-01、F-02**。未修改 F-03~F-08，未进入 B3，未提交/推送/创建分支/修改 CI。

## C1-A：F-01 的修复

**实现**

- 新增 `Vela/App/NovelBrowserRouting.swift`：把“打开到哪个标签”做成纯路由决策。
  - 私密会话：代次过期 → `.refuse`；来源标签仍存在且为私密 → `.existingTab`；否则 → `.newPrivateTab`。
  - 普通会话：活动标签存在 → `.activeTab`；否则 → `.newRegularTab`（保持原行为）。
- `NovelSession` 增加 `sourceTabId`；`activateNovelMode` 传来源标签 id；书架在 `openBookshelf` 捕获
  `bookshelfSourceTabId`，打开的书沿用该来源。
- `BrowserShellView.openInBrowser(_:for:)` 使用会话的 `isPrivateSession` / `sourceTabId` / `sessionGeneration`
  做路由；私密路径**不再读取** `activeTab` 作为候选。`.existingTab` 会先激活来源私密标签，再加载 URL。
- 读者层 `onOpenInBrowser` 仍然先校验 `session.isCurrent(in: novelSession)`；路由层再校验私密代次。
  过期会话安全拒绝，不落普通标签。
- 普通阅读器：路由回落到原来的 `activeTab` / 新建普通标签行为。

**测试（T-11）**

新增 `VelaTests/NovelBrowserRoutingTests.swift`：

- 私密会话 + 普通活动标签 + 有效私密来源 → `.existingTab(source)`；
- 来源缺失/来源是普通标签 + 普通活动标签 → `.newPrivateTab`（不回退活动标签）；
- 私密代次过期 → `.refuse`；
- 普通会话 → `.activeTab` / `.newRegularTab`。

**未覆盖**：实际 SwiftUI 阅读器按钮点击、标签激活后的屏幕表现。没有 UI 测试 target；路由决策已覆盖，
UI 端到端仍需模拟器/真机手工验证。

## C1-B：F-02 的修复

**实现**

- 代次语义改为“每个私密会话一个”：`privateNovelSessionGeneration` 在**会话开始**和**结束**时都递增。
- `TabManager` 增加 `onPrivateSessionStarted`：当一个私密标签在“私密标签集合为空”时被追加，通知环境。
- `AppEnvironment.beginPrivateSession()`：递增代次、释放旧私密小说服务、让 coordinator 轮换/清理旧私密 store。
  - `BrowserWebCoordinator.beginNewPrivateSession()` 先取出旧 store（置空共享属性），再异步清空旧实例；
    新会话的 WebView 会创建新 store。
- `AppEnvironment.endPrivateSession(expectedGeneration:)`：
  - 用 `PrivateSessionLedger.end(expectedGeneration:currentGeneration:perform:)` 校验；
  - 代次不匹配 → 返回 nil，**不关闭标签、不清下载、不释放小说服务、不清 store**；
  - 匹配 → 执行同步结束动作，返回下一代号次；调用方赋值后再异步清 store。
- 调用方全部携带事件发生时捕获的代次：
  - `BrowserShellView.swift:960-974`（离开无痕模式）；
  - `VelaApp.swift:161-166`（后台清理）。

**测试（T-12 及相关）**

- `VelaTests/PrivateSessionLedgerTests.swift`：旧会话的延迟结束不执行任何 actions；当前结束执行一次并推进；
  重复结束 no-op。
- `VelaTests/PrivateSessionStartTests.swift`：`onPrivateSessionStarted` 只在私密 strip 为空时触发，
  同一会话的第二个私密标签不触发；结束后再建私密标签触发新会话。
- `VelaTests/PrivateSessionStoreTests.swift`：新私密会话会拿到不同的 `WKWebsiteDataStore`（旧的被退休）。
- 既有 B1/B2 的重复清理、快速重进、普通模式隔离测试保留。

**未覆盖**：`AppEnvironment.endPrivateSession` 的真实接线（需要完整 AppServices/数据库宿主）没有端到端测试；
T-12 覆盖了同一个 `PrivateSessionLedger` 决策、TabManager 触发和 coordinator store 轮换，AppEnvironment
的调用顺序为代码审查。没有 UI 测试 target。

## C1 后的剩余限制

- 严格清理顺序仍不保证：代次失效是同步的；阅读器/书架关闭、loader cancel、旧内存库释放仍依赖
  SwiftUI/异步任务（F-03/F-04 未修）。
- 新会话在后台结束事件之后才创建时，该后台结束不会清理这个新会话；它会在下一次结束/后台时处理。
- 旧会话的迟到结束现在不会清理新会话；但旧阅读器仍可能持有旧内存库直到视图释放（F-03）。
- 新会话开始时（`beginPrivateSession`）只重置小说服务与 WebKit store；旧私密下载记录、最近关闭记录仍依赖
  `endPrivateSession` 的路径清理。若旧结束被 no-op，这些记录可能留到下一次结束/后台。
- `beginPrivateSession` 从 `TabManager` 的“首个私密标签”触发；因此“关闭全部私密标签后留下的私密主页”
  会被视为新会话，旧 store/小说服务随之重置。这是行为变化，需要按产品语义确认。
- 后台 Task 未启动、挂起/终止、WebKit 平台行为仍未验证。
- 所有测试未运行；未构建、未做模拟器/真机验证。

## C1 验证状态

| 检查项 | 状态 |
|---|---|
| 静态检查（diff、检索、括号平衡、`git diff --check`） | **已执行** |
| 实际构建 | **未执行** |
| 实际测试 | **未执行**（新增/调整测试已写） |
| 模拟器/设备 | **未执行** |
