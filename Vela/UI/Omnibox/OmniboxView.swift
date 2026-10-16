//
//  OmniboxView.swift
//  Vela
//
//  The address bar itself: the field, its accessories and its progress line.
//
//  Everything about *suggesting* lives in `OmniboxViewModel`; this file owns the
//  input control and nothing else. Two choices here are specific to iOS and both
//  are explained where they occur:
//
//    * The field is a `UITextField` bridged into SwiftUI rather than a
//      `TextField`. The omnibox has to answer the hardware arrow keys on an
//      iPad, and a SwiftUI `TextField` cannot: arrow keys are consumed by the
//      text system before `onKeyPress` sees them. A `UITextField` subclass
//      declaring the keys as `keyCommands` is the only place the keyboard
//      navigation can be implemented.
//
//    * The bar carries a 2 pt progress line on its bottom edge rather than a
//      progress ring inside the panel. The ring competed with the stop/reload
//      button for the same slot; the line costs no layout at all.
//

import SwiftUI
import UIKit

/// The address bar.
struct OmniboxView: View {
    var viewModel: OmniboxViewModel

    var isLoading: Bool
    var progress: Double
    var placeholder: String
    var onReload: () -> Void
    var onStop: () -> Void

    @Environment(\.browserPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: BrowserSpacing.tight) {
            securityBadge

            fieldArea

            if viewModel.isEditing && !viewModel.text.isEmpty {
                Button {
                    viewModel.setText("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            trailingAction
        }
        .padding(.horizontal, BrowserSpacing.compact)
        .frame(height: BrowserChrome.barHeight)
        .background {
            // The progress line is painted inside the panel rather than over it,
            // so its ends follow the capsule's corner instead of hanging past it.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                AddressProgressLine(
                    progress: progress,
                    isLoading: isLoading,
                    tint: palette.accent
                )
            }
        }
        // The omnibox pill inside the command bar. The tint under the material
        // is heavier here than on the flanking buttons because a URL has to
        // stay legible over whatever the page behind it happens to be.
        .browserFloatingChrome(
            radius: BrowserRadius.omnibox,
            material: .regularMaterial,
            tintStrength: 0.6,
            elevation: .card
        )
        .overlay {
            RoundedRectangle(cornerRadius: BrowserRadius.omnibox, style: .continuous)
                .strokeBorder(isEditingStroke, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.18), value: viewModel.isEditing)
        .animation(.easeOut(duration: 0.15), value: viewModel.text.isEmpty)
    }

    /// The ring drawn around the field while it is open.
    ///
    /// The omnibox is the only control whose "focused" state is a mode the rest
    /// of the chrome reacts to, so the state is drawn rather than left to the
    /// caret alone.
    private var isEditingStroke: Color {
        viewModel.isEditing ? palette.accent.opacity(0.55) : .clear
    }

    // MARK: - Field

    /// The field, plus the tap catcher that opens the session.
    ///
    /// The catcher covers only the field's own frame, not the whole bar: the
    /// reload button and the clear button live outside it and have to stay
    /// tappable while the omnibox is closed.
    private var fieldArea: some View {
        ZStack {
            OmniboxTextField(
                text: Binding(
                    get: { viewModel.text },
                    set: { viewModel.setText($0) }
                ),
                isEditing: viewModel.isEditing,
                placeholder: placeholder,
                onSubmit: { viewModel.submit() },
                onMoveHighlight: { viewModel.moveHighlight(by: $0) },
                onEscape: { viewModel.cancel() },
                onBeginEditing: { viewModel.beginEditing() },
                palette: palette,
                colorScheme: colorScheme
            )

            // Opening the session through a programmatic focus is what lets the
            // whole address be selected; a tap that lands on the field would
            // place the caret at the tap point instead.
            if !viewModel.isEditing {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.beginEditing() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("地址栏")
                    .accessibilityHint("打开地址栏以输入网址或搜索")
            }
        }
        .frame(height: BrowserChrome.barHeight - 14)
    }

    // MARK: - Accessories

