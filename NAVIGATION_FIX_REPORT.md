# 网页加载系统修复报告

对象：`VelaBrowserIOS`，分支 `swiftui-native-refactor`。
证据来源：GitHub Actions 上的 `xcodebuild`（macOS runner，iOS 模拟器）与本机代码审查。
本机（Windows）没有 Swift 工具链，因此**编译器只有 CI**，报告中的所有构建与测试结论都来自 CI 日志。

---

## 1. 根因

按严重程度排序。每条都给出代码位置和证据；证据不足的单独标注。

### 根因 1：明文 HTTP 被系统整体拦截 —— 所有 `http://` 站点都打不开

`Info.plist` 里没有任何 `NSAppTransportSecurity` 配置。App Transport Security 默认阻止
`WKWebView` 里的明文请求，所以地址栏接受了 `http://` 地址、`BrowserUrlResolver` 也把它解析成了
URL，然后 WebKit 在**发出任何数据包之前**就以
`NSURLErrorAppTransportSecurityRequiresSecureConnection` 失败。用户看到的是一个打不开的页面和一句
英文系统提示。这覆盖了所有只有 HTTP 的站点。

证据：`PublicWebSmokeTests.testACleartextHttpPageOpens` 加载 `http://example.com/`。

* 修复前：导航失败（该用例当时断言的是 `.failed`）。
* 修复后（CI 日志原文）：`=== cleartext smoke test: http://example.com/ → state=finished status=200 error=none ===`

仓库自己的文档把这个遗漏说成是有意为之，并且是错的：

* `README.md`：『Vela 没有开……这是有意的，和 Safari 行为一致』
* `BUILD_WITHOUT_MAC.md`：把"装上了但网页打不开"归因于网络

Safari 会打开 HTTP 页面并标注"不安全"。两处文档已改成实际情况。

修复用的是 `NSAllowsArbitraryLoadsInWebContent`，不是 `NSAllowsArbitraryLoads`：只作用于
`WKWebView` 内容，应用自身网络请求（下载、订阅列表、搜索引擎探测）仍受完整 ATS 约束；
证书校验完全没有放宽。

### 根因 2：视图层自己发起加载 —— 失败即无限重试，成功时重复请求

`Vela/Services/Web/WebViewHost.swift`（修改前 70–79 行）在托管 web view 没有已提交 URL 时
会自己 `load(initialUrl)`。这个条件在任何**失败**的预提交导航之后依然成立（失败不会产生 URL），
于是：导航失败 → `tab.isLoading` 回到 false → shell 观察到该变化 → body 重新求值 →
视图再次发起请求。每一次失败都重新武装守卫，同时 `didStartProvisionalNavigation` 每轮都清掉
`lastError`，所以标签页永远settle不到错误状态——这正是"打不开"表现为一片空白的原因。
成功路径上它还会和 `TabManager.load(url:in:)` 已经发出的同一个请求竞争。

说明：这条是**代码审查确认**，不是 CI 观察到的现象（我在写测试之前就已经把它删掉了）。
现在的保证由测试给出：`testAPageIsRequestedExactlyOnce` 断言本地服务器**实际收到**的请求数是 1。

### 根因 3：失败没有任何界面 —— `lastError` 写了但没人读

`BrowserWebCoordinator` 会把失败写进 `tab.lastError` / `runtimeState = .failed`，
`grep` 全仓库没有任何视图读这两个字段。加载失败的结果是一块白色矩形：没有原因、没有地址、
没有可点的东西。

### 根因 4：广告拦截实际上从未生效

`WKContentRuleListStore` 拒绝所有规则列表，错误信息不指出是哪一条规则：
`Invalid or unsupported regular expression`。

把 59 条规则**逐条**编译，全部失败，说明问题在它们共同的形状上。再逐个构造探测，答案很明确：

| `url-filter` | 结果 |
| --- | --- |
| `(abc|$)` | REFUSED |
| `([^a-zA-Z0-9_.%-]|$)` | REFUSED |
| `[^a-zA-Z0-9_.%-]` | OK |
| `^[a-z][a-z0-9+.-]*://([^/]+\.)?doubleclick\.net` | OK |

