//
//  BrowserComponents.swift
//  Vela
//
//  The empty states and collapsible sections used by every list screen.
//

import SwiftUI

// MARK: - Empty states
/// The one empty-state component. Every list that can be empty uses this, so
/// "no bookmarks", "no history" and "no downloads" cannot drift apart.
///
/// `ContentUnavailableView` rather than a hand-built stack: it already handles
/// Dynamic Type and the centred alignment inside a scroll view. The icon sits
/// on a soft accent badge instead of standing alone as a grey glyph — an empty
/// surface is the first thing a new user sees, and one lit element gives the
/// space a subject without adding a sentence.
struct EmptyState: View {
    var systemImage: String
    var title: String
    /// The one supporting line. Optional: an empty state whose title already
    /// says everything (or whose action button does) does not need to explain
    /// itself twice.
    var message: String
    /// An optional primary action, e.g. "新建标签页" on an empty tab list.
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.browserPalette) private var palette

    init(
        systemImage: String,
        title: String,
        message: String = "",
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
            VStack(spacing: BrowserSpacing.compact + 2) {
                AccentGlyphBadge(systemImage: systemImage)

                Text(title)
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
            }
        } description: {
            if !message.isEmpty {
                Text(message)
                    .foregroundStyle(palette.secondaryText)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
            }
        }
    }
}

/// The icon badge the empty and error surfaces share: a light glyph on a soft
/// accent disc.
///
/// One lit element gives an otherwise empty surface a subject, and reusing it
/// is what keeps "no downloads", "connection failed" and the blank start page
/// reading as one family rather than three unrelated illustrations.
struct AccentGlyphBadge: View {
    var systemImage: String
    var size: CGFloat = 68
    var iconSize: CGFloat = 30

    @Environment(\.browserPalette) private var palette

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: .light))
            .foregroundStyle(palette.accent)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                palette.accent.opacity(0.20),
                                palette.accent.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                Circle()
                    .strokeBorder(palette.accent.opacity(0.18), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
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
