import SwiftUI
import WebKit

/// Architecture visualization — multiple diagrams per mode (one per system/domain)
struct EntityGraphView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var mode = "software"
    @State private var selectedDiagramIndex = 0
    @State private var showPromptEditor = false
    @State private var promptDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            // Mode selector
            HStack(spacing: 4) {
                modeBtn("Software", mode: "software")
                modeBtn("Data Flow", mode: "dataflow")
                modeBtn("Deploy", mode: "deployment")
                Spacer()
                if isGenerating {
                    ProgressView().scaleEffect(0.5)
                }
                Button("Instructions") {
                    promptDraft = workspaceManager.diagramUserInstructions(for: mode)
                    showPromptEditor = true
                }
                .buttonStyle(.plain).font(.system(size: 9)).foregroundColor(VSDark.textDim)
                .padding(.horizontal, 6).padding(.vertical, 2).background(VSDark.bgActive).cornerRadius(3)

                Button("Rerun") { workspaceManager.regenerateArchitectureDiagram(mode: mode) }
                .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundColor(VSDark.textBright)
                .padding(.horizontal, 6).padding(.vertical, 2).background(VSDark.blue.opacity(0.3)).cornerRadius(3)
            }
            .padding(.horizontal, 8).padding(.vertical, 4).background(VSDark.bg)

            Divider().background(VSDark.border)

            // Sub-diagram tabs (one per system)
            let diagrams = parseDiagrams(currentMermaid)
            if diagrams.count > 1 {
                ScrollView(.vertical, showsIndicators: true) {
                    DiagramTagFlow(spacing: 4) {
                        ForEach(diagrams.indices, id: \.self) { i in
                            Button(action: { selectedDiagramIndex = i }) {
                                Text(diagrams[i].title)
                                    .font(.system(size: 9, weight: selectedDiagramIndex == i ? .bold : .regular))
                                    .foregroundColor(selectedDiagramIndex == i ? VSDark.textBright : VSDark.textDim)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(selectedDiagramIndex == i ? VSDark.blue.opacity(0.3) : VSDark.bgActive)
                                    .cornerRadius(4)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .frame(maxHeight: 80)
                .background(VSDark.bgSidebar)
                Divider().background(VSDark.border)
            }

            // Diagram content
            if !diagrams.isEmpty {
                let idx = min(selectedDiagramIndex, diagrams.count - 1)
                MermaidWebView(mermaidCode: diagrams[idx].mermaid)
            } else if isGenerating {
                VStack { Spacer(); ProgressView(); Text("Generating...").foregroundColor(VSDark.textDim).padding(.top, 8); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(VSDark.bg)
            } else {
                VStack { Spacer(); Text("No diagram. Click Rerun to generate.").foregroundColor(VSDark.textDim); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(VSDark.bg)
            }
        }
        .sheet(isPresented: $showPromptEditor) { promptEditorSheet }
        .onChange(of: mode) { _ in selectedDiagramIndex = 0 }
    }

    private var currentMermaid: String? {
        switch mode {
        case "software": return workspaceManager.softwareArchMermaid
        case "dataflow": return workspaceManager.dataFlowMermaid
        case "deployment": return workspaceManager.deploymentMermaid
        default: return nil
        }
    }

    private var isGenerating: Bool {
        workspaceManager.activeDiagramGenerationModes.contains(mode)
    }

    /// Parse combined mermaid string into separate diagrams.
    /// Handles: %%DIAGRAM_SEPARATOR format, JSON arrays, %%DIAGRAM_TITLE: prefix, raw mermaid.
    private func parseDiagrams(_ combined: String?) -> [(title: String, mermaid: String)] {
        guard let combined = combined, !combined.isEmpty else { return [] }

        // Step 1: Split into raw chunks
        var rawChunks: [(title: String, content: String)] = []

        if combined.contains("%%DIAGRAM_SEPARATOR") {
            for chunk in combined.components(separatedBy: "%%DIAGRAM_SEPARATOR") {
                if let parsed = Self.parseChunk(chunk) { rawChunks.append(parsed) }
            }
        } else {
            if let parsed = Self.parseChunk(combined) { rawChunks.append(parsed) }
        }

        // Step 2: For each chunk, check if content is JSON (cached bad data) or raw mermaid
        var results: [(title: String, mermaid: String)] = []
        for chunk in rawChunks {
            if let jsonDiagrams = Self.parseJSONDiagrams(chunk.content) {
                results.append(contentsOf: jsonDiagrams)
            } else {
                let mermaid = AIProviderClient.stripMermaidFences(chunk.content)
                if !mermaid.isEmpty {
                    results.append((title: chunk.title, mermaid: mermaid))
                }
            }
        }
        return results
    }

    /// Extract title and content from a chunk that may have %%DIAGRAM_TITLE: prefix
    private static func parseChunk(_ raw: String) -> (title: String, content: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("%%DIAGRAM_TITLE:") {
            let lines = trimmed.components(separatedBy: "\n")
            let title = String(lines[0].dropFirst("%%DIAGRAM_TITLE:".count)).trimmingCharacters(in: .whitespaces)
            let content = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? nil : (title: title, content: content)
        }
        return (title: "Diagram", content: trimmed)
    }

    /// Try to parse a string as JSON array of {title, mermaid} objects
    private static func parseJSONDiagrams(_ text: String) -> [(title: String, mermaid: String)]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        let results = arr.compactMap { obj -> (title: String, mermaid: String)? in
            let title = obj["title"] as? String ?? "Diagram"
            let mermaid = AIProviderClient.stripMermaidFences(obj["mermaid"] as? String ?? "")
            return mermaid.isEmpty ? nil : (title: title, mermaid: mermaid)
        }
        return results.isEmpty ? nil : results
    }

    private func modeBtn(_ title: String, mode m: String) -> some View {
        Button(action: { mode = m }) {
            Text(title).font(.system(size: 9, weight: mode == m ? .bold : .regular))
                .foregroundColor(mode == m ? VSDark.textBright : VSDark.textDim)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(mode == m ? VSDark.bgActive : Color.clear).cornerRadius(3)
        }.buttonStyle(.plain)
    }

    private var promptEditorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Additional Instructions").font(.headline).foregroundColor(VSDark.text)

            Text("The base prompt handles diagram format, styling, and structure automatically. Use this field to tell the AI what to focus on.")
                .font(.system(size: 11)).foregroundColor(VSDark.textDim)

            Text("Examples:")
                .font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.textDim)
            VStack(alignment: .leading, spacing: 2) {
                Text("• Focus only on the payment processing pipeline")
                Text("• Show all integrations with external services")
                Text("• Separate frontend and backend architectures")
                Text("• Include only services related to authentication")
            }
            .font(.system(size: 10)).foregroundColor(VSDark.textDim.opacity(0.8))

            TextEditor(text: $promptDraft)
                .font(.system(size: 12))
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(VSDark.border, lineWidth: 1)
                )

            HStack {
                Button("Clear") { promptDraft = "" }
                Spacer()
                Button("Cancel") { showPromptEditor = false }
                Button("Run with Instructions") {
                    workspaceManager.updateDiagramPrompt(promptDraft, for: mode)
                    showPromptEditor = false
                    workspaceManager.regenerateArchitectureDiagram(mode: mode)
                }.buttonStyle(.borderedProminent).tint(VSDark.blue)
            }
        }.padding(20).frame(width: 500, height: 400)
    }
}

