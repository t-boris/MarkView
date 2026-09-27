import Foundation
import AVFoundation
import AVFAudio

/// Whisper voice input — records audio, sends to OpenAI Whisper API, returns text
@MainActor
class WhisperClient: ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText: String?
    @Published var error: String?
    /// The last error is fixed in DDE Settings (API key, model): callers can offer to open them.
    @Published private(set) var errorOpensSettings = false

    private var audioRecorder: AVAudioRecorder?
    /// A new file per recording, so a late cleanup never deletes a newer recording.
    private var recordingURL: URL?
    /// Bumped by `cancel()`: a transcription started before it delivers nothing.
    private var generation = 0
    private var transcription: Task<String?, Never>?

    /// The recording in progress anywhere in the app — only one microphone at a time.
    private static weak var active: WhisperClient?

    /// Longest recording: 16 kHz mono WAV grows ~1.9 MB a minute, so 10 minutes stays well
    /// under Whisper's 25 MB upload limit. The recorder stops by itself at this length.
    static let maxRecordingDuration: TimeInterval = 600

    static let apiKeyStorage = "com.markview.dde.openai.apikey"
    static let modelStorage = "settings.whisper.model"

    /// Transcription models OpenAI accepts on /v1/audio/transcriptions.
    static let availableModels = ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
    static let defaultModel = "whisper-1"

    /// Model used for transcription, configurable in DDE Settings.
    static var selectedModel: String {
        let stored = UserDefaults.standard.string(forKey: modelStorage) ?? ""
        return availableModels.contains(stored) ? stored : defaultModel
    }

    var hasAPIKey: Bool {
        guard let key = UserDefaults.standard.string(forKey: Self.apiKeyStorage) else { return false }
        return !key.isEmpty
    }

    private var apiKey: String? {
        UserDefaults.standard.string(forKey: Self.apiKeyStorage)
    }

    /// Microphone authorization, for the Settings diagnostics panel.
    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        error = nil
        errorOpensSettings = false
        transcribedText = nil
        // Request microphone permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            // Cancelled while the permission prompt is up: the answer must not start recording.
            let requested = generation
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    guard self.generation == requested else { return }
                    if granted { self.beginRecording() }
                    else { self.error = "Microphone access denied. Enable in System Settings → Privacy → Microphone." }
                }
            }
        case .denied, .restricted:
            error = "Microphone access denied. Enable in System Settings → Privacy → Microphone."
        @unknown default:
            error = "Microphone not available"
        }
    }

    private func beginRecording() {
        // A second start while the permission prompt was up: one recording is enough.
        guard !isRecording else { return }
        // Starting a microphone elsewhere discards the recording in progress there.
        if let other = Self.active, other !== self, other.isRecording { other.cancel() }

        // Use WAV format — reliable for Whisper
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        // One file per recording: two recordings (terminal, voice note, intake) never share a file.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("markview_whisper_\(UUID().uuidString).wav")
        recordingURL = url

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
            let started = audioRecorder?.record(forDuration: Self.maxRecordingDuration) ?? false
            isRecording = started
            if started {
                Self.active = self
                NSLog("[Whisper] Recording started")
            } else {
                try? FileManager.default.removeItem(at: url)
                error = "Failed to start recording — check microphone"
                NSLog("[Whisper] record() returned false")
            }
        } catch {
            self.error = "Microphone error: \(error.localizedDescription)"
            NSLog("[Whisper] Recording error: \(error)")
        }
    }

    func stopRecording() async -> String? {
        guard isRecording, let recorder = audioRecorder, let url = recordingURL else { return nil }
        recorder.stop()
        isRecording = false
        audioRecorder = nil
        recordingURL = nil
        let fm = FileManager.default
        defer { try? fm.removeItem(at: url) }

        // Check file exists and has content
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 100 else {
            NSLog("[Whisper] Recording file empty or missing")
            error = "Recording failed — no audio captured"
            return nil
        }
        NSLog("[Whisper] Recording stopped, file size: \(size) bytes, sending to API...")

        let started = generation
        let task = Task { await transcribe(fileURL: url) }
        transcription = task
        let text = await task.value
        if generation != started {
            // Cancelled while transcribing: nothing is delivered, not even the cancellation error.
            error = nil
            transcribedText = nil
            return nil
        }
        transcription = nil
        return text
    }

    /// Stops a recording or transcription without a result and deletes the audio.
    func cancel() {
        generation += 1
        transcription?.cancel()
        transcription = nil
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
    }

    // MARK: - Whisper API

    func transcribe(fileURL: URL) async -> String? {
        errorOpensSettings = false
        guard let apiKey, !apiKey.isEmpty else {
            fail(.missingKey)
            return nil
        }

        guard let audioData = try? Data(contentsOf: fileURL) else {
            error = "Could not read recording"
            return nil
        }

        // Build multipart form data
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        // Model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(Self.selectedModel)\r\n".data(using: .utf8)!)

        // Prompt hint — helps Whisper understand the context
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
        body.append("The user is giving instructions about documentation, software architecture, and code.\r\n".data(using: .utf8)!)

        // Audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // Long dictation uploads megabytes: allow time for them on a slow connection.
        request.timeoutInterval = 30 + Double(audioData.count) / 200_000

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                // Read the status outside the guard binding — it is not in scope here.
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let failure = TranscriptionFailure.http(status: status, body: data, model: Self.selectedModel)
                // Status and error code only: the body can echo part of the API key.
                NSLog("[Whisper] Transcription failed: \(failure.tag ?? "HTTP \(status)")")
                fail(failure)
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                fail(.unreadableResponse)
                return nil
            }

            NSLog("[Whisper] Transcribed: \(text.prefix(100))")
            transcribedText = text
            return text
        } catch {
            // Cancelled on purpose (`cancel()`): not a failure to report.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return nil }
            NSLog("[Whisper] Transcription request failed: \(error)")
            fail(.network(error))
            return nil
        }
    }

    private func fail(_ failure: TranscriptionFailure) {
        errorOpensSettings = failure.fixInSettings
        error = failure.message
    }

    // MARK: - Self test

    /// Record for `seconds`, transcribe, and report exactly what happened.
    /// Used by the DDE Settings diagnostics panel so a Whisper failure shows its
    /// real cause (permission, key, model, HTTP status) instead of nothing at all.
    func runSelfTest(seconds: Double = 3.0) async -> String {
        guard hasAPIKey else {
            return "❌ OpenAI API key is not set. Add it in DDE Settings above."
        }
        switch Self.microphoneStatus {
        case .authorized, .notDetermined:
            break
        case .denied, .restricted:
            return "❌ Microphone access denied. System Settings → Privacy & Security → Microphone."
        @unknown default:
            return "❌ Microphone status unknown."
        }

        error = nil
        transcribedText = nil
        startRecording()

        // startRecording may go through an async permission prompt; wait for the
        // recorder to actually come up before starting the clock.
        let startDeadline = Date().addingTimeInterval(5)
        while !isRecording, error == nil, Date() < startDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if let error { return "❌ Could not start recording: \(error)" }
        guard isRecording else { return "❌ Recording did not start (timed out waiting for the microphone)." }

        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        guard isRecording else {
            return "⚠️ Interrupted: another microphone (terminal, voice note or intake) started during the test."
        }
        let text = await stopRecording()
        if let error { return "❌ \(error)" }
        guard let text else { return "❌ No transcript returned and no error reported." }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "⚠️ Request succeeded but the transcript is empty — model \(Self.selectedModel) heard nothing. Check the input device level."
        }
        return "✅ \(Self.selectedModel): \"\(trimmed)\""
    }
}

