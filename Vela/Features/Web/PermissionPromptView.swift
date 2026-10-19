//
//  Permissionprompt.swift
//  Vela
//
//  The sheet WebKit raises when a site asks for a device capability.
//

import SwiftUI
import UIKit

// MARK: - Permission prompt

struct PermissionPromptView: View {
    @Environment(\.browserPalette) private var palette

    var request: SitePermissionRequest
    var onDecision: (Bool, Bool) -> Void

    @State private var remember = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: iconName)
                .font(.system(size: 30))
                .foregroundStyle(palette.accent)
                .frame(width: 62, height: 62)
                .background(palette.accent.opacity(0.12), in: Circle())
                .padding(.top, 28)

            VStack(spacing: 6) {
                Text("允许「\(request.origin)」使用\(request.kind.displayName)？")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.center)
                Text("该网站请求访问你的\(request.kind.displayName)。")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            Toggle("以后对这个网站都这样", isOn: $remember)
                .tint(palette.accent)
                .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    onDecision(true, remember)
                } label: {
                    Text("允许").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onDecision(false, remember)
                } label: {
                    Text("不允许").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .browserSurfaceBackground(opacity: 0.72)
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
    }

    private var iconName: String {
        switch request.kind {
        case .camera: return "camera"
        case .microphone: return "mic"
        case .location: return "location"
        case .sensor: return "gyroscope"
        case .clipboard: return "doc.on.clipboard"
        }
    }
}
