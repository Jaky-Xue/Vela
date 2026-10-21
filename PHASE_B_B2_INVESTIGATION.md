# Phase B2 调查：小说模块的私密数据边界

- 基线：`3ed4197` + 阶段 B1 的本地修改（未提交）
- 性质：**只读调查**。本轮没有修改任何 Swift 实现、没有提交、没有推送。
- 结论先行：当前小说模块**完全不知道隐私模式**；私密标签页进入小说模式会把章节正文、书目、目录、
  阅读进度写入普通模式长期数据库，并用持久化 WebKit 存储抓取章节/目录。
  推荐的最小改法不是重写小说功能，而是给私密阅读一个独立的 `:memory:` SQLite 服务实例。

## 1. 调查范围

- 入口：`BrowserShellView.activateNovelMode` / `openNovel` / `NovelSession`
- 服务：`NovelLibraryService`、`NovelRepository`、`BrowserSchema` 的 `novel_*` 表
- 加载：`NovelChapterLoader`、`NovelTOCLoader`、`NovelModeService.extract/extractTOC`
- 展示：`NovelReaderView`、`NovelChapterWebView`、`NovelBookshelfView`
- 清理：`pruneChapters`、`delete`、`endPrivateSession`

## 2. 数据流（当前实现）

```
私密标签页（页面已在私密 store 中）
  │
  ├─ BrowserShellView.activateNovelMode (BrowserShellView.swift:1081)
  │    └─ NovelModeService.extract(from: 活动标签的 WebView)      ← 用私密 store，正确
  │
  ├─ env.novels.open(extraction) (NovelLibraryService.swift:58)
  │    ├─ books.first(matchKey)                                   ← 进程级书架，来自普通 DB
  │    ├─ repository.chapter(bookId:url:)                         ← 普通 DB 读
  │    ├─ repository.upsertChapter(chapter)                       ← 章节正文写普通 DB
  │    ├─ repository.upsert(book)                                 ← 书目/进度写普通 DB
  │    ├─ repository.pruneChapters(bookId:keep:60)                ← 普通 DB 删
  │    ├─ repository.saveTOCSource(...)                           ← 目录页地址写普通 DB
  │    └─ reload() → repository.allBooks()                        ← 普通 DB 读
  │
  ├─ NovelSession(book, chapter) → NovelReaderView
  │    ├─ prepare (NovelReaderView.swift:372)
  │    │    ├─ env.novels.tocEntries / cachedChapter / chapter    ← 普通 DB 读
  │    │    └─ saveNow() → markPosition                           ← 进度写普通 DB
  │    ├─ loadTOCIfNeeded (NovelReaderView.swift:402)
  │    │    ├─ tocLoader.load(urlString:)                          ← 离屏 WKWebView，.default() 持久化 store
  │    │    └─ env.novels.saveTOC / saveTOCSource                  ← 普通 DB 写
  │    ├─ load(url:index:) (NovelReaderView.swift:438)
  │    │    ├─ env.novels.chapter(bookId:url:)                     ← 普通 DB 读
  │    │    ├─ loader.load(urlString:)                             ← 离屏 WKWebView，.default() 持久化 store
  │    │    │    └─ NovelModeService.extract → env.novels.store    ← 章节正文写普通 DB
  │    │    └─ 章节 HTML 存入 chapter.contentHtml
  │    ├─ handleProgress (NovelReaderView.swift:588)
  │    │    └─ env.novels.updateProgress                          ← 每 ~2 秒写普通 DB
  │    ├─ onDisappear / 进入后台 → saveNow → markPosition          ← 普通 DB 写
  │    └─ NovelChapterWebView                                      ← .nonPersistent() + loadHTMLString
  │
  └─ NovelBookshelfView.books = env.novels.books                   ← 进程级普通书架
```

关键点：**章节/目录的离屏加载器使用 `.default()`**，它们的注释明确写着“共享浏览器的会话”，
这正是私密浏览要避免的；而 `.nonPersistent()` 只用于最终渲染本地 HTML 的显示 WebView。

