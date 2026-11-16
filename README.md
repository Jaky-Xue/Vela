# Vela

当前实现与支持范围见 [4.0.63 更新说明](RELEASE_4.0.63.md)。较早版本段落保留作历史记录。

**一个 iOS 原生浏览器。** 标签页、广告过滤、用户脚本、小说模式与书架、密码与保险箱、无痕浏览都在，而且全都跑在这台设备上。

[![最新版本](https://img.shields.io/github/v/release/Jaky-Xue/Vela?label=%E4%B8%8B%E8%BD%BD&color=blue)](https://github.com/Jaky-Xue/Vela/releases/latest)
[![许可证](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)
[![平台](https://img.shields.io/badge/iOS-17.0%2B-lightgrey)](https://github.com/Jaky-Xue/Vela/releases/latest)

Vela 用系统 WebKit 渲染网页，不带自己的网络栈，也没有账号体系。没有登录，没有云端，没有遥测——装上去就是一个能用的浏览器，卸载之后不留下任何东西。

---

## 下载与安装

每个版本都在 [**Releases**](https://github.com/Jaky-Xue/Vela/releases/latest) 发布，里面有一份未签名的 `.ipa`，以及 GitHub 自动打包的源码（`Source code (zip)` / `Source code (tar.gz)`）。

iOS 不允许安装没有签名的应用，所以 `.ipa` 需要用自己的 Apple ID 签一次名再装：

1. Windows / macOS 上安装 [Sideloadly](https://sideloadly.io/)（Windows 需要 [官网版 iTunes](https://www.apple.com/itunes/download/win64)，**不能**是 Microsoft Store 版，它不带 Sideloadly 需要的驱动）。
2. **先**插上 iPhone、解锁、信任这台电脑，**再**打开 Sideloadly。
3. 把 `Vela-unsigned.ipa` 拖进窗口，填入 Apple ID，点 **Start**。
4. 手机上到 **设置 ▸ 通用 ▸ VPN 与设备管理** 信任你的开发者证书。

免费 Apple ID 签出的证书 **7 天过期**，过期后应用会闪退，重新签名即可（[AltStore](https://altstore.io/) 可以自动续签）；付费开发者账号签出的证书有效期一年。

完整的 Windows 侧载流程、云 Mac 构建、常见故障排查，见 [`BUILD_WITHOUT_MAC.md`](BUILD_WITHOUT_MAC.md)。

**最低版本：iOS 17.0。**

---

## 它做什么

**浏览**

- 多标签：新建、关闭、切换、固定、最近关闭、退出后恢复会话
- 后台标签页自动回收内存（超过 6 个活跃 web view 时按最近使用顺序丢弃，固定的标签最后丢弃）
- 地址栏一个框搞定：输入网址就打开，输入词就搜索，`localhost`、IPv4、IPv6 字面量都认
- 输入建议按「网址 → 已打开的标签页 → 书签 → 搜索历史 → 浏览历史 → 搜索」的优先级合并
- 原生新标签页：常用网站、最近关闭
- 页面内查找，自己实现的高亮，不依赖 `window.find`

**隐私**

- 无痕模式：独立的 `WKWebsiteDataStore`，退出即清空，可要求生物识别才能进入
- 网页使用 WebKit 提供的系统隐私机制；三级跟踪保护偏好尚未接入独立执行策略
- 安全 DNS 目前仅保存偏好与服务商目录，尚未实现应用级 DoH 解析
- 网站权限逐项可控：相机、麦克风、位置、运动与方向、剪贴板，支持全局默认 + 站点级覆盖
- 外部应用跳转控制，带站点例外——网页用 `bilibili://` 这类深链把你拽出浏览器是最常见的骚扰之一，默认被拦下
- 不保留历史记录：开关打开后，浏览历史与搜索历史都不再写入
- WebRTC 泄露防护：开关 + 允许 / 防泄露（过滤私有地址候选）/ 仅中继 / 完全禁用，文档开始脚本在每个 frame 安装
- 清除浏览数据可以分项选择

**网页能力**

- 广告与内容过滤：Adblock Plus 语法编译成 `WKContentRuleList`，支持内置来源独立开关、HTTPS 远程订阅、自定义 ABP 子集规则、站点白名单和元素隐藏；来源缓存与候选快照经验证后再切换
- 手动隐藏页面元素：元素选择器会生成稳定的 CSS 选择器，跳过 `css-1x2y3z` 这种每次发版都变的类名
- 用户脚本：按 Tampermonkey 元数据安装、编辑、检查更新和删除；解析 `@match`/`@include`/`@require`/`@resource`/`@run-at`，安装时下载依赖；`GM_*` 值存储、菜单命令、`GM_xmlhttpRequest`/`GM_fetch`/`GM_cookie`/`GM_download`/`GM_openInTab`/每标签存储通过原生桥接执行，两个脚本的全局互不覆盖
- 小说模式与书架：提取书名、作者、正文和上一章/下一章链接，加入书架并记住阅读进度；章节正文缓存，可离线继续；阅读时有目录（从网站目录页解析）、上下章（页面无链接时用目录补足）以及上下滚动 / 整屏翻页两种翻页方式，阅读层会隐藏浏览器工具栏
- 密码与保险箱：条目只写入 iOS 钥匙串（`ThisDeviceOnly`），面容 ID / 触控 ID / 设备密码解锁，可一键填充当前网页的登录表单
- 网页标识：自动跟随设备——iPhone 用手机版，iPad 和 Mac 用桌面版（iPad 的网页按桌面布局渲染，横屏也和桌面一致）；桌面版会把 768–1024 宽的窗口按 1200 的桌面宽度排版再缩放，进入站点的桌面断点；单个网站可在菜单「桌面网站」里单独选择桌面/手机版并记住，长按图标恢复自动；也可选 Safari iPad 平板版、Safari / Chrome / Edge / Firefox 预设或自定义 User-Agent，标识和网页布局一起切换；初始即为自动模式
- 网页缩放：50%–200%，通过根元素的强制缩放实现，绕过网站自己的 viewport 与缩放规则，已打开的页面即时生效

**外观**

- 全局背景：纯净、暖阳、晚霞、青柠、极光、冰川、紫雾七种；后六种是静态光场，暖色（蜜桃橙、珊瑚玫红）与冷色（嫩芽青柠、薄荷青绿、冰蓝天青、薰衣草紫）各自成套，主页、设置、书架和浮层都透出同一片背景，玻璃工具栏会折射它
- 工具栏：手机底部栏和 iPad 顶栏分别可以增删、拖动排序；iPad 顶栏的侧边栏和菜单固定，中间是地址栏
- 手机手势：底部工具栏下拉收起（拖动时上方提示「释放后收起工具栏」），上拉返回首页；收起后把页面往回滚一下，工具栏就回来
- iPad 手势：顶栏上滑收起（书签栏一起），下滑回到主页
- 菜单面板：点面板右上角的编辑按钮就能在内置项之间拖动排序、隐藏或加回，并可以新建自己的网址快捷方式（选图标、命名、一键打开），不用先进设置
- iPad 布局：可在跟随设备 / 手机布局 / iPad 布局之间切换；参考 Safari，iPad 布局使用一条顶部工具栏、可收起的标签侧边栏和书签栏，不再在底部重复一套工具栏。硬件键盘快捷键（⌘T、⌘W、⌘L、⌘R、⌘F、⌘⇧T 等）同样可用
- 窗口管理：支持 iPad Split View / Slide Over / Stage Manager，自动模式按窗口宽度在双栏与单栏之间切换
- 外观模式与配色：浅色 / 深色 / 跟随系统，四套配色在运行时切换；切换会同时改写窗口的 interface style，立即全局生效，浅色/深色预览图可直接点按切换

**数据**

- SQLite 存储，全部在本机
- 书签：文件夹树、拖动排序、移动、搜索、文件夹选择器
- 历史：按天分组，三种删除范围（单条 / 整站 / 整天），保留期自动清理
- 下载：队列与并发上限、https 文件的分片多连接、暂停/继续（分片任务按已完成分片续传），服务器不支持 Range 时自动单连接；文件落在「我的 iPhone ▸ Vela」里

---

## 一个绕不开的平台事实

**iOS 不允许第三方浏览器内核。** 所有在 App Store 上架的浏览器，底层都是 WebKit，Vela 也一样。

这不是个可以绕过的实现细节，它划定了能做什么和不能做什么：

| | 做法 |
|---|---|
| 广告过滤 | `WKContentRuleList`——WebKit 唯一允许的规则引擎。规则是声明式的，所以正则规则、`$csp`、`$rewrite`、脚本注入和扩展选择器表达不了，设置页会如实告诉你跳过了多少条 |
| 用户脚本 | 按 Tampermonkey 的元数据解析 `@match` / `@include` / `@require` / `@resource` / `@run-at` / `@grant`。脚本可在管理页安装、编辑、检查更新和删除；`@require` 与 `@resource` 在安装时下载并随脚本保存。`GM_xmlhttpRequest`、`GM_fetch`、`GM_cookie`、`GM_download`、`GM_openInTab` 和 `GM_getTab` 系列需要原生能力，通过注入桥回到 App 执行；华为扩展 `GM_EX_*` 与原生 `window.close/focus` 语义仍不可用 |
| 下载 | 浏览器自己的传输层：https 文件用 URLSession 做 Range 分片、并发上限、暂停/续段；服务器不支持 Range 时自动单连接。URLSession 无法忠实完成的情况（明文 http、登录/挑战页、blob）回退到 WebKit 的 `WKDownload`，后者只支持单连接 |
| 网页翻译 | 按段落提取并由 Google 公共接口 / DeepL / OpenAI 兼容接口翻译，段落里的链接、加粗等行内标记保留；识别页面语言后像 Chrome 一样显示翻译栏，可显示原文、总是/不再翻译此网站，并继续翻译后来加载的内容 |
| 拦截统计 | WebKit 不报告哪条规则命中、命中多少次，所以 Vela 不编造一个「已拦截 N 条」的数字。页面上显示的是规则条数，以及实际隐藏掉的元素数——那个是自己做的，能精确计数 |

---

## 还没做的

诚实清单：

| 功能 | 情况 |
|---|---|
| 跨端同步（WebDAV / 自建服务器） | 数据模型和表结构都在，客户端的同步调度没写 |
| 自定义主页（换成你自己的 HTML） | 新标签页是原生的 |
| 视频接管与增强 | 未移植 |
| 应用内代理 | 未移植——iOS 上要走 `NetworkExtension`，是独立的工程与签名流程 |

纯 HTTP 站点可以正常打开。网页内容通过 `NSAllowsArbitraryLoadsInWebContent` 放行明文请求，这是浏览器的必要能力——用户在地址栏里输入什么地址是事先不知道的，而 Safari 同样会打开 HTTP 页面并标注"不安全"。这个开关只作用于 `WKWebView` 的内容；应用自身的网络请求（分片下载的 URLSession、订阅列表、搜索引擎探测）仍然受完整的 ATS 约束，所以明文 http 文件会回退给 WebKit 的下载通道。证书校验没有放宽，Vela 不会接受任何本该被拒绝的证书。

---

## 编译

需要 **macOS + Xcode 16 或更新版本**——iOS 应用只能在 macOS 上编译，没有替代方案。

```bash
open Vela.xcodeproj
```

然后在 Xcode 里：

1. 选中 `Vela` target → `Signing & Capabilities`
2. 勾选 `Automatically manage signing`，选你的 Team
3. 如果 `org.vela.browser.ios` 被占用，改成你自己的包名
4. 连上 iPhone，选为运行目标，⌘R

**手上没有 Mac** 也可以：见 [`BUILD_WITHOUT_MAC.md`](BUILD_WITHOUT_MAC.md)。仓库里的 GitHub Actions 工作流（[`.github/workflows/build-ios.yml`](.github/workflows/build-ios.yml)）会在 macOS runner 上出未签名的 IPA，Release 里的 `.ipa` 就是这么来的。

工程用的是 Xcode 16 的文件系统同步组（`PBXFileSystemSynchronizedRootGroup`）：往 `Vela/` 里加 `.swift` 文件会自动参与编译，不用改 `project.pbxproj`。

### 测试

```bash
xcodebuild test -project Vela.xcodeproj -scheme Vela \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

单元测试在 `VelaTests/`，覆盖的是类型签名保证不了的那部分行为：web view 池（超过上限怎么丢、丢完之后标签页上的前进后退状态怎么清）、地址栏把输入判成网址还是搜索词、标签页对外呈现的身份、历史 URL 的归一化、导航与加载状态、页面脚本的装配。没有界面测试——界面部分需要的是跑起来看，而不是断言。

CI 上这是独立的第二个 job，不会挡住 IPA 的产出，原因见 `BUILD_WITHOUT_MAC.md`。

---

## 工程结构

```
Vela/
  App/          VelaApp、AppEnvironment（组合根）、BrowserShellView
  Core/
    Models/     类型定义
    Tabs/       TabManager，标签与 web view 的所有权
    AdBlock/    规则编译器与引擎
    UserScripts/解析、匹配、注入、GM_ 桥
    Reader/     正文提取
    Novel/      章节提取与离屏加载
    Passwords/  钥匙串封装
  Data/
    SQLite/     轻量 SQLite 封装
    Repositories/  书签、历史、搜索记录、下载、用户脚本、会话、小说书架
  Services/
    Web/        配置装配、导航委托、页面脚本、web view 宿主
    Bookmarks/ History/ Downloads/ Settings/ Novels/ Passwords/
  Features/     各功能界面（设置、小说、密码等按子页拆文件）
  UI/           设计令牌与配色、表面材质、共享组件、图标
VelaTests/      单元测试
```

`AppEnvironment` 是组合根：所有服务在这里构造一次，再通过 SwiftUI 环境注入。状态用 Observation 框架的 `@Observable`，视图读取哪个属性就追踪哪个属性，跨层级有效。

分层规则与文件职责见 [`ARCHITECTURE.md`](ARCHITECTURE.md)。

---

## 许可

GPL-3.0，全文见 [`LICENSE`](LICENSE)，署名与商标说明见 [`LICENSE-NOTICE.md`](LICENSE-NOTICE.md)。

---

### 3.9.53 脚本安全模式

脚本在每次导航独立的 WKContentWorld 中运行，原生桥校验脚本身份、启用状态、版本、网址、授权及网络目标。当前仅支持主页面；iframe、unsafeWindow 和 GM_download 暂停支持。GM 请求必须声明 @connect（可用 self），跨源重定向会被拒绝。依赖网页全局变量或未声明权限的旧脚本可能需要修改。

安装链接先解析预览后确认；扩大权限、运行范围、依赖或更新来源的自动更新会被阻止，需从安装链接重新预览确认。49 条内置元素隐藏规则已接入 WebKit；隐藏例外暂按相同 selector 全局放行，因此可能少隐藏部分元素。规则编译失败保留上一列表；冷启动恢复页面等待规则就绪仍需进一步实现。

### 3.9.54 外观与规则管理

新增 6 套配色（总计 10 套）与 4 种背景（总计 13 种），菜单和设置采用白色图形配高对比度彩色底。菜单可长按拖动排序，主页收藏可拖到另一图标交换位置，排列持久保存。新配色正文及图标颜色有 WCAG 对比度回归检查；减少动态效果时关闭按压缩放及排序、背景切换动效。

设置 ▸ 广告拦截 ▸ 过滤来源与自定义规则 可添加 HTTPS UTF-8 纯文本来源、启停三组内置规则、编辑本地规则并更新订阅。每份来源最多 2 MB，总量最多 8 MB；缓存使用不可变内容 hash，支持 ETag/Last-Modified 与离线启动。HTML、空正文、include 指令、无效规则和系统编译失败不会覆盖当前配置。首个普通网页导航等待规则准备；首次编译失败仍会显示未就绪。

GM 异步值写入有原生落盘回执，失败拒绝 Promise；同一脚本的多标签与窗口更新会广播，逐键版本号忽略乱序旧事件。同步 GM_getValue 读取本地缓存；跨标签通知是异步的。脚本匹配规则作为独立本地覆盖，源码编辑和普通自动更新保留覆盖；分享可选择是否包含本地规则。无效源码可存草稿，不替换活动版本。

过滤语法是明确子集：域名/URL 锚点、网络放行、普通 CSS、资源类型和 match-case 有转换；image/script/style/font/media 等精确类型支持排除。XHR/WebSocket/object 等合并为 WebKit raw，不能等同完整 ABP；对 raw/document 的排除、混合包含/排除域、正则规则、扩展 CSS/scriptlet 仍跳过。隐藏例外仍保守地全局放行同一 selector。参见 [WebKit 规则格式](https://webkit.org/blog/3476/content-blockers-first-look/)。

继承 3.9.53 的安全限制：iframe、unsafeWindow、GM_download 暂停支持，网络仍不跟随跨源重定向。完整站点能力面板、权限扩大确认/回滚界面和真正流式/二进制 GM 请求仍需后续实现。详见 RELEASE_3.9.54.md。

### 3.9.55 菜单与设置调整

菜单恢复单色图标，图标标签不超过四字，保留长按拖动。脚本命令移到独立列表，异常详情折叠显示。设置统一行高与输入边框；添加订阅、编辑过滤规则和添加站点例外使用独立表单，字段有持久标签。长篇说明移到折叠区域。

新增脚本更新审阅和上一版本回滚：扩大权限、网站、依赖或更新来源时先保存待确认候选，原版本继续运行。审阅后确认绑定具体候选 hash；内容或脚本状态改变时拒绝陈旧确认。安装、编辑和普通自动更新保留上一份源码及依赖快照；回滚保留脚本数据、本地规则和启用状态。快照在本地独立文件中原子保存和校验，不把大段源码存入设置文档。详见 RELEASE_3.9.55.md。

## 3.9.56

分离普通/无痕主页路由；菜单保持单色并移除提示和脚本信息；设置改用明亮浅色图标底；总览取消强制深色，稳定卡片身份并统一低回弹动效。站点详情集中脚本和保护操作。逐 frame 原生授权、页面模式确认、增量 GM_fetch、二进制上传、下载完成语义、递归 include、精确隐藏例外与来源行号诊断接入。CI 增加 iPad 门禁；支持范围和真机验收边界见 RELEASE_3.9.56.md。

## 3.9.57

配色新增表面、深度与图标三类视觉角色，10 套配色各自决定卡片材质、圆角、阴影与图标风格；搜索栏、菜单与总览恢复半透明，iOS 26 使用系统 Liquid Glass，旧 SDK 用轻 tint 模糊回退，降低透明度时整块不透明。配色预览改为显示几何与深度的缩略图，切换配色不再覆盖已选背景和照片。菜单与主页收藏共用自定义 Layout 做长按拖动：瓦片绘制在滚动内容之上、跟手实时重排、落点按手指位置计算，静止长按仍打开上下文菜单；主页可直接「仅添加到主页收藏」，宽屏用满可容纳的列数。设置图标恢复参考设计的明亮系统色，辅助功能字号下当前值移到标题下方。打包前校验 Info.plist 版本与构建设置一致。详见 RELEASE_3.9.57.md。

## 4.0.63（Build 63）

首页只留图标：去掉「收藏」标题、数量、折叠和 `+`，去掉「最近关闭」板块；已有图标时页面上不再有其它文字，空首页用「添加图标」起步，之后长按页面添加。主页图标编辑弹窗改为「新建图标 / 编辑图标」。地址/搜索框加常驻描边，浅色与深色下都能和背景分开，编辑时改用强调色并加粗。设置 ▸ 通用 ▸ 保留新增「记录最近关闭的标签页」（默认开）：关闭后不再记录，已有列表从内存和数据库清除，标签页总览的「重新打开关闭的标签页」随之不可用。详见 RELEASE_4.0.63.md。

## 4.0.62（Build 62）

当前源码版本为 4.0 / Build 62，schema 14，最低 iOS 17；工程最低 Xcode 16，本轮 CI 请求 macos-26。详见 PROJECT_REVIEW.md 和 RELEASE_4.0.62.md。
下载仍由进程 DownloadService 调度，任务与确认提示记录窗口归属；私密下载还记录会话 UUID。每窗口派生自身私密列表，结束会话仅撤销本窗口本会话，启动时清理旧私密下载。
数据库建表/补字段/版本更新在同一事务内；迁移失败回滚、未来版本拒绝，不重置原数据。普通/私密标签持久化偏好保留现有行为，不声称私密标签从不落盘。
NavigationLog 默认关闭，仅记录调用方事件；recordHang 不提供实际检测，没有 MetricKit/MainThreadHangMonitor 或系统崩溃采集。无自动上传。
既有 CI 的 build 保持 needs: test，iPhone 与 iPad 都成功才打包。工作分支构建，禁止把历史基线或静态检查当作本轮测试通过。以最终 ReleaseReport 为实际结果；UI/真机/Instruments 未验证。
