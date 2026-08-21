import MurmurDictionary
import AppKit
import SwiftUI

/// The app's window: a sidebar and a detail pane, the shape every system app uses.
///
/// The window is a convenience, not the product. Dictation happens by holding the
/// push-to-talk key in whatever app you're already typing in, and the HUD is what you look
/// at while it happens. So this window's job is the things you can't do from a hotkey:
/// start a recording without one, read back what was transcribed, and teach the dictionary.
struct MainWindow: View {
    @Bindable var controller: DictationController

    @State private var section: Section = .dictate

    enum Section: String, CaseIterable, Identifiable {
        case dictate
        case history
        case dictionary

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dictate: "Dictate"
            case .history: "History"
            case .dictionary: "Dictionary"
            }
        }

        var symbol: String {
            switch self {
            case .dictate: "mic"
            case .history: "clock"
            case .dictionary: "character.book.closed"
            }
        }
    }

    /// Tabs, not a sidebar.
    ///
    /// A `NavigationSplitView` spends a fixed ~180pt column on three items that never grow,
    /// and collapses that column entirely once the window is narrow — which hid the only
    /// navigation the app has. Tabs cost a single row, stay visible at every width, and are
    /// what a three-section utility window uses on macOS anyway.
    var body: some View {
        TabView(selection: $section) {
            ForEach(Section.allCases) { item in
                pane(for: item)
                    .tabItem { Label(item.title, systemImage: item.symbol) }
                    .tag(item)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    /// Each pane gets its own `NavigationStack`. In a macOS `TabView` that is what gives
    /// `.searchable` and `.toolbar` somewhere to attach — without it the search field and
    /// the pane's action button have no anchor and silently don't render.
    @ViewBuilder
    private func pane(for section: Section) -> some View {
        NavigationStack {
            switch section {
            case .dictate: DictatePane(controller: controller)
            case .history: HistoryPane()
            case .dictionary: DictionaryPanel()
            }
        }
    }
}

// MARK: - Dictate

/// The record button, the live level, and the one line of status that matters.
private struct DictatePane: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared

    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?

    private var isRecording: Bool { controller.state.isActive }

    var body: some View {
        VStack(spacing: DS.Space.wide) {
            Spacer(minLength: 0)

            recordButton

            Text(statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)

            LevelBar(level: controller.level, isActive: isRecording)
                .frame(width: 220, height: 4)

            if !controller.transcript.isEmpty {
                Text(controller.transcript)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: 440, alignment: .leading)
                    .padding(DS.Space.roomy)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: DS.Radius.card))
            }

            Spacer(minLength: 0)

            microphoneRow
        }
        .padding(DS.Space.panel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: controller.state.isActive) { _, active in
            startedAt = active ? Date() : nil
            if !active { elapsed = 0 }
        }
        .task(id: startedAt) {
            guard startedAt != nil else { return }
            while !Task.isCancelled {
                if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// One large target, because this is the only thing on the pane you actually press.
    /// Click starts, click again stops — the hotkey is the hold-to-talk path, and making the
    /// button behave the same way would mean holding the mouse down to dictate.
    private var recordButton: some View {
        Button {
            if isRecording {
                controller.stopButtonRecording()
            } else {
                controller.startButtonRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isRecording ? AnyShapeStyle(DS.recording) : AnyShapeStyle(.tint))
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)

                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
        .animation(DS.Motion.standard, value: isRecording)
    }

    private var statusLine: String {
        switch controller.state {
        case .error(let message):
            return message
        case .idle:
            return "Hold \(settings.pushToTalkKey.displayName) anywhere to dictate, "
                + "or click to record here."
        case .starting:
            return "Starting…"
        case .listening:
            return "Listening — \(counterText)"
        case .finishing:
            return "Transcribing…"
        }
    }

    private var counterText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// The microphone picker lives here, not only in Settings.
    ///
    /// The system default input is frequently an aggregate or loopback device installed by
    /// screen recorders and audio routers, whose first channel carries no microphone signal
    /// at all. When that happens dictation records perfect silence and reports no error, so
    /// the control that fixes it has to be somewhere you'd actually look.
    private var microphoneRow: some View {
        HStack(spacing: DS.Space.snug) {
            Image(systemName: "waveform.badge.mic")
                .foregroundStyle(.secondary)

            Picker("Microphone", selection: Binding(
                get: { settings.inputDeviceUID ?? MicrophonePicker.systemDefaultTag },
                set: { settings.inputDeviceUID = $0 == MicrophonePicker.systemDefaultTag ? nil : $0 }
            )) {
                MicrophonePicker.options()
            }
            .labelsHidden()
            .frame(maxWidth: 280)
        }
        .disabled(isRecording)
    }
}

/// The microphone list, shared by the pane, Settings and the menu bar so all three can
/// never disagree about what's connected.
enum MicrophonePicker {
    /// A `Picker` tag can't be nil, and an empty string would collide with a device whose
    /// UID failed to read.
    static let systemDefaultTag = "__system_default__"

    @ViewBuilder
    static func options() -> some View {
        Text(defaultLabel).tag(systemDefaultTag)
        Divider()
        ForEach(AudioDevices.inputs()) { device in
            Text(device.name).tag(device.uid)
        }
    }

    /// Names what the system default currently resolves to, so an aggregate device sitting
    /// in that slot is visible rather than hidden behind the word "default".
    static var defaultLabel: String {
        guard let device = AudioDevices.systemDefaultInput() else { return "System default" }
        return "System default — \(device.name)"
    }
}

/// A level meter reduced to a single bar. A VU needle was decoration; this answers the only
/// question being asked, which is whether the microphone is hearing anything.
private struct LevelBar: View {
    let level: Float
    let isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: geometry.size.width * CGFloat(isActive ? min(max(level, 0), 1) : 0))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}