## 3. 证据位置

| 事实 | 位置 |
|---|---|
| 章节加载器固定使用持久化 store | `Vela/Core/Novel/NovelChapterLoader.swift:44` |
| 目录加载器固定使用持久化 store | `Vela/Core/Novel/NovelTOCLoader.swift:36` |
| 加载器注释声称共享浏览器会话 | `NovelChapterLoader.swift:40-44`、`NovelTOCLoader.swift:33-36` |
| 服务是进程级单例 | `Vela/App/AppServices.swift:110`（`self.novels = NovelLibraryService(...)`） |
| 服务直接持有具体仓库 | `NovelLibraryService.swift:25`（`private let repository: NovelRepository`） |
| 打开章节写库 | `NovelLibraryService.swift:58-116`（`upsertChapter`/`upsert`/`pruneChapters`/`saveTOCSource`） |
| 存储新章节写库 | `NovelLibraryService.swift:138-160` |
| 阅读进度写库 | `NovelLibraryService.swift:165-181`、`:195-210` |
| 目录读写库 | `NovelLibraryService.swift:213-231`、`:264-267` |
| 章节/书目/目录表 | `Vela/Data/BrowserSchema.swift:441,463,484,497` |
| 仓库读写 | `Vela/Data/Repositories/NovelRepository.swift:62,80,103,137,148,160,185,204,224,242` |
| 私密标签页入口 | `BrowserShellView.swift:1081-1107` |
| 会话结构（无隐私字段） | `BrowserShellView.swift:1301-1305` |
| 书架只读 `env.novels.books` | `Features/Novels/NovelBookshelfView.swift:27` |
| 阅读器 12 处直接使用 `env.novels` | `NovelReaderView.swift:379,385,404,413,416,427,434,441,466,503,600,606` |
| 显示 WebView 使用 `.nonPersistent()` | `NovelReaderView.swift:804-806`，`loadHTMLString` 在 `:852,863` |
| 结束私密会话不触碰小说 | `AppEnvironment.swift:234-243` |
| 小说测试 | **`VelaTests` 中没有任何 novel 测试**（`grep -ril novel VelaTests` 为空） |

## 4. 五个问题的直接回答

### Q1：私密模式下，章节和目录请求是否使用默认网络会话或普通持久化缓存？

**是。** `NovelChapterLoader` 与 `NovelTOCLoader` 都设置
`configuration.websiteDataStore = .default()`。它们加载的是站点页面（不是纯 HTML），会执行站点脚本、
携带/写入普通 profile 的 Cookie、LocalStorage 和缓存。

唯一的例外是最终展示 `NovelChapterWebView`：它用 `.nonPersistent()` + `loadHTMLString`，
不参与章节抓取；但章节 HTML 中的绝对图片 URL 仍可能由这个显示 WebView 发起请求
（这是一个新的 ephemeral store，不污染普通 profile，但仍是网络请求）。

活动标签页本身如果已处于私密模式，`NovelModeService.extract` 在它的 WebView 上运行，用的是私密 store——
这一段是安全的；泄漏发生在之后的离屏加载。

### Q2：私密模式下，书架、阅读进度、章节内容及相关元数据是否会写入磁盘？

**是，全部会。**

| 数据 | 写入点 | 表 |
|---|---|---|
| 书目、作者、来源、当前章节、进度、时间 | `open`/`persist`/`markPosition`/`updateProgress` | `novel_books` |
| 章节正文 HTML、标题、前后章 URL | `open`/`store` | `novel_chapters` |
| 目录条目 | `saveTOC` | `novel_toc_entries` |
| 目录页地址 | `saveTOCSource` | `novel_toc_sources` |

`NovelLibraryService` 在 `AppServices` 中构造一次，所有窗口共享；因此私密阅读会直接出现在常规书架，
并改变常规书的阅读进度。结束私密会话不会删除这些行。

