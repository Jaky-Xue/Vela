# Vela 架构

这份文档说明代码放在哪里、为什么放在那里，以及各层之间的边界。

## 分层

依赖方向只有一个：**App → Features/Services → Core/Data → UI**（界面反过来只依赖
Core 的值类型）。没有跨层回调，也没有全局单例，除了 `BrowserDatabase.shared`
这一个数据库连接入口。

| 目录 | 职责 | 不应该出现的东西 |
|---|---|---|
| `Vela/App/` | 应用入口、组合根、浏览器外壳 | 业务规则、SQL、页面脚本 |
| `Vela/Core/Models/` | 可持久化/可传输的值类型 | SwiftUI、WebKit、数据库 |
| `Vela/Core/<能力>/` | 纯逻辑：正文提取、小说提取、广告规则、钥匙串、下载分片 | 视图、单例状态 |
| `Vela/Data/` | SQLite 封装、表结构、Repository | UI、导航 |
| `Vela/Services/` | 编排：把 Core 与 Data 组合成有状态的领域服务 | List/View 布局 |
| `Vela/Features/` | 屏幕与面板 | SQL、Keychain、WKWebView 配置 |
| `Vela/UI/` | 设计令牌、共享组件、材质 | 业务状态 |

`AppEnvironment` 是唯一的组合根：所有长生命周期服务在这里构造一次，再通过
SwiftUI 环境注入。视图不 new 服务。

## 文件分工

一个文件只承担一类职责。已经拆分出来的部分：

- `UI/Theme.swift`：颜色令牌、配色目录、尺寸常量、环境值。
- `UI/BrowserSurfaces.swift`：卡片、列表、玻璃浮层三种表面处理。
- `UI/BrowserComponents.swift`：行、徽章、空状态、可折叠分组。
- `UI/SiteIconView.swift`：网站图标的级联加载与裁剪。
- `UI/ChromeBackdrop.swift`：决定工具栏墨色亮暗的亮度测量。
- `App/BrowserShellView.swift`：外壳入口与环境宿主；窗口的呈现、浮层、
  Chrome 中间态与测量都在 `App/Shell/ShellState.swift`，其余逻辑按职责分在
  `BrowserShellView+*.swift`。独立控件（查找栏、权限提示、分享面板、边缘
  返回手势、按钮反馈）各自成文件。
- `App/Shell/`：外壳状态机（见下节）。`BrowserSurface`、`ShellOverlay`、
  `BookshelfContext`、`MenuPresentation` 与 `ShellState` 都在这里。
- `Features/Settings/`：设置入口和每个子页一个文件。

新增功能时，先判断它属于哪一层，再决定文件；不要把新状态塞进
`BrowserShellView`，除非它确实是"外壳当前显示哪一层"。

## WebRTC 防泄露

`Core/Privacy/WebRTCGuard.swift` 生成一段 document-start 脚本，注入每个 frame，
先于网页脚本安装。它做两件事：过滤带私有/环回/链路本地地址的 `host` 候选
（防泄露），或把每个 `RTCPeerConnection` 的 `iceTransportPolicy` 改为 `relay`
（仅中继）；完全禁用模式则替换构造器并拒绝采集 API。策略值在
`BrowserPreferences.webRTCProtection`，默认防泄露，在
设置 ▸ WebRTC 泄露防护 中修改。

这层只依赖页面脚本注入，与浏览器界面层解耦。

## 外壳状态机

`App/Shell/ShellState.swift` 是窗口级呈现与 Chrome 中间态的唯一来源。它用
`@Observable @MainActor` 持有：

- `surface: BrowserSurface` — 主表面：`home` / `page` / `novel(NovelSession)` /
  `error`。同一时刻只有一个主表面；小说阅读器是表面而不是选中的布尔值，因此
  「阅读器覆盖在错误页再覆盖在主页上」这种组合在类型上就写不出来。
- `overlays: Set<ShellOverlay>` — 覆盖在主表面之上、但不替换它的层：
  总览、菜单、书签、历史、下载、离线页面、设置、密码、书架、扫码、查找栏、
  分享、添加书签选择、站点能力。`ShellOverlay` 的 `id` 只取 `Kind`，关联值
  （设置目标页、`BookshelfContext`）是数据而不是身份，所以
  `binding(forKind:)` 可以在不知道载荷的情况下回答「这个 sheet 是否打开」。
- `pendingMenuPresentation` — 菜单唯一的一条延迟呈现请求。
- Chrome 的瞬时几何（隐藏、拖动、抬升）、键盘与安全区测量、窗口原点、
  边缘返回手势的在途值、滚动记账，以及一行式提示（小说/离线/地址/扫码）。
  逐帧写入的 `scrollTracker` 仍是引用盒，字段变化不会让整棵视图树失效。

