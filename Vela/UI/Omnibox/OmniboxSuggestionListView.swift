//
//  OmniboxSuggestionListView.swift
//  Vela
//
//  The omnibox suggestion card.
//
//  The list floats over the page rather than pushing the document down, which is
//  what the iOS omnibox is expected to look like. That is why this file owns its
//  own height budget, its own material and its own disclosure state instead of
//  inheriting them from a layout parent.
//
//  Three behaviours here are called out where they live, because none is implied
//  by the rest of the design: per-section disclosure, long-press delete, and the
//  pop-up engine switcher.
//

import SwiftUI

struct OmniboxSuggestionListView: View {
    var viewModel: OmniboxViewModel
    /// The tallest the card may grow, in points. Injected rather than read from
    /// `UIScreen`, because the shell already knows its own size and a screen
    /// measurement would be wrong inside a sheet on iPad.
    var maxHeight: CGFloat

    @Environment(\.browserPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    /// Scaled metrics rather than constants, because the card's height budget is
    /// derived from the row count: if the rows grow with Dynamic Type and the
    /// budget does not, the last row is always half cut off.
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = BrowserMetrics.omniboxRowHeight
    @ScaledMetric(relativeTo: .subheadline) private var headerHeight: CGFloat = BrowserMetrics.omniboxHeaderHeight

    var body: some View {
        if viewModel.groups.isEmpty && viewModel.clipboardHint == nil {
            // Nothing to offer and nothing to paste: an empty card would be a
            // grey rectangle covering the page for no reason.
            EmptyView()
        } else {
            card
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            if let hint = viewModel.clipboardHint {
                pasteRow(hint)
                separator
            }

            if !viewModel.groups.isEmpty {
                suggestionList
            }
        }
        .browserCard(
            material: .regularMaterial,
            radius: BrowserRadius.card,
            elevation: .card,
            tint: palette.card.opacity(colorScheme == .dark ? 0.55 : 0.35)
        )
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sections

    private var suggestionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(viewModel.groups) { group in
                        Section {
                            if !viewModel.isCollapsed(group.section) {
                                ForEach(group.suggestions) { suggestion in
                                    row(suggestion)
                                        .id(suggestion.id)
                                        .background(rowBackground(for: suggestion))

                                    if !(group.id == viewModel.groups.last?.id
                                            && suggestion.id == group.suggestions.last?.id) {
                                        separator
                                    }
                                }
                            }
                        } header: {
                            sectionHeader(group)
                        }
                    }
                }
            }
            // The card takes exactly the height its content needs, capped at
            // the ceiling the shell proposes: a short list gets a short card
            // and a long one scrolls. Nothing about the height is modelled,
            // so nothing can drift out from under the card's own edge — which
            // is what the List this replaced kept doing, its row arithmetic
            // losing a few points on every surface and slicing the last row.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: maxHeight, alignment: .top)
            .scrollIndicators(.visible)
            .onChange(of: viewModel.highlightedId) { _, id in
                // Keyboard navigation can walk past the card's edge, so the
                // highlighted row is always pulled into view.
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ suggestion: OmniboxSuggestion) -> some View {
        let content = Button {
            viewModel.select(suggestion)
        } label: {
            OmniboxSuggestionRow(
                suggestion: suggestion,
                query: viewModel.text,
                isHighlighted: viewModel.highlightedId == suggestion.id,
                rowHeight: rowHeight
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())

        // Long-press menus: re-run the query elsewhere on a search row, delete
        // on a row that came from stored history. (The List this card grew out
        // of offered swipe-to-delete; on the self-sizing stack the long-press
        // menu carries it instead.)
        if suggestion.section.supportsEngineSwitch, viewModel.availableEngines.count > 1 {
            content.contextMenu {
                engineMenu(for: suggestion)
                if suggestion.section.isDeletable {
                    Divider()
                    deleteButton(for: suggestion)
                }
            }
        } else if suggestion.section.isDeletable {
            content.contextMenu {
                deleteButton(for: suggestion)
            }
        } else {
            content
        }
    }

    private func deleteButton(for suggestion: OmniboxSuggestion) -> some View {
        Button(role: .destructive) {
            withAnimation(.easeOut(duration: 0.2)) {
                viewModel.delete(suggestion)
            }
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func engineMenu(for suggestion: OmniboxSuggestion) -> some View {
        ForEach(viewModel.availableEngines) { engine in
            Button {
                viewModel.switchEngine(to: engine)
            } label: {
                if engine.name == suggestion.accessoryText {
                    Label(engine.name, systemImage: "checkmark")
                } else {
                    Text(engine.name)
                }
            }
        }
    }

    private func rowBackground(for suggestion: OmniboxSuggestion) -> some View {
        Group {
            if viewModel.highlightedId == suggestion.id {
                palette.rowHighlight
            } else {
                Color.clear
            }
        }
    }

    // MARK: - Header

    private func sectionHeader(_ group: OmniboxSuggestionGroup) -> some View {
        let collapsed = viewModel.isCollapsed(group.section)
        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                viewModel.toggle(group.section)
            }
        } label: {
            HStack(spacing: BrowserSpacing.tight) {
                Image(systemName: group.section.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)

                Text(group.section.title)
                    .font(.system(size: 12, weight: .semibold))

                Text("\(group.count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(palette.controlFill, in: Capsule())

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            .foregroundStyle(palette.secondaryText)
            .padding(.horizontal, BrowserSpacing.regular)
            .frame(height: headerHeight)
            .background(palette.card.opacity(0.55))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.section.title)，\(group.count) 项")
        .accessibilityHint(collapsed ? "展开" : "折叠")
    }

    // MARK: - Paste

    /// The paste affordance.
    ///
    /// Two parts, because iOS only allows one of them: the row's own label says
    /// what the paste will *do* ("前往" or "搜索"), and the actual work is done
    /// by a `PasteButton`, which is the one control the system grants a
    /// prompt-free pasteboard read to. `PasteButton` always draws the system's
    /// own label — there is no initializer that takes a custom one — so the
    /// trailing button is left at its default size rather than being made to
    /// look like the rest of the row.
    private func pasteRow(_ hint: OmniboxClipboardHint) -> some View {
        HStack(spacing: BrowserSpacing.compact) {
            Image(systemName: hint.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 20)

            Text(hint.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)

            Spacer(minLength: BrowserSpacing.tight)

            PasteButton(payloadType: String.self) { (items: [String]) in
                guard let value = items.first else { return }
                viewModel.pasteAndSubmit(value)
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(palette.accent)
        }
        .padding(.horizontal, BrowserSpacing.regular)
        // Pinned rather than `minHeight`: the card's height budget counts every
        // row as exactly `rowHeight`, so a row free to grow past it — a
        // two-line row, or one line at an enlarged text size — overflows the
        // budget and the last row is cut by the card's own bottom edge. The
        // metric scales with Dynamic Type, so the pinned height grows with the
        // text and nothing is squeezed at accessibility sizes.
        .frame(height: rowHeight)
        .contentShape(Rectangle())
    }

    private var separator: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(height: 0.5)
    }
}

// MARK: - Row

/// One suggestion row.
///
/// Split out of the list so it can be rendered on its own in a preview and so
/// the highlight pass runs once per row rather than once per list update.
struct OmniboxSuggestionRow: View {
    var suggestion: OmniboxSuggestion
    var query: String
    var isHighlighted: Bool
    var rowHeight: CGFloat

    @Environment(\.browserPalette) private var palette

    var body: some View {
        HStack(spacing: BrowserSpacing.compact) {
            leading

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                if !suggestion.subtitle.isEmpty {
                    Text(subtitle)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: BrowserSpacing.tight)

            if let accessory = suggestion.accessoryText, !accessory.isEmpty {
                Text(accessory)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.controlFill, in: Capsule())
            }
        }
        .padding(.horizontal, BrowserSpacing.regular)
        // Pinned rather than `minHeight`: the card's height budget counts every
        // row as exactly `rowHeight`, so a row free to grow past it — a
        // two-line row, or one line at an enlarged text size — overflows the
        // budget and the last row is cut by the card's own bottom edge. The
        // metric scales with Dynamic Type, so the pinned height grows with the
        // text and nothing is squeezed at accessibility sizes.
        .frame(height: rowHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leading: some View {
        if suggestion.hasSiteIdentity {
            SiteIconView(host: suggestion.host, size: 26)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(palette.controlFill)
                Image(systemName: suggestion.iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: 26, height: 26)
        }
    }

    /// The title, with every run the user's input matches picked out in the
    /// accent colour.
    private var title: AttributedString {
        OmniboxTextHighlighter.highlighted(
            suggestion.title,
            query: query,
            accent: palette.accent,
            base: palette.primaryText,
            font: .subheadline
        )
    }

    private var subtitle: AttributedString {
        OmniboxTextHighlighter.highlighted(
            suggestion.subtitle,
            query: query,
            accent: palette.accent,
            base: palette.secondaryText,
            font: .caption
        )
    }
}
