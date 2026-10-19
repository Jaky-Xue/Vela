//
//  BrowserKernelSettingsView.swift
//  Vela
//
//  The rendering engine's status, and an honest statement about Chromium.
//
//  iOS does not allow an app to ship Blink as its web-content engine; Chromium
//  on iOS is a browser shell around WKWebView, not an embeddable engine. Vela
//  therefore ships WebKit and exposes a kernel interface for an engine that
//  someone builds and vendors later. This screen says exactly that instead of
//  offering a switch that cannot work.
//

import SwiftUI

struct BrowserKernelSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    var body: some View {
        List {
            Section {
                ForEach(env.kernels.descriptors) { descriptor in
                    HStack(spacing: 12) {
                        Image(systemName: "cpu")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .frame(width: 30, height: 30)
                            .background(
                                palette.accent.opacity(0.13),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(descriptor.displayName)
                                .foregroundStyle(palette.primaryText)
                            Text(capabilityText(descriptor.capabilities))
                                .font(.caption2)
                                .foregroundStyle(palette.secondaryText)
                        }
                        Spacer()
                        if descriptor.id == env.kernels.active.descriptor.id {
                            Text("使用中")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(palette.accent)
                        }
                    }
                }
            } header: {
                Text("已注册的内核")
            } footer: {
                Text("内核负责为一个标签页创建内容视图，并在页面加载前安装自己的桥接。WebKit 是当前构建注册的唯一内核。")
            }

            Section {
                LabeledContent("Chromium", value: "未内置")
                Text("iOS 上 Chromium 没有可嵌入的 Blink 内容引擎——Chromium for iOS 的网页内容同样由 WKWebView 承载。因此本构建不能通过加一个依赖就获得 Chromium 内核；要真正接入，需要随包提供一个实现了 BrowserKernel 的框架。")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
            } header: {
                Text("Chromium / 自定义内核")
            }

            Section {
                LabeledContent(
                    "WebRTC 策略",
                    value: env.settings.webRTCProtectionEnabled
                        ? env.settings.webRTCProtectionSelection.displayName
                        : "已关闭"
                )
                    .foregroundStyle(palette.primaryText)
                NavigationLink("WebRTC 泄露防护") {
                    WebRTCProtectionSettingsView()
                }
            } header: {
                Text("WebRTC")
            } footer: {
                Text("WebRTC 防护是在 WebKit 之上用文档开始脚本实现的，与内核接口相互独立；换成自有内核时仍然适用。")
            }

            Section {
                Text("接入自有内核：实现 BrowserKernel（descriptor、makeWebView、prepare），在 AppEnvironment 创建 BrowserWebCoordinator 之前注册并 activate；非 WebKit 内核还需要先把内容视图从 WKWebView 抽象出来。")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
            } header: {
                Text("扩展说明")
            }
        }
        .navigationTitle("渲染内核")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func capabilityText(_ capabilities: BrowserKernelCapabilities) -> String {
        var names: [String] = []
        if capabilities.contains(.scriptInjection) { names.append("脚本注入") }
        if capabilities.contains(.contentBlocking) { names.append("内容过滤") }
        if capabilities.contains(.mediaCapture) { names.append("媒体采集") }
        if capabilities.contains(.webRTCLeakProtection) { names.append("WebRTC 防泄露") }
        if capabilities.contains(.webRTCControl) { names.append("WebRTC 控制") }
        if capabilities.contains(.pageSnapshot) { names.append("页面快照") }
        return names.isEmpty ? "未声明能力" : names.joined(separator: " · ")
    }
}
