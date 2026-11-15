# Vela 3.9.53（56）报告整改说明

依据：2026-11-15 Vela_Project_Analysis_Report.md。基于用户指定本地项目的 431db4b 提交，工作分支 fix/report-security-3.9.53。

## 已实现的范围

- S1/S2：特权桥从 page world 移除；每个脚本和每次导航使用独立 WKContentWorld。原生检查 world、脚本 ID、版本、启用状态、总开关、隐私模式、主 frame、网址、grant。回调绑定运行域及请求前缀，失效上下文不回退到网页域。
- 网络按 @connect 检查 HTTP(S) 目标。临时 URLSession 不共享 Cookie、凭据或缓存；仅手动按请求附加当前 WebKit 容器的匹配 Cookie。跨源重定向拒绝，同源每跳继续验证。所有响应逐字节累计时检查 24 MB 上限，进度报告节流。
- Cookie 能力按 grant 检查，list/delete 限于发起页面 URL 的匹配 Cookie；限制 domain/url；修复路径 /foo 与 /foobar 的边界及过期过滤。
- S4：*.example.com 包含裸域；match 路径与查询保持大小写。支持 GM.getValue 等 Promise 形式的 grant 拼写。
- S5：菜单恢复当前页面脚本命令，执行定位到注册 frame 和独立运行域；菜单改为自适应列宽。
- S6：链接安装下载解析后预览名称、版本、网站、权限、connect 与依赖数量，确认后安装该文本。扩大 grant、网址范围、依赖或来源的自动更新拒绝覆盖当前版本，提示重新预览安装。
- S10（部分）：失败的 require 保留空槽避免 URL/源码错配；不完整依赖不执行，初次安装停用并返回警告。未知 grant 标记不支持。
- A1：49 条内置通用隐藏规则进入 WKContentRuleList；保留 selector 列表供诊断，运行时不再漏用。
- A3/A4（保守子集）：网络域名条件包含子域；同时包含/排除的规则明确跳过，避免整表失效；网络放行规则排在阻断之后；#@# 相同 selector 全局不隐藏，避免误隐藏且不影响网络阻断。这是保守转换，并非完整 ABP 兼容。
- A6（部分）：启动尝试查找缓存列表；候选编译失败保留现有列表。只有成功编译才更新活动规则数量。
- A7/A8：设置显示隐藏/跳过规则与使用旧规则状态，明确站点白名单不暂停独立的手动隐藏。
- README 收敛远程订阅、三级跟踪策略、安全 DNS 的未实现承诺；统一 Info.plist 与构建设置版本号。

## 兼容性边界

当前安全模式只在主 frame 运行脚本。iframe、unsafeWindow、GM_download 暂停支持，安装预览明确提示。依赖网页全局变量、历史上未声明 grant 或 connect 的脚本可能需要适配。@connect 可以声明 self 或具体域名；跨源重定向不会自动跟随。依赖声明相同但远端内容变化不属于本轮完整供应链审计。

## 仍待实现

- S3 完整逐 frame 匹配和身份，about:blank/srcdoc 策略。
- S4 include 正则复杂度约束、规则编辑时即时校验。
- S5 main-menu/tool-menu/context-menu 特殊 run-at 调度。
- S6 完整权限差异确认 UI、版本回滚库。
- S7 原始声明与本地覆盖分离。
- S8 原生权威 GM 存储、异步落盘回执及跨标签广播。
- S9 二进制请求、后台分块接收、真正响应流和 GM_download 完成语义。
- S10 完整依赖记录/hash、草稿与可执行版本分离、错误诊断面板。
- A2/A5 完整订阅系统、自定义规则管理及语法矩阵；精确 scoped cosmetic exception。
- A6 首次导航等待规则就绪的启动门禁；本轮缓存恢复仍异步，不能保证首请求受保护。
- 阶段四完整站点能力面板、全套主题和动态字体真机视觉验收。

## 验证

新增 ReportRegressionTests，覆盖主域/子域和路径大小写、原生 grant/connect 拒绝、Cookie 路径边界、实际 WebKit 运行域隔离、实际 DOM 隐藏与移除规则恢复、隐藏例外不解除网络阻断。保留现有完整测试门禁，GitHub Actions 测试成功后才构建 Release 未签名 IPA。

最终构建链接、提交和 SHA256 随交付验证记录提供。本说明不表示整份报告所有阶段均已完成，也不表示已经做过 iPhone/iPad 真机验收。
