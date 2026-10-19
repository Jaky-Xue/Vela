# Vela 架构

这份文档说明代码放在哪里、为什么放在那里，以及以后把内核（非 WebKit 引擎、
WebRTC 控制）接进来时应该从哪一层动手。

## 分层

依赖方向只有一个：**App → Features/Services → Core/Data → UI**（界面反过来只依赖
Core 的值类型）。没有跨层回调，也没有全局单例，除了 `BrowserDatabase.shared`
这一个数据库连接入口。

| 目录 | 职责 | 不应该出现的东西 |
|---|---|---|
| `Vela/App/` | 应用入口、组合根、浏览器外壳 | 业务规则、SQL、页面脚本 |
| `Vela/Core/Models/` | 可持久化/可传输的值类型 | SwiftUI、WebKit、数据库 |
| `Vela/Core/<能力>/` | 纯逻辑：正文提取、小说提取、广告规则、钥匙串、内核协议 | 视图、单例状态 |
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
- `App/BrowserShellView.swift`：外壳状态、层级与动作接线；独立控件
  （查找栏、权限提示、分享面板、边缘返回手势、按钮反馈）各自成文件。
- `Features/Settings/`：设置入口和每个子页一个文件。

新增功能时，先判断它属于哪一层，再决定文件；不要把新状态塞进
`BrowserShellView`，除非它确实是"外壳当前显示哪一层"。

## 内核接口

`Core/Kernel/BrowserKernel.swift` 是浏览器与渲染引擎之间的接缝。

```swift
@MainActor
protocol BrowserKernel {
    var descriptor: BrowserKernelDescriptor { get }
    func makeWebView(for:configuration:) -> WKWebView
    func prepare(_:for:)            // 默认空实现
}
```

- 今天只有一个内核：`WebKitKernel`。它返回普通的 `WKWebView`，不额外安装任何
  东西，因为浏览器自己的桥（历史、滚动、元素选择、用户脚本）由
  `BrowserWebCoordinator` 装配。
- `BrowserKernelRegistry` 在 `AppEnvironment` 里构造，活动内核被传给
  `BrowserWebCoordinator`；`TabManager.ensureWebView` 通过
  `BrowserWebViewConfigurationProviding.makeWebView` 取得内容视图。
- 关于页的"渲染引擎 / 内核能力"直接读这个描述符，所以能力是**声明**出来的，
  不是 UI 里硬编码的承诺。

### 接入一个新内核

1. 实现 `BrowserKernel`：`descriptor` 里写清楚引擎和 `capabilities`；
   `makeWebView` 返回该引擎的内容视图；`prepare` 里安装自己的
   `WKScriptMessageHandler`、媒体桥或诊断钩子。
2. 在 `AppEnvironment` 构造 `BrowserKernelRegistry` 之后、创建
   `BrowserWebCoordinator` 之前注册它，并 `activate(id:)`。
3. 如果内核带来 WebRTC 控制，在能力里加上 `.webRTCControl`。外壳和设置只读
   能力位，不需要为每个内核写分支。
4. 非 WebKit 内核需要先把内容视图从 `WKWebView` 抽象出去（当前接口刻意返回
   `WKWebView`，是为了让 WebKit 子类/加固层今天就能接入）。这一步应该只改
   `BrowserWebViewConfigurationProviding` 与 `TabManager` 的 web view 池，
   不应改 `BrowserTabState`、会话持久化或任何 Feature。

## 扩展点

- **页面脚本**：`WebPageScripts.Handler` 增加一个消息名，并在
  `BrowserWebCoordinator.handle(message:from:)` 里加分支。脚本本身按
  `document-start` / `document-end` 注入。
- **用户脚本**：`UserScriptInjector` 只做包装，不处理业务。
- **广告过滤**：`AdBlockEngine` 产出 `WKContentRuleList`；订阅文本在磁盘，
  元数据在数据库。
- **新持久化**：在 `BrowserSchema.creationStatements` 里加
  `CREATE TABLE IF NOT EXISTS`，然后 bump `velaSchemaVersion`。新表会自动出现在
  老安装的下一次打开中，不需要单独的迁移步骤。