### Q3：现有模块能否在不重写小说功能的前提下区分普通与私密数据？

**当前不能，但接口改动可以很小。** 原因是服务只接受具体的 `NovelRepository`，且所有调用点都通过
`env.novels` 拿同一个进程级实例；没有任何边界参数。不过 `NovelLibraryService` 的行为完全由它持有的
`NovelRepository` 决定——这给了一个几乎不需要改服务内部的方案（见 §5）。

### Q4：如果需要修改接口，最小变更是什么？是否影响普通模式？

**推荐方案：私密阅读使用一个独立的 `:memory:` SQLite 数据库。**

做法：

1. `AppEnvironment` 增加一个懒创建的私有小说服务：
   - 新建 `SQLiteDatabase(path: ":memory:")`；
   - 执行 `BrowserSchema.creationStatements`；
   - `NovelLibraryService(repository: NovelRepository(database: db))`。
2. `AppEnvironment.novelLibrary(privateMode:)` 返回普通服务或私密服务；
   `endPrivateSession` 丢弃私密服务（数据库随之释放）。
3. `NovelSession` 增加 `isPrivateSession`，由进入时的活动标签页隐私模式决定。
4. shell 的 `activateNovelMode`、`openNovel`、书架 sheet 使用对应服务；
   `NovelReaderView` 用会话服务替换 12 处 `env.novels`。
5. `NovelChapterLoader` / `NovelTOCLoader` 增加 `dataStore` 参数：
   私密 → B1 的窗口私密 store；普通 → `.default()`。
6. 离开无痕模式时关闭阅读器（或明确保留策略），避免 B1 清理 store 与正在阅读的章节加载冲突。

**不需要**修改 `NovelLibraryService` 的内部逻辑、`NovelRepository`、数据库 schema 或做迁移。
`NovelLibraryService` 在 `:memory:` 仓库上原样工作（`reload`、`open`、`store`、TOC、进度都走同一套 SQL）。

**对普通模式的影响**：无。普通路径仍用 `AppServices.novels` 与持久化数据库；现有书架、章节缓存、
阅读进度和用户数据都不变。私密书架是空的、只含本次私密会话打开的书；结束会话后消失。

**代价/风险**：

- 第一次进入私密小说模式时，在内存里创建全部 `BrowserSchema` 表；一次性成本很小（约 20 张表）。
- 私密书架只列本次会话的书；常规书架在私密模式下不可见。这是产品选择（可改为只读展示常规书，
  但会增加“进度写到哪”的复杂度）。
- 私密阅读器的章节加载器需要站点会话；用 B1 的窗口私密 store 最自然。若离开无痕模式时阅读器仍开着，
  B1 的清理会清掉该 store。最小处理：离开无痕模式时关闭阅读器（shell 已有 `novelSession`）。
- 若 `:memory:` 数据库创建失败（实际上几乎不会），不得回退到持久化服务；应提示“私密模式下无法打开小说”
  并返回。
- 显示 WebView 保持 `.nonPersistent()`；若要求私密模式下连图片也不外发，需要另行处理章节 HTML 中的
  绝对图片 URL（不在本次最小范围）。

**备选（不推荐，改动更大）**：给 `NovelLibraryService` 增加可选仓库 + 内存字典；需要改约 10 个方法，
而 `:memory:` 方案复用了全部现有 SQL 逻辑。

### Q5：如何测试“私密模式退出后不残留新写入的私密数据，同时普通模式数据不受影响”？

建议分三层：

1. **纯单元（不需要 WebKit）**
   - 用两个服务实例：普通服务接一个临时文件/内存 `SQLiteDatabase`（预先建表），私密服务接另一个
     `:memory:` 数据库。
   - 对私密服务执行 `open` → `store` → `saveTOC` → `markPosition/updateProgress`；
     断言私密的 `novel_*` 行存在，普通库的行数保持不变。
   - 丢弃私密服务，新建一个私密服务；断言书架为空、章节为空。普通服务重新 `reload`，断言数据仍在。
