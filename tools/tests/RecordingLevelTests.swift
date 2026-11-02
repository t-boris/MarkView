import Foundation

// How loud a recording is: whether the microphone delivered silence.
var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name) \(detail)") }
}

func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
}

/// A WAV like AVAudioRecorder writes: RIFF, an optional extra chunk, fmt, data.
func wav(samples: [Int16], sizeField: UInt32? = nil, format: UInt16 = 1, bits: UInt16 = 16, extraChunk: Bool = false) -> Data {
    var body: [UInt8] = Array("WAVE".utf8)
    if extraChunk { body += Array("FLLR".utf8) + le(UInt32(3)) + [0, 0, 0] + [0] } // odd size, padded
    body += Array("fmt ".utf8) + le(UInt32(16)) + le(format) + le(UInt16(1)) + le(UInt32(16000))
        + le(UInt32(32000)) + le(UInt16(2)) + le(bits)
    let payload = samples.flatMap { le($0) }
    body += Array("data".utf8) + le(sizeField ?? UInt32(payload.count)) + payload
    return Data(Array("RIFF".utf8) + le(UInt32(body.count)) + body)
}

func near(_ a: Float?, _ b: Float) -> Bool { a.map { abs($0 - b) < 0.0001 } ?? false }

check("silence is digital zero", near(RecordingLevel.peak(ofWAV: wav(samples: [0, 0, 0, 0])), 0))
check("loudest sample wins, sign ignored", near(RecordingLevel.peak(ofWAV: wav(samples: [100, -16384, 200])), 0.5),
      "\(String(describing: RecordingLevel.peak(ofWAV: wav(samples: [100, -16384, 200]))))")
check("full scale negative sample", near(RecordingLevel.peak(ofWAV: wav(samples: [Int16.min])), 1))
check("an extra chunk before fmt is skipped", near(RecordingLevel.peak(ofWAV: wav(samples: [8192], extraChunk: true)), 0.25))
check("size field 0 (not finalized) reads to the end", near(RecordingLevel.peak(ofWAV: wav(samples: [0, 8192], sizeField: 0)), 0.25))
check("size field too large reads to the end", near(RecordingLevel.peak(ofWAV: wav(samples: [0, 8192], sizeField: 0xFFFF_FFFF)), 0.25))
check("no samples is no answer", RecordingLevel.peak(ofWAV: wav(samples: [])) == nil)
check("not a WAV is no answer", RecordingLevel.peak(ofWAV: Data("hello world, this is text".utf8)) == nil)
check("too short is no answer", RecordingLevel.peak(ofWAV: Data([1, 2, 3])) == nil)
check("float WAV is no answer", RecordingLevel.peak(ofWAV: wav(samples: [100], format: 3, bits: 32)) == nil)
check("8-bit WAV is no answer", RecordingLevel.peak(ofWAV: wav(samples: [100], bits: 8)) == nil)

check("decibels of full scale", RecordingLevel.decibels(1) == 0)
check("decibels of half", RecordingLevel.decibels(0.5) == -6)
check("decibels of zero", RecordingLevel.decibels(0) == -120)

check("quiet room noise is silent", RecordingLevel.isSilent(0.001))
check("the limit itself is not silent", !RecordingLevel.isSilent(RecordingLevel.silentPeak))
check("quiet speech is not silent (-40 dBFS)", !RecordingLevel.isSilent(0.01))
check("silent limit is about -54 dBFS", RecordingLevel.decibels(RecordingLevel.silentPeak) == -54,
      "\(RecordingLevel.decibels(RecordingLevel.silentPeak))")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all recording level checks passed")
