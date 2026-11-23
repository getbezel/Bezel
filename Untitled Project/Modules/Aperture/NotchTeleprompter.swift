import Foundation
import Observation

@MainActor @Observable
final class NotchTeleprompter {
    enum Mode: String, CaseIterable { case timed = "Timed", voice = "Follow my voice" }
    private(set) var script = PromptScript("")
    private(set) var line = 0
    private(set) var mode = Mode.timed
    private(set) var speed = 150
    private(set) var playing = false
    private(set) var preparing = false
    private(set) var finished = false
    private(set) var message: String?
    var active: Bool { !script.lines.isEmpty }

    @ObservationIgnored private let voice = PromptVoiceInput()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var position = PromptSpeechPosition(start: 0)

    @discardableResult
    func open(_ text: String) -> Bool {
        let parsed = PromptScript(text)
        guard !parsed.lines.isEmpty else { return false }
        close()
        script = parsed
        mode = .timed
        play()
        return true
    }

    func close() {
        pause()
        script = PromptScript("")
        line = 0
        finished = false
        message = nil
    }

    func toggle() {
        if playing { pause() } else { play() }
    }

    func choose(_ newMode: Mode) {
        guard active, newMode != mode else { return }
        pause()
        mode = newMode
        play()
    }

    func setSpeed(_ value: Int) {
        speed = min(300, max(60, value))
        if playing && mode == .timed { scheduleLine() }
    }

    func step(_ delta: Int) {
        let next = line + delta
        guard script.lines.indices.contains(next) else { return }
        let resume = playing
        pause()
        line = next
        position = PromptSpeechPosition(start: script.lines[next].start)
        finished = false
        message = nil
        if resume { play() }
    }

    func pause() {
        playing = false
        preparing = false
        work?.cancel()
        work = nil
        voice.stop()
    }

    private func play() {
        guard active, !playing else { return }
        if finished {
            line = 0
            position = PromptSpeechPosition(start: 0)
            finished = false
        }
        message = nil
        playing = true
        if mode == .timed { scheduleLine() }
        else { listen() }
    }

    private func scheduleLine() {
        work?.cancel()
        let entry = script.lines[line]
        let seconds = max(1.2, Double(max(1, entry.end - entry.start)) * 60 / Double(speed))
        work = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, playing, mode == .timed else { return }
            if line + 1 == script.lines.count { complete(); return }
            line += 1
            position = PromptSpeechPosition(start: script.lines[line].start)
            scheduleLine()
        }
    }

    private func listen() {
        preparing = true
        position = PromptSpeechPosition(start: max(position.furthest, script.lines[line].start))
        work = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            await voice.start(onReady: { [weak self] in self?.preparing = false },
                              onText: { [weak self] phrase in self?.follow(phrase) },
                              onEnd: { [weak self] error in
                guard let self, self.playing, self.mode == .voice else { return }
                if let error {
                    self.pause()
                    self.message = error
                } else {
                    self.work = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                        self?.listen()
                    }
                }
            })
        }
    }

    private func follow(_ phrase: String) {
        let cursor = position.update(phrase, in: script)
        guard cursor > 0 else { return }
        while line + 1 < script.lines.count, cursor >= script.lines[line].end { line += 1 }
        if cursor == script.words.count { complete() }
    }

    private func complete() {
        pause()
        finished = true
    }
}
