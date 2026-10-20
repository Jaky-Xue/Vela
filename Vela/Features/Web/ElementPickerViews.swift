//
//  ElementPickerViews.swift
//  Vela
//
//  The two pieces of UI the element picker needs: an instruction while the
//  page is armed, and a confirmation once an element has been tapped.
//
//  Without the confirmation the picker was a mode with no visible result: the
//  selected selector landed in the overlay state and nothing ever offered to
//  save it. The banner also gives the user a way out that does not depend on
//  finding the menu again.
//

import SwiftUI

struct ElementPickerBanner: View {
    @Environment(\.browserPalette) private var palette

    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text("轻点要隐藏的元素")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Text("选中后会询问是否隐藏，可随时取消。")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondaryText)
            }

            Spacer(minLength: 8)

            Button("取消", action: onCancel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .browserFloatingChrome(
            radius: BrowserRadius.card,
            material: .regularMaterial,
            tintStrength: 0.5,
            elevation: .card
        )
    }
}

struct ElementHideConfirmSheet: View {
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    var pick: ElementPickResult
    var onHide: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(palette.secondaryText.opacity(0.35))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            Image(systemName: "eye.slash")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 58, height: 58)
                .background(palette.accent.opacity(0.13), in: Circle())

            VStack(spacing: 5) {
                Text("隐藏这个元素？")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                Text(pick.matchedElementCount > 1
                     ? "这个选择器在本页匹配 \(pick.matchedElementCount) 个元素，它们会一起被隐藏。"
                     : "这个元素会在本页被隐藏。")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Text(pick.selector)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.primaryText)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    palette.controlFill.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            if !pick.tagName.isEmpty || !pick.textPreview.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("选中区域：\(pick.tagName.isEmpty ? "元素" : pick.tagName)")
                        .font(.caption.weight(.medium))
                    if !pick.textPreview.isEmpty {
                        Text("「\(pick.textPreview)」")
                            .font(.caption2)
                            .lineLimit(2)
                    }
                }
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("页面上已用蓝色框标出选中的区域。只对 \(pick.host) 生效，可随时在 设置 ▸ 广告与内容过滤 中移除。")
                .font(.caption2)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)

            Spacer(minLength: 0)

            VStack(spacing: 9) {
                Button {
                    onHide()
                    dismiss()
                } label: {
                    Text("隐藏").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onCancel()
                    dismiss()
                } label: {
                    Text("取消").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 22)
        .browserSurfaceBackground(opacity: 0.74)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}