/// A failed transcription explained for people: what went wrong, what to do next, and a short
/// technical tag (HTTP status, OpenAI error code) for bug reports — never the raw response body,
/// which is JSON and can echo part of the API key (BUG-009). Pure, so it is testable on its own.
struct TranscriptionFailure: Equatable {
    var problem: String
    var nextStep: String
    var tag: String?
    /// The fix is in DDE Settings (API key or model): the field offers to open them.
    var fixInSettings = false

    var message: String {
        "\(problem) \(nextStep)" + (tag.map { " (\($0))" } ?? "")
    }

    private static let retryOrTest = "Try again; if it keeps failing, run \u{201C}Record 3s and transcribe\u{201D} in DDE Settings."

    static let missingKey = TranscriptionFailure(
        problem: "No OpenAI API key is set.", nextStep: "Add one in DDE Settings.", fixInSettings: true)

    static let unreadableResponse = TranscriptionFailure(
        problem: "OpenAI answered, but not with a transcript.", nextStep: retryOrTest, tag: "HTTP 200", fixInSettings: true)

    /// A non-200 answer from /v1/audio/transcriptions. OpenAI's body is
    /// `{"error": {"message", "type", "code", "param"}}`; only `code` (or `type`) is used.
    static func http(status: Int, body: Data, model: String) -> TranscriptionFailure {
        let code = errorCode(in: body)
        let tag = (["HTTP \(status)"] + [code].compactMap { $0 }).joined(separator: " \u{00B7} ")
        func failure(_ problem: String, _ nextStep: String, settings: Bool = false) -> TranscriptionFailure {
            TranscriptionFailure(problem: problem, nextStep: nextStep, tag: tag, fixInSettings: settings)
        }
        switch (status, code) {
        case (401, _), (_, "invalid_api_key"):
            return failure("OpenAI rejected the API key.", "Check or replace the key in DDE Settings.", settings: true)
        case (_, "insufficient_quota"):
            return failure("The OpenAI account has run out of credit.",
                           "Add credit or raise the limit at platform.openai.com (Settings \u{2192} Billing), then dictate again.")
        case (429, _):
            return failure("OpenAI is limiting requests right now.", "Wait a minute and dictate again.")
        case (_, "unsupported_country_region_territory"):
            return failure("OpenAI does not offer its API in this country or region.",
                           "Transcription is not available from this network.")
        case (404, _), (_, "model_not_found"):
            return failure("The transcription model \(model) is not available for this API key.",
                           "Choose another model in DDE Settings.", settings: true)
        case (403, _):
            return failure("This API key is not allowed to use \(model).",
                           "Choose another model in DDE Settings, or check the key\u{2019}s permissions at platform.openai.com.", settings: true)
        case (413, _):
            return failure("The recording is too large for OpenAI.", "Dictate in shorter parts.")
        case (_, "audio_too_short"):
            return failure("The recording is too short to transcribe.", "Record a little longer.")
        case (400..<500, _):
            return failure("OpenAI could not process the recording.", retryOrTest, settings: true)
        case (500..<600, _):
            return failure("OpenAI\u{2019}s transcription service is having trouble.",
                           "Try again in a minute; status.openai.com lists outages.")
        default:
            return failure("Transcription failed.", retryOrTest, settings: true)
        }
    }

    /// The request never got an HTTP answer.
    static func network(_ error: Error) -> TranscriptionFailure {
        guard let urlError = error as? URLError else {
            return TranscriptionFailure(problem: "The request to OpenAI failed.", nextStep: retryOrTest, fixInSettings: true)
        }
        let tag = "URLError \(urlError.code.rawValue)"
        switch urlError.code {
        case .timedOut:
            return TranscriptionFailure(problem: "OpenAI took too long to answer.",
                                        nextStep: "Try again, or dictate in shorter parts.", tag: tag)
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            return TranscriptionFailure(problem: "MarkView cannot reach OpenAI.",
                                        nextStep: "Check the internet connection, then dictate again.", tag: tag)
        default:
            return TranscriptionFailure(problem: "The request to OpenAI failed.",
                                        nextStep: "Check the internet connection, then dictate again.", tag: tag)
        }
    }

    /// OpenAI's machine-readable error code (or type), when the body is an OpenAI error object.
    /// Anything that is not a short snake_case identifier is dropped, so no free text leaks out.
    private static func errorCode(in body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        for key in ["code", "type"] {
            if let value = error[key] as? String, isIdentifier(value) { return value }
        }
        return nil
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64
            && value.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }
}
