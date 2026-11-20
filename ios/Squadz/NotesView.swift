import SquadKit
import SwiftUI

/// The squad's field notes as a chat: everyone's notes in the order they were written, this
/// device's on the right, and a line to write the next one.
struct NotesView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var writing: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if model.notes.isEmpty {
                            Text("No notes yet. What you write here goes to everyone in the squad.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                        }
                        ForEach(model.notes) { note in
                            NoteBubble(note: note, mine: model.isMine(note)).id(note.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.notes.count) { _, _ in
                    model.markNotesRead()
                    if let last = model.notes.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onAppear {
                    model.markNotesRead()
                    if let last = model.notes.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Note to the squad", text: $text, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .focused($writing)
                    .onChange(of: text) { _, new in
                        if new.count > FieldNote.maxText { text = String(new.prefix(FieldNote.maxText)) }
                    }
                Button("Send", systemImage: "paperplane.fill") {
                    if model.sendNote(text) { text = "" }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct NoteBubble: View {
    let note: FieldNote
    let mine: Bool

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                Text(mine ? note.time.formatted(date: .omitted, time: .shortened)
                          : "\(note.author) · \(note.time.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(note.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(mine ? Color.accentColor : Color(.secondarySystemFill), in: .rect(cornerRadius: 14))
                    .foregroundStyle(mine ? Color.white : Color.primary)
            }
            if !mine { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}