2. **加载器数据存储选择**
   - 把“私密 → 共享私密 store / 普通 → `.default()`”抽成纯函数（或可注入的配置），
     断言不启动网络即可验证选择正确。
   - 可选集成测试：本地 HTTP 服务器返回章节页，私密 loader 用私密 store 加载；
     断言 `.default()` store 的 Cookie 没有新增。
3. **阅读器/书架 UI**
   - 无 UI test target，只能模拟器手动：私密标签进入小说模式 → 书架只显示本次会话的书 →
     退出无痕模式 → 书架为空；普通书架不变；重启后常规书架仍在。
4. **退出清理**
   - 结束私密会话后，断言私密服务被丢弃（新会话服务为空）；
     普通数据库行数、普通书架、普通阅读进度不变。

现有测试缺口：`VelaTests` 没有任何小说测试（T-09）。

## 5. 风险与待确认决策

| 编号 | 风险/决策 | 建议 |
|---|---|---|
| B2-D1 | 私密书架是否显示常规书架（只读）？ | 推荐不显示；私密模式只列本次会话的书 |
| B2-D2 | 离开无痕模式时阅读器仍开着怎么办？ | 推荐关闭阅读器，并在关闭前保存（私密进度随会话丢弃） |
| B2-D3 | 私密章节抓取使用哪个 store？ | B1 的窗口私密 store（共享站点的私密会话 Cookie） |
| B2-D4 | 章节 HTML 中绝对图片 URL 的网络请求 | 最小方案不处理；如需零外发，另做 HTML 过滤 |
| B2-D5 | `:memory:` 建库失败 | 不回退持久化；提示并禁用私密小说模式 |
| B2-R1 | 私密服务是每窗口还是进程级？ | 每窗口（与 B1 的窗口级私密会话一致） |
| B2-R2 | 常规书在私密模式下无法访问 | 已接受的产品限制，需在 UI 文案中说明 |

## 6. 测试计划（若批准实现）

| 测试 | 层级 | 说明 |
|---|---|---|
| 私密服务往返 | 单元 | open/store/chapter/TOC/progress 全部在 `:memory:` |
| 普通库不受影响 | 单元 | 临时普通 DB 行数前后一致 |
| 退出后新私密服务为空 | 单元 | 丢弃旧实例后新建，books/chapters/TOC 为空 |
| 普通服务回归 | 单元 | 用临时 DB 验证 open/store/reload（当前无小说测试） |
| 加载器 store 选择 | 单元 | 纯函数/配置注入 |
| 私密 loader 不写默认 Cookie | 集成（可选） | 本地服务器 + 两个 store |
| 私密书架/阅读器/退出 | 手工 | 模拟器；无 UI 测试 target |

## 7. 验证限制

- 本机无 Swift/Xcode：未编译、未运行任何测试。
- 没有小说测试可作为回归基线；实现时必须先补最小普通模式测试。
- 模拟器上的 WebKit Cookie/store 行为仍需 CI 或真机确认。

## 8. 结论

- 当前私密小说阅读会写入普通数据库并使用持久化网络会话，是已确认的隐私边界缺陷（R-02）。
- 推荐的最小实现是“独立 `:memory:` SQLite 服务 + 私密 loaders 使用 B1 store + 阅读器/书架按会话选服务”，
  不改服务内部、不改 schema、不影响普通模式。
- 需要用户确认 §5 的 D1/D2/D3 决策后，才进入实现。

> **决策状态（2026-10-21）**：D1/D2/D3 已批准（私密书架仅本次会话、退出关闭阅读器、loader 使用私密 store）。
> B2 实现暂缓，等阶段一审查通过后开始；阶段一不修改小说实现。

> **实施状态（2026-10-21）**：阶段一审查通过后已按本调查的推荐方案实施；详见
> `PHASE_B_IMPLEMENTATION_PLAN.md` §15。
