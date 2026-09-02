import MurmurDictionary
import AVFoundation
import Foundation
import Speech

/// Streaming on-device transcription via macOS 26's `SpeechAnalyzer` / `SpeechTranscriber`.
///
/// No model ships with the app — the OS downloads and manages the assets, so the first
/// run for a given locale may block briefly while `AssetInstallationRequest` completes.
actor AppleSpeechEngine: TranscriptionEngine {
    private let locale: Locale

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    /// Held so `finish()` can close the stream itself when the analyzer won't.
    private var chunkContinuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    /// Text the engine has committed. Volatile results are appended on top for display
    /// but discarded as soon as a final result covering the same range arrives.
    private var finalizedText = ""

    init(locale: Locale = Locale.current) {
        self.locale = locale
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        let module = transcriber ?? Self.makeTranscriber(locale: locale)
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.localeUnsupported(locale)
        }

        let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            ?? Locale(identifier: "en-US")

        let transcriber = Self.makeTranscriber(locale: resolvedLocale)
        self.transcriber = transcriber

        try await Self.ensureModelInstalled(for: transcriber)

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputContinuation

        // Bias the recognizer toward the dictionary's words before it hears anything. This
        // is a nudge, not a guarantee — `DictionaryCorrector` is the pass that actually
        // enforces spelling — but it's free and it catches things a post-hoc rewrite can't,
        // like a name the engine would otherwise split into two ordinary words.
        //
        // The list is capped at `DictionaryCorrector.biasLimit`. A long context list makes
        // these models drift: on quiet or ambiguous audio they start emitting the terms they
        // were primed with, which is a far worse failure than the misspelling it prevents.
        // Only the input-sequence initializers take a context up front, and this analyzer is
        // fed by `analyzer.start(inputSequence:)` later — so the context is applied here
        // instead. It must be set before any audio arrives to affect recognition.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if let context = await Self.context() {
            try? await analyzer.setContext(context)
        }

        finalizedText = ""

        let (chunks, chunkContinuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.chunkContinuation = chunkContinuation

        // Drain the transcriber's results into our simpler chunk stream.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    let snapshot = await self.absorb(result)
                    chunkContinuation.yield(TranscriptionChunk(text: snapshot, isFinal: false))
                }
                let final = await self?.finalizedText ?? ""
                chunkContinuation.yield(TranscriptionChunk(text: final, isFinal: true))
                chunkContinuation.finish()
            } catch {
                Log.speech.error("results stream failed: \(error.localizedDescription, privacy: .public)")
                chunkContinuation.finish(throwing: error)
            }
        }

        try await analyzer.start(inputSequence: inputStream)
        Log.speech.info("SpeechAnalyzer started for \(resolvedLocale.identifier, privacy: .public)")

        return chunks
    }

    func feed(_ chunk: AudioChunk) async {
        inputContinuation?.yield(AnalyzerInput(buffer: chunk.buffer))
    }

    /// Closes the session and flushes what the analyzer has, but never waits forever.
    ///
    /// `finalizeAndFinishThroughEndOfInput()` does not reliably return when the session was
    /// handed almost no audio — a key tapped rather than held, or a hold whose model load
    /// ran long enough to eat the whole utterance. It simply never comes back, and since
    /// the rest of the dictation lifecycle waits on this call, the HUD used to stay on
    /// screen with no way out short of relaunching the app.
    ///
    /// So the call is raced against a deadline. Past it the analyzer is told to stop where
    /// it is, and the result stream is closed from this side — whatever text had already
    /// been committed is still returned, which for an utterance this short is usually none.
    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil

        let analyzer = self.analyzer
        self.analyzer = nil
        self.transcriber = nil

        if let analyzer {
            let finalized = await withDeadline(seconds: Self.finalizeDeadline) {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    Log.speech.error("finalize failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            if !finalized {
                Log.speech.error("finalize timed out after \(Self.finalizeDeadline, privacy: .public)s — stopping the analyzer where it stands")
                // Detached: `cancelAndFinishNow` is the escape hatch for a stuck analyzer
                // and can be stuck itself. Nothing here needs to see it return.
                Task.detached { await analyzer.cancelAndFinishNow() }
            }
        }

        // The consumer of `chunks` waits for this stream to end. On the timed-out path the
        // analyzer never ends it, so close it here — otherwise the wedge simply moves one
        // step downstream.
        resultsTask?.cancel()
        resultsTask = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
    }

    private static let finalizeDeadline: Double = 5

    // MARK: - Result accumulation

    /// Folds one result into the running transcript and returns the full text to display.
    ///
    /// Final results are committed; a volatile result is shown appended to the committed
    /// text but never stored, so the next revision replaces it cleanly.
    private func absorb(_ result: SpeechTranscriber.Result) -> String {
        let text = String(result.text.characters)
        guard result.isFinal else {
            return (finalizedText + text).trimmingCharacters(in: .whitespaces)
        }
        finalizedText += text
        return finalizedText.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Setup helpers

    /// The dictionary's words, handed to the analyzer as contextual strings.
    ///
    /// Reads the store on the main actor because that's where it lives; the resulting array
    /// of strings is plain value data and crosses back safely.
    /// - Returns: nil when the dictionary is empty, so an empty context is never set for
    ///   nothing.
    ///
    /// Hops to the main actor rather than asserting it. The store is main-actor isolated and
    /// this runs on the engine's own executor — `MainActor.assumeIsolated` here doesn't check
    /// that claim, it asserts it, and takes the whole process down when it's false.
    private static func context() async -> AnalysisContext? {
        let phrases = await MainActor.run { DictionaryStore.shared.biasPhrases }
        guard !phrases.isEmpty else { return nil }

        let context = AnalysisContext()
        context.contextualStrings[.general] = phrases
        Log.speech.info("biasing with \(phrases.count, privacy: .public) dictionary phrase(s)")
        return context
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // `.volatileResults` is what makes live text appear while you're still talking.
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    private static func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let selected = transcriber.selectedLocales
        let alreadyThere = selected.allSatisfy { locale in
            installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        }
        guard !alreadyThere else { return }

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Log.speech.info("downloading speech model…")
                try await request.downloadAndInstall()
                Log.speech.info("speech model installed")
            }
        } catch {
            throw TranscriptionError.modelInstallFailed(error.localizedDescription)
        }
    }
}
