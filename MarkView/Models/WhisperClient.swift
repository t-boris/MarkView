import Foundation
import AVFoundation
import AVFAudio

/// Whisper voice input — records audio, sends to OpenAI Whisper API, returns text
@MainActor
class WhisperClient: ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText: String?
    @Published var error: String?

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
        transcribedText = nil
        // Starting a microphone elsewhere discards the recording in progress there.
        if let other = Self.active, other !== self, other.isRecording { other.cancel() }

        // Request microphone permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
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
        guard let apiKey = apiKey else {
            error = "OpenAI API key not set. Add it in Settings."
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
                let errBody = String(data: data, encoding: .utf8) ?? ""
                error = "Whisper API error (HTTP \(status), model \(Self.selectedModel)): \(errBody.prefix(300))"
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                error = "Could not parse Whisper response"
                return nil
            }

            NSLog("[Whisper] Transcribed: \(text.prefix(100))")
            transcribedText = text
            return text
        } catch {
            self.error = "Network error: \(error.localizedDescription)"
            return nil
        }
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
