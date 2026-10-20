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
