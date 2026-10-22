import SwiftUI
import OvermarkCore

/// The small panel where the user types the text of a text annotation.
///
/// The editor is presented by the coordinator, which owns the AppKit window.
/// The view only knows about the text and the two ways out: cancel or commit.
///
/// Text can span several lines: Return inserts a newline and ⌘Return commits,
/// so the panel can be driven from the keyboard without losing multi-line
/// input. Pass `initialText` to reopen it over an existing annotation — the
/// button turns into a save action for that case.
struct TextAnnotationEditorView: View {
    /// The colour the annotation will use.
    let color: AnnotationColor
    /// The stroke width the annotation will use.
    let lineWidth: Double
    /// Text to prefill the editor with (an existing annotation's text).
    let initialText: String
    /// Called when the user dismisses the editor without adding text.
    let onCancel: () -> Void
    /// Called with the typed text when the user confirms.
    let onCommit: (String) -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        color: AnnotationColor,
        lineWidth: Double,
        initialText: String = "",
        onCancel: @escaping () -> Void,
        onCommit: @escaping (String) -> Void
    ) {
        self.color = color
        self.lineWidth = lineWidth
        self.initialText = initialText
        self.onCancel = onCancel
        self.onCommit = onCommit
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $text)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L10n.tr("Type your text"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .allowsHitTesting(false)
                    }
                }

            Text(L10n.tr("⌘⏎ adds the text · ⏎ adds a new line"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 14, height: 14)
                    .overlay {
                        Circle().strokeBorder(.primary.opacity(0.3), lineWidth: 1)
                    }

                Text("\(L10n.tr("Size")) \(Int(lineWidth))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(L10n.tr("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button(
                    initialText.isEmpty ? L10n.tr("Add") : L10n.tr("Save"),
                    action: commit
                )
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380, height: 180)
        .onAppear { isFocused = true }
    }

    private func commit() {
        onCommit(text)
    }
}
