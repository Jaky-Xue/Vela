//
//  Theme.swift
//  Vela
//
//  Shared visual tokens. Ported from Aira's theme layer —
//  `core/theme/`, `features/theme/palettes/` and
//  `BrowserModalPresentationTokens.ets`, `BrowserTabsOverviewVisualTokens.ets`
//  (Aira Browser 3.7.4, GPL-3.0).
//
//  Aira ships a named-palette catalogue the user can pick from. Vela keeps the
//  same structure — a palette is a value, not a set of asset-catalogue colours —
//  because that is what lets a palette be swapped at runtime without a relaunch,
//  which is a promise the settings screen makes to the user.
//

import SwiftUI
import UIKit

/// A colour palette. Ported from the `features/theme/palettes/` entries.
struct BrowserPalette: Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    /// The accent used for selection, links and the progress bar.
    var accent: Color
    /// The chrome background: the address bar and the toolbar.
    var chromeBackground: Color
    /// Page background behind the web content.
    var surface: Color

    /// The palettes Aira ships, reduced to the four that read well at both
    /// Dynamic Type extremes.
    static let all: [BrowserPalette] = [
        BrowserPalette(
            id: "default",
            displayName: "默认",
            accent: Color(red: 0.15, green: 0.45, blue: 0.95),
            chromeBackground: Color(.secondarySystemBackground),
            surface: Color(.systemBackground)
        ),
        BrowserPalette(
            id: "morandi",
            displayName: "莫兰迪",
            accent: Color(red: 0.45, green: 0.40, blue: 0.38),
            chromeBackground: Color(red: 0.94, green: 0.93, blue: 0.91),
            surface: Color(red: 0.97, green: 0.96, blue: 0.95)
        ),
        BrowserPalette(
            id: "ocean",
            displayName: "深海",
            accent: Color(red: 0.10, green: 0.42, blue: 0.52),
            chromeBackground: Color(red: 0.90, green: 0.94, blue: 0.95),
            surface: Color(red: 0.96, green: 0.98, blue: 0.98)
        ),
        BrowserPalette(
            id: "crimson",
            displayName: "朱砂",
            accent: Color(red: 0.72, green: 0.24, blue: 0.20),
            chromeBackground: Color(red: 0.96, green: 0.93, blue: 0.92),
            surface: Color(red: 0.99, green: 0.97, blue: 0.97)
        )
    ]

    static let `default` = all[0]
}

/// Layout metrics shared by the chrome. Ported from
/// `BrowserBottomAddressPanelMetrics.ets` and `BrowserLayoutTokens`.
enum BrowserMetrics {
    /// The bottom address panel, which is the primary chrome on a phone.
    static let addressBarHeight: CGFloat = 44
    static let toolbarHeight: CGFloat = 44
    /// Ported from the max width in `CenteredDialogWidthViewModel`.
    static let dialogMaxWidth: CGFloat = 420
    /// The tab strip's cell size on a large screen.
    static let tabStripItemWidth: CGFloat = 200
    static let tabStripItemHeight: CGFloat = 34
    /// How far the toolbar slides away when the page scrolls down. Ported from
    /// `BrowserBottomChromeScrollCoordinator`'s collapse distance.
    static let toolbarCollapseDistance: CGFloat = 80
}

/// Environment value carrying the active palette, so a view deep in the tree
/// does not have to thread it through every initialiser.
private struct BrowserPaletteKey: EnvironmentKey {
    static let defaultValue = BrowserPalette.default
}

extension EnvironmentValues {
    var browserPalette: BrowserPalette {
        get { self[BrowserPaletteKey.self] }
        set { self[BrowserPaletteKey.self] = newValue }
    }
}

/// A reusable row used by the settings, bookmark, history and download lists.
///
/// Aira has a separate view model per list screen; the visual row is the same in
/// all of them, so it lives here once.
struct BrowserListRow<Leading: View, Trailing: View>: View {
    var title: String
    var subtitle: String?
    var detail: String?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        detail: String? = nil,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            trailing()
        }
        .contentShape(Rectangle())
    }
}

/// A favicon or a letter placeholder.
///
/// Aira renders a site icon from its `site_icons` cache. On iOS a favicon is not
/// readable from outside the page, so Vela shows the host's first letter in a
/// deterministic colour until a real icon can be fetched. The colour is derived
/// from the host so the same site always gets the same swatch.
struct SiteIconView: View {
    var host: String
    var size: CGFloat = 28
    var faviconUrl: String?

    var body: some View {
        Group {
            if let faviconUrl, let url = URL(string: faviconUrl) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            color
            Text(initial)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var initial: String {
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return String(trimmed.first.map(String.init) ?? "?").uppercased()
    }

    /// A stable hue from the host. FNV-1a rather than `hashValue`, which is
    /// seeded per process and would make a site change colour between launches.
    private var color: Color {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in host.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.45, brightness: 0.72)
    }
}

/// The bottom sheet detents Vela uses. Ported from
/// `BrowserSheetResponsiveLayoutViewModel`, which chooses a detent from the
/// content height so a two-row sheet does not open half-screen.
enum BrowserSheetDetent {
    static func forContentHeight(_ height: CGFloat) -> PresentationDetent {
        switch height {
        case ..<160: return .height(180)
        case ..<300: return .medium
        default: return .large
        }
    }
}

/// A compact pill that shows the current privacy mode. Ported from the private
/// indicator in `BrowserShellViewModel`.
struct PrivacyModeBadge: View {
    var mode: BrowserSessionPrivacyMode

    var body: some View {
        if mode == .private {
            Label("无痕", systemImage: "eyeglasses")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.18), in: Capsule())
                .foregroundStyle(.purple)
        }
    }
}

/// The empty-state view used by the bookmark, history and download lists.
struct BrowserEmptyState: View {
    var systemImage: String
    var title: String
    var message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}
