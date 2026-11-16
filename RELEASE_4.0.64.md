# Vela 4.0.64 更新说明

4.0 / Build 64，数据库 schema 14，最低 iOS 17。工程格式要求 Xcode 16，本轮交付 CI 使用 macos-26 与 iOS 26 SDK。发布包是未签名 IPA，安装时用自己的 Apple ID 签名。

## 经人机验证保护的站点打不开、加载极慢

grok.com、chatgpt.com 这类由 Cloudflare 保护的站点在 Vela 里会卡在验证页或极慢，同样的网络下 Chrome 正常。原因是这些站点会用"这次请求来自一个被改造过的浏览器"来判断客户端，而 Vela 注入的几处页面脚本在页面上是**可见的替换**，登录窗口又换了标识。

- **登录窗口继承页面的标识**。`window.open` 打开的窗口由 WebKit 用克隆配置创建，而 UA 覆盖（`customUserAgent`）是 web view 自身的属性、不在配置里，所以弹窗此前发给站点的是 WebKit 默认的 iPad 标识，而打开它的页面自称 macOS Safari。Cloudflare 把"会话中途标识发生变化"当作被换算或自动化客户端的信号，登录流程（ChatGPT 的 OAuth 跳转、Grok 的 X 登录）因此卡在永远不过的验证上。弹窗现在从父页面继承 UA 与内容模式。
- **注入脚本不再以替换的形式出现在页面上**。`history.pushState`/`replaceState`、`navigator.geolocation.*`、`navigator.clipboard.read*`、`Notification.requestPermission`、`RTCPeerConnection` 的包装改为装在平台原型上、非枚举、`toString()` 回答平台自己的 `[native code]`。行为完全不变——调用、参数、返回值一致——只是站点不再把浏览器自己的水管读成对页面的干涉。
- **网页标识只替换真正不同的值**。iPad 的桌面模式本身就让 `navigator.platform` 报 MacIntel，之前仍会重定义一个 getter；现在只在值不同时才替换。
- **收窄每个 iframe 的注入**。历史桥与滚动上报只在主框架（iframe 的 `pushState` 本来也会错误地改写地址栏）；YouTube 的点击/画质脚本只在视频站点的主框架，700ms 的画质定时器不再在每一页的每个框架里跑。
- **广告规则编译不再无限期挡住导航**。冷启动时导航最多等 250ms，规则就绪后再附加到已打开的 web view。
- **活动标签加载完成时不再立即截图**。重页面加载后的主线程少一次全页回读；切走时仍会截图，总览里的卡片不受影响。

## 验证

- 新增 `PageBridgeIntegrityTests`：在真实 `WKWebView` 里按站点会问的方式检查这些替换——`history` 上没有自有属性、枚举为 false、`String(history.pushState)` 是 `function pushState() { [native code] }`，并且 `pushState` 仍会上报给宿主；geolocation/Notification 的包装落在原型上并同样回答原生文案。
- CI 仍需 iPhone 与 iPad 两个模拟器的完整 XCTest 全部通过，打包前校验 Info.plist 版本与构建设置一致。
- **尚未验证**：真机、grok/chatgpt 的实际登录流程，以及 Cloudflare 是否因此放行。这几处改动针对的是可读出来的原因（可见的脚本替换、弹窗换标识、每帧注入、导航被规则编译挡住），需要在真机上复测确认。
