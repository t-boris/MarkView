import Foundation

/// How loud a recording is, to tell "the microphone delivered silence" (muted, wrong input device)
/// from "the recognizer heard nothing in real speech". Pure and Foundation-only, so it is testable on
/// its own (`tools/tests/recording-level-tests.sh`).
enum RecordingLevel {
    /// A recording whose loudest sample stays under this fraction of full scale (about -54 dBFS) is
    /// silence: speech through a microphone, even a quiet one, peaks far above it.
    static let silentPeak: Float = 0.002

    /// The loudest sample of a 16-bit PCM WAV as a fraction of full scale (0...1); nil when `data`
    /// is not such a WAV or holds no samples.
    static func peak(ofWAV data: Data) -> Float? {
        data.withUnsafeBytes { raw -> Float? in
            let count = raw.count
            func text(_ at: Int, _ length: Int) -> String {
                String(decoding: raw[at..<(at + length)], as: UTF8.self)
            }
            func u16(_ at: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self).littleEndian) }
            func u32(_ at: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian) }

            guard count >= 12, text(0, 4) == "RIFF", text(8, 4) == "WAVE" else { return nil }
            var offset = 12
            var isPCM16 = false
            while offset + 8 <= count {
                let id = text(offset, 4)
                let size = u32(offset + 4)
                let body = offset + 8
                if id == "fmt ", body + 16 <= count {
                    isPCM16 = u16(body) == 1 && u16(body + 14) == 16
                } else if id == "data" {
                    guard isPCM16 else { return nil }
                    // A recorder that was not finalized leaves the size 0 or too large: take what is there.
                    let available = count - body
                    let length = (size == 0 || size > available) ? available : size
                    let samples = length / 2
                    guard samples > 0 else { return nil }
                    var loudest = 0
                    for index in 0..<samples {
                        let value = Int(raw.loadUnaligned(fromByteOffset: body + index * 2, as: Int16.self).littleEndian)
                        loudest = max(loudest, value == Int(Int16.min) ? 32768 : abs(value))
                    }
                    return Float(loudest) / 32768
                }
                offset = body + size + (size & 1) // chunks are padded to an even length
            }
            return nil
        }
    }

    /// The peak in decibels relative to full scale, rounded; -120 for digital silence.
    static func decibels(_ peak: Float) -> Int {
        peak <= 0 ? -120 : Int((20 * log10(peak)).rounded())
    }

    static func isSilent(_ peak: Float) -> Bool { peak < silentPeak }
}
