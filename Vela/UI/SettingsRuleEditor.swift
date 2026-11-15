import SwiftUI

struct SettingsRuleEditor: View {
    @Environment(\.browserPalette) private var palette
    var prompt: String
    @Binding var text: String
    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty { Text(prompt).foregroundStyle(palette.secondaryText).padding(8).allowsHitTesting(false) }
            TextEditor(text: $text).scrollContentBackground(.hidden)
                .font(.system(.footnote, design: .monospaced)).frame(minHeight: 90)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }.padding(4)
        .background(palette.controlFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.primaryText.opacity(0.22), lineWidth: 1) }
    }
}
