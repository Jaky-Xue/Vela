//
//  ToolbarSettingsView.swift
//  Vela
//
//  The bottom bar's editor: choose which controls sit beside the omnibox and
//  drag them into the order you want.
//
//  The omnibox is not in either list. It is the bar's centre, and moving it
//  away would turn the address into a toolbar button — this screen edits the
//  clusters around it, which is the part with no fixed answer.
//

import SwiftUI

/// The two toolbars the app draws: the phone layout's bottom bar and the iPad
/// layout's top bar. They have separate control orders.
private enum ToolbarPlacement: String, CaseIterable, Identifiable, Hashable {
    case bottom
    case pad

    var id: String { rawValue }
    var title: String { self == .bottom ? "底部工具栏" : "iPad 顶部工具栏" }
}

struct ToolbarSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    @State private var placement: ToolbarPlacement = .bottom

    private var layout: ToolbarLayout {
        placement == .bottom ? env.settings.toolbarLayout : env.settings.padToolbarLayout
    }

    private var availableControls: [ToolbarControl] {
        // The iPad top bar draws the menu button itself.
        placement == .pad ? layout.availableControls.filter { $0 != .menu } : layout.availableControls
    }

    var body: some View {
        List {
            Section {
                Picker("编辑", selection: $placement) {
                    ForEach(ToolbarPlacement.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                Text(placement == .pad
                     ? "iPad 顶部工具栏的侧边栏按钮和菜单是固定的，中间始终是地址栏；下面编辑两侧的其余控件。"
                     : "手机布局的底部工具栏，地址栏固定在中间。")
            }

            Section {
                controls(for: .leading)
            } header: {
                sideHeader(.leading)
            } footer: {
                Text("拖动右侧手柄调整顺序，向左轻扫移除。")
            }

            Section {
                controls(for: .trailing)
            } header: {
                sideHeader(.trailing)
            } footer: {
                Text("每侧最多 \(ToolbarLayout.maximumPerSide) 个控件，中间始终是地址栏。")
            }

            Section {
                Button("恢复默认布局", systemImage: "arrow.counterclockwise") {
                    if placement == .bottom {
                        env.settings.toolbarLayout = ToolbarLayout()
                    } else {
                        env.settings.padToolbarLayout = ToolbarLayout(
                            leading: ToolbarLayout.defaultPadLeading,
                            trailing: ToolbarLayout.defaultPadTrailing
                        )
                    }
                }
                .foregroundStyle(palette.accent)
            }
        }
        .navigationTitle("工具栏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
    }

    private func sideHeader(_ side: ToolbarSide) -> some View {
        HStack {
            Text(side.title)
            Spacer()
            if layout.controls(for: side).count < ToolbarLayout.maximumPerSide {
                Menu {
                    if availableControls.isEmpty {
                        Text("所有控件都已在工具栏上")
                    } else {
                        ForEach(availableControls) { control in
                            Button(control.title, systemImage: control.symbolName) {
                                add(control, to: side)
                            }
                        }
                    }
                } label: {
                    Label("添加", systemImage: "plus.circle")
                        .font(.caption.weight(.medium))
                        .textCase(nil)
                }
            }
        }
    }

    @ViewBuilder
    private func controls(for side: ToolbarSide) -> some View {
        let items = layout.controls(for: side)

        if items.isEmpty {
            Text("这一侧没有控件")
                .foregroundStyle(palette.secondaryText)
        } else {
            ForEach(items) { control in
                HStack(spacing: 12) {
                    Image(systemName: control.symbolName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.accent)
                        .frame(width: 26)
                    Text(control.title)
                        .foregroundStyle(palette.primaryText)
                    Spacer()
                    if control.requiresPage {
                        Text("需要网页")
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            }
            .onMove { source, destination in
                move(side, from: source, to: destination)
            }
            .onDelete { offsets in
                remove(side, at: offsets)
            }
        }
    }

    private func move(_ side: ToolbarSide, from source: IndexSet, to destination: Int) {
        var items = layout.controls(for: side)
        items.move(fromOffsets: source, toOffset: destination)
        apply(items, to: side)
    }

    private func remove(_ side: ToolbarSide, at offsets: IndexSet) {
        var items = layout.controls(for: side)
        items.remove(atOffsets: offsets)
        apply(items, to: side)
    }

    private func add(_ control: ToolbarControl, to side: ToolbarSide) {
        var items = layout.controls(for: side)
        guard items.count < ToolbarLayout.maximumPerSide, !items.contains(control) else { return }
        items.append(control)
        apply(items, to: side)
    }

    private func apply(_ items: [ToolbarControl], to side: ToolbarSide) {
        let updated = layout.replacing(side, with: items)
        if placement == .bottom {
            env.settings.toolbarLayout = updated
        } else {
            env.settings.padToolbarLayout = updated
        }
    }
}
