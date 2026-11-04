//
//  AboutView.swift
//  Vela
//
//  The About screen and the honest list of what is not implemented.
//

import SwiftUI
import UIKit

// MARK: - About

/// The licence line below is the one legal fact this screen carries;
/// everything else stays out of the way of the icon, the name and the version.
struct AboutView: View {
    /// Read from the bundle rather than written down: a version typed into a
    /// string is the one fact in this screen guaranteed to drift from the
    /// build it describes.
    private static let marketingVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "?"

    private static let buildVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "?"

    var body: some View {
        List {
            Section {
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
                Text("Vela 是专为 iOS 设计的浏览器，以 GNU General Public License v3.0 发布。")
                    .font(.footnote)
                Text("完整许可与署名说明见源代码中的 LICENSE-NOTICE.md。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("GNU General Public License v3.0", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
            } header: {
                Text("许可")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .settingsList()
    }
}