`url-filter` 不是普通 ICU 正则：WebKit 用内容拦截匹配器的受限引擎校验它，**拒绝任何不在末尾的
`$` 锚点，包括组内的 `$`**。编译器给每一条域名锚定规则都追加了 `([^…]|$)`，于是整个列表被拒，
广告拦截一次都没生效过。

关键在于**拒绝不是局部的**：WebKit 拒绝整个规则列表，一条不可表达的规则就会静默关掉全部拦截。
所以 `regexFilter` 现在会校验自己的输出（正则是否合法、是否存在非末尾的 `$`），
表达不了的规则被丢弃并计入 invalid，代价是一条规则而不是全部。

`AdBlockContentRuleCompilationTests` 会编译编译器能产出的**每一种形状**，把这条约束变成测试而不是记忆。

另外两处同源缺陷，都让"编译成功"变得不可能或无效：

* `install` 在编译前删除旧列表，而删除**从不存在**的标识符会报错。CI 日志原文：
  `removing an absent rule list → Error Domain=WKErrorDomain Code=8 ... "Rule list removal failed"`。
  也就是说全新安装的第一次编译必然抛错，`refreshAdBlockRules` 把它当作"保留原有规则"吞掉，
  而原有规则是空的——规则列表永远不会被安装。
* `attachedList` 在一个游离的 `Task` 里赋值、而 continuation 立刻恢复，所以即使编译成功，
  紧接着的那次导航（启动后的第一个页面，或切换拦截开关后的 reload）也拿不到任何规则。

两处都已修。`removeContentRuleList` 的行为由
`testRemovingARuleListThatDoesNotExist` 记录下来（并断言真正要保证的性质：之后的编译必须成功），
不再依赖我对文档的猜测。

### 根因 5：策略取消被当成页面加载失败

`decidePolicyFor` 对每个 `target="_blank"` / `window.open` 都回答 `.cancel`。
WebKit 把它报告为 `WebKitErrorFrameLoadInterruptedByPolicyChange`（102），
它不在 `NSURLErrorDomain` 里，所以只判断 `NSURLErrorCancelled` 的旧代码把它当成真实失败，
**每次在新标签页打开链接，当前页面都会被标记为失败**。

证据：`testOpeningALinkInANewTabLeavesTheCurrentTabAlone`（修复前失败，现在通过）。

### 根因 6：没有导航关联标识，旧回调会覆盖新导航的状态

`handleLoadFailure` 的取消分支无条件把 `isLoading` 置 false、清空 `pendingUrl`。
被 `TabManager.load` 取代的那次导航取消时，会清掉**取代它的那次**导航的加载状态。

### 根因 7（较轻，但都是真的）

| 问题 | 位置 | 证据 |
| --- | --- | --- |
| `WKWebView.title` 在 `didFinish` 时可能还是空，于是标签页/历史/地址栏只显示主机名 | `BrowserWebCoordinator.didFinish` | `testAPlainPageLoadsAndReportsItsTitleAndUrl` 修复前断言失败（`("") is not equal to ("Page One")`） |
| WebKit 用自带的空文档（`about:blank`）回应连不上的连接且不报错，被当成加载成功——`commit about:blank` + `finish`，用户得到空白页 | `didFinish` | 导航日志原文：`start provisional https://127.0.0.1:1/` → `commit committed about:<5 字符>` → `finish finished about:<5 字符>` |
| 括号 IPv6 地址永远解析不出：`[::1]:8080` 的主机被切成了字符串 `[` | `BrowserUrlResolver` | `testAnIPv6LiteralInBracketsUsesHttp` 修复前断言失败 |
| 内容进程崩溃后无条件 `reload()`，对没有文档的 web view 是空操作，标签页永久停在 `crashed` + 空白 | `webViewWebContentProcessDidTerminate` | 代码审查 |
| 死了的协议方法 `recordVisit` 会伪造 tabId（`url.host ?? "unknown"`）；`historyTransitionProvider` 传了但从没被读过 | `TabManager` | `grep` 无调用点 |

### 根因 8：浏览器自称 Safari 17 ——「显示浏览器版本太低」

`TabManager` 里的 `BrowserUserAgent` 把 `Version/17.0` 和 `Mobile/15E148` 写死。设备上的
iOS 比这新，于是**每一个网站都被告知这是 Safari 17**，会检查版本的网站直接回「浏览器版本太低」。
引擎是新的，只有标签是旧的，而标签就是网站判断的全部依据。

