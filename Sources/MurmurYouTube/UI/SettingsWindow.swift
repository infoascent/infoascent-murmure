import SwiftUI

/// Settings, opened with ⌘, through the standard `Settings` scene so the system wires up
/// the menu item and the shortcut.
///
/// A grouped `Form`, which is what every system settings pane is. Each control carries its
/// explanation underneath rather than in a tooltip: these are choices made once and then
/// forgotten, so the cost of reading them is paid once too.
struct SettingsWindow: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            transcription.tabItem { Label("Transcription", systemImage: "waveform") }
        }
        .frame(width: 520)
        .scenePadding()
    }

    private var general: some View {
        Form {
            Section {
                Picker("Push to talk", selection: Binding(
                    get: { settings.pushToTalkKey },
                    set: { key in
                        settings.pushToTalkKey = key
                        controller.reloadHotkey()
                    }
                )) {
                    ForEach(PushToTalkKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
            } footer: {
                Text("Hold this key in any app to dictate. The window's record button works "
                    + "regardless of what's focused.")
            }

            Section {
                Picker("Microphone", selection: Binding(
                    get: { settings.inputDeviceUID ?? MicrophonePicker.systemDefaultTag },
                    set: { settings.inputDeviceUID = $0 == MicrophonePicker.systemDefaultTag ? nil : $0 }
                )) {
                    MicrophonePicker.options()
                }
            } footer: {
                Text("Screen recorders and audio routers install aggregate devices that take "
                    + "over the system default input and carry no microphone signal. If the "
                    + "level never moves, pick your microphone here explicitly.")
            }

            Section {
                Toggle("Play a sound when recording starts and stops", isOn: $settings.soundEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private var transcription: some View {
        Form {
            Section {
                Picker("Engine", selection: $settings.engine) {
                    ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                        Text(choice == .apple ? "Apple" : "Parakeet").tag(choice)
                    }
                }
            } footer: {
                Text(settings.engine == .apple
                    ? "Apple's on-device transcriber. Streams text while you speak, needs no "
                        + "download, and follows your Mac's language."
                    : "Parakeet on the Neural Engine. Resolves on release rather than live, "
                        + "and downloads a ~470 MB model on first use.")
            }

            Section {
                Toggle("Clean up transcripts", isOn: $settings.cleanupEnabled)
                Toggle("Use on-device AI for cleanup", isOn: $settings.smartCleanup)
                    .disabled(!settings.cleanupEnabled || !FoundationModelFormatter.isAvailable)
            } footer: {
                if let reason = FoundationModelFormatter.unavailableReason {
                    Text(reason)
                } else {
                    Text("Cleanup removes fillers and fixes punctuation. The AI pass handles "
                        + "spoken self-corrections and lists as well, and never leaves your Mac. "
                        + "Dictionary corrections run either way.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
