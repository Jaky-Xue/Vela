# Vela 4.0 — Build 62

保留 4.0 产品版本，Build 61 → 62，最低 iOS 17，Xcode 16 为工程格式最低要求；交付 CI 使用 macos-26/Xcode 26 系列。

修复多窗口私密下载/确认弹窗/列表隔离、后台清理顺序、SQLite 原子迁移、无痕主页图标第三方请求、活动窗口快捷键。下载 upsert 保留恢复 blob，分片取消后禁止旧输出发布。
新增 BrowserDatabaseMigrationTests、DownloadRepositoryTests、PrivateDownloadIsolationTests、PrivateSessionLifecycleTests、BrowserCommandCenterTests、PrivateHomeFaviconTests；保留原有测试。

NavigationLog 仅为默认关闭的事件记录器，没有实际卡顿/崩溃自动采集，不宣称 MetricKit 或 MainThreadHangMonitor 已实现。普通与私密标签现有恢复偏好保持原样；私密下载重启后不恢复。

构建必须经过 iPhone 和 iPad 完整测试门禁，不发布 GitHub Release，不推送 main。最终 CI 结果、产物 SHA-256、未验证项目见 G:\Vela-4.0-62-ReleaseReport.md。
真机、Stage Manager、后台杀进程/expiration、UI 全流程和 Instruments 数据尚需验证。

CI 最小权限：build/test 使用 contents: read；旧分支证据镜像移到独立 mirror job，仅该 job 拥有 contents: write。迁移、下载入队、标签保存具备错误信号；全项目临时/清理 try? 未机械替换，持久化 UI 全链路仍需真机验证。

错误处理补充：脚本依赖刷新写入失败返回警告并保留 lastError；小说 TOC 仅在写入成功后发布缓存，失败不显示未保存状态。新增关闭数据库的故障注入回归测试。

普通下载在进程重启时由主窗口接管旧窗口归属，保留恢复数据，避免已关闭的辅助窗口留下不可控制的普通下载；活跃进程中的窗口不能操作其他窗口归属任务。新增重启归属/恢复数据回归测试。
