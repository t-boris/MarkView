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
    private var recordingURL: URL

    private static let apiKeyStorage = "com.markview.dde.openai.apikey"
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

    init() {
        // `beginRecording` overwrites this with the .wav path it actually records
        // to — which is what the multipart body declares. Start from the same
        // extension so the two can never disagree.
        let tempDir = FileManager.default.temporaryDirectory
        recordingURL = tempDir.appendingPathComponent("markview_whisper.wav")
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        error = nil
        transcribedText = nil

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
        // Delete old recording
        try? FileManager.default.removeItem(at: recordingURL)

        // Use WAV format — reliable for Whisper
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("markview_whisper.wav")

        do {
            audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
            let started = audioRecorder?.record() ?? false
            isRecording = started
            if started {
                NSLog("[Whisper] Recording started to \(recordingURL.path)")
            } else {
                error = "Failed to start recording — check microphone"
                NSLog("[Whisper] record() returned false")
            }
        } catch {
            self.error = "Microphone error: \(error.localizedDescription)"
            NSLog("[Whisper] Recording error: \(error)")
        }
    }

    func stopRecording() async -> String? {
        guard isRecording, let recorder = audioRecorder else { return nil }
        recorder.stop()
        isRecording = false
        audioRecorder = nil

        // Check file exists and has content
        let fm = FileManager.default
        guard fm.fileExists(atPath: recordingURL.path),
              let attrs = try? fm.attributesOfItem(atPath: recordingURL.path),
              let size = attrs[.size] as? Int, size > 100 else {
            NSLog("[Whisper] Recording file empty or missing")
            error = "Recording failed — no audio captured"
            return nil
        }
        NSLog("[Whisper] Recording stopped, file size: \(size) bytes, sending to API...")

        return await transcribe(fileURL: recordingURL)
    }

    // MARK: - Whisper API

    private func transcribe(fileURL: URL) async -> String? {
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
        request.timeoutInterval = 30

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
