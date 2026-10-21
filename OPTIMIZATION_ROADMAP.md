# Vela 优化路线图（阶段 A 产出）

- 基线：`3ed4197`（`main`，工作区干净）
- 本文件只提出计划，**未实施任何修改**。
- 依据：`ARCHITECTURE_AUDIT.md`、`DEPENDENCY_MAP.md`、`RISK_REGISTER.md`。

## 0. 排序原则

1. 先修“会改变用户数据/隐私/内存占用”的问题，再谈性能与结构。
2. 每个改动必须有可验证的验收条件和回滚方式。
3. 性能改动必须先有基线；没有测量数字就不宣称提升百分比。
4. 不新增功能、不引入 AI、不引入大型依赖、不重写导航核心。
5. 不同时改导航、持久化、标签页管理和业务模块。每个阶段一组边界明确的问题。

---

## 1. 阶段 B：高风险问题修复（需用户批准后开始）

### B0（建议先做，需单独批准）：最小崩溃采集

- **对应**：R-24、R-26。
- **问题**：已知的“重新打开崩溃”没有任何日志；现有诊断只覆盖导航。
- **范围**：新增一个 `Diagnostics/` 小模块：
  - `NSSetUncaughtExceptionHandler` + `SIGABRT/SIGSEGV` 处理（只写入，不吞掉崩溃）；
  - 可选 MetricKit `MXCrashDiagnostic`（iOS 14+）；
  - 写到 `Application Support/Vela/Diagnostics/crash-<timestamp>.json`，设置 ▸ 导航诊断页提供“导出崩溃记录”。
- **为什么先做**：没有它，B3/B5 中任何与生命周期相关的修复都无法证明是否解决了崩溃。
- **明确**：这是诊断能力，不是产品功能；如果用户不希望新增该通道，则跳过 B0，并把 R-24 保持为“无法验证”。
- **验收**：人为触发一次测试崩溃（仅 Debug 构建的隐藏开关）后，下次启动能看到并导出记录。
- **回滚**：删除模块与启动安装点。

### B1：私密标签页共享数据存储

- **对应**：R-01。**影响**：私密模式的登录/弹窗、结束会话清理。
- **范围**（实施时确定）
  - `BrowserWebCoordinator` 持有窗口级 `sharedPrivateDataStore` 并由 `makeConfiguration` 使用；
  - `AppEnvironment.endPrivateSession` 清理同一实例；
  - 普通模式保持 `WKWebsiteDataStore.default()`；
  - 小说章节/目录加载器在 B2 接入；阅读器显示 WebView 只渲染本地 HTML，保持现状。
- **验收**
  - 两个私密标签页的 `configuration.websiteDataStore` 是同一对象；
  - 标签 A 设置 cookie，标签 B 的 `document.cookie` 可见；
  - 结束私密会话后 `getAllCookies` 为空（在清理完成之后）。
- **测试**：T-01，加入 `VelaTests` 的集成测试（本地服务器 + 两个私密标签页）。
- **回滚**：恢复每配置新建 store。
- **风险**：私密 store 的生命周期需要明确；窗口关闭时要释放。
- **状态（2026-10-21）**：已实施，测试已写入，未运行；详见 `PHASE_B_IMPLEMENTATION_PLAN.md` §11。
- **阶段一修正（2026-10-21）**：store 轮换已实施（取出旧实例后再清空），新增轮换/并发清理测试；
  仍未构建/运行。详见 `PHASE_B_IMPLEMENTATION_PLAN.md` §14。

### B2：小说模块接入私密边界

- **对应**：R-02、R-15 的小说部分。
- **范围**：两个加载器接收 `WKWebsiteDataStore`；`NovelLibraryService.open/store` 接收
  `BrowserDataBoundary`，私密时不写 `novel_*` 表；阅读器私密模式提示“不会加入书架”。
- **验收**
  - 私密标签页进入小说模式后，`novel_books/novel_chapters` 行数不变；
  - 普通标签页行为不变；
  - 加载器使用的 store 与活动标签页的隐私模式一致。
