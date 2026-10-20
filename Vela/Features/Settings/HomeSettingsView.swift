//
//  HomeSettingsView.swift
//  Vela
//
//  The home surface's tile settings: icon size, shape and spacing.
//
//  The home background picture used to be chosen here. It is the global
//  background picture now — 外观 ▸ 自定义背景图片 — because a picture that
//  belonged to the home alone could not sit behind the top bar without the bar
//  reading as a band of colour over the wallpaper.
//

import SwiftUI

// MARK: - Screen

/// The home-surface settings screen.
struct HomeSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                HStack {
                    Text("图标大小")
                    Spacer()
                    Text("\(Int(env.settings.preferences.homeTileIconSize ?? 40)) pt")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { env.settings.preferences.homeTileIconSize ?? 40 },
                        set: { newValue in
                            env.settings.update { $0.homeTileIconSize = newValue }
                        }
                    ),
                    in: 28...64,
                    step: 2
                )

                Picker("形状", selection: Binding(
                    get: { env.settings.preferences.homeTileShape ?? "rounded" },
                    set: { newValue in
                        env.settings.update { $0.homeTileShape = newValue }
                    }
                )) {
                    Text("圆角").tag("rounded")
                    Text("圆形").tag("circle")
                    Text("方角").tag("square")
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("间距")
                    Spacer()
                    Text("\(Int(env.settings.preferences.homeTileSpacing ?? 12)) pt")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { env.settings.preferences.homeTileSpacing ?? 12 },
                        set: { newValue in
                            env.settings.update { $0.homeTileSpacing = newValue }
                        }
                    ),
                    in: 8...28,
                    step: 2
                )
            } header: {
                Text("收藏图标")
            } footer: {
                Text("改动即时生效，直接回到主页就能看到。")
            }
        }
        .navigationTitle("主页")
        .navigationBarTitleDisplayMode(.inline)
        .browserListSurface()
    }
}