修的过程中测试又纠正了我的第一版做法：「不给自己设 UA」并不等于「发系统自己的串（也就是 Safari 的串）」。
模拟器实测，裸的 `WKWebView` 发的是：

```
Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148
```

**没有 `Version/`，也没有 `Safari/`**——这两个 token 是 Safari 自己加的。会找它们的网站会把缺失
当成「内置浏览器」，然后要求用户用 Safari 打开——同一个抱怨的另一半。所以标识串改成 Safari 形状、
由**当前系统版本号**拼出；桌面版只改平台标识和 `Mobile/` 标记。

证据：`testTheIdentifierPresentedIsSafariShapedAndCurrent`（断言页面看到 `Version/<真实主版本>.`、
`Safari/`，且不含 `Version/17.0`）。

### 根因 9：页面自己发的埋点被取消，导致切回标签页会重新加载

一份真实的导航日志（Bing 搜索）：

```
#1 start provisional https://www.bing.com/search?…
#1 redirect … → https://cn.bing.com/search?…
#1 commit / #1 finish
#2 start provisional https://cn.bing.com/fd/ls/GLinkPing.aspx?…
#2 cancel cancelled  WebKitErrorDomain/102
```

搜索本身是对的（重定向被跟随，地址栏跟着走）。第二条是 Bing 自己发的点击统计埋点：`start` 说明
**Vela 放行了它**（被 Vela 拒绝的导航走不到 `didStartProvisionalNavigation`），随后 WebKit 报告它被中断——
没有当成失败，所以结果页没有被错误页盖住，这部分是正确的。

但它把标签页的状态留在了 `cancelled`，而结果页还在屏幕上。`needsPageFetch` 认为 `cancelled` 的标签页
需要重新取页面，于是**切走再切回来会重新加载搜索结果**，用户丢失阅读位置。

修的时候发现「屏幕上有没有文档」这个判断一直是错的：`WKWebView.url` 报告的是**正在进行的导航**，
不是已显示的文档。实测：`/slow` 的导航被停止后，`/one` 还在屏幕上，而 `webView.url` 读出来是 `/slow`。
`tab.url` 也不行——`TabManager.load` 在发出请求时就乐观地写了它。

所以标签页新增 `committedUrl`，**只由 `didCommit` 写**（那是唯一意味着「文档到了」的事件）。
判定改为看它。两个方向都有测试：有文档 → 不重新取；只有被停掉的那一次导航 → 重新取。

### 未证实的假设

* 真实 60 秒网络超时：分类逻辑有单元测试，端到端没有验证（有界测试里放不下 60 秒）。
* Web 内容进程崩溃：WebKit 没有公开的杀进程接口，测试直接投递 delegate 回调，不是真实崩溃。

---

## 2. 修改清单

### 新增文件

| 文件 | 作用 |
| --- | --- |
| `Vela/Services/Web/NavigationLog.swift` | 结构化导航日志。只在内存，永不落盘；URL 脱敏后存储（查询参数只记数量，userinfo 和片段丢弃）；无痕模式自然没有可泄漏的持久化数据 |
| `Vela/Features/Web/WebPageErrorView.swift` | 失败界面：原因、失败网址、重新加载、返回上一页、复制网址、返回主页；以及 HTTP 4xx/5xx 的一行提示 `ServerStatusNotice` |
| `Vela/Features/Settings/NavigationDiagnosticsView.swift` | 诊断页：开关、复制诊断信息、清空、逐条记录（事件 / 阶段 / 耗时 / 脱敏地址 / 错误域与错误码 / 当时是否开着拦截和用户脚本） |
| `VelaTests/NavigationTestSupport.swift` | 本地 HTTP 服务器（`NWListener`，只监听回环，带请求计数）+ 生产同构的 `TabManager`/`BrowserWebCoordinator` 组装 |
| `VelaTests/WebNavigationIntegrationTests.swift` | 真实 `WKWebView` 走生产路径的端到端导航测试 |
| `VelaTests/TabLoadStateTests.swift` | 失败分类、加载状态机、日志脱敏 |
| `VelaTests/AdBlockRuleSafetyTests.swift` | 规则语义：不能匹配正常网页、必须匹配广告域名、不能藏掉整页、输出必须是合法正则 |
| `VelaTests/AdBlockContentRuleCompilationTests.swift` | 真的交给 WebKit 编译：整表、逐条、每种形状、白名单例外规则 |
| `VelaTests/PublicWebSmokeTests.swift` | 真实公网 HTTPS/HTTP 冒烟测试 |