- **测试**：T-06。
- **回滚**：参数化改动可逐步退回；不写库的分支可单独关闭。
- **状态（2026-10-21）**：已按 `:memory:` SQLite 方案实施（不改 `NovelLibraryService` 内部），
  新增 `NovelPrivacyTests`；**未构建/未运行**。详见 `PHASE_B_IMPLEMENTATION_PLAN.md` §15。
- **验收审查（2026-10-21）**：F-01（私密打开到普通标签，S2）等 8 项发现。
- **C1 修复（2026-10-21）**：F-01、F-02 已实现并补路由/代次/触发/store 轮换测试；F-03~F-08 未修；
  **未构建/未运行**。详见 `PHASE_B_ACCEPTANCE_REVIEW.md` 与 plan §17。

### B3：标签页关闭清理点

- **对应**：R-03、R-20（最小部分）。
- **范围**（只做关闭，不重排状态所有权）
  1. `TabManager` 增加 `onWillCloseTab` 回调（在 `destroyWebView` 之前调用）。
  2. coordinator 实现：取消该 tab 的 XHR、删除 `userScriptTabStates[tabId]`、删除该 tab 的菜单命令。
  3. 任务闭包对 `webView` 改为弱引用（或每步检查 tab 是否仍存在）。
  4. `AppEnvironment` 接线；`TranslationService` 可选地在关闭时 `records.removeValue(forKey:)`。
- **验收**
  - 关闭标签后，上述三张表不再包含该 tab id；
  - 一个慢速 GM XHR 在关闭标签后立即结束（`CancellationError` 路径）；
  - WebView 在关闭后可被释放（weak 引用为 nil）。
- **测试**：T-02。
- **回滚**：删除回调与三处清理。

### B4：WebView 池上限在创建时执行

- **对应**：R-04。
- **范围**：在 `load`/`openTab` 完成后调用 `enforceLiveWebViewCap`，并把刚创建的 tab 排除在受害者之外。
- **验收**：`openTab(activate: false)` 连续 20 次后 `liveWebViewCount <= maximumLiveWebViews`，
  且最新打开的 tab 仍有 WebView。
- **测试**：T-04。
- **回滚**：移除调用点。

### B5：异步动作校验活动标签

- **对应**：R-05。
- **范围**：`activateReaderMode`、`toggleAdBlock` 捕获 `tabId` + `navigationSerial`，await 后校验；
  顺带检查 `saveOfflinePage`、`startPageTranslation` 是否也需要（后者已有 generation）。
- **验收**：在提取/编译期间切换标签，旧结果不显示在新标签上，旧标签不被错误重载。
- **测试**：T-03（可用一个延迟的本地页面模拟阅读提取）。
- **回滚**：逐个 guard 独立。

### B6：小而独立的数据正确性修复

- **对应**：R-06、R-07。
- **范围**：启动时读取最近关闭（或停止写入）；把 element-hide 重置从 `clearAllBrowsingData` 移出。
- **验收**：重启后最近关闭可用（若选择读取）；只清缓存后手动隐藏规则仍在。
- **测试**：T-05、T-07。
- **回滚**：两个改动互不依赖。

### B7：私密标签页禁用远程图标候选

- **对应**：R-16 的隐私部分。
- **范围**：`SiteIconView` 增加“是否允许远程候选”开关；`TabsOverviewView`、`BrowserSidebarView`、
  `OmniboxSuggestionListView` 对私密标签页传 false，只使用显式/本地图标或首字母占位。
- **验收**：私密模式下打开总览/侧栏，抓包中没有标签页 host 的第三方图标请求；普通模式行为不变。
- **测试**：用 `URLProtocol` 桩记录请求，断言私密路径为空。
- **回滚**：默认值恢复为允许。

### 阶段 B 的完成标准

- 所有 S2 已确认缺陷要么修复，要么在登记册中写明“不修”的理由与剩余风险。
- CI 的 `test` job 通过；新增测试全部包含在 `VelaTests`。
- 每个改动都有独立 diff、验收记录、回滚说明。
- 更新 `RISK_REGISTER.md` 的状态列（新增“状态”列或标注）。

