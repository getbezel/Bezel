import AVFoundation
import Speech

@MainActor
final class PromptVoiceInput {
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var configurationObserver: NSObjectProtocol?
    private var generation = UUID()

    enum Failure: LocalizedError {
        case speechPermission, microphonePermission, language, input, service
        var errorDescription: String? {
            switch self {
            case .speechPermission: "Allow Speech Recognition for Bezel in Privacy & Security."
            case .microphonePermission: "Allow Microphone for Bezel in Privacy & Security."
            case .language: "On-device speech is unavailable for your language. Try timed scrolling."
            case .input: "Choose a working microphone in Sound Settings, then press Play."
            case .service: "Speech recognition is unavailable. Try timed scrolling or press Play to retry."
            }
        }
    }

    func start(onReady: @escaping @MainActor () -> Void,
               onText: @escaping @MainActor (String) -> Void,
               onEnd: @escaping @MainActor (String?) -> Void) async {
        stop()
        let token = generation
        guard let recognizer = SFSpeechRecognizer(locale: .current),
              recognizer.supportsOnDeviceRecognition else { onEnd(Failure.language.localizedDescription); return }
        let speech = await Self.speechPermission()
        guard token == generation else { return }
        guard speech == .authorized else { onEnd(Failure.speechPermission.localizedDescription); return }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard token == generation else { return }
        guard mic else { onEnd(Failure.microphonePermission.localizedDescription); return }
        guard recognizer.isAvailable else { onEnd(Failure.service.localizedDescription); return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { onEnd(Failure.input.localizedDescription); return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.engine = engine
        self.request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.audioTap(for: request))
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                      object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.stop()
                onEnd(Failure.input.localizedDescription)
            }
        }
        do {
            engine.prepare()
            try engine.start()
            task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] phrase, final, error in
                guard let self, self.generation == token else { return }
                if let phrase { onText(phrase) }
                guard self.generation == token, error != nil || final else { return }
                self.stop()
                onEnd(error)
            })
            onReady()
        } catch {
            stop()
            onEnd(Failure.input.localizedDescription)
        }
    }

    func stop() {
        generation = UUID()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        engine = nil
        request = nil
        task = nil
    }

    private nonisolated static func speechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status != .notDetermined { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    // The microphone callback runs on Core Audio's thread. Only Apple's streaming request crosses it.
    private nonisolated static func audioTap(for request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func resultHandler(
        deliver: @escaping @MainActor @Sendable (String?, Bool, String?) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let phrase = result?.bestTranscription.formattedString
            let failure = error as NSError?
            // A quiet interval can end an on-device recognition request. Re-arm it without
            // advancing the script, so the next spoken line works after a long pause.
            let silence = failure?.domain == "kAFAssistantErrorDomain" && failure?.code == 1110
            let final = (result?.isFinal ?? false) || silence
            let message = silence ? nil : failure?.localizedDescription
            Task { @MainActor in deliver(phrase, final, message) }
        }
    }
}
