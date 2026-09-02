import MurmurDictionary
import AVFoundation
import AppKit
import Foundation
import Observation

/// Builds the engine named by the current setting.
///
/// Deliberately at file scope rather than a static on `DictationController`: the class is
/// `@MainActor`, which would make a static method main-actor-isolated and therefore
/// ineligible to be `@Sendable`. Reading the setting per-utterance is what lets the menu's
/// engine picker take effect on the very next hold instead of needing a restart.
@Sendable
func engineForCurrentSetting() -> any TranscriptionEngine {
    // Always invoked from `beginDictation`, which runs on the main actor.
    MainActor.assumeIsolated {
        switch Settings.shared.engine {
        case .apple: AppleSpeechEngine()
        case .parakeet: ParakeetEngine()
        }
    }
}

@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing
        case error(String)

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing: true
            case .idle, .error: false
            }
        }
    }

    private(set) var state: State = .idle
    /// Hands-free: the mic stays open after the key comes back up, until the next tap.
    private(set) var isLocked = false
    /// Live transcript, updated as the engine revises it. Drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0…1 mic level for the waveform.
    private(set) var level: Float = 0

    private let hotkey = HotkeyMonitor()
    private let capture = AudioCapture()
    private let makeEngine: @Sendable () -> any TranscriptionEngine

    /// Injected only by tests; production reads the setting per-utterance below.
    private let formatter: (any TextFormatter)?

    /// Chosen per-utterance so the menu toggle applies to the very next hold.
    private var activeFormatter: any TextFormatter {
        if let formatter { return formatter }
        return Settings.shared.smartCleanup
            ? FoundationModelFormatter()
            : RuleBasedFormatter()
    }

    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    /// Returns the ordered recording when compare mode is on, empty otherwise.
    private var feedTask: Task<[AudioChunk], Never>?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?

    /// Timestamps for the dashboard: when the key went down, and when it came up.
    private var holdStarted: Date?
    private var releasedAt: Date?
    private var engineName = ""

    /// Compare mode only: the recording, kept so every engine sees identical audio.
    private var recorded: [AudioChunk] = []
    private var isComparing = false

    /// Identifies one utterance. Every asynchronous step carries the number it was started
    /// with and refuses to touch shared state once a newer one has begun.
    private var session = 0
    /// The lifecycle queue. See `enqueue`.
    private var work: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    /// Gesture recognition for the push-to-talk key.
    private var pressedAt: Date?
    private var lastShortTapAt: Date?
    private var pendingLock = false
    private var ignoreNextRelease = false

    /// How close together two taps have to be to read as one double tap.
    private static let doubleTapWindow: TimeInterval = 0.45

    init(
        formatter: (any TextFormatter)? = nil,
        makeEngine: @escaping @Sendable () -> any TranscriptionEngine = engineForCurrentSetting
    ) {
        self.formatter = formatter
        self.makeEngine = makeEngine
    }

    // MARK: - Lifecycle

    /// - Returns: `false` if the hotkey tap couldn't be installed (missing Accessibility).
    @discardableResult
    func activate() -> Bool {
        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.onPress = { [weak self] in self?.handleKeyDown() }
        hotkey.onRelease = { [weak self] in self?.handleKeyUp() }
        return hotkey.start()
    }

    func deactivate() {
        hotkey.stop()
        cancelDictation()
    }

    /// Re-arms the tap after the user picks a different push-to-talk key.
    @discardableResult
    func reloadHotkey() -> Bool {
        hotkey.stop()
        return activate()
    }

    // MARK: - The push-to-talk gesture

    /// The key going down.
    ///
    /// Three gestures share one key: hold to talk, a stray brush that must be ignored, and
    /// a double tap that latches the mic open. Which one this is can only be known on the
    /// way back up, so the press always starts capture — throwing away 300ms of audio costs
    /// nothing, and waiting to find out would clip the first word of every utterance.
    private func handleKeyDown() {
        let now = Date()

        // Latched and talking: this tap is the stop. The matching release must not then be
        // read as the end of a hold that never happened.
        if isLocked {
            isLocked = false
            ignoreNextRelease = true
            pressedAt = nil
            lastShortTapAt = nil
            Log.hotkey.info("hands-free lock released")
            endDictation()
            return
        }

        if Settings.shared.handsFreeLockEnabled,
           let last = lastShortTapAt,
           now.timeIntervalSince(last) <= Self.doubleTapWindow {
            pendingLock = true
        }
        lastShortTapAt = nil
        pressedAt = now
        beginDictation()
    }

    /// The key coming back up: this is where the gesture is finally identified.
    private func handleKeyUp() {
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }
        guard let pressedAt else { return }
        self.pressedAt = nil

        let held = Date().timeIntervalSince(pressedAt)
        let wasBrief = held < Settings.shared.minimumHoldSeconds

        // Second tap of a double tap: keep the mic open until the next tap. A *held* second
        // press is an ordinary hold, not a latch — someone who wants to keep holding the
        // key is already telling us when they're done.
        if pendingLock {
            pendingLock = false
            if wasBrief {
                isLocked = true
                Log.hotkey.info("hands-free lock engaged")
                return
            }
        }

        // A brush of the key while typing, or the first tap of a double tap. Either way
        // there is no utterance here.
        if wasBrief {
            lastShortTapAt = Date()
            abortDictation()
            return
        }

        endDictation()
    }

    // MARK: - Button-driven recording

    /// Starts a recording from a Record button rather than the hotkey.
    ///
    /// Wispr Flow's hotkey is held down for the duration **only in compare mode**. Reaching
    /// into another app is a comparison affordance; during ordinary dictation it would mean
    /// every recording silently shipped your audio to a third party's servers.
    func startButtonRecording() {
        guard case .idle = state else { return }
        if Settings.shared.compareMode { WisprTrigger.press() }
        beginDictation()
    }

    /// Releases Wispr's hotkey first, so its upload starts while our own engines are still
    /// finishing — otherwise every run would wait the full round trip end to end.
    func stopButtonRecording() {
        WisprTrigger.release()
        endDictation()
    }

    // MARK: - Dictation

    private func beginDictation() {
        guard case .idle = state else { return }
        Log.speech.info("dictation begin")
        session += 1
        let session = self.session
        state = .starting
        transcript = ""
        holdStarted = Date()
        isComparing = Settings.shared.compareMode
        recorded.removeAll(keepingCapacity: true)
        engineName = isComparing ? "Comparing…" : Settings.shared.engine.displayName
        startWatchdog(session: session)

        enqueue { await self.startPipeline(session) }
    }

    /// Builds the capture chain. Runs on the lifecycle queue, so nothing else in this class
    /// is running while it does.
    private func startPipeline(_ session: Int) async {
        // Released before we got as far as asking for a microphone: nothing has been built
        // yet, so there is nothing to unwind.
        guard session == self.session, case .starting = state else { return }

        do {
            guard await Permissions.requestMicrophone() else {
                fail("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                return
            }
            guard session == self.session, case .starting = state else { return }

            let engine = makeEngine()
            self.engine = engine

            let chunks = try await engine.start()

            // Compare mode captures in *Apple's* format, not a format of our choosing.
            //
            // SpeechAnalyzer enforces `Audio sample data must be 16-bit signed integers`
            // as a hard precondition — feeding it float32 doesn't fail gracefully, it
            // kills the process. Parakeet is the flexible one (its `feed` converts
            // int16/int32/float32), so the strict engine picks the format and the
            // tolerant engine adapts. Both still replay the identical buffers.
            let formatOwner: any TranscriptionEngine = isComparing ? AppleSpeechEngine() : engine
            guard let format = await formatOwner.preferredInputFormat() else {
                throw TranscriptionError.noAudioFormat
            }

            // Audio must reach the engine in capture order. A stream plus a single
            // draining task guarantees that; spawning a Task per buffer would not.
            let (audioStream, audioContinuation) = AsyncStream<AudioChunk>.makeStream(
                bufferingPolicy: .bufferingNewest(64)
            )
            self.audioContinuation = audioContinuation

            // The recording is accumulated *inside* the ordered drain, not by spawning
            // a task per buffer. Unstructured tasks have no ordering guarantee, so
            // collecting them separately could assemble the replay audio out of order
            // and silently produce word-salad from the comparison.
            let comparing = isComparing
            self.feedTask = Task.detached(priority: .userInitiated) {
                var recording: [AudioChunk] = []
                for await chunk in audioStream {
                    if comparing { recording.append(chunk) }
                    await engine.feed(chunk)
                }
                return recording
            }

            try capture.start(
                outputFormat: format,
                deviceUID: Settings.shared.inputDeviceUID,
                onBuffer: { chunk in
                    audioContinuation.yield(chunk)
                },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.updateLevel(level) }
                }
            )

            // Bail out if the user already let go while we were spinning up.
            guard session == self.session, case .starting = self.state else {
                await self.teardown()
                return
            }

            self.state = .listening
            if Settings.shared.soundEnabled { NSSound(named: "Tink")?.play() }

            self.consumeTask = Task { @MainActor in
                do {
                    for try await chunk in chunks {
                        self.transcript = chunk.text
                    }
                } catch {
                    self.fail(error.localizedDescription)
                }
            }
        } catch {
            self.fail(error.localizedDescription)
        }
    }

    private func endDictation() {
        // `.finishing` is "active", so without this a second press during processing would
        // run the whole tail again — re-reading `transcript` before the first pass cleared
        // it and pasting the same utterance twice. The window is wide: Parakeet transcribes
        // inside `finish()`, and smart cleanup adds up to 4s on top.
        guard state.isActive, state != .finishing else { return }
        isLocked = false
        state = .finishing
        capture.stop()
        level = 0
        releasedAt = Date()

        let session = self.session
        enqueue { await self.stopPipeline(session) }
    }

    /// Throws away an utterance nobody meant to start.
    ///
    /// The pill comes down immediately — the whole point of this path is that a key brushed
    /// while typing leaves nothing behind — and the engine is unwound behind it on the
    /// lifecycle queue.
    private func abortDictation() {
        guard state.isActive else { return }
        Log.speech.info("dictation discarded — key held below the minimum")
        capture.stop()
        isLocked = false
        state = .idle
        transcript = ""
        level = 0

        let session = self.session
        enqueue { await self.abortPipeline(session) }
    }

    private func abortPipeline(_ session: Int) async {
        guard session == self.session else { return }

        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        consumeTask?.cancel()
        consumeTask = nil

        let feed = feedTask
        let engine = self.engine
        feedTask = nil
        self.engine = nil

        // Wound down *off* the queue, unlike every other path here.
        //
        // Nothing this session produced is wanted — no transcript, no recording — and
        // `finish()` on a streaming engine can take a second or more. The first tap of a
        // double tap comes through here, so waiting for it would mean the hands-free
        // recording that tap latches open starts with its first word already gone.
        Task.detached {
            _ = await feed?.value
            await engine?.finish()
        }
    }

    /// Finalizes the engine, cleans the transcript and types it. Runs on the lifecycle
    /// queue, behind whatever `startPipeline` still had to do.
    private func stopPipeline(_ session: Int) async {
        guard session == self.session, state == .finishing else { return }

        // Drain every captured buffer into the engine before asking it to finalize,
        // or the tail of the utterance gets dropped.
        audioContinuation?.finish()
        audioContinuation = nil
        recorded = await feedTask?.value ?? []
        feedTask = nil

        // Bounded, because an engine that never returns from `finish()` would hold the
        // whole lifecycle open — and this is the one place the user is already waiting.
        // Apple's engine defends itself as well; this covers whichever engine is selected.
        let closing = engine
        engine = nil
        if await withDeadline(seconds: 8, { await closing?.finish() }) == false {
            Log.speech.error("engine finish timed out — giving up on the tail of this utterance")
        }

        let consuming = consumeTask
        consumeTask = nil
        _ = await withDeadline(seconds: 3) { await consuming?.value }
        consuming?.cancel()

        guard session == self.session else { return }

        if isComparing {
            await runComparison()
            return
        }

        let raw = transcript
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.speech.error("empty transcript — the engine received audio but recognised nothing")
            state = .idle
            transcript = ""
            return
        }
        Log.speech.info("raw transcript: \(raw.count, privacy: .public) chars")

        let cleaned = Settings.shared.cleanupEnabled
            ? await activeFormatter.format(raw)
            : raw

        // The dictionary runs last, and runs regardless of the cleanup setting. Biasing
        // only raises the odds of the right word; this is the pass that guarantees it,
        // so it must not be something the user can accidentally switch off.
        let (output, corrections) = DictionaryStore.shared.corrector.apply(to: cleaned)
        if !corrections.isEmpty {
            Log.speech.info("dictionary · \(corrections.count, privacy: .public) correction(s) applied")
        }

        // Last checkpoint before the one irreversible act in this class. A watchdog
        // reset during a long cleanup pass orphans this session, and typing its
        // transcript into whatever has focus by then would be a genuine surprise.
        guard session == self.session else { return }

        recordRun(text: output, corrections: corrections)
        Log.inject.info("inserting \(output.count, privacy: .public) chars")
        TextInjector.insert(output)
        if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }

        state = .idle
        transcript = ""
    }

    private func cancelDictation() {
        isLocked = false
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil

        let engine = self.engine
        self.engine = nil
        Task { await engine?.finish() }

        state = .idle
        transcript = ""
        level = 0
    }

    private func teardown() async {
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        await feedTask?.value
        feedTask = nil
        let closing = engine
        engine = nil
        _ = await withDeadline(seconds: 8) { await closing?.finish() }
        consumeTask?.cancel()
        consumeTask = nil
    }

    // MARK: - Serialising the lifecycle

    /// Runs one lifecycle step only once the previous one has finished.
    ///
    /// Press and release can land milliseconds apart — a key brushed while typing does
    /// exactly that — and each half of the lifecycle suspends several times. Left to
    /// interleave, the release path ends up awaiting an engine the press path is still
    /// building, and the two overwrite each other's continuation and tasks. The utterance
    /// then never reaches `.idle`: the pill sits on screen and the only cure is relaunching
    /// the app. Serialising the steps makes them run in the order the key was actually
    /// pressed in, which is the order the user experienced.
    private func enqueue(_ step: @escaping @MainActor () async -> Void) {
        let previous = work
        work = Task { @MainActor in
            await previous?.value
            await step()
        }
    }

    /// Last resort, so that no failure can leave the pill on screen for good.
    ///
    /// Every path back to `.idle` is serialised now, but an engine that never returns from
    /// `finish()` would still wedge the queue, and today that costs a relaunch. A session
    /// still starting long after any hardware would have come up, or still finishing long
    /// after any transcript would have landed, is abandoned instead.
    private func startWatchdog(session: Int) {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            var starting = 0.0
            var finishing = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, session == self.session, !Task.isCancelled else { return }

                switch self.state {
                case .starting: starting += 0.5
                case .finishing: finishing += 0.5
                case .listening: break          // a latched hold is allowed to run all day
                case .idle, .error: return
                }

                if starting > 10 || finishing > 60 {
                    Log.app.error("dictation wedged — abandoning the session and re-arming")
                    self.forceReset()
                    return
                }
            }
        }
    }

    /// Drops everything in flight and returns to a state the next key press can use.
    private func forceReset() {
        work?.cancel()
        work = nil
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil
        engine = nil
        isLocked = false
        pendingLock = false
        ignoreNextRelease = false
        pressedAt = nil
        // Orphans every step still running inside the abandoned queue.
        session += 1
        state = .idle
        transcript = ""
        level = 0
    }

    // MARK: - Helpers

    private func retainForComparison(_ chunk: AudioChunk) {
        guard isComparing else { return }
        recorded.append(chunk)
    }

    /// Replays the recording through every engine and files the results as one group.
    ///
    /// Nothing is injected in this mode — the point is to read the outputs side by side,
    /// and typing one of them into whatever had focus would be a surprise.
    private func runComparison() async {
        let chunks = recorded
        recorded.removeAll(keepingCapacity: false)

        guard !chunks.isEmpty, let holdStarted, let releasedAt else {
            state = .idle
            transcript = ""
            return
        }

        transcript = "Running both engines…"

        let group = UUID().uuidString
        let held = releasedAt.timeIntervalSince(holdStarted)

        // Filed one at a time as each engine finishes, so the window fills in progressively
        // rather than snapping both rows into place at the end.
        let results = await EngineComparison.run(chunks: chunks) { result in
            RunLog.record(
                DictationRun(
                    date: releasedAt,
                    engine: result.engine,
                    audioSeconds: held,
                    processSeconds: result.seconds,
                    text: result.text,
                    group: group
                )
            )
        }

        for result in results {
            Log.speech.info("""
                compare · \(result.engine, privacy: .public): \
                \(result.seconds, format: .fixed(precision: 2))s — \
                \(result.text, privacy: .public)
                """)
        }

        // Wispr Flow, if its hotkey was held for this same utterance. It transcribes in the
        // cloud, so its row lands after both local engines have already finished — the wait
        // happens here rather than blocking the rows above from appearing.
        if WisprReader.isInstalled {
            transcript = "Waiting for Wispr Flow…"
            if let wispr = await WisprReader.result(after: holdStarted, timeout: 8) {
                RunLog.record(
                    DictationRun(
                        date: releasedAt,
                        engine: wispr.engine,
                        audioSeconds: held,
                        processSeconds: wispr.seconds,
                        text: wispr.text,
                        group: group
                    )
                )
                Log.speech.info("""
                    compare · \(wispr.engine, privacy: .public): \
                    \(wispr.seconds, format: .fixed(precision: 2))s — \
                    \(wispr.text, privacy: .public)
                    """)
            } else {
                Log.speech.info("compare · Wispr Flow: no result (hotkey not held, or timed out)")
            }
        }

        self.holdStarted = nil
        self.releasedAt = nil
        isComparing = false
        state = .idle
        transcript = ""

        if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }
    }

    /// Files the finished utterance for the dashboard.
    ///
    /// `processSeconds` is measured from key release, not from capture start — that's the
    /// wait the user actually experiences, and it's the only number on which a streaming
    /// engine and a batch engine can be compared honestly.
    private func recordRun(text: String, corrections: [AppliedCorrection] = []) {
        guard let holdStarted, let releasedAt else { return }
        RunLog.record(
            DictationRun(
                date: releasedAt,
                engine: engineName,
                audioSeconds: releasedAt.timeIntervalSince(holdStarted),
                processSeconds: Date().timeIntervalSince(releasedAt),
                text: text,
                corrections: corrections.isEmpty ? nil : corrections
            )
        )
        self.holdStarted = nil
        self.releasedAt = nil
    }

    /// Light smoothing so the waveform glides instead of strobing at buffer rate.
    private func updateLevel(_ new: Float) {
        level += (new - level) * 0.35
    }

    private func fail(_ message: String) {
        Log.app.error("dictation failed — \(message, privacy: .public)")
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .error(message)
        level = 0

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .error = state { state = .idle }
        }
    }
}