// MARK: - History

/// Past transcriptions, searchable, each copyable.
private struct HistoryPane: View {
    @State private var store = RunStore.shared
    @State private var query = ""
    @State private var isConfirmingClear = false

    private var runs: [DictationRun] {
        let all = store.runs.reversed().map { $0 }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.text.localizedStandardContains(trimmed) }
    }

    var body: some View {
        Group {
            if runs.isEmpty {
                ContentUnavailableView {
                    Label(
                        store.runs.isEmpty ? "No transcriptions" : "No matches",
                        systemImage: store.runs.isEmpty ? "clock" : "magnifyingglass"
                    )
                } description: {
                    Text(store.runs.isEmpty
                        ? "Everything you dictate shows up here."
                        : "Try a different search.")
                }
            } else {
                List {
                    ForEach(runs) { run in
                        HistoryRow(run: run)
                            .listRowSeparator(.visible)
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $query, prompt: "Search transcriptions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Delete All", systemImage: "trash") { isConfirmingClear = true }
                    .disabled(store.runs.isEmpty)
            }
        }
        // Confirmed, unlike a single row: one row is trivially re-recorded, the whole
        // history is not, and there's no undo.
        .confirmationDialog(
            "Delete all \(store.runs.count) transcriptions?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { RunLog.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }
}

private struct HistoryRow: View {
    let run: DictationRun

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Text(run.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DS.Space.snug) {
                Text(run.date, style: .time)
                Text("·")
                Text(run.engine)
                Text("·")
                Text(String(format: "%.1fs", run.processSeconds))

                if let corrections = run.corrections, !corrections.isEmpty {
                    Text("·")
                    Label("\(corrections.count) corrected", systemImage: "character.book.closed")
                        .help(corrections.map { "\($0.from) → \($0.to)" }.joined(separator: ", "))
                }

                Spacer()

                Button(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.text, forType: .string)
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        didCopy = false
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, DS.Space.tight)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { RunLog.delete(run) }
        }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.text, forType: .string)
            }
            Button("Delete", role: .destructive) { RunLog.delete(run) }
        }
    }
}
