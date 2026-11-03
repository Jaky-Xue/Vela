//
//  WebRTCProtectionSettingsView.swift
//  Vela
//
//  The WebRTC leak-protection policy.
//
//  This is a browser-level policy rather than a per-site permission: a page can
//  open a peer connection from any frame, and there is no prompt at which to
//  ask the user about each one. The switch turns the whole guard on or off; the
//  modes below decide what "on" means, and are explained in place because the
//  trade-off (relay-only can break calls; blocked removes the API) is the
//  setting.
//

import SwiftUI

struct WebRTCProtectionSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    private var selection: WebRTCProtectionMode { env.settings.webRTCProtectionSelection }
    private var isEnabled: Bool { env.settings.webRTCProtectionEnabled }

    var body: some View {
        List {
            Section {
                Toggle("启用 WebRTC 泄露防护", isOn: Binding(
                    get: { isEnabled },
                    set: { applyEnabled($0) }
                ))
            } header: {
                Text("防护开关")
            }

            Section {
                ForEach(WebRTCProtectionMode.allCases) { option in
                    Button {
                        apply(option)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: option.symbolName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(option == selection ? palette.onAccent : palette.accent)
                                .frame(width: 34, height: 34)
                                .background(
                                    option == selection ? palette.accent : palette.accent.opacity(0.13),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.displayName)
                                    .foregroundStyle(palette.primaryText)
                                Text(option.summary)
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 6)

                            if option == selection {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .opacity(isEnabled ? 1 : 0.5)
                }
            } header: {
                Text("防护模式")
            }

        }
        .navigationTitle("WebRTC 泄露防护")
        .navigationBarTitleDisplayMode(.inline)
        .settingsList()
    }

    private func applyEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        env.settings.webRTCProtectionEnabled = enabled
        reloadActiveTab()
    }

    private func apply(_ option: WebRTCProtectionMode) {
        guard option != selection || !isEnabled else { return }
        // `webRTCProtectionSelection` also flips the switch on.
        env.settings.webRTCProtectionSelection = option
        reloadActiveTab()
    }

    private func reloadActiveTab() {
        guard let tab = env.tabManager.activeTab, !tab.isHome else { return }
        _ = env.tabManager.reload(tab: tab)
    }
}
