// Which language built-in dictation uses, and how a long recording's windows become one text.
import Foundation
var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name) \(detail)") }
}
func pick(_ preferred: [String], _ supported: [String]) -> [String] {
    DictationLanguage.candidates(stored: "", preferred: preferred, supported: supported)
}
func pick(stored: String, _ preferred: [String], _ supported: [String]) -> [String] {
    DictationLanguage.candidates(stored: stored, preferred: preferred, supported: supported)
}

// What macOS reported on the development Mac (62 supported languages, 5 installed on this Mac;
// the candidates are filtered by "supported", the installed check happens afterwards).
let supported = ["ar-SA", "de-DE", "en-AU", "en-GB", "en-US", "fr-FR", "ru-RU", "uk-UA", "zh-CN"]

check("normalized", DictationLanguage.normalized("ru_RU") == "ru-RU")
check("language code", DictationLanguage.languageCode("zh-Hans-CN") == "zh" && DictationLanguage.languageCode("RU_ru") == "ru")

// Automatic: the system's languages in order.
check("first system language first", pick(["en-US", "ru-RU"], supported) == ["en-US", "en-AU", "en-GB", "ru-RU"],
      "\(pick(["en-US", "ru-RU"], supported))")
check("exact match leads its language", pick(["en-US"], supported).first == "en-US")
check("variants of the same language follow", pick(["en-US"], supported) == ["en-US", "en-AU", "en-GB"], "\(pick(["en-US"], supported))")
check("a region macOS lacks falls back to the language", pick(["ru-US"], supported) == ["ru-RU"], "\(pick(["ru-US"], supported))")
check("system language order is kept", pick(["en-US", "ru-US"], supported) == ["en-US", "en-AU", "en-GB", "ru-RU"], "\(pick(["en-US", "ru-US"], supported))")
check("a bare language code works", pick(["de"], supported) == ["de-DE"], "\(pick(["de"], supported))")
check("script subtags use the language", pick(["zh-Hans-CN"], supported) == ["zh-CN"], "\(pick(["zh-Hans-CN"], supported))")
check("no duplicates", Set(pick(["en-US", "en-GB", "en"], supported)).count == pick(["en-US", "en-GB", "en"], supported).count,
      "\(pick(["en-US", "en-GB", "en"], supported))")
check("unsupported languages give no candidates", pick(["xx-XX"], supported).isEmpty)
check("no system languages give no candidates", pick([], supported).isEmpty)
check("underscore identifiers from macOS match", pick(["ru-RU"], ["ru_RU", "en_US"]) == ["ru-RU"], "\(pick(["ru-RU"], ["ru_RU", "en_US"]))")
check("matching ignores case", pick(["RU-ru"], supported) == ["ru-RU"], "\(pick(["RU-ru"], supported))")

// A stored choice is the only candidate: never silently another language.
check("stored choice wins over the system languages", pick(stored: "ru-RU", ["en-US"], supported) == ["ru-RU"])
check("stored choice is the only candidate", pick(stored: "en-US", ["ru-RU"], supported) == ["en-US"], "\(pick(stored: "en-US", ["ru-RU"], supported))")
check("stored language code resolves to a variant", pick(stored: "ru", ["en-US"], supported) == ["ru-RU"])
check("stored choice macOS does not support gives none", pick(stored: "xx-XX", ["en-US"], supported).isEmpty)
check("blank stored choice means automatic", pick(stored: "  ", ["ru-RU"], supported) == ["ru-RU"])

// A long recording arrives in windows of about a minute (measured: a 207 s file came back as results
// starting at 0.0, 60.1, 120.2 and 180.2 s); the final result is only the last window.
var windows = TranscriptWindows()
check("no windows: empty text", windows.text == "")
windows.add(start: 0.0, text: "first minute")
check("one window", windows.text == "first minute")
windows.add(start: 120.2, text: "third minute")
windows.add(start: 60.1, text: "second minute")
check("windows come out in audio order, not arrival order", windows.text == "first minute second minute third minute", windows.text)
windows.add(start: 180.2, text: "last 27 seconds")
check("the final window is added, not substituted", windows.text == "first minute second minute third minute last 27 seconds", windows.text)
windows.add(start: 60.4, text: "second minute again")
check("a window reported again replaces its text", windows.text == "first minute second minute again third minute last 27 seconds", windows.text)
var padded = TranscriptWindows()
padded.add(start: 0, text: "  spoken  \n")
padded.add(start: 60, text: "   ")
padded.add(start: 120, text: "after silence")
check("blank windows add nothing and edges are trimmed", padded.text == "spoken after silence", padded.text)

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all dictation language checks passed")
