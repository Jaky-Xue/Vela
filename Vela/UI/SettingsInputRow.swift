import SwiftUI

/// A persistent label plus a visible editing surface; placeholders are examples.
struct SettingsInputRow: View {
    var title: String
    var prompt: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            TextField(prompt, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }.padding(.vertical, 4)
    }
}