---

## 2. 阶段 C：模块职责与状态治理

前置：阶段 B 已完成，R-03/R-05 的清理点已存在。

### C1：状态所有权收敛（最小范围）

- **对应**：R-20。
- **做什么**
  1. 明确 `tab.url` 的写入者：保留 `TabManager.load`（用户意图）与 coordinator 的
     `didCommit/didFinish`（事实）；shell 的 `goHome/returnToPage` 改为调用 `TabManager` 的方法，
     不直接写 `url/isHome/loadState`。
  2. 阅读模式状态从 shell 移到“窗口级阅读会话”对象，或至少把所有异步回写加上标签校验（B5 已完成）。
  3. 进度条观察一个窄模型，不写 `tab.estimatedProgress`（与 D6 合并）。
- **不做**：不引入全局状态容器、不把所有状态改成单向数据流、不重写 `BrowserTabState`。
- **验收**：`grep` 显示 `tab.url =` 只出现在 coordinator 与 `TabManager`；shell 不再直接写标签的页面状态。
- **回滚**：方法级改动，可逐个恢复。

### C2：依赖收窄

- **对应**：R-19。
- **做什么**
  1. 删除 coordinator 中未被调用的 3 个协作者（bookmarks/searchHistory/sessionRepository），除非在 C1 中真正使用。
  2. 新增 Feature 时使用窄依赖（初始化参数或自定义 `EnvironmentKey`）；不再往 `AppEnvironment` 加转发属性。
  3. 评估把 `Core` 明确分为 `Models/Logic/Runtime` 三个子目录（只移动文件，不改类型）。
- **验收**：`AppEnvironment` 的转发属性数量不增加；coordinator 构造参数减少 3 个。
- **回滚**：纯删除/移动，易回滚。

### C3：导航动作与私密路由去重

- **对应**：R-21。
- **做什么**：抽一个 `BrowserActions`（值类型 + 方法）承载 reload/back/home/find/private 路由；
  菜单、工具栏、硬件命令、总览、侧栏都调用它。私密路由只保留 `TabManager` 中的解析。
- **验收**：新增一个入口不需要复制分支；现有行为测试全绿。
- **注意**：这是重构中最容易引入回归的一项，应放在 B/C 之后、有测试保护时做。

### C4：死代码与文档清理

- **对应**：R-22。
- **做什么**：删除 `AddressBarView.swift`、`BrowserTabMutationResult`、`SyncProviderId`（或注明计划）、
  `clearTabChain`（或接入关闭清理）；修正指向不存在类型的注释；更新 `ARCHITECTURE.md`/`PORTING.md`
  的数字与分层描述；删除 0 字节任务文件或补内容。
- **验收**：全仓库检索这些符号为 0；文档数字与 `find/wc` 一致。
- **回滚**：删除前用 `git revert` 单提交恢复。

### 阶段 C 的完成标准

- 每个模块至少有“负责/不负责/拥有状态”的一段文档（可直接补进 `ARCHITECTURE.md`）。
- 没有新增循环依赖；`AppEnvironment` 不再扩张。
- 关闭标签的生命周期契约在代码与测试中可见。

---

## 3. 阶段 D：性能与体验（先测量，后优化）

### D1：建立基线（必须先做）

- **对应**：R-25。
- **做什么**
  1. 在关键路径加 `OSSignposter`（iOS 15+）或 `os_signpost`：
     `adblock.compile`、`history.recordVisit`、`preview.capture`、`offline.save/open`、
     `scripts.attach`、`navigation.policy`、`didCommit`、`didFinish`。
  2. 用 CI 构建 Debug/Release IPA，在真机上用 Instruments（Time Profiler、Hangs、Allocations、
     VM Tracker、SwiftUI）采集。
  3. 记录基线表（模板见 §5）。
