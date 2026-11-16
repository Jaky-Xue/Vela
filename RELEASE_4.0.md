# Vela 4.0 — Build 62

保留 4.0 产品版本，Build 61 → 62，最低 iOS 17，Xcode 16 为工程格式最低要求；交付 CI 使用 macos-26/Xcode 26 系列。

修复多窗口私密下载/确认弹窗/列表隔离、后台清理顺序、SQLite 原子迁移、无痕主页图标第三方请求、活动窗口快捷键。下载 upsert 保留恢复 blob，分片取消后禁止旧输出发布。
新增 BrowserDatabaseMigrationTests、DownloadRepositoryTests、PrivateDownloadIsolationTests、PrivateSessionLifecycleTests、BrowserCommandCenterTests、PrivateHomeFaviconTests；保留原有测试。

NavigationLog 仅为默认关闭的事件记录器，没有实际卡顿/崩溃自动采集，不宣称 MetricKit 或 MainThreadHangMonitor 已实现。普通与私密标签现有恢复偏好保持原样；私密下载重启后不恢复。

构建必须经过 iPhone 和 iPad 完整测试门禁，不发布 GitHub Release，不推送 main。最终 CI 结果、产物 SHA-256、未验证项目见 G:\Vela-4.0-62-ReleaseReport.md。
真机、Stage Manager、后台杀进程/expiration、UI 全流程和 Instruments 数据尚需验证。
