//
//  BrowserComponents.swift
//  Vela
//
//  The shared rows, badges, empty states and collapsible sections used by every list screen.
//

import SwiftUI
import UIKit

// MARK: - Rows

/// A reusable row used by the settings, bookmark, history and download lists.
///
/// The same visual row is used by every list screen, so it lives here once.
struct BrowserListRow<Leading: View, Trailing: View>: View {
    @Environment(\.browserPalette) private var palette

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
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            trailing()
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Sheets

/// The bottom sheet detents Vela uses.
enum BrowserSheetDetent {
    static func forContentHeight(_ height: CGFloat) -> PresentationDetent {
        switch height {
        case ..<160: return .height(180)
        case ..<300: return .medium
        default: return .large
        }
    }
}

// MARK: - Badges

/// A compact pill that shows the current privacy mode.
struct PrivacyModeBadge: View {
    var mode: BrowserSessionPrivacyMode

    var body: some View {
        if mode == .private {
            Label("无痕", systemImage: "eyeglasses")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.20), in: Capsule())
                .foregroundStyle(Color.purple)
        }
    }
}

// MARK: - Empty states
/// The one empty-state component. Every list that can be empty uses this, so
/// "no bookmarks", "no history" and "no downloads" cannot drift apart.
///
/// `ContentUnavailableView` rather than a hand-built stack: it already handles
/// Dynamic Type, the icon weight and the centred alignment inside a scroll view.
struct EmptyState: View {
    var systemImage: String
    var title: String
    var message: String
    /// An optional primary action, e.g. "新建标签页" on an empty tab list.
    var actionTitle: String?
    var action: (() -> Void)?

    init(
        systemImage: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Collapsible sections

/// A section header that folds its content away, with the count and the chevron
/// on the trailing edge.
///
/// The surfaces here have more to show than fits, so the header is a control
/// rather than a label: everything below the first fold is one tap away.
struct CollapsibleSectionHeader: View {
    var title: String
    var systemImage: String?
    var count: Int?
    /// An ink override for a header drawn on something other than a palette
    /// surface — the home's custom picture.
    var tint: Color?
    var isExpanded: Bool
    var onToggle: () -> Void

    @Environment(\.browserPalette) private var palette

    init(
        title: String,
        systemImage: String? = nil,
        count: Int? = nil,
        tint: Color? = nil,
        isExpanded: Bool,
        onToggle: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.tint = tint
        self.isExpanded = isExpanded
        self.onToggle = onToggle
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: BrowserSpacing.tight) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                }

                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(palette.controlFill, in: Capsule())
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .foregroundStyle(tint ?? palette.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title)，\($0) 项" } ?? title)
        .accessibilityHint(isExpanded ? "折叠" : "展开")
    }
}

/// A titled block that can be folded away, used by the new-tab surface, the
/// bookmark list and the history list so all three fold the same way.
struct CollapsibleSection<Content: View>: View {
    var title: String
    var systemImage: String?
    var count: Int?
    var tint: Color?
    @Binding var isExpanded: Bool
    var content: () -> Content

    init(
        title: String,
        systemImage: String? = nil,
        count: Int? = nil,
        tint: Color? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.tint = tint
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSpacing.compact) {
            CollapsibleSectionHeader(
                title: title,
                systemImage: systemImage,
                count: count,
                tint: tint,
                isExpanded: isExpanded,
                onToggle: {
                    withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
                }
            )

            if isExpanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