    /// The lock is the only security indicator iOS exposes; WebKit reports it
    /// through the page's URL scheme, so the badge is derived from the URL
    /// rather than from a certificate inspection.
    ///
    /// Drawn as a tinted disc rather than a bare glyph, so the leading edge of
    /// the omnibox has the same visual weight as the trailing reload button and
    /// the field between them reads as the middle of three parts.
    private var securityBadge: some View {
        Image(systemName: securitySymbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(securityTint)
            .frame(width: 24, height: 24)
            .background(securityTint.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }

    /// The badge's glyph. On the home surface there is no page and so no origin
    /// to report, and a globe would be a claim about a document that is not
    /// there — a magnifier says what the field does instead.
    private var securitySymbol: String {
        guard !viewModel.currentPageUrl.isEmpty else { return "magnifyingglass" }
        return isSecure ? "lock.fill" : "globe"
    }

    private var securityTint: Color {
        guard !viewModel.currentPageUrl.isEmpty else { return palette.secondaryText }
        return isSecure ? .green : palette.secondaryText
    }

    @ViewBuilder
    private var trailingAction: some View {
        if !viewModel.isEditing && !viewModel.currentPageUrl.isEmpty {
            Button(action: isLoading ? onStop : onReload) {
                Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLoading ? "停止" : "重新载入")
        }
    }

    private var isSecure: Bool {
        viewModel.currentPageUrl.lowercased().hasPrefix("https://")
    }
}

// MARK: - Progress line

/// The 2 pt loading line on the bottom edge of the address bar.
///
/// A determinate bar while WebKit reports progress, and a sweep while it has not
/// reported anything yet — a page that has been requested but has not committed
/// reports `0`, and a bar pinned at zero width for a second reads as broken.
struct AddressProgressLine: View {
    var progress: Double
    var isLoading: Bool
    var tint: Color

    @State private var sweeping = false

    private var isIndeterminate: Bool { isLoading && progress < 0.03 }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if isIndeterminate {
                    Capsule()
                        .fill(tint.opacity(0.9))
                        .frame(width: max(24, geometry.size.width * 0.28))
                        .offset(x: sweeping ? geometry.size.width : -geometry.size.width * 0.3)
                        .animation(
                            .easeInOut(duration: 1.1).repeatForever(autoreverses: false),
                            value: sweeping
                        )
                } else if isLoading || progress > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, geometry.size.width * min(1, progress)))
                        .animation(.easeOut(duration: 0.2), value: progress)
                }
            }
        }
        .frame(height: BrowserMetrics.progressLineHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isLoading || progress > 0 ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: isLoading)
        .onChange(of: isIndeterminate) { _, value in
            sweeping = value
        }
        .onAppear { sweeping = isIndeterminate }
        .accessibilityHidden(true)
    }
}

// MARK: - Text field

/// The omnibox's input control.
///
/// A `UITextField` bridge, for the keyboard reasons described in the file
/// header. It also owns focus: the omnibox is opened by the bar's tap catcher
/// and closed by the shell, and both of those are commands the field has to be
/// told about rather than discover.
struct OmniboxTextField: UIViewRepresentable {
    @Binding var text: String
    var isEditing: Bool
    var placeholder: String
    var onSubmit: () -> Void
    var onMoveHighlight: (Int) -> Void
    var onEscape: () -> Void
    var onBeginEditing: () -> Void

    var palette: BrowserPalette
    var colorScheme: ColorScheme

    func makeUIView(context: Context) -> OmniboxUITextField {
        let field = OmniboxUITextField()
        field.delegate = context.coordinator
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.clearButtonMode = .never
        field.textContentType = .URL
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onMoveHighlight = { delta in
            context.coordinator.parent.onMoveHighlight(delta)
        }
        field.onEscape = {
            context.coordinator.parent.onEscape()
        }
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged(_:)),
            for: .editingChanged
        )
        return field
    }

    func updateUIView(_ field: OmniboxUITextField, context: Context) {
        context.coordinator.parent = self

        if field.text != text {
            field.text = text
        }

        let tokens = palette.tokens(for: colorScheme)
        field.textColor = UIColor(tokens.primaryText)
        field.tintColor = UIColor(tokens.accent)
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: UIColor(tokens.secondaryText),
                .font: UIFont.preferredFont(forTextStyle: .body)
            ]
        )

        // Focus is a command from the shell, not something the field decides.
        // Selection happens only on a programmatic focus, so a tap that lands
        // inside the field while the user is already editing still places the
        // caret where they tapped.
        if isEditing {
            field.isUserInteractionEnabled = true
            if !field.isFirstResponder {
                context.coordinator.selectAllOnNextFocus = true
                field.becomeFirstResponder()
            }
        } else {
            if field.isFirstResponder {
                field.resignFirstResponder()
            }
            // Taps fall through to the SwiftUI catcher over the bar, which is
            // what opens the session.
            field.isUserInteractionEnabled = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: OmniboxTextField
        /// Set when focus is granted programmatically; cleared once the select
        /// all has been applied.
        var selectAllOnNextFocus = false

        init(parent: OmniboxTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onBeginEditing()
            guard selectAllOnNextFocus else { return }
            selectAllOnNextFocus = false
            // Deferred by one runloop turn: the tap that opened the omnibox is
            // still being delivered, and it would otherwise place the caret
            // after this call and undo the selection.
            DispatchQueue.main.async {
                textField.selectAll(nil)
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }

        func textFieldShouldClear(_ textField: UITextField) -> Bool {
            parent.text = ""
            return false
        }
    }
}

/// The `UITextField` the omnibox uses.
///
/// The subclass exists for one reason: `keyCommands` is the only hook that sees
/// the hardware arrow keys before the text system consumes them, which is what
/// makes "up and down move the highlighted suggestion" work on an iPad with a
/// keyboard attached.
final class OmniboxUITextField: UITextField {
    var onMoveHighlight: ((Int) -> Void)?
    var onEscape: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []

        let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleUp))
        let down = UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleDown))
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape))

        // Without this the text system claims the arrows first and the
        // commands below are never dispatched.
        up.wantsPriorityOverSystemBehavior = true
        down.wantsPriorityOverSystemBehavior = true
        escape.wantsPriorityOverSystemBehavior = true

        commands.append(contentsOf: [up, down, escape])
        return commands
    }

    @objc private func handleUp() { onMoveHighlight?(-1) }
    @objc private func handleDown() { onMoveHighlight?(1) }
    @objc private func handleEscape() { onEscape?() }
}
