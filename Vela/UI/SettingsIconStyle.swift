//
//  SettingsIconStyle.swift
//  Vela
//
//  The colour, symbol and search words each settings destination owns.
//
//  The root list is a map of destinations, and colour is what makes one of
//  them findable at a glance. The rows used to wear a monochrome tint of the
//  palette's accent, which made every screen look alike; a vivid tile with a
//  white glyph is the same language the system's own settings screens use.
//  The hues are deliberately bright rather than darkened for contrast: the
//  row's name carries the meaning and the tile is the landmark, so the tile
//  may sit at the 2–4:1 Apple's own Settings icons do.
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
    var size: CGFloat = 36

    private var cornerRadius: CGFloat { (size * 0.25).rounded() }

    var body: some View {
        Image(systemName: symbolName)
            .symbolVariant(filled ? .fill : .none)
            .font(.system(size: size * 0.46, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [Color(velaHex: topHex), Color(velaHex: bottomHex)],
                    startPoint: .top,
                    endPoint: .bottom
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
        case .googleAccounts: return "Google 账号"
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
        case .googleAccounts: return "person.crop.circle"
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
        case .googleAccounts: return 0x4285F4
        case .general: return 0x8E8E93
        case .appearance: return 0xC936F0
        case .toolbar: return 0x21C7E8
        case .menuPanel: return 0x6C5CE7
        case .downloads: return 0x0A7BF5
        case .searchEngine: return 0x18A0F8
        case .userAgent: return 0xF5A000
        case .userScripts: return 0x2BC35B
        case .contentBlocker: return 0x12B98A
        case .elementHide: return 0xF0509A
        case .passwords: return 0xF5B301
        case .privateBrowsing: return 0x9B5DE5
        case .sitePermissions: return 0x2F7BF6
        case .externalNavigation: return 0xF5413A
        case .webrtc: return 0x0FA3B1
        case .clearData: return 0xE5342C
        case .dataTransfer: return 0x2BB673
        case .about: return 0x5A7FD0
        }
    }

    var iconBottomHex: UInt32 {
        switch self {
        case .googleAccounts: return 0x1A73E8
        case .general: return 0x6C6C72
        case .appearance: return 0xA21CD6
        case .toolbar: return 0x0FA8CC
        case .menuPanel: return 0x4F41C8
        case .downloads: return 0x0060D2
        case .searchEngine: return 0x0B7FD1
        case .userAgent: return 0xD07E00
        case .userScripts: return 0x1AA046
        case .contentBlocker: return 0x0A946C
        case .elementHide: return 0xD12C78
        case .passwords: return 0xD29400
        case .privateBrowsing: return 0x7D3FC8
        case .sitePermissions: return 0x1B5FD0
        case .externalNavigation: return 0xD32720
        case .webrtc: return 0x0A8290
        case .clearData: return 0xC4241D
        case .dataTransfer: return 0x1A935A
        case .about: return 0x3F62AC
        }
    }

    /// Words a search can match besides the row's own name: what the screen is
    /// called elsewhere in the app, and the English name of the feature.
    var searchKeywords: String {
        switch self {
        case .googleAccounts:
            return "google 谷歌 账号 账户 登录 登陆 account login gmail"
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
