//
//  HistoryView.swift
//  Vela
//
//  The history manager. Ported from `AiraBrowser/entry/src/main/ets/app/pages/HistoryManagerPage.ets`
//  and the removal scopes in `HistorySyncModels` (Aira Browser 3.7.4, GPL-3.0).
//
//  Grouped by day, with the three removal scopes the data layer supports exposed
//  as swipe actions: one entry, the whole host, or the whole day. Ported from the
//  scope switch in `SettingsSiteDataClearCoordinator`; keeping the scopes
//  distinct is what stops "delete this" from silently meaning "delete
//  everything from this site".
//
//  iOS port enhancement (this revision). Aira's history page renders every day
//  it has, expanded, because ArkUI's list has no disclosure control. An imported
//  or long-lived profile is then thousands of rows in one scroll. Each day is
//  now a collapsible section — the two most recent days open, the rest folded —
//  which is the same shape the omnibox's suggestion card uses.
//

import SwiftUI
import UIKit

struct HistoryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selectedEntry: HistoryUrl?
    @State private var recentlyRemoved: [HistoryUrl] = []
    @State private var showClearConfirm = false
    /// Explicit fold choices, keyed by day. A day absent from this map follows
    /// the "two most recent days are open" rule, so the default does not have to
    /// be written on every reload.
    @State private var dayFoldOverrides: [String: Bool] = [:]

    /// How many days are expanded before the user touches anything.
    private static let openDayCount = 2

    private var history: HistoryService { env.history }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Search results, or the day-grouped list.
    private var searchResults: [HistoryUrl] {
        history.search(searchText)
    }

    var body: some View {
        List {
            if isSearching {
                if searchResults.isEmpty {
                    EmptyState(
                        systemImage: "clock.arrow.circlepath",
                        title: "没有匹配的记录",
                        message: "换个关键词试试。"
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section("\(searchResults.count) 条结果") {
                        ForEach(searchResults) { entry in
                            row(entry)
                        }
                    }
                }
            } else if history.dayGroups.isEmpty {
                EmptyState(
                    systemImage: "clock",
                    title: "还没有浏览记录",
                    message: "访问过的网页会显示在这里。"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(Array(history.dayGroups.enumerated()), id: \.element.id) { index, group in
                    Section {
                        if !isFolded(group, at: index) {
                            ForEach(group.entries) { entry in
                                row(entry)
                            }
                        }
                    } header: {
                        dayHeader(group, at: index)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "搜索历史记录")
        .navigationTitle("历史记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Ported from the undo affordance in the history manager: a
                    // removal is reversible from the same screen until the user
                    // leaves it.
                    if !recentlyRemoved.isEmpty {
                        Button("撤销上一次删除", systemImage: "arrow.uturn.backward") {
                            undoLastRemoval()
                        }
                    }
                    Divider()
                    Button("清除全部历史记录", systemImage: "trash", role: .destructive) {
                        showClearConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("清除全部历史记录？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                recentlyRemoved = history.dayGroups.flatMap(\.entries)
                history.removeAll()
            }
        } message: {
            Text("这也会清除搜索记录。此操作无法撤销。")
        }
        .sheet(item: $selectedEntry) { entry in
            HistoryDetailSheet(entry: entry, visits: history.visits(for: entry))
        }
        .onAppear { history.reload() }
    }

    @ViewBuilder
    private func dayHeader(_ group: HistoryDayGroup, at index: Int) -> some View {
        let folded = isFolded(group, at: index)
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                dayFoldOverrides[group.id] = !folded
            }
        } label: {
            HStack(spacing: 6) {
                Text(group.displayTitle)
                Text("\(group.entries.count)")
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(folded ? 0 : 90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The inset-grouped style would otherwise uppercase the day name.
        .textCase(nil)
        .accessibilityHint(folded ? "展开" : "折叠")
    }

    /// Whether a day is folded.
    ///
    /// An explicit choice always wins; otherwise the first `openDayCount` days
    /// are open and everything older is folded.
    private func isFolded(_ group: HistoryDayGroup, at index: Int) -> Bool {
        dayFoldOverrides[group.id] ?? (index >= Self.openDayCount)
    }

    @ViewBuilder
    private func row(_ entry: HistoryUrl) -> some View {
        Button {
            selectedEntry = entry
        } label: {
            HStack(spacing: 12) {
                SiteIconView(host: entry.host, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayTitle)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(entry.displayHost)
                            .lineLimit(1)
                        if entry.visitCount > 1 {
                            Text("·")
                            Text("\(entry.visitCount) 次")
                                .monospacedDigit()
                        }
                        Text("·")
                        Text(entry.lastVisitAt, format: .dateTime.hour().minute())
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                recentlyRemoved.append(entry)
                history.remove(entry, scope: .singleUrl)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                open(entry)
            } label: {
                Label("打开", systemImage: "arrow.up.forward.square")
            }
            .tint(.blue)

            Button {
                recentlyRemoved.append(entry)
                history.removeHost(entry)
            } label: {
                Label("此站全部", systemImage: "trash.slash")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button("在新标签页打开", systemImage: "plus.square.on.square") {
                openInNewTab(entry)
            }
            Button("拷贝网址", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = entry.url
            }
            Button("添加到书签", systemImage: "bookmark") {
                env.bookmarks.addBookmark(url: entry.url, title: entry.displayTitle, parentNodeId: nil)
            }
            Divider()
            Button("删除这一天", systemImage: "calendar.badge.minus", role: .destructive) {
                removeDay(containing: entry)
            }
            Button("删除此网站", systemImage: "trash.slash", role: .destructive) {
                recentlyRemoved.append(entry)
                history.removeHost(entry)
            }
        }
    }

    // MARK: - Actions

    private func open(_ entry: HistoryUrl) {
        guard let url = URL(string: entry.url), let tab = env.tabManager.activeTab else { return }
        tab.isHome = false
        tab.url = url.absoluteString
        env.tabManager.ensureWebView(for: tab).load(URLRequest(url: url))
        dismiss()
    }

    private func openInNewTab(_ entry: HistoryUrl) {
        guard let url = URL(string: entry.url) else { return }
        let tab = env.tabManager.createTab(
            url: url.absoluteString,
            privacyMode: .regular,
            openSource: .history,
            activate: false
        )
        _ = env.tabManager.ensureWebView(for: tab)
    }

    private func removeDay(containing entry: HistoryUrl) {
        guard let group = history.dayGroups.first(where: { $0.entries.contains { $0.id == entry.id } }) else { return }
        recentlyRemoved.append(contentsOf: group.entries)
        history.remove(dayGroup: group)
    }

    /// Re-inserts the most recently removed entries.
    ///
    /// Delegates to the repository's normal record path rather than restoring
    /// rows directly: a restored entry has to go through the same upsert the
    /// original visit did, or its URL row and visit row would disagree.
    private func undoLastRemoval() {
        let toRestore = recentlyRemoved
        recentlyRemoved = []
        for entry in toRestore {
            guard let url = URL(string: entry.url) else { continue }
            history.recordVisit(
                url: url,
                title: entry.title,
                tabId: "undo",
                boundary: .persistent,
                transition: .restore
            )
        }
    }
}

/// One history entry's detail, with every visit.
private struct HistoryDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    var entry: HistoryUrl
    var visits: [HistoryVisit]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.displayTitle)
                            .font(.headline)
                        Text(entry.url)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }

                Section("统计") {
                    LabeledContent("访问次数", value: "\(entry.visitCount)")
                    LabeledContent("地址栏输入", value: "\(entry.typedCount)")
                    LabeledContent("首次访问", value: entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("最近访问", value: entry.lastVisitAt.formatted(date: .abbreviated, time: .shortened))
                }

                Section("访问记录") {
                    ForEach(visits) { visit in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(visit.visitedAt.formatted(date: .abbreviated, time: .standard))
                                    .font(.subheadline)
                                Text(visit.transition.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if visit.visitDurationMs > 0 {
                                Text(formatDuration(visit.visitDurationMs))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .navigationTitle("详细信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时"
    }
}
