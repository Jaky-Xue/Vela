# Vela 4.0 (62) 工程审查

## 基线与边界
2026-11-16，原始目录 G:\ClaudeWork\VelaBrowserIOS；main；提交 1abb79d86cc40d6b18827c170f3153c0699f0b72；Git 工作区干净，未发现用户未提交修改。使用忽略行尾空白的 diff 核对改动。
原始完整备份（含 .git）：G:\VelaBrowserIOS-original-20261116-114503.zip。仅修改独立副本，原始项目与 Git 历史保留。
本机 Windows，没有 Xcode/Swift；gh 已登录 Jaky-Xue，origin=https://github.com/Jaky-Xue/Vela.git。G 盘初始剩余约 116 GiB。
原始 CI 基线：run 43794964328，head=1abb79d，iPhone/iPad/Build Vela 均 success。此历史结果不代表新代码通过。

## 结构、职责和依赖
- Vela/App：VelaApp 创建进程 AppServices，各 BrowserWindowRoot 创建 AppEnvironment。
- AppServices：进程数据库、设置、书签、历史、下载、规则、密码、小说与命令入口。
- AppEnvironment：windowId、TabManager、WebCoordinator、窗口弹层、私密阅读器代际。
- Vela/Core：模型、标签 LRU 和 WebView 上限、命令、分片下载与后台会话桥。
- Vela/Data：SQLite 串行递归锁、事务、BrowserSchema、Repository SQL。
- Vela/Services：业务服务、WebKit 导航与脚本、下载调度、Keychain 密码、小说、离线保存。
- Vela/Features 与 UI：SwiftUI 页面、主页、共享图标、主题与动画。
- VelaTests：真实 WebKit + LocalHTTPServer 的 NavigationTestSupport、单元和隐私测试。

数据流：SwiftUI → 窗口环境/Service → Repository → SQLite；网络回调回到 MainActor 后更新观察状态。
状态以 @Observable 管理。保留 ShellState.scrollTracker 引用盒，未引入逐帧发布状态。保留 BrowserMotion、WebView LRU 与数量上限。
页面生命周期由 TabManager 和 BrowserWebCoordinator 协同；关闭标签触发清理脚本请求与页面状态，进程终止和内存压力走现有恢复/回收路径。

## 生命周期和隔离
普通标签恢复语义保持原样；不擅自改变现有私密标签持久化策略。私密 WebKit store 按窗口非持久化；私密小说在内存数据库。私密标签元数据仍可能根据原设置持久化，不宣称所有私密元数据永不落盘。
新增下载 window_id/private_session_id（模型为可选以兼容旧 Codable）；私密会话以随机 UUID 标识。每窗口列表按归属派生，不再让共享 reload 的 privacyMode 替换其他窗口视图。确认弹窗按窗口保存，控制操作校验归属。
进程启动仅清理已失效私密下载；打开第二个普通窗口不会全局清理私密任务。后台重连校验数据库任务与会话存活，未归属旧私密任务不恢复。
background 回调同步锁定 → beginEndPrivateSession → 关闭阅读器/书架/标签 → 当前会话下载清理 → 捕获旧 store → 后台 lease 内异步清理旧 store；随后仅普通队列参与后台启动。旧回调不得重建私密记录、manifest 或输出文件。

## 数据库和下载
SQLite 保留 WAL、NORMAL 同步、外键、递归锁、索引。schema 13 → 14；整个建表、字段补齐、索引与版本更新在 BEGIN IMMEDIATE 事务内。PRAGMA/ALTER 失败向上传递并回滚。未来版本和无效版本拒绝且不重置用户数据库。
DownloadRepository 使用 ON CONFLICT UPDATE 保留 resume_data；避免 INSERT OR REPLACE 丢失恢复 blob。清理不使用 300 条列表上限；严格按窗口/会话查询和删除。
普通 URLSession 后台能力与分片策略保留。manifest 携带归属，重连以数据库身份为准。网络 cookie/referer 富化、安全策略与并发限制保留。WebKit 回退和脚本保存都携带相同归属。
下载分片合并写临时文件，发布与取消共享短锁，避免会话清理后重新发布旧文件。大型文件合并仍在后台，不将 WebKit 对象送到 detached task。

