import AppKit
import SwiftUI

@main
struct MurmurYouTubeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A `Window` rather than a `WindowGroup`: this app has one window, and letting ⌘N
        // spawn a second copy of it makes no sense.
        Window("Murmur", id: AppDelegate.mainWindowID) {
            MainWindow(controller: delegate.controller)
        }
        .defaultSize(width: 860, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Fully qualified: this app has its own `Settings` type, which otherwise shadows
        // SwiftUI's settings scene.
        SwiftUI.Settings {
            SettingsWindow(controller: delegate.controller)
        }

        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Image(systemName: delegate.controller.state.isActive ? "waveform.circle.fill" : "waveform")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    let controller = DictationController()
    private var hud: HUDPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hud = HUDPanel(controller: controller)

        if !controller.activate() {
            Permissions.promptForAccessibility()
            // The tap can only be created once the user grants Accessibility, and there's
            // no notification for that — poll until it takes.
            retryActivation()
        }

        // Write the dashboard up front so the menu item always opens something, even before
        // the first dictation.
        RunLog.regenerate()

        // Parakeet's models take ~20s to load from disk, and that cost lands on whichever
        // dictation touches them first — so the first hold after every launch would stall
        // with the HUD showing nothing. Warm them in the background instead, but only when
        // they're actually going to be used and are already downloaded.
        if Settings.shared.engine == .parakeet, ParakeetModels.isDownloaded {
            Task.detached(priority: .utility) {
                _ = try? await ParakeetModels.shared.manager()
            }
        }

        // Off the hot path: the first Foundation Models call is slow enough to blow the
        // cleanup timeout, and that cost only has to be paid once per launch.
        if Settings.shared.cleanupEnabled, Settings.shared.smartCleanup {
            FoundationModelFormatter.prewarm()
        }

        observeState()
        observeWindowClose()
        Log.app.info("Murmur ready — hold \(Settings.shared.pushToTalkKey.displayName, privacy: .public) to dictate")
    }

    // MARK: - Living in the menu bar

    /// Closing the window must not quit the app.
    ///
    /// This is a dictation tool: it is useful precisely when you are working in some other
    /// app, and the window is only where you go afterwards to read back or teach it a word.
    /// Quitting on close would mean the hotkey stops working the moment you tidy your desk.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon — during the window's brief life there — brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.showMainWindow() }
        return true
    }

    /// Drops the Dock icon once the last window is gone, and restores it when one returns.
    ///
    /// `LSUIElement` in Info.plist would hide the Dock icon permanently, which costs the app
    /// its menu bar and makes ⌘Q and the standard Edit menu unavailable while the window is
    /// open. Switching the activation policy at runtime keeps both: a real app with a real
    /// menu bar while you're looking at it, and nothing but a menu bar item once you close it.
    private func observeWindowClose() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            // `Notification` isn't `Sendable`, so the window is lifted out of it before the
            // isolation hop. The observer is registered on `.main`, so this already runs on
            // the main thread — `assumeIsolated` states that, it doesn't change it.
            nonisolated(unsafe) let object = notification.object
            MainActor.assumeIsolated {
                guard let closing = object as? NSWindow else { return }
                // The HUD is a non-activating panel and must never count as a window that
                // keeps the Dock icon alive.
                guard !(closing is HUDPanel) else { return }

                // The closing window is still in `NSApp.windows` at this point, so it has to
                // be excluded explicitly rather than simply counted.
                let othersRemain = NSApp.windows.contains { window in
                    window !== closing
                        && window.isVisible
                        && !(window is HUDPanel)
                        && window.canBecomeMain
                }
                guard !othersRemain else { return }

                // Deferred a runloop turn: changing the policy while AppKit is still tearing
                // down the window leaves the menu bar in a half-swapped state.
                Task { @MainActor in
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    /// Brings the window back from the menu bar, restoring the Dock icon first so the app
    /// has a menu bar to activate into.
    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(mainWindowID) == true }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            // No window to raise: SwiftUI recreates it from the scene on this action.
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.deactivate()
    }

    /// Shows and hides the HUD in step with the controller's state.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.controller.state.isActive {
                    self.hud?.present()
                } else {
                    self.hud?.dismiss()
                }
                self.observeState()
            }
        }
    }

    private func retryActivation() {
        Task { @MainActor in
            while !Permissions.hasAccessibility {
                try? await Task.sleep(for: .seconds(1))
            }
            controller.activate()
            Log.app.info("Accessibility granted — hotkey armed")
        }
    }
}

// MARK: - Menu bar

private struct MenuContent: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(controller.state.isActive ? "Stop Recording" : "Start Recording") {
            if controller.state.isActive {
                controller.stopButtonRecording()
            } else {
                controller.startButtonRecording()
            }
        }

        Text("Hold \(settings.pushToTalkKey.displayName) to dictate")

        Divider()

        Picker("Microphone", selection: Binding(
            get: { settings.inputDeviceUID ?? MicrophonePicker.systemDefaultTag },
            set: { settings.inputDeviceUID = $0 == MicrophonePicker.systemDefaultTag ? nil : $0 }
        )) {
            MicrophonePicker.options()
        }

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

        Toggle("Clean up text", isOn: $settings.cleanupEnabled)

        Divider()

        Button("Open Murmur") {
            openWindow(id: AppDelegate.mainWindowID)
            AppDelegate.showMainWindow()
        }
        .keyboardShortcut("o")

        Button("Quit Murmur") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
