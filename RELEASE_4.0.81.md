# Vela 4.0.81 更新说明

4.0 / Build 81，最低 iOS 17。行为与 4.0.79 相同，只修测试。

## 测试修正

- iPad 的自动标识不再写自定义 User-Agent 之后，`testTheIdentifierIsSafarisOnThisDevice`
  仍在断言手机的尾巴：桌面页应带 `Version/27.2 Safari/605.1.15`，手机页带
  `Version/27.2 Mobile/15E148 Safari/604.1`。断言改为跟随设备判定。
- 同步修正两处过时注释。

## 交付内容（与 4.0.79 一致）

- 网页标识：iPad 自动标识回到 WebKit 自己的标识 + Safari 尾巴，修复沉浸式翻译在 iPad 不出入口；版本号仍取最新。
- 登录小窗：键盘改为滚动内边距，不再顶页面；登录页只注入外观样式表（`LoginWebConfigurationTests` 守住）。
- 活跃热力图：圆角正方形块。
