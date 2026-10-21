import SwiftUI
import PresentifyCore

/// The small panel where the user types the text of a text annotation.
///
/// The editor is presented by the coordinator, which owns the AppKit window.
/// The view only knows about the text and the two ways out: cancel or commit.
struct TextAnnotationEditorView: View {
    /// The colour the annotation will use.
    let color: AnnotationColor
    /// The stroke width the annotation will use.
    let lineWidth: Double
    /// Called when the user dismisses the editor without adding text.
    let onCancel: () -> Void
    /// Called with the typed text when the user confirms.
    let onCommit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Type your text", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(commit)

            HStack {
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 14, height: 14)
                    .overlay {
                        Circle().strokeBorder(.primary.opacity(0.3), lineWidth: 1)
                    }

                Text("Size \(Int(lineWidth))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Add", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320, height: 110)
        .onAppear { isFocused = true }
    }

    private func commit() {
        onCommit(text)
    }
}