### 主要修改

| 文件 | 改了什么 |
| --- | --- |
| `Info.plist` | 增加 `NSAppTransportSecurity` / `NSAllowsArbitraryLoadsInWebContent`（根因 1） |
| `Vela/Core/Models/TabModels.swift` | 拆开两个本来就必须分开的问题：`TabRuntimeState` 只描述 web view 是否存在；新增 `TabLoadState`（idle/requested/provisional/committed/finished/cancelled/failed/crashed）。`lastError: String` 换成 `lastFailure: TabNavigationFailure?`（种类、标题、说明、URL、错误域、错误码、是否可重试），新增 `emptyResponse` / `insecureConnection` 两种失败。新增 `serverStatus`（HTTP 状态，与导航失败区分）和 `navigationSerial`。新增 `needsPageFetch`，把"这个标签页要不要取页面"放到标签页上回答 |
| `Vela/Services/Web/WebViewHost.swift` | **不再发起任何加载**，只剩挂载/卸载和 KVO 观察。删掉 `initialUrl`、`isHome`（唯一调用点传的永远是 false）和 `blankPageHtml` |
| `Vela/Core/Tabs/TabManager.swift` | 加载只有一个入口：`load(url:in:)`；新增 `openTab(url:...)` 把"建标签页"和"发请求"合成一步；`activateTab` 负责把冷标签页的页面取回来（`needsPageFetch`）；新增 `reload(tab:)` / `stopLoading(tab:)`，让状态写入和请求留在同一个地方。`discardWebView` 把状态退回 `idle` 并清掉失败。删掉死代码 `recordVisit` 和 `historyTransitionProvider` |
| `Vela/Services/Web/BrowserWebCoordinator.swift` | 导航状态机与关联。按 `WKNavigation` **对象身份**判断过期回调（WebKit 在 commit / finish / 两个失败回调里给的是同一个对象，URL 比较做不到这件事：同 URL 的两次导航无法区分，重定向还会让 URL 中途变化）。**开始永远赢**；失败和取消只能降级仍在进行中的导航。取消 → `.cancelled`（不显示错误页）；策略中断（102）按取消处理；空文档 → `.emptyResponse`；崩溃 → `.crashed` 且不自动 reload。新增 `didReceiveServerRedirectForProvisionalNavigation` 让地址栏跟上重定向。`decidePolicyFor navigationResponse` 记录主文档 HTTP 状态（非 2xx 不再当失败）。标题为空时问 `document.title`。每次导航事件都写结构化日志 |
| `Vela/UI/AddressBarView.swift` | 解析器给出明确策略：`navigate` / `handOff` / `search` / `rejected(原因)`，无效输入有反馈而不是静默关掉地址栏。`file:` / `data:` / `javascript:` / `blob:` / `about:`（`about:blank` 除外）/ `ftp:` 明确拒绝。`http(s)` 必须有 host（`URL(string:)` 返回对象不等于可用）。修好括号 IPv6。国际化域名带百分号编码兜底 |
| `Vela/Core/AdBlock/AdBlockRuleCompiler.swift` | 去掉 `([^…]|$)`（根因 4）；新增 `isAcceptable`，输出前校验合法性并拒绝非末尾的 `$`，表达不了的规则被丢弃而不是拖垮整表 |
| `Vela/Core/AdBlock/AdBlockEngine.swift` | 删除旧列表改为可容忍；`attachedList` 的赋值和 continuation 恢复放在同一个 main-actor 块里，消除"下一次导航拿不到规则"的竞态 |
| `Vela/App/BrowserShellView.swift` | 失败时渲染 `WebPageErrorView`（保留 web view 供重试）；HTTP 错误状态用一行提示覆盖在页面之上；地址栏提交改为按 `AddressBarResolution` 分支，被拒绝的输入弹窗说明并可直接改为搜索；所有 reload / stop 走 `TabManager` |
| `Vela/App/AppEnvironment.swift`、`Vela/App/VelaApp.swift` | 注入 `NavigationLog`；`handleInboundUrl` 走 `openTab` |
| `Vela/Services/Settings/SettingsService.swift` | 诊断开关单独一份文档（不往 `BrowserPreferences` 里加键，那份文档是整体解码的，加一个键会让所有既有安装的设置归零） |
| `Vela/Core/Models/SearchEngineCatalog.swift` | 搜索词编码去掉 `%`，避免 `100%` 被送去当成 `100`，也避免重复编码 |
| 书签 / 历史 / 主页的导航入口 | 统一改用 `openTab` |
| `README.md`、`BUILD_WITHOUT_MAC.md`、`PORTING.md` | 改掉关于 ATS 和 UA 的错误说法；排障段落指向"设置 ▸ 加载诊断" |

