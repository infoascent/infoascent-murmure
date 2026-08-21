import MurmurDictionary
import AppKit
import SwiftUI

/// The dictionary: add, edit, delete, search.
///
/// Both entry kinds live in one list rather than separate tabs — they're two shapes of the
/// same idea and you want to see everything you've taught it at once.
///
/// Every control here is a stock control. The previous version drew its own buttons out of
/// a `Button` wrapped in `onLongPressGesture`, and that gesture swallowed the tap: the Save
/// button in the editor could be clicked but never fired, so nothing could be added to the
/// dictionary at all. Stock controls also bring focus rings, keyboard traversal, Escape to
/// cancel and Return to confirm, none of which the hand-drawn ones had.
struct DictionaryPanel: View {
    @State private var store = DictionaryStore.shared
    @State private var query = ""
    @State private var editing: DictionaryEntry?
    @State private var isAdding = false

    private var entries: [DictionaryEntry] { store.filtered(by: query) }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label(
                        store.entries.isEmpty ? "Dictionary empty" : "No matches",
                        systemImage: store.entries.isEmpty ? "character.book.closed" : "magnifyingglass"
                    )
                } description: {
                    Text(store.entries.isEmpty
                        ? "Add names and phrases it keeps getting wrong."
                        : "Try a different search.")
                } actions: {
                    if store.entries.isEmpty {
                        Button("Add Entry") { isAdding = true }
                    }
                }
            } else {
                List {
                    ForEach(entries) { entry in
                        DictionaryRow(
                            entry: entry,
                            onToggle: {
                                var updated = entry
                                updated.isEnabled.toggle()
                                store.update(updated)
                            }
                        )
                        .contentShape(.rect)
                        .onTapGesture(count: 2) { editing = entry }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                store.delete(entry)
                            }
                        }
                        .contextMenu {
                            Button("Edit…") { editing = entry }
                            Button("Delete", role: .destructive) { store.delete(entry) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $query, prompt: "Search dictionary")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Entry", systemImage: "plus") { isAdding = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
        .sheet(isPresented: $isAdding) {
            DictionaryEditor(entry: nil) { store.add($0) }
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry) { store.update($0) }
        }
    }

    /// The file path is shown because the dictionary is meant to be editable outside the UI —
    /// which is only true if you can find it.
    private var footer: some View {
        HStack {
            Text("\(store.entries.count) \(store.entries.count == 1 ? "entry" : "entries")")
            Spacer()
            Button("Reveal dictionary.txt") {
                revealDictionaryFile()
            }
            .buttonStyle(.link)
            .help(DictionaryStore.fileURL.path)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.snug)
        .background(.bar)
    }

    /// Creates the file before revealing it. Until the first entry is saved `dictionary.txt`
    /// doesn't exist, and Finder silently opens the enclosing folder with nothing selected,
    /// which reads as the button being broken.
    private func revealDictionaryFile() {
        let url = DictionaryStore.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Row

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Toggle("Enabled", isOn: Binding(get: { entry.isEnabled }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            VStack(alignment: .leading, spacing: DS.Space.hair) {
                HStack(spacing: DS.Space.snug) {
                    if entry.kind == .correction {
                        Text(entry.hear)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(entry.write)
                        .fontWeight(.medium)
                }
                Text(entry.kind == .correction ? "Correction" : "Term")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .opacity(entry.isEnabled ? 1 : 0.45)
        .padding(.vertical, DS.Space.tight)
    }
}

// MARK: - Editor

private struct DictionaryEditor: View {
    let entry: DictionaryEntry?
    let onSave: (DictionaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var kind: DictionaryEntry.Kind
    @State private var hear: String
    @State private var write: String

    init(entry: DictionaryEntry?, onSave: @escaping (DictionaryEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _kind = State(initialValue: entry?.kind ?? .term)
        _hear = State(initialValue: entry?.hear ?? "")
        _write = State(initialValue: entry?.write ?? "")
    }

    private var draft: DictionaryEntry {
        DictionaryEntry(
            id: entry?.id ?? UUID(),
            kind: kind,
            write: write.trimmingCharacters(in: .whitespacesAndNewlines),
            hear: kind == .correction ? hear.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            isEnabled: entry?.isEnabled ?? true
        )
    }

    private var warnings: [DictionaryWarning] { DictionaryWarning.check(draft) }

    private var isValid: Bool {
        !draft.write.isEmpty && (kind == .term || !draft.hear.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Text(entry == nil ? "New Entry" : "Edit Entry")
                .font(.headline)

            Picker("Kind", selection: $kind) {
                Text("Term").tag(DictionaryEntry.Kind.term)
                Text("Correction").tag(DictionaryEntry.Kind.correction)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                if kind == .correction {
                    TextField("When you hear", text: $hear, prompt: Text("cloud code"))
                }
                TextField(
                    kind == .correction ? "Write" : "Word or phrase",
                    text: $write,
                    prompt: Text(kind == .correction ? "Claude Code" : "Anthropic")
                )
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: kind == .correction ? 92 : 52)

            ForEach(warnings) { warning in
                Label(warning.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(DS.Space.wide)
        .frame(width: 420)
    }
}