// MARK: - Mermaid WebView Renderer with zoom/pan

struct MermaidWebView: NSViewRepresentable {
    let mermaidCode: String

    func makeNSView(context: Context) -> WKWebView { WKWebView() }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let hash = mermaidCode.hashValue
        if context.coordinator.lastHash == hash { return }
        context.coordinator.lastHash = hash
        webView.loadHTMLString(buildHTML(), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator { var lastHash = 0 }

    private func buildHTML() -> String {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg = isDark ? "#1e1e1e" : "#ffffff"
        let btnBg = isDark ? "#252526" : "#f3f3f3"
        let btnBorder = isDark ? "#3c3c3c" : "#d4d4d4"
        let btnColor = isDark ? "#d4d4d4" : "#1e1e1e"
        let edgeBg = isDark ? "#1e1e1e" : "#ffffff"

        let escaped = mermaidCode
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")

        return """
        <!DOCTYPE html><html><head><meta charset="UTF-8">
        <script src="https://cdn.jsdelivr.net/npm/mermaid@10.6.1/dist/mermaid.min.js"></script>
        <style>
            *{margin:0;padding:0}
            body{background:\(bg);overflow:hidden;width:100vw;height:100vh}
            #container{width:100vw;height:100vh;overflow:hidden;cursor:grab}
            #container:active{cursor:grabbing}
            #diagram{transform-origin:0 0;display:inline-block;padding:20px}
            .node rect,.node polygon,.node circle{stroke-width:2px!important}
            .edgeLabel{background-color:\(edgeBg)!important;font-size:11px!important}
            .cluster rect{rx:8!important;ry:8!important}
            #controls{position:fixed;bottom:10px;right:10px;display:flex;gap:3px;z-index:100}
            #controls button{width:28px;height:28px;border-radius:4px;border:1px solid \(btnBorder);
                background:\(btnBg);color:\(btnColor);font-size:14px;cursor:pointer;
                display:flex;align-items:center;justify-content:center}
            #controls button:hover{background:\(isDark ? "#37373d" : "#e0e0e0")}
            #zoom-level{color:#808080;font-size:10px;line-height:28px;padding:0 4px}
            #error{color:#f44747;padding:20px;font-family:monospace;font-size:13px;white-space:pre-wrap}
        </style>
        </head><body>
        <div id="container"><div id="diagram"></div></div>
        <div id="controls">
            <button onclick="zoomIn()">+</button>
            <span id="zoom-level">100%</span>
            <button onclick="zoomOut()">−</button>
            <button onclick="resetView()">⟲</button>
        </div>
        <script>
            mermaid.initialize({startOnLoad:false,theme:'\(isDark ? "dark" : "default")',themeVariables:{
                primaryColor:'\(isDark ? "#264f78" : "#d1e7ff")',primaryTextColor:'\(isDark ? "#d4d4d4" : "#1e1e1e")',primaryBorderColor:'#569cd6',
                lineColor:'#569cd6',secondaryColor:'\(bg)',tertiaryColor:'\(btnBg)',
                background:'\(bg)',mainBkg:'\(btnBg)',nodeBorder:'#569cd6',
                clusterBkg:'\(bg)',clusterBorder:'\(btnBorder)',titleColor:'\(btnColor)',
                edgeLabelBackground:'\(bg)'},flowchart:{useMaxWidth:false,htmlLabels:true,curve:'basis'}});

            const diagram=document.getElementById('diagram'),container=document.getElementById('container');
            let scale=1,panX=0,panY=0,dragging=false,startX=0,startY=0;

            // Render via JS API — avoids HTML-escaping issues with inline mermaid
            const code = '\(escaped)';
            mermaid.render('mermaid-svg', code).then(({svg}) => {
                diagram.innerHTML = svg;
                fitDiagram();
            }).catch(err => {
                diagram.innerHTML = '<div id="error">Mermaid render error:\\n' +
                    err.message.replace(/</g,'&lt;') + '\\n\\nCode:\\n' +
                    code.replace(/</g,'&lt;').replace(/\\\\n/g,'\\n') + '</div>';
            });

            function fitDiagram(){
                setTimeout(()=>{const svg=diagram.querySelector('svg');if(svg){
                    const sw=svg.getBoundingClientRect().width,sh=svg.getBoundingClientRect().height,
                    cw=container.clientWidth,ch=container.clientHeight;
                    scale=Math.min(cw/(sw+40),ch/(sh+40),1.5);scale=Math.max(0.2,scale);
                    panX=(cw-sw*scale)/2;panY=(ch-sh*scale)/2;applyTransform()}},100);
            }
            function applyTransform(){diagram.style.transform=`translate(${panX}px,${panY}px) scale(${scale})`;
                document.getElementById('zoom-level').textContent=Math.round(scale*100)+'%'}
            function zoomIn(){scale=Math.min(5,scale*1.25);applyTransform()}
            function zoomOut(){scale=Math.max(0.1,scale/1.25);applyTransform()}
            function resetView(){scale=1;panX=0;panY=0;applyTransform()}
            container.addEventListener('wheel',e=>{e.preventDefault();const r=container.getBoundingClientRect(),
                mx=e.clientX-r.left,my=e.clientY-r.top,os=scale;
                scale*=e.deltaY>0?0.9:1.1;scale=Math.max(0.1,Math.min(5,scale));
                panX=mx-(mx-panX)*(scale/os);panY=my-(my-panY)*(scale/os);applyTransform()});
            container.addEventListener('mousedown',e=>{dragging=true;startX=e.clientX-panX;startY=e.clientY-panY});
            container.addEventListener('mousemove',e=>{if(!dragging)return;panX=e.clientX-startX;panY=e.clientY-startY;applyTransform()});
            container.addEventListener('mouseup',()=>dragging=false);
            container.addEventListener('mouseleave',()=>dragging=false);
        </script></body></html>
        """
    }
}

// MARK: - Wrapping flow layout for diagram tags

// MARK: - Markdown Content Renderer (for Research answers, descriptions, etc.)

struct MarkdownContentView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let hash = markdown.hashValue
        if context.coordinator.lastHash == hash { return }
        context.coordinator.lastHash = hash
        webView.loadHTMLString(buildHTML(), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator { var lastHash = 0 }

    private func buildHTML() -> String {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg = isDark ? "#1e1e1e" : "#ffffff"
        let fg = isDark ? "#d4d4d4" : "#1e1e1e"
        let fgDim = isDark ? "#808080" : "#6e7681"
        let codeBg = isDark ? "#252526" : "#f6f8fa"
        let codeFg = isDark ? "#ce9178" : "#c7254e"
        let borderC = isDark ? "#333" : "#e1e4e8"
        let accent = isDark ? "#569cd6" : "#0366d6"
        let accent2 = isDark ? "#9cdcfe" : "#0550ae"

        let escaped = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        return """
        <!DOCTYPE html><html><head><meta charset="UTF-8">
        <script src="https://cdn.jsdelivr.net/npm/markdown-it@13.0.1/dist/markdown-it.min.js"></script>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                background: \(bg); color: \(fg); font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 12px; line-height: 1.6; padding: 12px 16px;
            }
            h1 { font-size: 16px; color: \(accent); margin: 12px 0 6px; border-bottom: 1px solid \(borderC); padding-bottom: 4px; }
            h2 { font-size: 14px; color: \(accent); margin: 10px 0 4px; }
            h3 { font-size: 13px; color: \(accent2); margin: 8px 0 4px; }
            h4,h5,h6 { font-size: 12px; color: \(accent2); margin: 6px 0 3px; }
            p { margin: 4px 0; }
            ul, ol { margin: 4px 0 4px 20px; }
            li { margin: 2px 0; }
            code { background: \(codeBg); color: \(codeFg); padding: 1px 4px; border-radius: 3px; font-size: 11px; }
            pre { background: \(codeBg); padding: 8px 10px; border-radius: 4px; margin: 6px 0; overflow-x: auto; }
            pre code { background: none; padding: 0; color: \(fg); }
            blockquote { border-left: 3px solid \(accent); padding-left: 10px; color: \(fgDim); margin: 6px 0; }
            strong { color: \(isDark ? "#e0e0e0" : "#1a1a1a"); }
            em { color: \(isDark ? "#c586c0" : "#6f42c1"); }
            a { color: \(accent); text-decoration: none; }
            a:hover { text-decoration: underline; }
            table { border-collapse: collapse; margin: 6px 0; }
            th, td { border: 1px solid \(borderC); padding: 4px 8px; font-size: 11px; }
            th { background: \(codeBg); color: \(accent); }
            hr { border: none; border-top: 1px solid \(borderC); margin: 8px 0; }
        </style>
        </head><body>
        <div id="content"></div>
        <script>
            const md = window.markdownit({ html: false, linkify: true, typographer: true });
            document.getElementById('content').innerHTML = md.render(`\(escaped)`);
        </script>
        </body></html>
        """
    }
}

struct DiagramTagFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, offset) in layout(proposal: proposal, subviews: subviews).offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (offsets: [CGPoint], size: CGSize) {
        let maxW = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxW && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            offsets.append(CGPoint(x: x, y: y))
            rowH = max(rowH, s.height)
            x += s.width + spacing
            maxX = max(maxX, x)
        }
        return (offsets, CGSize(width: maxX, height: y + rowH))
    }
}
