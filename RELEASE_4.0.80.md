# Vela 4.0.80 更新说明

4.0 / Build 80，最低 iOS 17。

## 登录小窗：把「不注入脚本」变成可验证的约定

- 登录窗的 `WKWebViewConfiguration` 收拢到 `LoginWebConfiguration.make()`：只注入外观样式表，没有用户脚本、没有 GM 桥、没有页面脚本桥。
- 新增 `LoginWebConfigurationTests` 守住这条线：只有一个脚本且与外观脚本一致、使用浏览器默认的 cookie 库、只附加 Safari 尾巴而不覆盖标识。
- 行为与 4.0.79 相同，没有功能性改动。

## 脚本与标识

- 自动标识保持 WebKit 自己的标识加 Safari 尾巴，iPhone 与 iPad 两种模式都不写自定义 User-Agent；两种模式下脚本走同一条注入路径。
- 沉浸式翻译在 iPad 上的真机验证仍待确认（4.0.79 修复了 77 的自定义 Mac 标识）。
