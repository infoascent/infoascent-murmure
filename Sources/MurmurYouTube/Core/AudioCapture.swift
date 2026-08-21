import AVFoundation
import Foundation

/// Microphone capture with on-the-fly conversion to whatever format the speech engine wants.
///
/// The tap runs on a real-time audio thread, so everything it touches lives behind
/// `nonisolated(unsafe)` and is only ever mutated from that one thread.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    /// What `converter` expects: the tap's format, or a mono version of it.
    private nonisolated(unsafe) var captureFormat: AVAudioFormat?

    /// Which channel of a multi-channel tap carries the microphone.
    ///
    /// Chosen once per recording and then held. Picking per buffer would let it hop between
    /// channels on a pause, splicing two different sources into one utterance.
    private nonisolated(unsafe) var dominantChannel: Int?
    private nonisolated(unsafe) var channelEnergy: [Double] = []
    private nonisolated(unsafe) var energyFrames = 0
    private var isRunning = false

    /// Called on the audio thread with each converted buffer.
    private nonisolated(unsafe) var onBuffer: (@Sendable (AudioChunk) -> Void)?
    /// Called on the audio thread with a 0…1 RMS level, for the HUD waveform.
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?

    func start(
        outputFormat: AVAudioFormat,
        deviceUID: String?,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        guard !isRunning else { return }

        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.outputFormat = outputFormat

        // Bind the device *before* reading the input format: the format reported by the
        // node belongs to whatever device is currently attached, so reading it first would
        // configure the converter for the old device and hand the engine resampled noise.
        //
        // `reset()` first because the engine is reused across recordings. Once its graph has
        // been configured against one device, moving to another without a reset leaves the
        // node reporting the previous device's format.
        if let device = AudioDevices.preferred(uid: deviceUID) {
            engine.reset()
            try AudioDevices.bind(engine, to: device)
            Log.audio.info("input device: \(device.name, privacy: .public)")
        }

        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)

        // The tap's buffers are mixed down to mono *by hand* rather than by the converter.
        //
        // `AVAudioEngine` caches its input node's output format and never refreshes it after
        // the device moves: `setDeviceID` genuinely switches the hardware — `inputFormat`
        // reports the microphone's 1 channel — but `outputFormat` stays on the previous
        // device's channel count, and the node upmixes the mono microphone across all of
        // them. One channel then carries the voice and the rest carry silence.
        //
        // Handing that to `AVAudioConverter` averages the channels, so a 16-channel
        // aggregate divides speech by 16: loud enough to move a level meter, roughly 24 dB
        // too quiet for the recogniser, and reported nowhere. Selecting the channel that
        // actually carries signal sidesteps the whole thing, and keeps working no matter
        // which aggregate device the system has made default.
        let captureFormat = nativeFormat.channelCount > 1
            ? AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: nativeFormat.sampleRate,
                channels: 1,
                interleaved: false
              ) ?? nativeFormat
            : nativeFormat

        self.captureFormat = captureFormat
        dominantChannel = nil
        channelEnergy = [Double](repeating: 0, count: Int(nativeFormat.channelCount))
        energyFrames = 0

        converter = captureFormat == outputFormat
            ? nil
            : AVAudioConverter(from: captureFormat, to: outputFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: nativeFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        Log.audio.info("capture started — native \(nativeFormat.sampleRate, privacy: .public)Hz \(nativeFormat.channelCount, privacy: .public)ch → mono → engine \(outputFormat.sampleRate, privacy: .public)Hz \(outputFormat.channelCount, privacy: .public)ch")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        converter = nil
        captureFormat = nil
        dominantChannel = nil
        channelEnergy = []
        energyFrames = 0
        onBuffer = nil
        onLevel = nil
        Log.audio.info("capture stopped")
    }

    // MARK: - Audio thread

    private func handle(_ tapBuffer: AVAudioPCMBuffer) {
        onLevel?(Self.rms(of: tapBuffer))

        guard let outputFormat, let captureFormat else { return }

        // Collapse a multi-channel tap onto the one channel carrying the microphone.
        let buffer = captureFormat.channelCount < tapBuffer.format.channelCount
            ? extractDominantChannel(from: tapBuffer, into: captureFormat)
            : tapBuffer
        guard let buffer else { return }

        // AVAudioEngine reuses the tap's buffer as soon as this returns, so the engine
        // must never see it directly — copy when no conversion would otherwise allocate.
        guard let converter else {
            if let copy = Self.copy(buffer) {
                onBuffer?(AudioChunk(buffer: copy))
            }
            return
        }

        // Output frame count scales with the sample-rate ratio; round up so we never clip.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // The input block runs synchronously inside `convert`, on this thread.
        nonisolated(unsafe) let input = buffer
        let consumed = Latch()
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !consumed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }

        if let error {
            Log.audio.error("conversion failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard status != .error, converted.frameLength > 0 else { return }
        onBuffer?(AudioChunk(buffer: converted))
    }

    /// Copies the microphone's channel out of a multi-channel tap buffer.
    ///
    /// Which channel that is gets decided from the first ~0.4s of audio, by total energy,
    /// and then held for the rest of the recording. Deciding per buffer would let the
    /// choice hop on a pause — the moment every channel is equally quiet — and splice two
    /// different sources into one utterance.
    private func extractDominantChannel(
        from buffer: AVAudioPCMBuffer,
        into format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return nil }

        let selected: Int
        if let dominantChannel {
            selected = min(dominantChannel, channelCount - 1)
        } else {
            for channel in 0..<min(channelCount, channelEnergy.count) {
                let samples = channels[channel]
                var sum = 0.0
                for i in 0..<frames {
                    let sample = Double(samples[i])
                    sum += sample * sample
                }
                channelEnergy[channel] += sum
            }
            energyFrames += frames

            let loudest = channelEnergy.indices.max { channelEnergy[$0] < channelEnergy[$1] } ?? 0
            // Roughly 0.4s at any sample rate this hardware produces.
            if Double(energyFrames) >= buffer.format.sampleRate * 0.4 {
                dominantChannel = loudest
                Log.audio.info("using input channel \(loudest, privacy: .public) of \(channelCount, privacy: .public)")
            }
            selected = loudest
        }

        guard let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData
        else { return nil }

        mono.frameLength = buffer.frameLength
        destination[0].update(from: channels[selected], count: frames)
        return mono
    }

    /// Deep-copies a tap buffer into storage we own.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }

        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else {
            return nil
        }

        return copy
    }

    /// One-shot flag. Only touched from the audio thread inside a synchronous call.
    private final class Latch: @unchecked Sendable {
        private var fired = false
        /// - Returns: the value *before* this call, then latches to `true`.
        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        // Loudest channel, not channel 0. On a multi-channel device the microphone is
        // rarely the first leg — reading channel 0 alone is what makes a working mic look
        // like a dead one.
        var rms: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            var sum: Float = 0
            for i in 0..<count {
                let sample = samples[i]
                sum += sample * sample
            }
            rms = max(rms, (sum / Float(count)).squareRoot())
        }

        // Map roughly -50…0 dBFS onto 0…1 so quiet speech still moves the meter.
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }
}
