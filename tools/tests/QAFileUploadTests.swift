import AppKit
import ImageIO
import WebKit

// End-to-End QA file upload, on the production path: a real BrowserSession in an off-screen window (the way a QA player sits), the real
// BrowserAgentExecutor snapshot and native mouse click, and real WebKit. The page asks for a file the way pages do: a visible
// `input[type=file]`, and a styled label in front of a hidden one. The click opens the page's file chooser; the session answers it with the
// built-in test image, and the page itself reads the File it was given (name, type, size, decoded pixels). Nothing is shown to a person.

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    print(condition ? "PASS" : "FAIL", name, condition ? "" : detail())
    if !condition { failures += 1 }
}
func spin(_ seconds: Double = 10, until done: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
}
DispatchQueue.global().asyncAfter(deadline: .now() + 90) { print("FAIL timeout"); exit(1) }

let html = """
<!doctype html><title>Upload fixture</title>
<p>Avatar</p><input type="file" id="direct" name="avatar">
<label for="hidden" id="pick">Upload photo</label><input type="file" id="hidden" style="display:none">
<p id="result">nothing chosen</p>
<script>
async function report(input) {
  const file = input.files[0];
  if (!file) { document.getElementById('result').textContent = 'empty'; return; }
  const bitmap = await createImageBitmap(file);
  document.getElementById('result').textContent = JSON.stringify({id: input.id, name: file.name, type: file.type, size: file.size, w: bitmap.width, h: bitmap.height});
}
for (const input of document.querySelectorAll('input[type=file]')) input.addEventListener('change', () => report(input));
</script>
"""

/// The person at the file chooser, as a script: the files they pick (nil: they cancel), and how many times they were asked.
@MainActor final class ChooserPrompts: UserPrompts {
    var answer: [URL]?
    var calls = 0
    func ask(_ prompt: UserPrompt) -> Int? { nil }
    func chooseFiles(allowsMultiple: Bool, allowsDirectories: Bool) -> [URL]? { calls += 1; return answer }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.accessory)
    let prompts = ChooserPrompts()
    let session = BrowserSession(url: nil, prompts: prompts)
    let window = QAWebWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    session.webView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    window.contentView = session.webView
    window.orderBack(nil)
    session.webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/upload/")!)
    spin { !session.webView.isLoading && session.title == "Upload fixture" }
    check("the fixture page loads", session.title == "Upload fixture")

    @MainActor func tool(_ name: String, _ args: [String: Any]) -> BrowserAgentTools.Reply {
        var reply = BrowserAgentTools.Reply(text: "", pngBase64: nil)
        var done = false
        Task { @MainActor in reply = await BrowserAgentExecutor.run(name, args, in: session); done = true }
        spin { done }
        return reply
    }
    @MainActor func pageText(_ script: String) -> String {
        var value = ""
        var done = false
        session.webView.evaluateJavaScript(script) { result, _ in value = result as? String ?? ""; done = true }
        spin { done }
        return value
    }
    @MainActor func result() -> String { pageText("document.getElementById('result').textContent") }
    @MainActor func reset() { _ = pageText("document.getElementById('result').textContent='nothing chosen'; for (const i of document.querySelectorAll('input[type=file]')) i.value=''; 'ok'") }
    @MainActor func ref(_ line: String, in snapshot: String) -> String? {
        snapshot.split(separator: "\n").first { $0.contains(line) }.flatMap { text in
            text.range(of: "\\[(e[0-9]+)\\]", options: .regularExpression).map { String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
        }
    }

    // The picture the production runner hands out, as a file (the actor writes it with AtomicFile; here the bytes are the same).
    guard let png = QATestImage.pngData() else { check("the built-in picture is drawn", false); return }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qa-file-upload-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let pictureURL = folder.appendingPathComponent(QATestImage.fileName)
    try? png.write(to: pictureURL)
    prompts.answer = [pictureURL]

    // What the assistant is shown: the visible field, and the label that opens the hidden one (the hidden field itself is not shown).
    let snapshot = tool("browser_snapshot", [:]).text
    let direct = ref("input:file", in: snapshot)
    let label = ref("label \"Upload photo\"", in: snapshot)
    check("the snapshot shows the visible file field", direct != nil, snapshot)
    check("the snapshot shows the label of the hidden file field", label != nil, snapshot)
    check("the hidden file field itself is not listed", snapshot.components(separatedBy: "input:file").count - 1 == 1, snapshot)

    @MainActor func decoded() -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(result().utf8))) as? [String: Any] }

    // A click on the visible field: the page gets the picture, byte for byte, and decodes it at its own size.
    if let direct {
        let clicked = tool("browser_click", ["ref": direct])
        check("the click on the file field succeeds", !clicked.isError, clicked.text)
        spin { result() != "nothing chosen" }
        let file = decoded()
        check("the page receives the built-in picture named as the prompt says", file?["name"] as? String == QATestImage.fileName, result())
        check("the page sees a PNG of the size of the built-in picture", file?["type"] as? String == "image/png" && file?["size"] as? Int == png.count, result())
        check("the page decodes it at \(QATestImage.width) by \(QATestImage.height)", file?["w"] as? Int == QATestImage.width && file?["h"] as? Int == QATestImage.height, result())
        check("the chooser was asked exactly once", prompts.calls == 1, "\(prompts.calls)")
        check("the next snapshot shows the file name in the field's value", tool("browser_snapshot", [:]).text.contains(QATestImage.fileName))
    }

    // A click on the label: the hidden field gets the same picture.
    reset()
    if let label {
        let clicked = tool("browser_click", ["ref": label])
        check("the click on the label succeeds", !clicked.isError, clicked.text)
        spin { result() != "nothing chosen" }
        check("the hidden field received the picture through its label", decoded()?["id"] as? String == "hidden" && decoded()?["name"] as? String == QATestImage.fileName, result())
        check("the chooser was asked a second time", prompts.calls == 2, "\(prompts.calls)")
    }

    // No answer is a cancelled chooser, as a person closing the panel: the page gets nothing and nothing hangs.
    reset()
    prompts.answer = nil
    if let direct {
        _ = tool("browser_click", ["ref": direct])
        spin(2) { false }
        check("a refused chooser leaves the field empty", result() == "nothing chosen", result())
        check("and the chooser was still asked", prompts.calls == 3, "\(prompts.calls)")
    }

    window.contentView = nil
    window.close()
    print(failures == 0 ? "All QA file upload checks passed." : "\(failures) QA file upload check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}
