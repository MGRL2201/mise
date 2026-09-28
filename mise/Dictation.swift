import AVFoundation
import Speech

/// On-device dictation for quick add: mic -> SpeechAnalyzer/SpeechTranscriber, live text in `transcript`.
// ponytail: SpeechTranscriber only (iOS/macOS 26 on-device); no SFSpeechRecognizer fallback for devices or
// locales it doesn't cover. Upgrade = SFSpeechRecognizer + SFSpeechAudioBufferRecognitionRequest when those show up.
@Observable @MainActor final class Dictation {
    static let micDenied = "Microphone access is off. Turn it on in Settings to dictate tasks."

    var transcript = ""
    var isRecording = false
    var error: String?
    /// True while start() or stop() is mid-flight; blocks overlapping calls that would leak a live engine.
    private(set) var busy = false

    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?

    func start() async {
        guard !isRecording, !busy else { return }
        busy = true
        defer { busy = false }
        transcript = ""
        error = nil
        // SpeechAnalyzer runs on device; only the mic needs permission (no SFSpeechRecognizer authorization).
        guard await AVAudioApplication.requestRecordPermission() else { error = Self.micDenied; return }
        guard SpeechTranscriber.isAvailable else { error = "Dictation isn't available on this device."; return }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            error = "Dictation isn't available for your language."
            return
        }
        do {
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults], attributeOptions: [])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                error = "Dictation isn't available on this device."
                return
            }
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let engine = AVAudioEngine()
            self.engine = engine
            input = continuation
            try Self.tap(engine.inputNode, into: continuation, as: format)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            results = Task {
                var finalized = ""
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal { finalized += text }
                        transcript = result.isFinal ? finalized : finalized + text
                    }
                } catch {
                    await fail(error)
                }
            }
            try await analyzer.start(inputSequence: stream)
            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            await fail(error)
        }
    }

    /// Stops listening, waits for the final words, and returns the whole transcript.
    func stop() async -> String {
        guard isRecording, !busy else { return transcript }
        busy = true
        defer { busy = false }
        stopAudio()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            self.error = error.localizedDescription
            await analyzer?.cancelAndFinishNow()
        }
        await results?.value
        analyzer = nil
        results = nil
        return transcript
    }

    private func fail(_ error: Error) async {
        self.error = error.localizedDescription
        stopAudio()
        results?.cancel()
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
    }

    private func stopAudio() {
        isRecording = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        input?.finish()
        input = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Nonisolated so the tap block (called on the audio thread) doesn't inherit MainActor isolation.
    nonisolated private static func tap(_ node: AVAudioInputNode, into out: AsyncStream<AnalyzerInput>.Continuation,
                                        as format: AVAudioFormat) throws {
        let natural = node.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, let converter = AVAudioConverter(from: natural, to: format) else { throw NoMicrophone() }
        node.installTap(onBus: 0, bufferSize: 4096, format: natural) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / natural.sampleRate) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0 { out.yield(AnalyzerInput(buffer: converted)) }
        }
    }

    nonisolated private struct NoMicrophone: LocalizedError {
        var errorDescription: String? { "No microphone found." }
    }
}
