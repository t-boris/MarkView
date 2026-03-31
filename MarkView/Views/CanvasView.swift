import SwiftUI
import WebKit

/// Interactive architecture canvas — D3.js force-directed graph
/// Auto-generates from semantic DB, then allows editing: drag nodes, add/remove edges, export
struct CanvasView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 6) {
                Text("Canvas").font(.system(size: 10, weight: .bold)).foregroundColor(VSDark.text)
                Spacer()
                Button(action: { exportMermaid() }) {
                    HStack(spacing: 2) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 9))
                        Text("Mermaid").font(.system(size: 9))
                    }.foregroundColor(VSDark.textDim)
                }.buttonStyle(.plain)
                Button(action: { reloadGraph() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10)).foregroundColor(VSDark.textDim)
                }.buttonStyle(.plain).help("Reload from DB")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(VSDark.bgActive)

            // D3 Canvas — graphVersion forces reload
            CanvasWebView(graphData: buildGraphData())
                .id(graphVersion)
        }
    }

    private func buildGraphData() -> String {
        guard let db = workspaceManager.semanticDatabase else { return "{\"nodes\":[],\"links\":[]}" }

        let modules = db.allModules().filter { $0.id.hasPrefix("cmod_") }
        var nodes: [[String: Any]] = []
        var links: [[String: Any]] = []
        var nodeIds = Set<String>()

        for mod in modules {
            let symbols = db.symbolsForModule(mod.id)
            let typeSymbol = symbols.first(where: { $0.kind == "component" })
            let typeName: String
            if let ctx = typeSymbol?.context, ctx.hasPrefix("["), let end = ctx.firstIndex(of: "]") {
                typeName = String(ctx[ctx.index(after: ctx.startIndex)..<end])
            } else { typeName = "component" }

            nodes.append(["id": mod.id, "name": mod.name, "type": typeName])
            nodeIds.insert(mod.id)
        }

        // Relations
        for mod in modules {
            for rel in db.relationsForModule(mod.id) {
                if nodeIds.contains(rel.targetId) {
                    links.append(["source": mod.id, "target": rel.targetId, "type": rel.type])
                }
            }
        }

        let data: [String: Any] = ["nodes": nodes, "links": links]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return "{\"nodes\":[],\"links\":[]}"
        }
        return jsonStr
    }

    private func exportMermaid() {
        // TODO: read current positions from D3 and generate Mermaid
        NSPasteboard.general.clearContents()
        var mermaid = "graph TD\n"
        guard let db = workspaceManager.semanticDatabase else { return }
        let modules = db.allModules().filter { $0.id.hasPrefix("cmod_") }
        for mod in modules {
            let safeName = mod.name.replacingOccurrences(of: " ", with: "_")
            mermaid += "    \(safeName)[\(mod.name)]\n"
        }
        for mod in modules {
            let safeName = mod.name.replacingOccurrences(of: " ", with: "_")
            for rel in db.relationsForModule(mod.id) {
                if let target = modules.first(where: { $0.id == rel.targetId }) {
                    let safeTarget = target.name.replacingOccurrences(of: " ", with: "_")
                    mermaid += "    \(safeName) --> \(safeTarget)\n"
                }
            }
        }
        NSPasteboard.general.setString(mermaid, forType: .string)
    }

    @State private var graphVersion = 0
    private func reloadGraph() {
        graphVersion += 1
    }
}

// MARK: - D3.js WebView

