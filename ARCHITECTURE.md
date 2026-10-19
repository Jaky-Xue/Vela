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

## 验证

本机没有 Swift 工具链。可编译性由 `.github/workflows/build-ios.yml` 在 macOS
runner 上验证；单元测试是独立 job。提交前先跑仓库里的结构性检查（大括号/字符串
平衡），再推送，阅读两个 job 的结果。
