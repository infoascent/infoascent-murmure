import Foundation
import Observation

/// Which speech engine transcribes an utterance.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case parakeet

    var displayName: String {
        switch self {
        case .apple: "Apple (streaming)"
        case .parakeet: "Parakeet (batch)"
        }
    }

    /// Apple shows text while you talk; Parakeet only resolves on release.
    var showsLiveText: Bool { self == .apple }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var pushToTalkKey: PushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey) }
    }

    /// How long the push-to-talk key has to be held before the recording counts.
    ///
    /// The key lives where a hand rests, and clipping it while typing used to start an
    /// utterance nobody meant. Anything shorter than this is discarded without
    /// transcribing. `0` accepts every press.
    var minimumHoldSeconds: Double {
        didSet { defaults.set(minimumHoldSeconds, forKey: Keys.minimumHoldSeconds) }
    }

    /// Two quick taps latch the mic open, one tap ends it — dictation without holding the
    /// key down for the whole utterance.
    var handsFreeLockEnabled: Bool {
        didSet { defaults.set(handsFreeLockEnabled, forKey: Keys.handsFreeLockEnabled) }
    }

    var engine: SpeechEngineChoice {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    /// Which microphone to record from, stored by CoreAudio UID. `nil` means "whatever the
    /// system default is", which is the right default but the wrong answer often enough —
    /// aggregate/loopback devices install themselves as the default and record silence —
    /// that the choice has to be exposed.
    var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) }
    }

    /// Run every engine on each recording and show them side by side, instead of
    /// transcribing with one. Nothing is typed into the focused app in this mode.
    var compareMode: Bool {
        didSet { defaults.set(compareMode, forKey: Keys.compareMode) }
    }

    /// Run the cleanup pass before injecting. Off = raw engine output.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }

    /// Use the on-device LLM for cleanup instead of the deterministic rule pass.
    var smartCleanup: Bool {
        didSet { defaults.set(smartCleanup, forKey: Keys.smartCleanup) }
    }

    /// Play a short tick when capture starts and stops.
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        static let inputDeviceUID = "inputDeviceUID"
        static let smartCleanup = "smartCleanup"
        static let compareMode = "compareMode"
        static let minimumHoldSeconds = "minimumHoldSeconds"
        static let handsFreeLockEnabled = "handsFreeLockEnabled"
    }

    private init() {
        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.rightOption.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .rightOption
        // Apple by default: no download, no dependency, live text while speaking.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        inputDeviceUID = defaults.string(forKey: Keys.inputDeviceUID)
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        smartCleanup = defaults.object(forKey: Keys.smartCleanup) as? Bool ?? false
        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        // Long enough to drop a key brushed while typing, short enough to keep a one-word
        // answer. Measured against real holds: deliberate ones don't come in under 400ms.
        minimumHoldSeconds = defaults.object(forKey: Keys.minimumHoldSeconds) as? Double ?? 0.4
        handsFreeLockEnabled = defaults.object(forKey: Keys.handsFreeLockEnabled) as? Bool ?? true
    }
}
