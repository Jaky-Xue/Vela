//
//  HomeFavoriteEditSheet.swift
//  Vela
//
//  Editing one home favourite: its name, its address, and whether the tile
//  draws the name.
//
//  The sheet is the long-press menu's 编辑 destination. Nothing here touches
//  the bookmark store: a home tile is its own copy, which is what lets a tile
//  be renamed or given a different address without changing a bookmark.
//

import SwiftUI

struct HomeFavoriteEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// `nil` creates a new tile; a value edits that one.
    var favorite: HomeFavorite?
    /// Name, normalised address, and the per-tile name override (`nil` follows
    /// 外观 ▸ 主页图标).
    var onSave: (String, String, Bool?) -> Void

    @State private var title: String
    @State private var url: String
    @State private var showsTitleOverride: Bool?

    init(favorite: HomeFavorite?, onSave: @escaping (String, String, Bool?) -> Void) {
        self.favorite = favorite
        self.onSave = onSave
        _title = State(initialValue: favorite?.title ?? "")
        _url = State(initialValue: favorite?.url ?? "")
        _showsTitleOverride = State(initialValue: favorite?.showsTitle)
    }

    private var isNew: Bool { favorite == nil }

    private var normalizedUrl: String? {
        HomeFavoritesService.normalizedUrl(url)
    }

    private var defaultShowsTitle: Bool {
        env.settings.preferences.homeTileShowsTitle ?? true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("名称", text: $title)
                }

                Section {
                    TextField("网址", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       normalizedUrl == nil {
                        Text("请输入 http 或 https 开头的网址。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("网址")
                }

                Section {
                    Toggle("显示名称", isOn: Binding(
                        get: { showsTitleOverride ?? defaultShowsTitle },
                        set: { showsTitleOverride = $0 }
                    ))

                    if showsTitleOverride != nil {
                        Button("跟随外观设置（\(defaultShowsTitle ? "显示" : "隐藏")）") {
                            showsTitleOverride = nil
                        }
                    }
                } header: {
                    Text("名称显示")
                } footer: {
                    Text("「外观 ▸ 主页图标」里的开关是所有收藏的默认值；在这里设置后，只影响这一个收藏。")
                }
            }
            .navigationTitle(isNew ? "新建收藏" : "编辑收藏")
            .navigationBarTitleDisplayMode(.inline)
            .browserListSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let normalized = normalizedUrl else { return }
                        onSave(title, normalized, showsTitleOverride)
                        dismiss()
                    }
                    .disabled(normalizedUrl == nil)
                }
            }
        }
    }
}
