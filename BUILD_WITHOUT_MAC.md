# 没有 Mac 怎么把 Vela 装到 iPhone 上

iOS 应用**只能在 macOS 上编译**——这是苹果的工具链约束，没有替代方案。但"编译"和"签名安装"是两件事，可以分开解决：

```
GitHub Actions 的 macOS 机器        →   编译出未签名的 IPA
你的 Windows 电脑 + 侧载工具        →   用你的 Apple ID 签名并装进 iPhone
```

这条路完全可行，而且你机器上已经有 [Sideloadly](https://sideloadly.io/)（`D:\` 下那套 iOS 侧载工具链），少了装工具的步骤。

---

## 路线 A：GitHub Actions + Sideloadly（推荐）

### 第一步：拿到未签名的 IPA

仓库里已经有现成的工作流：`.github/workflows/build-ios.yml`。

1. 把 `VelaBrowserIOS/` 推到一个 GitHub 仓库

   ```bash
   cd G:/ClaudeWork/VelaBrowserIOS
   git init
   git add .
   git commit -m "Vela: Aira Browser iOS port"
   git remote add origin https://github.com/<你的用户名>/<仓库名>.git
   git push -u origin main
   ```

2. 打开仓库的 **Actions** 标签页 → 左侧选 **Build unsigned IPA** → 右侧 **Run workflow**
3. 等 5～10 分钟，构建完成后在这一次运行的页面底部下载 **Vela-unsigned-ipa** 这个 artifact，解压得到 `Vela-unsigned.ipa`

> **免费额度**：公开仓库的 macOS runner 完全免费。私有仓库用免费账户的 2000 分钟/月，但 macOS 按 **10 倍** 计费——也就是一次 6 分钟的构建吃掉 60 分钟额度，一个月大约能跑 33 次。够个人用，但别没事就点。

工作流里 `runs-on: macos-15` 是有意选的：工程用的是 Xcode 16 的文件系统同步组格式，更早的 Xcode 打不开。

### 第二步：用 Sideloadly 装到 iPhone

1. **先确认 iTunes 装对了版本**。Sideloadly 在 Windows 上需要 Apple 的设备驱动，必须是 [apple.com 官网下载的 iTunes](https://www.apple.com/itunes/download/win64)，**不能是 Microsoft Store 版本**——Store 版是 UWP 打包的，不带 Sideloadly 需要的那套驱动。装好后至少打开一次、连一次手机确认能识别。

   （只装 iCloud 也可以，如果已经装了 iCloud 官网版就跳过这步。）

2. 打开 Sideloadly，**不要**连手机之前就启动它。顺序是：先插上 iPhone → 解锁 → 信任这台电脑 → 再开 Sideloadly。

3. 把 `Vela-unsigned.ipa` 拖进 Sideloadly 窗口，或者点 IPA 图标选择它。

4. **Apple ID** 一栏填你的 Apple ID。

   - **免费账号**：能装，但证书 **7 天过期**，而且最多同时装 3 个自签应用（Vela 占一个名额）
   - **付费开发者账号**（$99/年）：证书 1 年有效

5. 点 **Start**。会弹出输入 Apple ID 密码的对话框（Sideloadly 拿它去苹果服务器换签名证书，**不是**发给 Vela 的作者，这是它自己的机制）。

6. 手机端会提示"信任此开发者"，去 **设置 ▸ 通用 ▸ VPN 与设备管理** 里信任你的 Apple ID 证书。

7. 回主屏幕，Vela 的图标就在那里。

### 关于 7 天过期

免费账号的签名 7 天后失效，应用会打不开（图标还在，点开闪退）。重新签名有两种方法：

- **手动**：重新跑一次上面第二步（IPA 文件留着，不用重新构建）
- **自动**：装 [AltStore](https://altstore.io/)，用它的 AltServer 在 Windows 上做后台续签。代价是电脑要定期开机、和手机在同一 Wi-Fi 下

如果只是自己用，手动重签够用。

---

## 路线 B：租云 Mac

按小时租一台真的 Mac，用 Xcode 图形界面。

| 服务 | 大致价格 | 说明 |
|---|---|---|
| [MacinCloud](https://www.macincloud.com/) | 约 $1/小时起，有月付档 | 最常见的选择，按小时或按月 |
| [MacStadium](https://www.macstadium.com/) | 偏贵，面向团队 | 性能好，配置麻烦一点 |
| AWS EC2 `mac2.metal` | 约 $0.65/小时起 | 需要 AWS 账号，按秒计费但最少 24 小时 |

租到之后的操作和 `README.md` 里写的一样：`open Vela.xcodeproj` → 选 Team → ⌘R。云 Mac 通常不能直接插 iPhone，所以产出的是 IPA，还是要回到路线 A 的第二步用 Sideloadly 装。

**不建议**在云 Mac 上跑模拟器截图验证：延迟会让这件事非常难受，而真机装上去试更快。

---

## 路线 C：借一台 Mac

只要对方的 Mac 能装 Xcode 16+：

1. 把 `VelaBrowserIOS/` 拷过去
2. `open Vela.xcodeproj`
3. 用自己的 Apple ID 登录 Xcode（Settings ▸ Accounts）
4. 选 target → Signing & Capabilities → 勾 Automatically manage signing → Team 选自己的个人团队
5. Product ▸ Archive → Distribute App ▸ Custom ▸ Development 导出 IPA
6. 拿回来用 Sideloadly 装

10 分钟能做完。如果身边有 Mac 用户，这是最省事的路。

---

## 装上去之后可能遇到的事

**闪退**：先看是不是签名过期。免费账号 7 天是硬限制。

**"Unable to install"**：检查 iPhone 上的开发者模式。iOS 16+ 需要手动开：**设置 ▸ 隐私与安全性 ▸ 开发者模式**，打开后手机会重启。

**Sideloadly 卡在 "Connecting"**：多半是 iTunes 版本问题，或者手机上没点"信任"。拔插一次，注意手机上弹出的对话框要点信任。

**装上了但网页打不开**：检查手机能否正常上网。Vela 没有引入 `NSAllowsArbitraryLoads`，所以纯 HTTP 站点在 WebKit 的默认策略下可能被拦——这是有意的，和 Safari 行为一致。

**编译失败**：先看 Actions 的构建日志。如果报的是 SDK/API 不存在（比如 `WKDownload.progress`），说明 runner 上的 Xcode 比预期旧，把工作流里的 `macos-15` 改成更新的镜像再试。

---

## 关于上架 App Store

**不要指望这条路**。带用户脚本的浏览器基本过不了审核——App Store 审核指南 2.5.2 禁止应用下载并执行会改变应用功能的代码，用户脚本正好是这件事。这也是为什么 iOS 上所有带用户脚本的浏览器（Stay、Userscripts）都只能在 App Store 上以受限形式存在，完整功能版本走侧载。

再加上 GPL-3.0 与 App Store 的条款本身就有冲突（GPL 要求用户能自由重新分发，App Store 的 DRM 和签名限制与之矛盾），这个移植本质上就是一个自用项目。
