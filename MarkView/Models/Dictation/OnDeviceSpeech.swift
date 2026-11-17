import Foundation
import Speech
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Dictation without an OpenAI key: macOS's own speech recognition, run on this Mac
/// (`requiresOnDeviceRecognition`), so the audio never leaves it. `WhisperClient` uses it whenever
/// no OpenAI key is set. macOS recognizes one language per request and cannot detect it, so the
/// language is chosen here (DDE Settings) or follows the system's languages.
enum OnDeviceSpeech {
    // MARK: - Permission

    /// Speech Recognition access, asked for separately from the microphone.
    static var authorization: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Language

    /// How a language is named for people ("Russian (Russia)").
    static func displayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// The language dictation uses now: the stored choice, else the first system language macOS can
    /// recognize on this Mac. A failure says what to install or choose.
    static func resolveLanguage() -> Result<String, TranscriptionFailure> {
        let stored = Settings.standard.value(Setting.dictationLanguage)
        let preferred = Locale.preferredLanguages
        let candidates = DictationLanguage.candidates(
            stored: stored, preferred: preferred,
            supported: SFSpeechRecognizer.supportedLocales().map(\.identifier))
        for identifier in candidates where isInstalled(identifier) { return .success(identifier) }
        let wanted = candidates.first ?? (stored.isEmpty ? preferred.first : stored) ?? "en-US"
        return .failure(.languageNotInstalled(displayName(wanted)))
    }

    /// The language has its on-device model on this Mac (Keyboard → Dictation downloads it).
    static func isInstalled(_ identifier: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: identifier))?.supportsOnDeviceRecognition ?? false
    }

    /// Every language that can be recognized on this Mac now, for the Settings picker. Creates a
    /// recognizer per supported language (about 0.3 s, and each logs), so call it once, off the
    /// main thread.
    static func installedLanguages() -> [String] {
        SFSpeechRecognizer.supportedLocales()
            .map { DictationLanguage.normalized($0.identifier) }
            .filter(isInstalled)
            .sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
    }

    // MARK: - Recognition

    /// Text of the recorded audio file, recognized on this Mac. Empty when no speech was heard.
    /// Honors task cancellation.
    static func transcribe(fileURL: URL, language: String) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.supportsOnDeviceRecognition else { throw Failure.languageNotInstalled(displayName(language)) }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let job = Job()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                // Already cancelled: the continuation is resumed with the cancellation, nothing starts.
                guard job.begin(continuation) else { return }
                let task = recognizer.recognitionTask(with: request) { result, error in
                    // macOS recognizes about a minute at a time: every finished window arrives as its own
                    // result and the final one holds only the last window, so the windows are collected.
                    if let result {
                        let transcription = result.bestTranscription
                        if let start = transcription.segments.first?.timestamp {
                            job.add(start: start, text: transcription.formattedString)
                        }
                        if result.isFinal { job.finishWithText(); return }
                    }
                    if let error {
                        // "No speech detected" ends the recording without more text, not as a failure.
                        if isNoSpeech(error) { job.finishWithText() } else { job.finish(.failure(error)) }
                    }
                }
                job.attach(task)
            }
        } onCancel: {
            job.cancel()
        }
    }

    enum Failure: Error {
        case languageNotInstalled(String)
    }

    /// kAFAssistantErrorDomain 1110: the recognizer finished without hearing speech.
    private static func isNoSpeech(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
    }

    /// One recognition: resumes its continuation exactly once, whether the recognizer answers,
    /// fails or is cancelled, and cancels the recognizer's task when the caller's task is cancelled.
    // unchecked Sendable: `lock` guards the continuation, the recognition task, the flags and the transcript windows.
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?
        private var task: SFSpeechRecognitionTask?
        private var done = false
        private var cancelled = false
        private var windows = TranscriptWindows()

        /// A finished window of the recording, starting `start` seconds in.
        func add(start: TimeInterval, text: String) {
            lock.lock(); defer { lock.unlock() }
            windows.add(start: start, text: text)
        }

        /// Everything collected so far is the answer.
        func finishWithText() {
            lock.lock()
            let text = windows.text
            lock.unlock()
            finish(.success(text))
        }

        /// False when the job was cancelled before it began; the continuation is then already resumed.
        func begin(_ continuation: CheckedContinuation<String, Error>) -> Bool {
            lock.lock()
            if cancelled {
                done = true
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func attach(_ task: SFSpeechRecognitionTask) {
            lock.lock()
            self.task = task
            let cancelNow = done
            lock.unlock()
            if cancelNow { task.cancel() }
        }

        func finish(_ result: Result<String, Error>) {
            lock.lock()
            guard !done, let continuation else { lock.unlock(); return }
            done = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
            finish(.failure(CancellationError()))
        }
    }
}
