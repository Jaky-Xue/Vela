# Vela

**一个 iOS 原生浏览器。** 标签页、广告过滤、用户脚本、阅读模式、小说模式与书架、密码与保险箱、无痕浏览都在，而且全都跑在这台设备上。

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
- 跟踪保护三级可调，落到 WebKit 的第三方 Cookie 策略上
- 安全 DNS：模式和服务器目录，内置 5 个 DoH 服务商
- 网站权限逐项可控：相机、麦克风、位置、运动与方向、剪贴板，支持全局默认 + 站点级覆盖
- 外部应用跳转控制，带站点例外——网页用 `bilibili://` 这类深链把你拽出浏览器是最常见的骚扰之一，默认被拦下
- 不保留历史记录：开关打开后，浏览历史与搜索历史都不再写入
- WebRTC 泄露防护：开关 + 允许 / 防泄露（过滤私有地址候选）/ 仅中继 / 完全禁用，文档开始脚本在每个 frame 安装
- 清除浏览数据可以分项选择

**网页能力**

- 广告与内容过滤：Adblock Plus 语法编译成 `WKContentRuleList`，支持内置规则、远程订阅、自定义规则、站点白名单和元素隐藏
- 手动隐藏页面元素：元素选择器会生成稳定的 CSS 选择器，跳过 `css-1x2y3z` 这种每次发版都变的类名
- 用户脚本：元数据块解析、`@match` 与 `@include` 双语法匹配、`GM_*` 值存储、菜单命令、元数据编辑；支持从文件安装，按当前页面的 URL 逐次重算匹配结果
- 阅读模式：按可读性评分提取正文，用原生阅读界面呈现
- 小说模式与书架：提取书名、作者、正文和上一章/下一章链接，加入书架并记住阅读进度；章节正文缓存，可离线继续；阅读时有目录（从网站目录页解析）、上下章（页面无链接时用目录补足）以及上下滚动 / 整屏翻页两种翻页方式，阅读层会隐藏浏览器工具栏
- 密码与保险箱：条目只写入 iOS 钥匙串（`ThisDeviceOnly`），面容 ID / 触控 ID / 设备密码解锁，可一键填充当前网页的登录表单
- 网页标识：桌面版、手机版或自定义 User-Agent

**外观**

- 全局背景：纯净、暖阳、晚霞、青柠、极光、冰川、紫雾七种；后六种是静态光场，暖色（蜜桃橙、珊瑚玫红）与冷色（嫩芽青柠、薄荷青绿、冰蓝天青、薰衣草紫）各自成套，主页、设置、书架和浮层都透出同一片背景，玻璃工具栏会折射它
- 工具栏：手机底部栏和 iPad 顶栏分别可以增删、拖动排序；iPad 顶栏的侧边栏和菜单固定，中间是地址栏
- iPad 手势：顶栏上滑收起（书签栏一起），下滑回到主页
- 菜单面板：内置项可以隐藏、拖动排序并加回来；还可以添加自己的网址快捷方式，选图标、命名、一键打开
- iPad 布局：可在跟随设备 / 手机布局 / iPad 布局之间切换；参考 Safari，iPad 布局使用一条顶部工具栏、可收起的标签侧边栏和书签栏，不再在底部重复一套工具栏。硬件键盘快捷键（⌘T、⌘W、⌘L、⌘R、⌘F、⌘⇧T 等）同样可用
- 窗口管理：支持 iPad Split View / Slide Over / Stage Manager，自动模式按窗口宽度在双栏与单栏之间切换
- 外观模式与配色：浅色 / 深色 / 跟随系统，四套配色在运行时切换

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
| 用户脚本 | `WKUserScript`，注入点固定为文档开始和文档结束。需要特权的 `GM_xmlhttpRequest`、`GM_download`、`GM_cookie` 用不了，申请了这些权限的脚本仍可安装，详情页会标注 |
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

## 项目源头

Vela 起源于 **Aira Browser**——一个鸿蒙 NEXT 上的开源浏览器，同样以 GPL-3.0 发布。Vela 保留了它的数据表结构与功能语义，在 iOS 上重新实现，[`PORTING.md`](PORTING.md) 记录了两者的逐模块对应关系。

除此之外两者没有关系：Vela 是独立项目，不是 Aira 的官方版本，也不受其背书或赞助。

上游项目：<https://github.com/mason173/aira-browser>
