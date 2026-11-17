# Vela 4.0.72 更新说明

4.0 / Build 72，数据库 schema 14，最低 iOS 17。工程格式要求 Xcode 16，本轮交付 CI 使用 macos-26 与 iOS 26 SDK。发布包是未签名 IPA，安装时用自己的 Apple ID 签名。

## 设置新增「账号 ▸ 登录」

设置根页最上方新增「账号」分组，一项「登录」，行尾显示已添加数量与哪些服务商处于登录状态。Google 与 Apple 在同一个页面里统一管理：

**浏览器中的登录**
- Google、Apple 各一行，显示「已登录 / 未登录」。判断依据是浏览器自己的 Cookie（只读 Cookie 名称，不读值）；账号地址本来就不写在 Cookie 里，所以这里不会编造一个地址。
- 页面写明：登录在服务商自己的页面完成，Vela 不保存密码，也不上传这里列出的账号。

**已添加的账号**
- 一个统一列表：每行带服务商标识（Google / Apple）、邮箱与备注。点按打开该服务商的账号页（Google：我的账号；Apple：account.apple.com）；长按可移除。
- 「添加账号」里选服务商、填邮箱与备注。同一个邮箱在不同服务商是两条账号（Gmail 与 Apple ID 是两次登录）；同一服务商同一个邮箱只保留一行，再次添加只更新备注。
- 只校验地址形状，不向服务商验证——这是一份本机标签，不是凭证。

**登录与退出**
- 「登录 Google」「登录 Apple」分别在新标签页打开官方登录页，登录后回到设置，状态行会更新。
- 「退出所有账号」清除 Google（google.com、accounts.google.com、youtube.com、googleapis.com、gstatic.com 等）与 Apple（apple.com、appleid.apple.com、idmsa.apple.com、account.apple.com、icloud.com）站点的**全部网站数据**（Cookie、本地存储、缓存），并清空本机账号列表。需要确认，不能撤销；不做「只清一个域名」的折中，否则用户会在看不见的地方仍然登录着。

## 说明与边界

- 没有接入 Google 或 Apple 的登录 SDK，也没有 OAuth 客户端：应用内不会替用户拿令牌，也不接触密码。登录就是浏览器打开服务商的登录页。
- 账号列表只存在本机的 `UserDefaults`，不参与 iCloud 同步，也不进入「导入与导出」。

## 验证

- 新增 `WebAccountServiceTests`：地址归一化、同服务商去重并更新备注、不同服务商的同一地址是两条、非法地址拒绝、重启后保留、删除只影响一条、两个服务商的登录页与域名各自正确。
- CI 仍需在 iPhone 与 iPad 模拟器上跑完整 XCTest 并构建 Release。
- **真机未验证**：退出后 Google / Apple 站点是否确实显示为未登录、登录后状态行的刷新时机。
