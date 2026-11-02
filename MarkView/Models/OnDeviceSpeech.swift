import Foundation
import Speech

/// Dictation without an OpenAI key: macOS's own speech recognition, run on this Mac
/// (`requiresOnDeviceRecognition`), so the audio never leaves it. `WhisperClient` uses it whenever
/// no OpenAI key is set. macOS recognizes one language per request and cannot detect it, so the
/// language is chosen here (DDE Settings) or follows the system's languages.
enum OnDeviceSpeech {
    /// The dictation language chosen in DDE Settings, as a BCP 47 identifier; "" = follow the system.
    static let languageStorage = "settings.dictation.locale"

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
        let stored = UserDefaults.standard.string(forKey: languageStorage) ?? ""
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

/// Which language dictation uses: pure, so it is testable on its own
/// (`tools/tests/dictation-language-tests.sh`). This and `TranscriptWindows` below are the pure tail
/// of the file: keep them last and Foundation-only.
enum DictationLanguage {
    /// BCP 47 form of an identifier ("ru_RU" → "ru-RU").
    static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    /// The language part of an identifier, lowercased ("zh-Hans-CN" → "zh").
    static func languageCode(_ identifier: String) -> String {
        normalized(identifier).split(separator: "-").first.map { $0.lowercased() } ?? ""
    }

    /// Languages to try, best first, each one `supported`. A stored choice is the only candidate:
    /// when its model is missing the user is told so, never given another language. Otherwise each
    /// system language in order — itself when supported, then the supported variants of the same
    /// language ("ru-US" finds "ru-RU").
    static func candidates(stored: String, preferred: [String], supported: [String]) -> [String] {
        let available = supported.map(normalized)
        func match(_ identifier: String) -> [String] {
            let wanted = normalized(identifier).lowercased()
            let code = languageCode(identifier)
            let exact = available.filter { $0.lowercased() == wanted }
            let sameLanguage = available.filter { languageCode($0) == code && $0.lowercased() != wanted }.sorted()
            return exact + sameLanguage
        }
        let trimmed = stored.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return Array(match(trimmed).prefix(1)) }
        var seen = Set<String>()
        return preferred.flatMap(match).filter { seen.insert($0).inserted }
    }
}

/// The text of a whole recording. macOS recognizes audio in windows of about a minute: each finished
/// window is reported as its own result and the final result holds only the last one, so keeping just
/// the final result drops everything before it (a 207 s recording came back as its last 27 s). Pure,
/// so it is testable on its own.
struct TranscriptWindows {
    private var texts: [Int: String] = [:]

    /// A window that starts `start` seconds into the audio. A window reported again replaces its
    /// earlier text instead of repeating it.
    mutating func add(start: TimeInterval, text: String) {
        texts[Int(start.rounded(.down))] = text
    }

    /// The windows in audio order, joined by a space; windows with no speech add nothing.
    var text: String {
        texts.keys.sorted()
            .compactMap { texts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