视图通过 `BrowserShellView+State.swift` 的转发访问器读写它；呈现一律走
`present(_:)` / `dismiss(_:)` / `binding(forKind:)`，不再散落布尔量。
`OmniboxViewModel` 不属于这里：那是一个文本框的会话，不是窗口的呈现状态。

### 主表面与浮层的边界

`BrowserSurface` 回答「内容列显示什么」，`ShellOverlay` 回答「什么盖在上面」。
标签页切换只刷新表面的非小说半边（`syncBaseSurface`）；阅读器打开时，标签页
的变化不会替换表面，关闭阅读器时才回到当前标签页自己的状态。

### 菜单的延迟呈现（不可破坏）

菜单本身是一个 sheet，「添加书签」「书签」「设置」「书架」等是第二个 sheet。
在同一个 update 里既 dismiss 菜单又 present 目标，会和 UIKit 的呈现机制竞争；
早期版本正是因此让 添加书签 与 书签 偶尔表现为点不动或卡住。

现在的顺序是强制的：

1. `handleMenuAction` 只关闭菜单并调用 `shell.queueMenu(_:)`，绝不直接 present。
2. 菜单 sheet 绑定 `shell.menuBinding`，其 `onDismiss` 调用
   `shell.performPendingMenuPresentation()`。
3. 该方法在菜单完全消失后按请求 present 对应浮层；书架是唯一例外，它必须
   先由外壳捕获活动标签页的隐私模式与当前私密代次，再异步取得对应书库，
   因此通过 `onBookshelfRequested` 回到外壳的 `openBookshelf()`。

查找、进入小说、桌面版、刷新、无痕切换等非 sheet 动作仍可立即执行。

## 菜单面板

`Core/Models/MenuModels.swift` 定义 `VelaMenuAction`、`MenuShortcut`、
`MenuTile` 和 `MenuLayout`。布局以原始字符串保存在偏好文档里（顺序、隐藏项、
快捷方式），`MenuPanelView` 只负责画传给它的 tiles。设置 ▸ 菜单面板 负责编辑。

## 运动语言

`UI/BrowserMotion.swift` 是唯一的动画入口。它按职责给出曲线而不是让每个调用点
自己写 `.spring`：

| 入口 | 用在 |
|---|---|
| `chrome` | 命令栏、搜索页、查找栏的显隐 |
| `surface` | 主页 ↔ 网页、错误页、阅读器之下的页面替换 |
| `overview` | 标签总览自底部升起 |
| `novelEnter` | 小说阅读器进入（命令栏同曲线退场） |
| `backdrop` | 背景图片 / 环境场 / 材质切换 |
| `sheet` | 二级 sheet 内部状态变化 |
| `notice` | 一行提示、扫码层 |
| `tileDrag` | 磁贴拖动（Reduce Motion 时为 nil） |
| `sidebar` / `settle` / `press` / `hint` | 侧栏、手势回弹、按压、拖动提示 |

所有公开入口都接收 `accessibilityReduceMotion`：开启时返回 0.12 秒的短淡出，
拖动类入口返回 `nil`，调用点不需要自己判断。大面积用较慢曲线（`surface`
约 0.46），小反馈用较快曲线（`crisp` 约 0.26），同一时刻只突出一个主角。

## 小说目录与翻页

`novel_toc_entries` / `novel_toc_sources` 保存一本书的目录和目录页地址。进入小说
模式时章节页给出的目录链接会写入来源；阅读页按需用 `NovelTOCLoader` 离屏加载
目录页，`NovelModeService.tocExtractionScript` 选取章节链接并缓存。下一页/上一页
在章节本身没有链接时回退到目录邻居。翻页方式（滚动 / 整屏翻页）保存在
`BrowserPreferences.novelPageMode`，只切换 web view 的分页属性，不重载章节。

## 窗口与共享服务

`AppServices` 是进程级的组合根：数据库、设置、书签、历史、下载、小说、密码、
离线页面和命令中心都在这里构造一次，并启动一次（`bootOnce`）。`AppEnvironment`
是每个窗口的组合根：它持有该窗口的 `TabManager`、`BrowserWebCoordinator`、
`WebPageOverlays`、`NavigationLog` 和 `TranslationService`，并从 `AppServices`
转发共享服务。`VelaApp` 的 `WindowGroup` 为每个场景建立一个
`WindowEnvironmentStore`，因此 Stage Manager 里的两个窗口各有自己的标签会话；
`tab_sessions.window_id` 是这条边界的持久化形式。第一个窗口使用 `window-main`，
启动时只有它的会话会被恢复，其余窗口 id 在下次启动时清理。