---

## 3. 测试结果

CI 运行 `38864804210`（最后一次改动）——两次作业全绿：

| 项 | 结果 |
| --- | --- |
| 构建（Release，`-sdk iphoneos`，未签名 IPA） | **通过**（`xcodebuild build`，2 分 17 秒） |
| 单元 + 集成测试（iOS 模拟器） | **通过：171 个测试，0 失败**（`Executed 171 tests, with 0 failures (0 unexpected)`） |
| 导航端到端（本地服务器 + 真实 WKWebView） | **通过**，见下表 |
| 公网 HTTPS 冒烟 | **通过** |
| 公网明文 HTTP 冒烟 | **通过**：`http://example.com/ → state=finished status=200` |

修复过程中失败的用例都是真问题，逐条修掉（不是放宽断言）：

| 失败 | 结论 |
| --- | --- |
| `testTheCosmeticRulesHideTheAdSlotAndNotTheContent` | 挖出根因 4 |
| `testAnIPv6LiteralInBracketsUsesHttp` | 挖出 IPv6 解析缺陷 |
| `testAPlainPageLoadsAndReportsItsTitleAndUrl`（标题为空） | 挖出 `WKWebView.title` 竞态 |
| `testAConnectionRefusedFailsWithARefusedReason`（报成 finished） | 挖出空文档被当成成功 |
| `testAnUnresolvableHostFailsWithADnsReason`（种类是 other） | 挖出根因 1（ATS 挡在 DNS 之前） |

有 3 处是**测试自己写错**，已按实际行为修正并写明理由：cosmetic 选择器检查把属性选择器
（`div[data-ad-slot]`）当成不合格；脱敏长度算错 1；被用户停掉的标签页在重新激活时确实会重新取页面
（否则就是永久空白）。

### 端到端覆盖（本地服务器，真实 WKWebView，走生产 `TabManager` + `BrowserWebCoordinator`）

通过：普通 HTML 页面、JS 执行、查询参数、302 重定向、重定向链、404/403/500（**提交并渲染服务器自己的页面，不算导航失败**）、
DNS 失败、连接被拒、停止加载、新导航取代旧导航、跟随链接、`target="_blank"`、mailto 外链、
多标签页隔离、后台标签页加载、回收后重新激活、崩溃回调、广告规则不阻断主文档、
cosmetic 规则隐藏广告位而不动正文、关闭拦截后广告位可见、无痕标签页。

### 未运行 / 环境受限

| 项 | 原因 |
| --- | --- |
| 真机（iPhone）验证 | 只有 CI 模拟器；没有做签名安装到设备 |
| 真实网络超时（60 秒）的端到端 | 有界测试放不下；分类逻辑有单元测试 |
| 真实 Web 内容进程崩溃 | WebKit 无公开接口；测试直接投递回调 |
| 明文 HTTP 重定向到 HTTPS 的端到端 | 本地服务器没有证书，而自签证书应当（也就会）被拒绝——不会为了测试放宽校验。重定向机制本身已覆盖（302 → 采用最终 URL） |
| UI 外观（错误页、诊断页）截图 | 只验证了编译；没有跑起模拟器看界面 |

---

## 4. 核心验收