## 错误与诊断
迁移失败抛错并显示原有 startupError。新增下载 lastError 和列表错误文本；enqueue 必须先写成功。标签保存记录 sessionSaveError。书签服务已有 lastError，离线保存与脚本安装已有失败返回；未机械移除非关键清理/可选解析的 try?。
NavigationLog 是默认关闭的内存事件记录器；recordHang 仅记录调用方提供的事件，未安装 MetricKit、MainThreadHangMonitor、自定义 signal handler 或完整崩溃收集。本次不新增诊断采集或自动上传。URL query/fragment 使用原有脱敏；任意错误消息仍需在未来启用采集前额外审查。

## 发现问题与优先级
P0：私密下载全局清理、共享列表模式切换、共享确认弹窗、启动普通窗口误清理其他窗口、异步清理前后台队列重启。已针对这些路径改码并补测试。
P1：迁移错误吞掉/非原子版本更新、恢复数据被 upsert 清空、无痕主页未传递图标策略、命令按注册顺序。已改码并补测试。
P2：大型 Swift 文件多职责仍在；不为减少行数改 actor/所有权。错误处理的完整 UI 闭环与大查询主线程成本需后续逐场景验证。

## 验证和剩余风险
本机不能运行 XCTest 或 Instruments。完整 iPhone/iPad 模拟器测试和 Release 构建通过既有 CI 执行，最终以发布报告实际结果为准。真机 Stage Manager、后台杀进程恢复、磁盘耗尽、后台 expiration、密码库和 UI 全流程仍需验收；不提供未经测量的性能数字。
保留原有 WindowSessionTests、TabCloseCleanupTests、NovelPrivacyTests 等，新增迁移、下载仓库、下载隔离、私密生命周期、命令与无痕主页测试；NavigationTestSupport 配置生产等价下载归属。
以下是全体 Swift 文件的清单与 try? 分布，属于结构扫描；重点代码已人工阅读，不将清单扫描描述为所有功能已逐行审计或运行验证。