## 用户脚本

`UserScriptParser` 解析 Tampermonkey 元数据块，`UserScriptMatcher` 分别处理
`@match`（Chrome 匹配模式）和 `@include`（通配/正则）。`UserScriptService`
负责安装、编辑和更新：安装时下载 `@require` 与 `@resource`，把源码、声明和
资源一起存入 `user_scripts`；更新按数字版本比较，并保留脚本 id、启用状态、
GM 值存储与创建时间。`UserScriptInjector` 把依赖、资源和 API 一起注入页面；
`GM_xmlhttpRequest`、`GM_fetch`、`GM_cookie`、`GM_download`、`GM_openInTab`
和 `GM_getTab/saveTab/getTabs` 通过消息桥回到
`BrowserWebCoordinator`，再用 `__velaUserScriptBridge.resolve` 把结果送回页面。
`GM_registerMenuCommand` 注册的命令显示在菜单面板的“用户脚本”区。

## 网页翻译

`WebPageScripts.translationSupportScript` 按“叶子块元素”（段落、列表项、标题、
表格单元等）提取翻译单元，单元带着 `innerHTML` 走请求，所以链接、加粗和其它
行内标记在译文里保留；写回时先按元素结构逐文本节点替换，结构不一致才回退到整块
`innerHTML`。原文记录在文本节点上，`显示原文` 是原地恢复，不重新加载文档。
`TranslationService` 负责识别语言（NaturalLanguage）、按服务商批量上限发送、
处理 Google 返回的包装元素、以及翻译 MutationObserver 报告的新增内容。
Google / DeepL / OpenAI 兼容接口、目标语言、自动提示开关和按网站的
总是/不再翻译规则保存在独立的 `TranslationSettings` 文档中。界面是页面顶部的
`TranslationBar`，而不是弹窗：检测到外语页面时出现，翻译中显示进度，翻译后可
显示原文或修改规则。

## 离线页面

保存时向 WebKit 要一份 web archive（`createWebArchiveData`），连同预览图和 JSON
清单写入 `Application Support/Vela/OfflinePages/<id>/`，元数据写入
`offline_pages`。打开时把归档交给新标签页的
`WKWebView.load(data:mimeType:"application/x-webarchive")`；标签页会标记
`isOfflinePage`，避免导航代理把归档的合成文档地址写回真实网址。

## 后台下载

分片传输使用带唯一标识的 `URLSessionConfiguration.background`，任务上写入
`taskDescription` 以便换进程后仍能对应到字节段；标识随 manifest 落盘。
App 因后台事件被唤起时，`VelaAppDelegate` 把
`handleEventsForBackgroundURLSession` 交给 `BackgroundDownloadRegistry`，
`DownloadService` 在启动时安装重连器并重连遗留任务。进入后台时队列里待开始的任务
也会立即启动，交给同一套后台会话。WebKit 回退通道没有 URLSession，仍不支持后台续传。

## 标签页滚动位置

回收 web view 时把 `contentOffset.y + contentInset.top` 归一化后写入标签页并置
`pendingScrollRestore`；会话恢复的标签页同样带这个标记。`didFinish` 消费一次标记，
用 `WebPageScripts.scrollRestoreScript` 在布局稳定后把文档滚回原位置。

## 验证

本机没有 Swift 工具链。可编译性由 `.github/workflows/build-ios.yml` 在 macOS
runner 上验证；单元测试是独立 job。提交前先跑仓库里的结构性检查（大括号/字符串
平衡），再推送，阅读两个 job 的结果。

## 4.0 (62) 实现状态（2026-11-16）

当前源码版本为 4.0 / Build 62，schema 14，最低 iOS 17；工程最低 Xcode 16，本轮 CI 请求 macos-26。详见 PROJECT_REVIEW.md 和 RELEASE_4.0.md。
下载仍由进程 DownloadService 调度，任务与确认提示记录窗口归属；私密下载还记录会话 UUID。每窗口派生自身私密列表，结束会话仅撤销本窗口本会话，启动时清理旧私密下载。
数据库建表/补字段/版本更新在同一事务内；迁移失败回滚、未来版本拒绝，不重置原数据。普通/私密标签持久化偏好保留现有行为，不声称私密标签从不落盘。
NavigationLog 默认关闭，仅记录调用方事件；recordHang 不提供实际检测，没有 MetricKit/MainThreadHangMonitor 或系统崩溃采集。无自动上传。
既有 CI 的 build 保持 needs: test，iPhone 与 iPad 都成功才打包。工作分支构建，禁止把历史基线或静态检查当作本轮测试通过。以最终 ReleaseReport 为实际结果；UI/真机/Instruments 未验证。