- **验收**：得到至少一轮可重复的启动/导航/切换/翻译/过滤数据；没有数据就不进入 D2。
- **回滚**：signpost 是纯增量，可保留。

### D2：广告规则编译移出主线程并合并

- **对应**：R-10。
- **依赖**：D1 显示编译确实是热点（或订阅足够大）。
- **做什么**：`AdBlockRuleCompiler.compile` 标 `nonisolated`；解析/编码在 `Task.detached`；
  `refreshAdBlockRules` 单飞 + 合并；订阅下载加大小/状态码限制。
- **验收**：编译期间主线程无 >100ms 的 hang（以 Hangs 工具为准）；规则结果与改前逐条一致
  （现有 `AdBlockContentRuleCompilationTests` 保证）；开关快速切换只产生一次最终编译。
- **回滚**：线程迁移与合并可分别回滚。

### D3：预览图编码移出主线程

- **对应**：R-11。**做什么**：`downscaled + jpegData` 放入 `Task.detached`；主 actor 只更新缓存。
- **验收**：`didFinish` 前后主线程无图像编码栈；总览卡片仍显示正确图片。
- **回滚**：移回主 actor。

### D4：离线归档 I/O 异步化

- **对应**：R-12。**做什么**：archive/preview/manifest 写入与读取放到后台；打开页面时先读后加载。
- **验收**：保存 20 MB 页面时 UI 不掉帧；打开离线页面时间不劣化。
- **回滚**：按写入/读取分别回滚。

### D5：用户脚本装配去重与快照缓存

- **对应**：R-09。**做什么**：去掉 `beginNavigation` 的重复装配；`UserScriptService` 缓存启用集合与 GM 值。
- **验收**：一次导航只装配一次；脚本安装/编辑后下一次导航立即生效（现有测试覆盖）。
- **回滚**：恢复第二次装配与直接查询。

### D6：进度更新与外壳重算解耦

- **对应**：R-14。**做什么**：进度节流到 ~10 Hz；或让 `OmniboxView`/进度条观察独立模型。
- **验收**：D1 的 SwiftUI 更新计数在加载期间显著下降；进度条仍平滑（视觉验收）。
- **回滚**：恢复逐次写入。

### D7：历史写入移出导航策略回调（仅在 D1 证明必要时）

- **对应**：R-13。**做什么**：串行后台队列写历史；保持“先 record、后 updateTitle”的顺序。
- **验收**：导航到 `didStartProvisional` 的时间不因历史量增长而增长；历史列表内容一致。
- **回滚**：恢复同步。

### D8：图标请求收敛与私密外发（建议提前到 B7）

- **对应**：R-16。
- **做什么**：私密标签页禁用远程图标候选（含 Google favicon 服务）；负缓存 + 并发上限。
- **验收**：私密模式下打开总览/侧栏，网络请求中不出现标签页 host 的第三方图标请求；
  普通模式总览首屏请求数有上限；失败站点不重复请求。
- **回滚**：缓存策略独立。

---

## 4. 阶段 E：系统回归与最终审查

1. 运行 CI 的 build + test；记录两个 job 的实际结果（不允许把未运行写成通过）。
2. 按 `RISK_REGISTER.md` §测试缺口补齐 T-01~T-07；UI 测试是否引入由用户决定。
3. 完整的跨模块场景验证（对应任务书 §10 的 15 项）：
   - 加载中切标签 / 关闭标签；
   - 翻译/阅读期间刷新、跳转、关闭页面；
   - 连续前进/后退/刷新/重定向；
   - 规则更新期间加载网页；
   - 多标签快速创建/切换/关闭；
   - 下载期间切页/进入后台；
   - 脚本失败/重复注入；
   - 内容进程终止恢复；
   - 网络错误/取消/存储失败；
   - 普通/无痕隔离；
   - 长时浏览内存；
   - 多功能同时启用的状态一致性；
   - 退出重启后的会话恢复。
4. 审查完整 `git diff`，逐项对照本路线图的验收条件。
5. 更新 `ARCHITECTURE.md`、`PORTING.md`、`RISK_REGISTER.md` 状态。
6. 输出最终报告：已验证项、剩余风险、环境限制未验证项。