struct CanvasWebView: NSViewRepresentable {
    let graphData: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let hash = graphData.hashValue
        if context.coordinator.lastHash == hash { return }
        context.coordinator.lastHash = hash
        webView.loadHTMLString(buildHTML(), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator { var lastHash = 0 }

    private func buildHTML() -> String {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg = isDark ? "#1e1e1e" : "#ffffff"
        let textColor = isDark ? "#d4d4d4" : "#1e1e1e"
        let linkColor = isDark ? "#555" : "#ccc"

        return """
        <!DOCTYPE html><html><head><meta charset="UTF-8">
        <script src="https://cdn.jsdelivr.net/npm/d3@7.9.0/dist/d3.min.js"></script>
        <style>
            * { margin: 0; padding: 0; }
            body { background: \(bg); overflow: hidden; font-family: -apple-system, sans-serif; }
            svg { width: 100vw; height: 100vh; }
            .node-label { font-size: 10px; fill: \(textColor); pointer-events: none; text-anchor: middle; }
            .node-type { font-size: 7px; fill: #808080; pointer-events: none; text-anchor: middle; }
            .link { stroke: \(linkColor); stroke-width: 1.5; fill: none; marker-end: url(#arrow); }
            .link:hover { stroke: #569cd6; stroke-width: 2.5; }
            #controls { position: fixed; bottom: 8px; right: 8px; display: flex; gap: 4px; }
            #controls button { padding: 4px 8px; border: 1px solid #3c3c3c; background: \(isDark ? "#252526" : "#f3f3f3");
                color: \(textColor); border-radius: 4px; font-size: 10px; cursor: pointer; }
            #controls button:hover { background: \(isDark ? "#37373d" : "#e0e0e0"); }
            #stats { position: fixed; top: 4px; right: 8px; font-size: 9px; color: #808080; }
        </style>
        </head><body>
        <svg id="canvas"></svg>
        <div id="controls">
            <button onclick="resetZoom()">Reset</button>
            <button onclick="toggleLabels()">Labels</button>
        </div>
        <div id="stats"></div>
        <script>
        const data = \(graphData);
        const width = window.innerWidth, height = window.innerHeight;
        const svg = d3.select('#canvas');
        const g = svg.append('g');

        // Arrow marker
        svg.append('defs').append('marker')
            .attr('id', 'arrow').attr('viewBox', '0 -5 10 10')
            .attr('refX', 20).attr('refY', 0)
            .attr('markerWidth', 6).attr('markerHeight', 6)
            .attr('orient', 'auto')
            .append('path').attr('d', 'M0,-5L10,0L0,5')
            .attr('fill', '\(linkColor)');

        // Color by type
        const typeColors = {
            service: '#4ec9b0', database: '#c586c0', api: '#569cd6', queue: '#ce9178',
            system: '#9cdcfe', gateway: '#dcdcaa', cache: '#d7ba7d', storage: '#608b4e',
            library: '#569cd6', framework: '#4ec9b0', tool: '#808080', module: '#4ec9b0',
            pipeline: '#dcdcaa', worker: '#ce9178', scheduler: '#c586c0',
            process: '#4ec9b0', strategy: '#569cd6', stakeholder: '#dcdcaa',
            instrument: '#c586c0', portfolio: '#4ec9b0', risk: '#f44747',
            indicator: '#dcdcaa', signal: '#ce9178', concept: '#9cdcfe',
            default: '#808080'
        };
        function nodeColor(type) { return typeColors[type] || typeColors.default; }

        // Simulation
        const simulation = d3.forceSimulation(data.nodes)
            .force('link', d3.forceLink(data.links).id(d => d.id).distance(80))
            .force('charge', d3.forceManyBody().strength(-200))
            .force('center', d3.forceCenter(width/2, height/2))
            .force('collision', d3.forceCollide().radius(30));

        // Links
        const link = g.selectAll('.link').data(data.links).enter().append('line')
            .attr('class', 'link');

        // Nodes
        const node = g.selectAll('.node').data(data.nodes).enter().append('g')
            .attr('class', 'node')
            .call(d3.drag()
                .on('start', (e,d) => { if(!e.active) simulation.alphaTarget(0.3).restart(); d.fx=d.x; d.fy=d.y; })
                .on('drag', (e,d) => { d.fx=e.x; d.fy=e.y; })
                .on('end', (e,d) => { if(!e.active) simulation.alphaTarget(0); })
            );

        node.append('circle')
            .attr('r', d => Math.min(8 + (d.name.length * 0.3), 14))
            .attr('fill', d => nodeColor(d.type))
            .attr('stroke', d => d3.color(nodeColor(d.type)).darker(0.5))
            .attr('stroke-width', 1.5)
            .style('cursor', 'grab');

        node.append('text').attr('class', 'node-label')
            .attr('dy', d => Math.min(8 + (d.name.length * 0.3), 14) + 12)
            .text(d => d.name);

        node.append('text').attr('class', 'node-type')
            .attr('dy', d => Math.min(8 + (d.name.length * 0.3), 14) + 22)
            .text(d => d.type);

        // Tick
        simulation.on('tick', () => {
            link.attr('x1', d => d.source.x).attr('y1', d => d.source.y)
                .attr('x2', d => d.target.x).attr('y2', d => d.target.y);
            node.attr('transform', d => `translate(${d.x},${d.y})`);
        });

        // Zoom
        const zoom = d3.zoom().scaleExtent([0.1, 5]).on('zoom', e => g.attr('transform', e.transform));
        svg.call(zoom);

        function resetZoom() { svg.transition().duration(500).call(zoom.transform, d3.zoomIdentity); }

        let showLabels = true;
        function toggleLabels() {
            showLabels = !showLabels;
            d3.selectAll('.node-label, .node-type').style('display', showLabels ? 'block' : 'none');
        }

        document.getElementById('stats').textContent = `${data.nodes.length} nodes, ${data.links.length} edges`;
        </script>
        </body></html>
        """
    }
}