- **新设置**：`BrowserPreferences` 里只加 **Optional** 字段，并补
  `BrowserPreferences.init` 的默认值。整个偏好文档是整体解码的，非可选新字段会
  让老安装的文档解码失败、设置全部重置。

## WebRTC 防泄露

`Core/Privacy/WebRTCGuard.swift` 生成一段 document-start 脚本，注入每个 frame，
先于网页脚本安装。它做两件事：过滤带私有/环回/链路本地地址的 `host` 候选
（防泄露），或把每个 `RTCPeerConnection` 的 `iceTransportPolicy` 改为 `relay`
（仅中继）；完全禁用模式则替换构造器并拒绝采集 API。策略值在
`BrowserPreferences.webRTCProtection`，默认防泄露，在
设置 ▸ WebRTC 泄露防护 中修改。

这层与内核无关：换成自有内核时，仍可以用同样的脚本注入点。

## 菜单面板

`Core/Models/MenuModels.swift` 定义 `VelaMenuAction`、`MenuShortcut`、
`MenuTile` 和 `MenuLayout`。布局以原始字符串保存在偏好文档里（顺序、隐藏项、
快捷方式），`MenuPanelView` 只负责画传给它的 tiles。设置 ▸ 菜单面板 负责编辑。

## Chromium 现状

iOS 没有可嵌入的 Blink：Chromium for iOS 的网页内容同样由 WKWebView 承载。
因此本工程不能通过加一个 Swift Package 就得到 Chromium 内核。`BrowserKernel`
是已经留好的接口；真正接入需要随包提供一个实现该协议的框架，并先把
`BrowserWebViewConfigurationProviding.makeWebView` 的返回类型从 `WKWebView`
抽象出去。设置 ▸ 渲染内核 会如实显示这一点，不会提供无法生效的开关。

## 下载

`Services/Downloads/DownloadService.swift` 是队列和状态机，
`Core/Downloads/SegmentedDownloadSession.swift` 负责一次文件传输：

- 队列：`activeGuids` 限制同时运行的任务数；等待中的任务以 `.pending`
  持久化，槽位释放后按创建时间启动。
- 分片：先 HEAD 探测 `Accept-Ranges`，再按 `segmentsPerDownload` 切成连续
  字节区间，各区间的 `URLSessionDownloadTask` 并发运行。完成的分片留在目标
  目录的隐藏 `.vela-<guid>-partN` 文件里，manifest 记录哪些分片已完成；
  暂停或重启后只补未完成的分片，再按顺序合并。
- 回退：URLSession 失败在首字节之前、或响应是登录/挑战 HTML 时，服务用
  `WKWebView.startDownload` 重试同一请求。明文 http 也在 URLSession 的 ATS
  之外，会走这条回退。WKDownload 的 resume data 继续作为它的续传方式。
- 分片/队列只对 http(s) 文件生效；blob/data URL 交给 WebKit。

## 界面形态与键盘

- `InterfaceLayoutMode`（跟随设备 / 手机 / iPad）保存在偏好文档。
  `BrowserShellView` 按 `UIDevice.idiom + horizontalSizeClass` 选择单栏或
  双栏；iPad 布局由 `Features/Pad/BrowserSidebarView`（标签侧边栏）和
  `BookmarksBarView`（书签栏）组成，底部工具栏只覆盖内容列。
- `BrowserCommands` 是 SwiftUI 的 `Commands` 菜单；按钮调用
  `BrowserCommandCenter.perform`，外壳在 `onAppear` 注册处理器。这样命令
  不需要持有外壳状态。
- `Info.plist` 不再声明 `UIRequiresFullScreen`，因此 Split View / Slide Over /
  Stage Manager 可以调整窗口；`自动` 布局会按宽度切换。多个 Stage Manager
  窗口仍共享同一份 `AppEnvironment` 会话。

## 验证

本机没有 Swift 工具链。可编译性由 `.github/workflows/build-ios.yml` 在 macOS
runner 上验证；单元测试是独立 job。提交前先跑仓库里的结构性检查（大括号/字符串
平衡），再推送，阅读两个 job 的结果。
