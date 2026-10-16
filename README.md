# Vela

一个 iOS 原生浏览器。标签页、广告过滤、用户脚本、阅读模式、无痕浏览，全都在，而且全都跑在这台设备上。

Vela 用系统 WebKit 渲染网页，不带自己的网络栈，也没有账号体系。没有登录，没有云端，没有遥测——装上去就是一个能用的浏览器，卸载之后不留下任何东西。

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
- 清除浏览数据可以分项选择

**网页能力**

- 广告与内容过滤：Adblock Plus 语法编译成 `WKContentRuleList`，支持内置规则、远程订阅、自定义规则、站点白名单和元素隐藏
- 手动隐藏页面元素：元素选择器会生成稳定的 CSS 选择器，跳过 `css-1x2y3z` 这种每次发版都变的类名
- 用户脚本：元数据块解析、`@match` 与 `@include` 双语法匹配、`GM_*` 值存储、菜单命令、元数据编辑
- 阅读模式：按可读性评分提取正文，用原生阅读界面呈现
- 网页标识：桌面版、手机版或自定义 User-Agent

**数据**

- SQLite 存储，全部在本机
- 书签：文件夹树、拖动排序、移动、搜索、文件夹选择器
- 历史：按天分组，三种删除范围（单条 / 整站 / 整天），保留期自动清理
- 下载：断点续传、重试，文件落在「我的 iPhone ▸ Vela」里

---

## 一个绕不开的平台事实

**iOS 不允许第三方浏览器内核。** 所有在 App Store 上架的浏览器，底层都是 WebKit，Vela 也一样。

这不是个可以绕过的实现细节，它划定了能做什么和不能做什么：

| | 做法 |
|---|---|
| 广告过滤 | `WKContentRuleList`——WebKit 唯一允许的规则引擎。规则是声明式的，所以正则规则、`$csp`、`$rewrite`、脚本注入和扩展选择器表达不了，设置页会如实告诉你跳过了多少条 |
| 用户脚本 | `WKUserScript`，注入点固定为文档开始和文档结束。需要特权的 `GM_xmlhttpRequest`、`GM_download`、`GM_cookie` 用不了，申请了这些权限的脚本仍可安装，详情页会标注 |
| 下载 | `WKDownload`。有断点续传，但没有分片多连接，也没有下载队列 |
| 拦截统计 | WebKit 不报告哪条规则命中、命中多少次，所以 Vela 不编造一个「已拦截 N 条」的数字。页面上显示的是规则条数，以及实际隐藏掉的元素数——那个是自己做的，能精确计数 |

---

## 还没做的

诚实清单：

| 功能 | 情况 |
|---|---|
| 跨端同步（WebDAV / 自建服务器） | 数据模型和表结构都在，客户端的同步调度没写 |
| 网页翻译 | 正文提取脚本在，翻译服务商配置与调用没接 |
| 离线页面保存 | 表结构在，保存与查看没做 |
| 自定义主页（换成你自己的 HTML） | 新标签页是原生的 |
| 小说模式与书架 | 未移植 |
| 视频接管与增强 | 未移植 |
| 密码保险箱 | 未移植——iOS 上更该直接用系统钥匙串 |
| 应用内代理 | 未移植——iOS 上要走 `NetworkExtension`，是独立的工程与签名流程 |
| iPad 形态（双栏、键盘快捷键、书签栏、窗口管理） | 只有手机布局 |
| 底部工具栏自定义排序 | 动作目录和默认顺序在，排序界面没做 |

另外，iOS 上访问非 HTTPS 站点需要 `NSAllowsArbitraryLoads`，Vela 没有开。它跟随 WebKit 的默认策略，只在你显式导航到 HTTP 地址时才加载。

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

**手上没有 Mac** 也可以：见 [`BUILD_WITHOUT_MAC.md`](BUILD_WITHOUT_MAC.md)，用 GitHub Actions 的 macOS runner 出未签名的 IPA，再用 Sideloadly 之类的工具用自己的 Apple ID 签名安装。

工程用的是 Xcode 16 的文件系统同步组（`PBXFileSystemSynchronizedRootGroup`）：往 `Vela/` 里加 `.swift` 文件会自动参与编译，不用改 `project.pbxproj`。

**最低版本**：iOS 17.0。

### 测试

```bash
xcodebuild test -project Vela.xcodeproj -scheme Vela \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

单元测试在 `VelaTests/`，覆盖的是类型签名保证不了的那部分行为：web view 池（超过上限怎么丢、丢完之后标签页上的前进后退状态怎么清）、地址栏把输入判成网址还是搜索词、标签页对外呈现的身份、历史 URL 的归一化。没有界面测试——界面部分需要的是跑起来看，而不是断言。

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
  Data/
    SQLite/     轻量 SQLite 封装
    Repositories/  书签、历史、搜索记录、下载、用户脚本、会话
  Services/
    Web/        配置装配、导航委托、页面脚本、web view 宿主
    Bookmarks/ History/ Downloads/ Settings/
  Features/     各功能界面
  UI/           主题、地址栏、工具栏
VelaTests/      单元测试
```

`AppEnvironment` 是组合根：所有服务在这里构造一次，再通过 SwiftUI 环境注入。状态用 Observation 框架的 `@Observable`，视图读取哪个属性就追踪哪个属性，跨层级有效。

---

## 许可

GPL-3.0，全文见 [`LICENSE`](LICENSE)，署名与商标说明见 [`LICENSE-NOTICE.md`](LICENSE-NOTICE.md)。

---

## 项目源头

Vela 起源于 **Aira Browser**——一个鸿蒙 NEXT 上的开源浏览器，同样以 GPL-3.0 发布。Vela 保留了它的数据表结构与功能语义，在 iOS 上重新实现，[`PORTING.md`](PORTING.md) 记录了两者的逐模块对应关系。

除此之外两者没有关系：Vela 是独立项目，不是 Aira 的官方版本，也不受其背书或赞助。

上游项目：<https://github.com/mason173/aira-browser>