| 验收项 | 结论 | 依据 |
| --- | --- | --- |
| 地址栏提交有效 URL 后确实发起导航 | 是 | `testAPlainPageLoadsAndReportsItsTitleAndUrl`、`testAPageIsRequestedExactlyOnce`（服务器计数 = 1） |
| 页面成功返回后能显示实际网页内容 | 是 | 本地页面 + JS 读取 DOM；公网 example.com / wikipedia / duckduckgo 均 `finished` 且有标题 |
| 搜索词生成正确的搜索地址 | 是 | 单元测试（中文、空格、`&`、`%`、往返一致）+ 公网 `Bing → status=200 title="vela browser - Search"` |
| 重定向后地址栏与 WebView URL 一致 | 是 | `testARedirectEndsOnTheDestinationUrl`、`testARedirectChainEndsOnTheDestinationUrl` |
| 加载失败时显示正确错误状态 | 是 | 每种失败都映射到具体种类和中文文案；错误页有单元与集成测试 |
| 重试可以重新发起导航 | 是 | `testAFailedTabLoadsAgainAndClearsTheFailure`、`testReloadAfterAFailureIssuesAFreshRequest`（serial 递增） |
| 取消请求后不会永久显示加载中 | 是 | `testStoppingALoadIsNotAFailure` |
| 连续导航不会被旧回调覆盖 | 是 | `testASupersededNavigationDoesNotClobberTheNewerOne` |
| 切换标签页不会串用其他页面状态 | 是 | `testTwoTabsKeepTheirOwnState`、`testATabOpenedInTheBackgroundIsStillFetched` |
| 关闭广告拦截诊断开关不会破坏正常导航 | 是 | `testWithAdBlockingDisabledTheAdSlotIsVisible`（关掉后广告位可见，页面仍 `finished`） |
| 原有功能无回归 | 是 | 原有 30 个用例全部保留并通过，含书签、历史、标签页池、隐私模式 |

---

## 5. 剩余问题

1. **真实设备未验证。** 模拟器通过不等于真机通过（内存压力、ATS 在真机上的行为、WebKit 版本差异）。
   建议：装一次 IPA，按"设置 ▸ 加载诊断"复制一份日志。
2. **超时分类未端到端验证。** 复现方法：把一个 HTTPS 站点配成黑洞地址（如 `https://10.255.255.1/`），
   观察 ~60 秒后是否落到 `.timeout` 并显示"连接超时"。
3. **`WKWebView.title` 竞态是绕过而不是根治。** 现在在标题为空时问 `document.title`，
   代价是每个无标题页面多一次 JS 往返。若 WebKit 修好这个竞态，这段可以删掉。
4. **`$` 锚点被限制在末尾。** `|https://example.com/x|` 这类"整串结尾"规则仍可表达，
   但任何需要在中间使用 `$` 的规则会被丢弃并计入 invalid。`unsupportedRuleCount` 会体现。
5. **后台标签页崩溃不会自动恢复。** 崩溃后标签页停在崩溃态，激活时显示错误页并提供重新载入。
   这是有意的（避免崩溃循环），但如果用户长时间不切回去，标签页会一直是空白页。
6. **UI 未人工检视。** 错误页和诊断页只过了编译器。建议在真机/模拟器上看一眼深色模式和 iPhone SE 宽度。

---

## 6. 最终结论

在**有实际测试证据**的范围内：网页现在能打开，而且是端到端证实的——
本地 HTTP 服务器上的真实 `WKWebView` 导航、以及公网 `https://www.example.com/`、
`https://www.wikipedia.org/`、`https://duckduckgo.com/`、`http://example.com/` 和一次真实的 Bing 搜索，
全部落到 `finished` 并带正确标题；171 个测试 0 失败；Release 构建通过并产出未签名 IPA。

在这之前，"打不开"至少有四个独立原因：明文 HTTP 被 ATS 整体拦截、视图层自己发起加载导致失败即
无限重试、失败没有任何界面、以及一条让 WebKit 拒绝整张规则表的 url-filter。「版本太低」是第五个：
浏览器自称 Safari 17。

没有解决的：真机行为、真实网络超时的端到端、真实进程崩溃的自动恢复。

下一步建议：装一次真机，先打开一个纯 HTTP 站点和一个 HTTPS 站点各一次，再从"设置 ▸ 加载诊断"
复制日志回来——如果还有问题，日志会直接指出是哪一个阶段、哪一个错误域。
