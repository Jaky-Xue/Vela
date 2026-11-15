//
//  SettingsIconStyle.swift
//  Vela
//
//  The colour, symbol and search words each settings destination owns.
//
//  The root list is a map of destinations, and colour is what makes one of
//  them findable at a glance. The rows used to wear a monochrome tint of the
//  palette's accent, which made every screen look alike; a saturated tile with
//  a white glyph is the same language the system's own settings screens use.
//  Every gradient stop here keeps a white glyph at 4.5:1 in both appearances,
//  so the tiles read the same under every palette.
//

import SwiftUI

/// A settings row's icon: a white glyph on a saturated gradient tile.
struct SettingsRowIcon: View {
    var symbolName: String
    var topHex: UInt32
    var bottomHex: UInt32
    /// Follow the palette's icon character: filled for the solid palettes,
    /// outlined for the ones that ask for line symbols.
    var filled: Bool = true
    var size: CGFloat = 34

    private var cornerRadius: CGFloat { (size * 0.27).rounded() }

    var body: some View {
        Image(systemName: symbolName)
            .symbolVariant(filled ? .fill : .none)
            .font(.system(size: size * 0.44, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [Color(velaHex: topHex), Color(velaHex: bottomHex)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}

extension SettingsDestination {
    /// The row's name. The root list, the search results and the accessibility
    /// label all read it from here rather than restating it per row.
    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .toolbar: return "工具栏"
        case .menuPanel: return "菜单面板"
        case .downloads: return "下载"
        case .searchEngine: return "搜索引擎"
        case .userAgent: return "网页标识"
        case .userScripts: return "用户脚本"
        case .contentBlocker: return "广告拦截"
        case .elementHide: return "隐藏的元素"
        case .passwords: return "密码与保险箱"
        case .privateBrowsing: return "无痕模式"
        case .sitePermissions: return "网站权限"
        case .externalNavigation: return "外部应用跳转"
        case .webrtc: return "WebRTC 泄露防护"
        case .clearData: return "清除浏览数据"
        case .dataTransfer: return "导入与导出"
        case .about: return "关于 Vela"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .toolbar: return "dock.rectangle"
        case .menuPanel: return "square.grid.2x2"
        case .downloads: return "arrow.down.circle"
        case .searchEngine: return "magnifyingglass"
        case .userAgent: return "safari"
        case .userScripts: return "curlybraces"
        case .contentBlocker: return "shield"
        case .elementHide: return "eye.slash"
        case .passwords: return "key.fill"
        case .privateBrowsing: return "eyeglasses"
        case .sitePermissions: return "lock.shield"
        case .externalNavigation: return "arrow.up.forward.app"
        case .webrtc: return "shield.lefthalf.filled"
        case .clearData: return "trash"
        case .dataTransfer: return "arrow.up.arrow.down.circle"
        case .about: return "info.circle"
        }
    }

    /// The lighter and darker ends of the icon's gradient.
    var iconTopHex: UInt32 {
        switch self {
        case .general: return 0x6E737A
        case .appearance: return 0x8B4CDB
        case .toolbar: return 0x0E7A82
        case .menuPanel: return 0x4C57C9
        case .downloads: return 0x2C6FE0
        case .searchEngine: return 0x1E6FAE
        case .userAgent: return 0xA85812
        case .userScripts: return 0x2E7D4F
        case .contentBlocker: return 0x1B7C4E
        case .elementHide: return 0x3C7288
        case .passwords: return 0x94660A
        case .privateBrowsing: return 0x6A5BD9
        case .sitePermissions: return 0x2B62C4
        case .externalNavigation: return 0xC2453A
        case .webrtc: return 0x177A6B
        case .clearData: return 0xC0392B
        case .dataTransfer: return 0x327A36
        case .about: return 0x4A6A9C
        }
    }

    var iconBottomHex: UInt32 {
        switch self {
        case .general: return 0x585C63
        case .appearance: return 0x7137B8
        case .toolbar: return 0x0B5F66
        case .menuPanel: return 0x3B45A4
        case .downloads: return 0x2257B4
        case .searchEngine: return 0x175887
        case .userAgent: return 0x88440B
        case .userScripts: return 0x24633E
        case .contentBlocker: return 0x156240
        case .elementHide: return 0x2F5A6B
        case .passwords: return 0x754F07
        case .privateBrowsing: return 0x5447AE
        case .sitePermissions: return 0x224E9C
        case .externalNavigation: return 0x9C372E
        case .webrtc: return 0x125F54
        case .clearData: return 0x992D22
        case .dataTransfer: return 0x28612C
        case .about: return 0x3B557D
        }
    }

    /// Words a search can match besides the row's own name: what the screen is
    /// called elsewhere in the app, and the English name of the feature.
    var searchKeywords: String {
        switch self {
        case .general:
            return "通用 基础 启动 默认 general startup basic"
        case .appearance:
            return "外观 主题 配色 颜色 深浅色 夜间 背景 图标 字体 theme appearance palette color"
        case .toolbar:
            return "工具栏 地址栏 底部 顶部 按钮 toolbar bar"
        case .menuPanel:
            return "菜单 面板 排序 快捷方式 menu panel shortcut"
        case .downloads:
            return "下载 文件 离线 download offline file"
        case .searchEngine:
            return "搜索引擎 默认 百度 必应 谷歌 search engine"
        case .userAgent:
            return "网页标识 UA 标识 桌面版 手机版 桌面网站 user agent"
        case .userScripts:
            return "用户脚本 脚本 javascript script userscript"
        case .contentBlocker:
            return "广告 拦截 屏蔽 规则 过滤 adblock block filter rule"
        case .elementHide:
            return "隐藏 元素 广告 屏蔽 element hide"
        case .passwords:
            return "密码 保险箱 自动填充 password vault autofill"
        case .privateBrowsing:
            return "无痕 隐私 私密 隐身 验证 锁定 private incognito"
        case .sitePermissions:
            return "网站 权限 摄像头 麦克风 位置 通知 permission camera microphone location"
        case .externalNavigation:
            return "外部 应用 跳转 链接 打开 external app link scheme"
        case .webrtc:
            return "webrtc 泄露 防护 地址 ip leak protection"
        case .clearData:
            return "清除 数据 缓存 历史 记录 全部 clear data cache history cookie"
        case .dataTransfer:
            return "导入 导出 备份 迁移 数据 transfer import export backup"
        case .about:
            return "关于 版本 信息 许可 开源 about version license"
        }
    }
}
