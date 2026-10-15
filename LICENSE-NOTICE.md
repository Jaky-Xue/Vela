# 许可与署名

## 这是什么

Vela 是 **Aira Browser 的修改版本**（derivative work）。

- 上游项目：Aira Browser，<https://github.com/mason173/aira-browser>
- 上游版本：3.7.4
- 上游许可：GNU General Public License v3.0

`LICENSE` 是 GPL-3.0 的完整文本，从上游源码树原样复制。

---

## GPL-3.0 对这个项目意味着什么

### 1. Vela 必须以 GPL-3.0 发布

GPL-3.0 第 5 条：基于受版权保护作品的作品整体必须按同一许可授权。Vela 重写了 Aira 的代码，但保留了它的类型契约、数据库表结构和功能语义——这是衍生作品，不是独立创作。所以：

**Vela 的完整源代码必须在 GPL-3.0 下提供。** 你现在拿到的这份源码就是满足这个条件的载体。

### 2. 分发二进制时必须提供对应源码

GPL-3.0 第 6 条。如果你把编译好的 IPA 发给别人，必须同时（或按第 6(d) 条以书面承诺）提供完整的对应源码，包括你做的任何修改。

自己装在自己的手机上不分发，则不触发这个义务。

### 3. 修改必须标注

GPL-3.0 第 5(a) 条：修改过的文件必须带有显著声明，说明你改过以及改动日期。这个工程是通过重写实现移植的，不是逐文件修改上游文件——上游的 `.ets` 文件一个都没有被改动，而是产生了新的 Swift 文件。所以这个要求主要落在**保留上游署名**上，而不是在每个文件头标注"已修改"。

上游的 `.ets` 文件一个都没有被改动，对应关系因此集中记录在 `PORTING.md` 的《移植映射表》里：每个 Swift 模块对应上游哪个路径、哪些是等价实现、哪些是刻意偏离、哪些根本没有移植。这是署名，也是改动可追溯的依据。`README.md` 和本文件同样载有上游署名，应用内的「关于」页也保留了一节事实性说明。

### 4. 没有专利授权或附加限制

GPL-3.0 第 11 条授予专利许可。Vela 没有添加任何 GPL-3.0 第 7 条禁止的附加限制条款。

---

## 上游许可之外的成分

上游源码树里还包含第三方组件，Vela 没有搬运它们，但如果将来搬运，各自的许可是独立的：

| 组件 | 位置 | 许可 |
|---|---|---|
| Mozilla Readability | `third_party/mozilla-readability` | Apache-2.0 |
| Brave adblock resources | `cpp/rust/aira_adblock_core/resources/brave-resources-v0.13.2.json` | MPL-2.0 |
| cURL | `cpp/third_party/curl` | curl 许可（MIT/X 类） |
| Mbed TLS | `cpp/third_party/mbedtls` | Apache-2.0 |

**Vela 的实际依赖只有系统框架**：SwiftUI、WebKit、SQLite3、LocalAuthentication、QuickLook、UniformTypeIdentifiers。没有引入任何第三方 Swift 包，没有 `Package.swift`，没有 CocoaPods，没有 Carthage。

`third_party/mozilla-readability` 在上游树里**只有 `LICENSE.md` 和 `README.md`，没有脚本文件**——这是 Vela 自己重新实现正文提取的原因（见 `PORTING.md`）。

---

## 商标

上游有 `TRADEMARKS.md`，核心约束是：

> GPL-3.0 适用于受版权保护的源码，但不授予商标权。修改后的分发版本应当使用自己的产品名称、应用标识、签名身份和视觉标识。可以保留许可证和署名规则要求的事实性声明。

按这条，Vela 做了这些：

| | 上游 Aira | Vela |
|---|---|---|
| 产品名称 | Aira | Vela |
| Bundle ID | `org.aira.browser` | `org.vela.browser.ios` |
| 应用图标 | Aira 图标（分层图标资源） | 系统符号，未使用 Aira 图标 |
| 视觉标识 | Aira 配色与品牌 | 自有色板，未使用 Aira 品牌资源 |

**没有**使用 Aira 的名称、logo 或图标作为产品标识。

**有**使用 Aira 名称作事实性描述，例如 "Aira Browser 的 iOS 移植"、"基于 Aira Browser"。这是上游商标政策明确允许的。

如果你要分发 Vela：

- 保留 `README.md`、`PORTING.md` 和本文件里的上游署名
- 不要使用 Aira 的名称或 logo 暗示这是官方版本、或暗示 Aira 项目背书
- 改自己的 Bundle ID 和签名身份（`Vela.xcodeproj` 里的 `PRODUCT_BUNDLE_IDENTIFIER`）

---

## 与 App Store 的冲突（说明，不是建议）

GPL-3.0 与 App Store 的条款存在已知冲突：GPL 第 6 条要求接收者能自由重新分发，而 App Store 的 DRM、签名限制和最终用户许可协议不允许这样做。FSF 的立场是 GPL 软件不能通过 App Store 分发。

除此之外，带用户脚本的浏览器本身也过不了审核（审核指南 2.5.2 禁止下载并执行改变应用功能的代码）。

**结论**：这个移植是一个自用/侧载项目，不是上架项目。

---

## 上游的许可声明

上游仓库 `LICENSE` 文件的开头：

```
                    GNU GENERAL PUBLIC LICENSE
                       Version 3, 29 June 2007
```

完整文本见本项目根目录的 `LICENSE` 文件，共 674 行，与上游逐字节一致。
