//
//  MenuSettingsView.swift
//  Vela
//
//  The menu panel's editor: which built-in tiles are shown, their order, and
//  any URL shortcuts the user added.
//
//  The menu is a grid of destinations, so this screen mirrors that shape: the
//  visible tiles are a reorderable list, hidden built-ins are one tap from
//  returning, and a shortcut is a small form with a name, a URL and an icon.
//

import SwiftUI

struct MenuSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    @State private var showingShortcutEditor = false

    private var layout: MenuLayout { env.settings.menuLayout }

    var body: some View {
        List {
            Section {
                ForEach(layout.visibleTiles) { tile in
                    tileRow(tile)
                }
                .onMove { source, destination in
                    env.settings.menuLayout = layout.movingVisible(from: source, to: destination)
                }
                .onDelete { offsets in
                    env.settings.menuLayout = removing(at: offsets)
                }
            } header: {
                HStack {
                    Text("显示的菜单项")
                    Spacer()
                    addMenu
                }
            } footer: {
                Text("拖动排序，左滑移除。移除的内置项会进入下方「已隐藏」，随时可以加回来。")
            }

            if !layout.hiddenTiles.isEmpty {
                Section("已隐藏") {
                    ForEach(layout.hiddenTiles) { tile in
                        Button {
                            env.settings.menuLayout = layout.settingVisible(true, id: tile.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: tile.symbolName)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(palette.secondaryText)
                                    .frame(width: 26)
                                Text(tile.title)
                                    .foregroundStyle(palette.primaryText)
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("点一下即可重新显示在菜单中。")
                }
            }

            if !layout.shortcuts.isEmpty {
                Section("自定义快捷方式") {
                    ForEach(layout.shortcuts) { shortcut in
                        HStack(spacing: 12) {
                            Image(systemName: shortcut.symbolName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(palette.accent)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shortcut.title)
                                    .foregroundStyle(palette.primaryText)
                                Text(shortcut.url)
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                env.settings.menuLayout = layout.removingShortcut(id: shortcut.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .accessibilityLabel("删除快捷方式")
                        }
                    }
                }
            }

            Section {
                Button("恢复默认菜单", systemImage: "arrow.counterclockwise") {
                    env.settings.menuLayout = layout.reset()
                }
                .foregroundStyle(palette.accent)
            } footer: {
                Text("恢复后，所有内置项按默认顺序显示，自定义快捷方式会被移除。")
            }
        }
        .navigationTitle("菜单面板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
        .sheet(isPresented: $showingShortcutEditor) {
            MenuShortcutEditorView { shortcut in
                showingShortcutEditor = false
                if let shortcut {
                    env.settings.menuLayout = layout.adding(shortcut)
                }
            }
            .environment(env)
        }
    }

    private var addMenu: some View {
        Menu {
            if layout.hiddenTiles.isEmpty {
                Text("没有隐藏的内置项")
            } else {
                ForEach(layout.hiddenTiles) { tile in
                    Button(tile.title, systemImage: tile.symbolName) {
                        env.settings.menuLayout = layout.settingVisible(true, id: tile.id)
                    }
                }
            }
            Divider()
            Button("新建网址快捷方式", systemImage: "link.badge.plus") {
                showingShortcutEditor = true
            }
        } label: {
            Label("添加", systemImage: "plus.circle")
                .font(.caption.weight(.medium))
                .textCase(nil)
        }
    }

    private func tileRow(_ tile: MenuTile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: tile.symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 26)
            Text(tile.title)
                .foregroundStyle(palette.primaryText)
            Spacer()
            if tile.shortcut != nil {
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
            } else if tile.requiresPage {
                Text("需要网页")
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .contextMenu {
            if let shortcut = tile.shortcut {
                Button("删除快捷方式", systemImage: "trash", role: .destructive) {
                    env.settings.menuLayout = layout.removingShortcut(id: shortcut.id)
                }
            }
        }
    }

    /// Removing a built-in hides it; removing a shortcut deletes it outright,
    /// because a shortcut has no "restore" row to bring it back from.
    private func removing(at offsets: IndexSet) -> MenuLayout {
        let visible = layout.visibleTiles
        var updated = layout.hidingVisible(at: offsets)
        for index in offsets where visible.indices.contains(index) {
            if let shortcut = visible[index].shortcut {
                updated = updated.removingShortcut(id: shortcut.id)
            }
        }
        return updated
    }
}

// MARK: - Shortcut editor

struct MenuShortcutEditorView: View {
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    /// Called with the new shortcut, or nil when the form was cancelled.
    var onFinish: (MenuShortcut?) -> Void

    @State private var title = ""
    @State private var url = ""
    @State private var symbolName = "link"
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（如 工作台）", text: $title)
                    TextField("网址（如 example.com/panel）", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text("没有写协议的网址会按 https 打开。")
                }

                Section("图标") {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
                        spacing: 10
                    ) {
                        ForEach(MenuShortcut.symbolChoices, id: \.self) { name in
                            Button {
                                symbolName = name
                            } label: {
                                Image(systemName: name)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(symbolName == name ? palette.onAccent : palette.primaryText)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        symbolName == name ? palette.accent : palette.controlFill.opacity(0.7),
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(name)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("新建快捷方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        onFinish(nil)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { save() }
                        .disabled(normalizedURL == nil)
                }
            }
        }
        .browserAmbientSheet()
    }

    private var normalizedURL: URL? {
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let candidate = raw.contains("://") ? raw : "https://" + raw
        guard let parsed = URL(string: candidate),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              parsed.host != nil else {
            return nil
        }
        return parsed
    }

    private func save() {
        guard let normalizedURL else {
            errorMessage = "请填写一个 http 或 https 网址。"
            return
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorMessage = "请填写名称。"
            return
        }
        onFinish(
            MenuShortcut(
                title: trimmedTitle,
                url: normalizedURL.absoluteString,
                symbolName: symbolName
            )
        )
        dismiss()
    }
}
