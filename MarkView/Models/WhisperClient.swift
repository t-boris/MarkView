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

    var hasAPIKey: Bool {
        guard let key = UserDefaults.standard.string(forKey: Self.apiKeyStorage) else { return false }
        return !key.isEmpty
    }

    private var apiKey: String? {
        UserDefaults.standard.string(forKey: Self.apiKeyStorage)
    }

    init() {
        let tempDir = FileManager.default.temporaryDirectory
        recordingURL = tempDir.appendingPathComponent("markview_whisper.m4a")
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
        body.append("whisper-1\r\n".data(using: .utf8)!)

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
                let errBody = String(data: data, encoding: .utf8) ?? ""
                error = "Whisper API error: \(errBody.prefix(200))"
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
}