---

## 5. 性能基线模板（D1 使用）

没有真机数据之前，本文件不填任何数字。测量记录至少包含：

| 字段 | 内容 |
|---|---|
| 设备 / 芯片 | 例如 iPhone 15 / A16 |
| 系统 | 例如 iOS 26.x |
| 构建 | Release，CI `workflow_dispatch` 产出的未签名 IPA，签名方式 |
| 测试网页 | 固定列表：一个轻页面、一个重广告页面、一个长文章、一个视频站、一个中文 SPA |
| 网络 | Wi-Fi / 5G，记录是否同一网络 |
| 重复次数 | 每项 ≥5 次，记录中位数与范围 |

指标与步骤：

| 指标 | 步骤 | 工具 |
|---|---|---|
| 冷启动 | 终止 App → 启动 → 到主页可交互 | signpost + Instruments App Launch |
| 首次页面加载 | 新建标签 → 输入固定 URL → `didFinish` | signpost（navigation 阶段） |
| 前进/后退/刷新 | 固定页面连续 20 次 | signpost + Hangs |
| 标签创建/切换/关闭 | 20 个标签循环 | Time Profiler + Allocations |
| 多标签内存 | 8 / 20 / 40 个标签 | VM Tracker |
| 广告过滤开/关 | 同一重广告页两种设置 | Time Profiler、`adblock.compile` signpost |
| 翻译耗时 | 固定长文章，Google/DeepL 各一次 | `TranslationService` signpost |
| 阅读/小说提取 | 固定文章/章节 | signpost |
| 长时内存 | 浏览 30 分钟后 | VM Tracker |
| 主线程 hang | 全流程 | Instruments Hangs（>100ms） |
| 崩溃 | 全流程 | B0 的崩溃记录（若批准） |

记录模板（复制到实际测量时）：

```
日期：
提交：
设备 / 系统 / 构建：
测试页面：
项目：
  运行 1 / 2 / 3 / 4 / 5：
  中位数：
  改前 / 改后：
  附：trace 文件路径
```

---

## 6. 建议的最小改动顺序

如果只批准一小步，按这个顺序做：

1. **B1**（私密 store）——用户可直接感知，改动小，测试明确。
2. **B3**（关闭清理点）——一次结构改动解决三类资源问题。
3. **B5**（异步标签校验）——两个 guard，风险低。
4. **B4**（池上限）——一行调用点 + 测试。
5. **B2**（小说隐私）——需要产品决策（私密模式是否入书架）。
6. **B7**（私密图标外发）——隐私修复，改动极小。
7. **B6**（最近关闭 / element-hide）——独立的小修。
8. **D1**（基线）——在动任何性能代码之前。
9. **B0**（崩溃采集）——若希望解决 R-24，建议与 1–3 并行批准。

每一步都应是一个独立提交（或一小组提交），附验收记录。

---

## 7. 明确不做的事

- 不引入全局事件总线；只加一个标签页关闭回调。
- 不重写 `TabManager`、`BrowserWebCoordinator` 或 `BrowserTabState`。
- 不为了“省内存”而在后台批量关标签、频繁重建 WebView、清空缓存或关闭现有功能。
- 不引入第三方浏览器内核（iOS 也不允许）。
- 不新增 AI 总结、工作台、重型信息管理或任何未获批准的新功能。
- 不在没有测量数据时宣称“提升 X%”。
- 不把“未运行的测试”写成通过。

---

## 8. 阶段门禁

阶段 A 到此结束。**没有修改任何应用源码**；本目录新增的四个文档是唯一产物：

- `ARCHITECTURE_AUDIT.md`
- `DEPENDENCY_MAP.md`
- `RISK_REGISTER.md`
- `OPTIMIZATION_ROADMAP.md`

等待用户审阅。批准后，阶段 B 从 B1 开始；每次只做一组，完成后提交阶段报告并再次等待批准。