| 文件 | 行数 | try? 数量 |
| --- | ---: | ---: |
| `Vela/App/AppEnvironment.swift` | 543 | 8 |
| `Vela/App/AppServices.swift` | 206 | 2 |
| `Vela/App/BackgroundPictureBackdrop.swift` | 46 | 0 |
| `Vela/App/BrowserCommands.swift` | 100 | 0 |
| `Vela/App/BrowserNavigationActions.swift` | 60 | 0 |
| `Vela/App/BrowserShellView+Actions.swift` | 359 | 1 |
| `Vela/App/BrowserShellView+AddressBar.swift` | 208 | 1 |
| `Vela/App/BrowserShellView+Chrome.swift` | 528 | 0 |
| `Vela/App/BrowserShellView+ChromeBehavior.swift` | 70 | 0 |
| `Vela/App/BrowserShellView+Composition.swift` | 267 | 0 |
| `Vela/App/BrowserShellView+Content.swift` | 266 | 0 |
| `Vela/App/BrowserShellView+Gestures.swift` | 149 | 0 |
| `Vela/App/BrowserShellView+Novel.swift` | 213 | 1 |
| `Vela/App/BrowserShellView+Observers.swift` | 199 | 0 |
| `Vela/App/BrowserShellView+OfflinePages.swift` | 71 | 0 |
| `Vela/App/BrowserShellView+PadLayout.swift` | 389 | 0 |
| `Vela/App/BrowserShellView+Presentations.swift` | 281 | 0 |
| `Vela/App/BrowserShellView+TabOverview.swift` | 76 | 0 |
| `Vela/App/BrowserShellView+WindowMetrics.swift` | 53 | 0 |
| `Vela/App/BrowserShellView.swift` | 139 | 0 |
| `Vela/App/EdgeSwipeBackIndicator.swift` | 45 | 0 |
| `Vela/App/NovelBrowserRouting.swift` | 59 | 0 |
| `Vela/App/NovelSession.swift` | 67 | 0 |
| `Vela/App/Shell/BrowserShellView+State.swift` | 308 | 0 |
| `Vela/App/Shell/BrowserSurface.swift` | 43 | 0 |
| `Vela/App/Shell/ShellOverlay.swift` | 156 | 0 |
| `Vela/App/Shell/ShellState.swift` | 300 | 0 |
| `Vela/App/ShellScrollTracker.swift` | 109 | 0 |
| `Vela/App/ShellWindowMetrics.swift` | 93 | 0 |
| `Vela/App/VelaApp.swift` | 320 | 1 |
| `Vela/App/VelaAppDelegate.swift` | 28 | 0 |
| `Vela/Core/AdBlock/AdBlockBuiltInRules.swift` | 162 | 0 |
| `Vela/Core/AdBlock/AdBlockRuleCompiler.swift` | 872 | 1 |
| `Vela/Core/AdBlock/BoundedHTTPData.swift` | 21 | 0 |
| `Vela/Core/AdBlock/CSSSelectorValidation.swift` | 66 | 0 |
| `Vela/Core/AdBlock/FilterIncludeResolver.swift` | 48 | 0 |
| `Vela/Core/AdBlock/FilterSubscription.swift` | 47 | 0 |
| `Vela/Core/Commands/BrowserCommandCenter.swift` | 51 | 0 |
| `Vela/Core/Downloads/BackgroundDownloadRegistry.swift` | 70 | 0 |
| `Vela/Core/Downloads/SegmentedDownloadSession.swift` | 821 | 20 |
| `Vela/Core/Models/BookmarkModels.swift` | 175 | 0 |
| `Vela/Core/Models/BrowserModels.swift` | 668 | 0 |
| `Vela/Core/Models/ContentBlockerModels.swift` | 39 | 0 |
| `Vela/Core/Models/DownloadModels.swift` | 239 | 0 |
| `Vela/Core/Models/ElementHideModels.swift` | 60 | 0 |
| `Vela/Core/Models/HistoryModels.swift` | 267 | 0 |
| `Vela/Core/Models/HomeFavoriteModels.swift` | 106 | 0 |
| `Vela/Core/Models/InterfaceModels.swift` | 81 | 0 |
| `Vela/Core/Models/MenuModels.swift` | 327 | 0 |
| `Vela/Core/Models/NovelModels.swift` | 186 | 0 |
| `Vela/Core/Models/OfflineModels.swift` | 153 | 0 |
| `Vela/Core/Models/PasswordModels.swift` | 91 | 0 |
| `Vela/Core/Models/PermissionModels.swift` | 73 | 0 |
| `Vela/Core/Models/PrivacyModels.swift` | 66 | 0 |
| `Vela/Core/Models/SearchEngineCatalog.swift` | 465 | 0 |
| `Vela/Core/Models/SiteDisplayModels.swift` | 144 | 0 |
| `Vela/Core/Models/TabModels.swift` | 700 | 0 |
| `Vela/Core/Models/ToolbarModels.swift` | 177 | 0 |
| `Vela/Core/Models/UserAgentModels.swift` | 422 | 0 |
| `Vela/Core/Models/UserScriptModels.swift` | 590 | 0 |
| `Vela/Core/Novel/NovelChapterLoader.swift` | 173 | 2 |
| `Vela/Core/Novel/NovelLoaderSupport.swift` | 54 | 0 |
| `Vela/Core/Novel/NovelModeService.swift` | 548 | 2 |
| `Vela/Core/Novel/NovelTOCLoader.swift` | 157 | 2 |
| `Vela/Core/Novel/NovelURLRoute.swift` | 181 | 0 |
| `Vela/Core/Passwords/KeychainStore.swift` | 123 | 0 |
| `Vela/Core/Privacy/WebRTCGuard.swift` | 206 | 0 |
| `Vela/Core/Tabs/TabManager.swift` | 1214 | 6 |
| `Vela/Core/Tabs/TabPreviewStore.swift` | 198 | 10 |
| `Vela/Core/Transfer/DataExchange.swift` | 244 | 4 |
| `Vela/Core/UserScripts/UserScriptHTTP.swift` | 85 | 0 |
| `Vela/Core/UserScripts/UserScriptInjector.swift` | 1193 | 4 |
| `Vela/Core/UserScripts/UserScriptMatcher.swift` | 246 | 1 |
| `Vela/Core/UserScripts/UserScriptNativePolicy.swift` | 72 | 0 |
| `Vela/Core/UserScripts/UserScriptParser.swift` | 185 | 0 |
| `Vela/Core/UserScripts/UserScriptValueChanges.swift` | 11 | 0 |
| `Vela/Data/BrowserDatabase.swift` | 202 | 1 |
| `Vela/Data/BrowserSchema.swift` | 499 | 0 |
| `Vela/Data/Repositories/BookmarkRepository.swift` | 466 | 0 |
| `Vela/Data/Repositories/DownloadRepository.swift` | 225 | 1 |
| `Vela/Data/Repositories/HistoryRepository.swift` | 486 | 0 |
| `Vela/Data/Repositories/NovelRepository.swift` | 258 | 2 |
| `Vela/Data/Repositories/OfflinePageRepository.swift` | 139 | 0 |
| `Vela/Data/Repositories/SearchHistoryRepository.swift` | 177 | 0 |
| `Vela/Data/Repositories/TabSessionRepository.swift` | 224 | 0 |
| `Vela/Data/Repositories/UserScriptRepository.swift` | 353 | 4 |
| `Vela/Data/SQLite/SQLiteDatabase.swift` | 368 | 1 |
| `Vela/Features/Bookmarks/AddBookmarkChoiceSheet.swift` | 242 | 0 |
| `Vela/Features/Bookmarks/BookmarksView.swift` | 398 | 0 |
| `Vela/Features/Downloads/DownloadsView.swift` | 298 | 0 |
| `Vela/Features/History/HistoryView.swift` | 370 | 0 |
| `Vela/Features/Home/HomeFavoriteEditSheet.swift` | 105 | 0 |
| `Vela/Features/Home/HomeFavoriteTile.swift` | 51 | 0 |
| `Vela/Features/Home/NewTabHomeView.swift` | 814 | 1 |
| `Vela/Features/Novels/NovelBookshelfView.swift` | 214 | 0 |
| `Vela/Features/Novels/NovelReaderRuntime.swift` | 40 | 0 |
| `Vela/Features/Novels/NovelReaderView.swift` | 1062 | 0 |
| `Vela/Features/Novels/NovelTOCSheet.swift` | 82 | 0 |
| `Vela/Features/Offline/OfflinePagesView.swift` | 177 | 0 |
| `Vela/Features/Pad/BookmarksBarView.swift` | 210 | 0 |
| `Vela/Features/Pad/BrowserSidebarView.swift` | 419 | 1 |
| `Vela/Features/Passwords/PasswordVaultView.swift` | 671 | 0 |
| `Vela/Features/Settings/AboutView.swift` | 68 | 0 |
| `Vela/Features/Settings/AppearanceSettingsView.swift` | 591 | 0 |
| `Vela/Features/Settings/ContentBlockerSettingsView.swift` | 191 | 0 |
| `Vela/Features/Settings/DataTransferSettingsView.swift` | 193 | 3 |
| `Vela/Features/Settings/FilterSourcesSettingsView.swift` | 137 | 0 |
| `Vela/Features/Settings/GeneralSettingsView.swift` | 124 | 0 |
| `Vela/Features/Settings/MenuSettingsView.swift` | 294 | 0 |
| `Vela/Features/Settings/PendingScriptUpdateView.swift` | 107 | 0 |
| `Vela/Features/Settings/PrivateBrowsingSettingsView.swift` | 110 | 0 |
| `Vela/Features/Settings/ScriptWorldSettingsView.swift` | 29 | 0 |
| `Vela/Features/Settings/SearchEngineSettingsView.swift` | 203 | 0 |
| `Vela/Features/Settings/SettingsSubpages.swift` | 447 | 0 |
| `Vela/Features/Settings/SettingsView.swift` | 378 | 0 |
| `Vela/Features/Settings/ToolbarSettingsView.swift` | 170 | 0 |
| `Vela/Features/Settings/UserAgentSettingsView.swift` | 242 | 1 |
| `Vela/Features/Settings/UserScriptsView.swift` | 1015 | 2 |
| `Vela/Features/Settings/WebRTCProtectionSettingsView.swift` | 98 | 0 |
| `Vela/Features/Tabs/TabsOverviewView.swift` | 914 | 1 |
| `Vela/Features/Tools/QRScannerView.swift` | 293 | 1 |
| `Vela/Features/Web/ElementPickerViews.swift` | 139 | 0 |
| `Vela/Features/Web/PermissionPromptView.swift` | 72 | 0 |
| `Vela/Features/Web/SiteCapabilitiesView.swift` | 66 | 0 |
| `Vela/Features/Web/UserScriptInstallPromptView.swift` | 224 | 0 |
| `Vela/Features/Web/WebPageErrorView.swift` | 200 | 1 |
| `Vela/Services/Bookmarks/BookmarkService.swift` | 235 | 5 |
| `Vela/Services/Downloads/DownloadService.swift` | 1280 | 39 |
| `Vela/Services/History/HistoryService.swift` | 172 | 14 |
| `Vela/Services/Home/HomeFavoritesService.swift` | 235 | 2 |
| `Vela/Services/Novels/InMemoryNovelLibrary.swift` | 72 | 0 |
| `Vela/Services/Novels/NovelLibraryService.swift` | 294 | 7 |
| `Vela/Services/Offline/OfflinePageService.swift` | 282 | 11 |
| `Vela/Services/Passwords/PasswordVaultService.swift` | 381 | 2 |
| `Vela/Services/Permissions/PermissionAuditService.swift` | 73 | 2 |
| `Vela/Services/Privacy/ContentBlocker.swift` | 297 | 3 |
| `Vela/Services/Privacy/DeviceAuthentication.swift` | 68 | 0 |
| `Vela/Services/Search/SearchSuggestionClient.swift` | 334 | 2 |
| `Vela/Services/Settings/BackgroundImageStore.swift` | 120 | 4 |
| `Vela/Services/Settings/SettingsService.swift` | 544 | 3 |
| `Vela/Services/Transfer/DataTransferService.swift` | 125 | 0 |
| `Vela/Services/UserScripts/UserScriptService.swift` | 1067 | 5 |
| `Vela/Services/UserScripts/UserScriptVersionStore.swift` | 60 | 2 |
| `Vela/Services/Web/BrowserWebCoordinator+Navigation.swift` | 991 | 2 |
| `Vela/Services/Web/BrowserWebCoordinator+UIDelegate.swift` | 470 | 0 |
| `Vela/Services/Web/BrowserWebCoordinator+UserScripts.swift` | 770 | 18 |
| `Vela/Services/Web/BrowserWebCoordinator.swift` | 1137 | 3 |
| `Vela/Services/Web/EdgeSwipeBackBridge.swift` | 202 | 0 |
| `Vela/Services/Web/NavigationLog.swift` | 313 | 0 |
| `Vela/Services/Web/WebPageOverlays.swift` | 177 | 0 |
| `Vela/Services/Web/WebPageScripts+Fullscreen.swift` | 72 | 0 |
| `Vela/Services/Web/WebPageScripts+Interaction.swift` | 188 | 0 |
| `Vela/Services/Web/WebPageScripts+Media.swift` | 361 | 0 |
| `Vela/Services/Web/WebPageScripts+Permissions.swift` | 196 | 0 |
| `Vela/Services/Web/WebPageScripts+Zoom.swift` | 100 | 0 |
| `Vela/Services/Web/WebPageScripts.swift` | 759 | 3 |
| `Vela/Services/Web/WebViewHost.swift` | 554 | 1 |
| `Vela/UI/AddressBarView.swift` | 317 | 0 |
| `Vela/UI/AmbientBackground.swift` | 1154 | 0 |
| `Vela/UI/BrowserComponents.swift` | 178 | 0 |
| `Vela/UI/BrowserMotion.swift` | 147 | 0 |
| `Vela/UI/BrowserSurfaceAccessibility.swift` | 18 | 0 |
| `Vela/UI/BrowserSurfaces.swift` | 275 | 0 |
| `Vela/UI/BrowserVisualStyle.swift` | 59 | 0 |
| `Vela/UI/ChromeBackdrop.swift` | 96 | 0 |
| `Vela/UI/ChromeButtonStyle.swift` | 26 | 0 |
| `Vela/UI/ColorHex.swift` | 57 | 0 |
| `Vela/UI/FindBar.swift` | 92 | 0 |
| `Vela/UI/HamburgerGlyph.swift` | 38 | 0 |
| `Vela/UI/IconColorStyle.swift` | 28 | 0 |
| `Vela/UI/MenuPanelView.swift` | 703 | 0 |
| `Vela/UI/Omnibox/OmniboxModels.swift` | 321 | 0 |
| `Vela/UI/Omnibox/OmniboxSearchPageView.swift` | 162 | 0 |
| `Vela/UI/Omnibox/OmniboxSuggestionListView.swift` | 401 | 0 |
| `Vela/UI/Omnibox/OmniboxView.swift` | 494 | 0 |
| `Vela/UI/Omnibox/OmniboxViewModel.swift` | 742 | 5 |
| `Vela/UI/SettingsIconStyle.swift` | 192 | 0 |
| `Vela/UI/SettingsInputRow.swift` | 20 | 0 |
| `Vela/UI/SettingsRuleEditor.swift` | 17 | 0 |
| `Vela/UI/ShareSheet.swift` | 26 | 0 |
| `Vela/UI/SiteIconView.swift` | 723 | 1 |
| `Vela/UI/Theme.swift` | 483 | 0 |

CI 最小权限：build/test 使用 contents: read；旧分支证据镜像移到独立 mirror job，仅该 job 拥有 contents: write。迁移、下载入队、标签保存具备错误信号；全项目临时/清理 try? 未机械替换，持久化 UI 全链路仍需真机验证。

错误处理补充：脚本依赖刷新写入失败返回警告并保留 lastError；小说 TOC 仅在写入成功后发布缓存，失败不显示未保存状态。新增关闭数据库的故障注入回归测试。
