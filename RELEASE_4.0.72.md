# Vela 4.0.72 更新说明

4.0 / Build 72，数据库 schema 14，最低 iOS 17。工程格式要求 Xcode 16，本轮交付 CI 使用 macos-26 与 iOS 26 SDK。发布包是未签名 IPA，安装时用自己的 Apple ID 签名。

## 设置新增「Google 账号」

设置根页最上方新增「账号」分组，第一项是 Google 账号（行尾显示已添加数量与是否已登录）。

**浏览器中的 Google 登录状态**
- 直接从浏览器自己的 Cookie 判断是否已登录 Google（只读 Cookie 名称，不读取值，也不读取账号地址——地址本来就不在 Cookie 里）。
- 页面写明：登录在 Google 自己的页面完成，Vela 不保存密码，也不上传这里列出的账号。

**已添加的账号**
- 本机记录「邮箱 + 备注」，一键打开「我的 Google 账号」；长按可移除。同一个地址再次添加只会更新备注，不会出现两行。
- 添加时只校验地址形状，不会向 Google 请求验证——这是一份本机标签，不是凭证。列表不随登录状态自动填充，因为地址拿不到。

**登录与退出**
- 「在新标签页登录 Google」打开 Google 官方登录页（`accounts.google.com`），登录后回到设置，上面的状态会更新。
- 「退出所有 Google 账号」清除 `google.com`、`accounts.google.com`、`youtube.com`、`googleapis.com`、`gstatic.com` 等 Google 站点的**全部网站数据**（Cookie、本地存储、缓存），并清空本机账号列表。需要确认，不能撤销；不做「只清一个域名」的折中，否则用户会在看不见的地方仍然登录着。

## 说明与边界

- 没有接入 Google 登录 SDK，也没有 OAuth 客户端：应用内不会替用户拿 Google 令牌，也不接触密码。登录就是浏览器打开 Google 的登录页。
- 账号列表只存在本机的 `UserDefaults`，不参与 iCloud 同步，也不进入「导入与导出」。

## 验证

- 新增 `GoogleAccountServiceTests`：地址归一化、同址去重并更新备注、非法地址拒绝、重启后保留、删除只影响一条。
- CI 仍需在 iPhone 与 iPad 模拟器上跑完整 XCTest 并构建 Release。
- **真机未验证**：退出后 Google 站点是否确实显示为未登录、登录后状态行的刷新时机。
