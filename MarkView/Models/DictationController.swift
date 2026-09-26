import Foundation
import AVFoundation
import Combine

/// Dictation into a text field (the intake sheet): click to record, click again to stop, and the
/// whole transcript goes to the field once Whisper answers. Adds what a field needs on top of
/// `WhisperClient`: elapsed time, a warning before the length cap and an automatic stop at it,
/// cancel without inserting, and the inline status (error, nothing recognized, no permission).
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Waiting for the microphone (the permission prompt may be up).
        case starting
        case recording(since: Date)
        case transcribing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// Inline message under the field after a failure or an empty transcript.
    @Published private(set) var message: String?
    /// The message is about microphone access: the field offers to open System Settings.
    @Published private(set) var microphoneDenied = false

    /// How long before the cap the recording indicator warns.
    static let warningLead: TimeInterval = 30
    var maxDuration: TimeInterval { WhisperClient.maxRecordingDuration }

    var isActive: Bool { phase != .idle }
    var isRecording: Bool { if case .recording = phase { return true } else { return false } }
    var nearLimit: Bool { isRecording && elapsed >= maxDuration - Self.warningLead }

    private let whisper = WhisperClient()
    private var insert: ((String) -> Void)?
    private var ticker: Timer?
    /// Bumped on every start and cancel: a transcript from an older recording is dropped.
    private var session = 0
    private var subscriptions = Set<AnyCancellable>()

    init() {
        whisper.$isRecording.removeDuplicates()
            .sink { [weak self] recording in self?.recordingChanged(recording) }
            .store(in: &subscriptions)
        whisper.$error
            .sink { [weak self] error in self?.startFailed(error) }
            .store(in: &subscriptions)
    }

    /// Starts recording, or stops it and hands the transcript to `insert`.
    func toggle(insert: @escaping (String) -> Void) {
        switch phase {
        case .idle:
            session += 1
            self.insert = insert
            message = nil
            microphoneDenied = false
            phase = .starting
            whisper.startRecording()
        case .starting:
            cancel()
        case .recording:
            stop()
        case .transcribing:
            break
        }
    }

    /// Discards the recording or transcription in progress; nothing is inserted.
    func cancel() {
        guard isActive else { return }
        session += 1
        stopTicker()
        phase = .idle
        insert = nil
        whisper.cancel()
    }

    func dismissMessage() {
        message = nil
        microphoneDenied = false
    }

    private func stop() {
        stopTicker()
        phase = .transcribing
        let current = session
        Task { [weak self] in
            guard let self else { return }
            let text = await whisper.stopRecording()
            guard current == session, phase == .transcribing else { return }
            phase = .idle
            let deliver = insert
            insert = nil
            guard let text else {
                message = whisper.error ?? "Transcription failed."
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                message = "No speech recognized."
            } else {
                deliver?(trimmed)
            }
        }
    }

    private func recordingChanged(_ recording: Bool) {
        if recording, phase == .starting {
            phase = .recording(since: Date())
            elapsed = 0
            startTicker()
        } else if !recording, isRecording {
            // Stopped from outside (another microphone started): nothing to insert.
            stopTicker()
            phase = .idle
            insert = nil
        }
    }

    private func startFailed(_ error: String?) {
        guard let error, phase == .starting else { return }
        phase = .idle
        insert = nil
        message = error
        let status = WhisperClient.microphoneStatus
        microphoneDenied = status == .denied || status == .restricted
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard case .recording(let since) = phase else { return }
        elapsed = Date().timeIntervalSince(since)
        // The recorder itself stops at the cap; transcribe what was recorded.
        if elapsed >= maxDuration { stop() }
    }
}
