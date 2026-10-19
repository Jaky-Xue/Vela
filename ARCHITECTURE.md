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
- `App/BrowserShellView.swift`：外壳状态、层级与动作接线；独立控件
  （查找栏、权限提示、分享面板、边缘返回手势、按钮反馈）各自成文件。
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

## 菜单面板

`Core/Models/MenuModels.swift` 定义 `VelaMenuAction`、`MenuShortcut`、
`MenuTile` 和 `MenuLayout`。布局以原始字符串保存在偏好文档里（顺序、隐藏项、
快捷方式），`MenuPanelView` 只负责画传给它的 tiles。设置 ▸ 菜单面板 负责编辑。

## 验证

本机没有 Swift 工具链。可编译性由 `.github/workflows/build-ios.yml` 在 macOS
runner 上验证；单元测试是独立 job。提交前先跑仓库里的结构性检查（大括号/字符串
平衡），再推送，阅读两个 job 的结果。
