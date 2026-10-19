//
//  AboutView.swift
//  Vela
//
//  The About screen and the honest list of what is not implemented.
//

import SwiftUI
import UIKit

// MARK: - About

/// The attribution line below is what the GPL-3.0 licence and the upstream
/// trademark policy require; everything else on the screen stays out of the
/// way of the icon, the name and the version.
struct AboutView: View {
    @Environment(AppEnvironment.self) private var env

    /// Read from the bundle rather than written down: a version typed into a
    /// string is the one fact in this screen guaranteed to drift from the
    /// build it describes.
    private static let marketingVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "?"

    private static let buildVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "?"

    /// What the active kernel says it can do, in the user's terms. The engine
    /// seam advertises capabilities rather than promising behaviour, so this
    /// row is the honest summary of the build's engine.
    private var kernelCapabilityText: String {
        let capabilities = env.kernels.active.descriptor.capabilities
        var names: [String] = []
        if capabilities.contains(.scriptInjection) { names.append("脚本注入") }
        if capabilities.contains(.contentBlocking) { names.append("内容过滤") }
        if capabilities.contains(.mediaCapture) { names.append("媒体采集") }
        if capabilities.contains(.webRTCLeakProtection) { names.append("WebRTC 防泄露") }
        if capabilities.contains(.webRTCControl) { names.append("WebRTC 控制") }
        if capabilities.contains(.pageSnapshot) { names.append("页面快照") }
        return names.isEmpty ? "—" : names.joined(separator: " · ")
    }

    var body: some View {
        List {            Section {
                VStack(spacing: 10) {
                    // The icon as installed — the same asset the home screen
                    // shows — rather than a glyph standing in for it.
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                        }
                    Text("Vela")
                        .font(.title2.weight(.semibold))
                    Text("版本 \(Self.marketingVersion) (\(Self.buildVersion))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("规则总数") {
                    Text("\(env.adBlock.ruleCount)")
                        .monospacedDigit()
                }
                LabeledContent("渲染引擎", value: env.kernels.active.descriptor.engineDescription)
                LabeledContent("内核能力", value: kernelCapabilityText)
                    .font(.footnote)
            } header: {
                Text("状态")
            } footer: {
                Text("Vela 通过内核接口取得页面内容视图。当前构建注册的是 WebKit 内核；后续内核可在同一接口下注册并启用。")
            }

            Section {
                Text("Vela 是 Aira Browser（GPL-3.0）的 iOS 移植版，以自己的名称与视觉标识分发。")
                    .font(.footnote)
                Link("GNU General Public License v3.0", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                Link("Aira Browser 上游仓库", destination: URL(string: "https://github.com/mason173/aira-browser")!)
            } header: {
                Text("许可与致谢")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
