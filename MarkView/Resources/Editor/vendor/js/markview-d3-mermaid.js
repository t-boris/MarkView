        // D3 INTERACTIVE CANVAS FOR MERMAID DIAGRAMS
        // ============================================================================

        function initMermaidCanvas(container, mermaidSource) {
            if (typeof d3 === 'undefined') {
                container.innerHTML = '<div style="padding:20px;color:#808080;">Loading libraries...</div>';
                return;
            }
            if (typeof ELK === 'undefined') {
                // ELK (layered layout) is large: loaded when the first diagram needs it.
                const tag = document.createElement('script');
                tag.src = 'vendor/js/elk.bundled.js';
                tag.onload = () => initMermaidCanvas(container, mermaidSource);
                tag.onerror = () => { container.innerHTML = '<div style="padding:20px;color:#808080;">Layout engine failed to load</div>'; };
                document.head.appendChild(tag);
                return;
            }

            const isDark = document.documentElement.getAttribute('data-theme') !== 'light';
            const bg = isDark ? '#1e1e1e' : '#ffffff';
            const textColor = isDark ? '#d4d4d4' : '#1e1e1e';
            const linkColor = isDark ? '#555' : '#bbb';
            const tc = {service:'#4ec9b0',database:'#c586c0',api:'#569cd6',queue:'#ce9178',
                system:'#9cdcfe',gateway:'#dcdcaa',cache:'#d7ba7d',pipeline:'#dcdcaa',
                worker:'#ce9178',scheduler:'#c586c0',process:'#4ec9b0',strategy:'#569cd6',
                risk:'#f44747',instrument:'#c586c0',ui:'#9cdcfe',library:'#808080',external:'#f44747',
                data:'#c586c0',decision:'#d7ba7d',actor:'#9cdcfe',config:'#808080',default:'#808080'};
            const groupColors = ['#264f78','#2d4a22','#4a2d22','#2d2d4a','#4a4a22','#224a4a'];

            function guessType(label) {
                const l = label.toLowerCase();
                if (l.includes('db') || l.includes('database') || l.includes('postgres') || l.includes('redis') || l.includes('mongo') || l.includes('sql')) return 'database';
                if (l.includes('api') || l.includes('endpoint') || l.includes('rest') || l.includes('grpc')) return 'api';
                if (l.includes('queue') || l.includes('kafka') || l.includes('rabbit') || l.includes('nats')) return 'queue';
                if (l.includes('gateway') || l.includes('nginx') || l.includes('proxy') || l.includes('cdn')) return 'gateway';
                if (l.includes('pipeline') || l.includes('flow') || l.includes('stage')) return 'pipeline';
                if (l.includes('service') || l.includes('svc') || l.includes('worker')) return 'service';
                return 'default';
            }

            const {nodes, links, groups, direction} = parseMermaid(mermaidSource);
            if (nodes.length === 0) { container.innerHTML = '<div style="padding:20px;color:#808080;font-size:calc(11px * var(--ui-scale, 1));">No nodes found</div>'; return; }

            nodes.forEach(n => { n.type = n.kind || guessType(n.label); n.color = tc[n.type] || tc.default; });
            const uniqueGroups = [...new Set(nodes.map(n=>n.group).filter(Boolean))];
            const groupColorMap = {};
            uniqueGroups.forEach((g,i) => { groupColorMap[g] = groupColors[i % groupColors.length]; });

            const nodeById0 = {}; nodes.forEach(n => { nodeById0[n.id] = n; });
            const groupBoxes = {};

            // Node sizes from their labels
            nodes.forEach(n => {
                const lines = n.label.replace(/<br\s*\/?>/gi, '\n').split('\n');
                const maxLineLen = Math.max(...lines.map(l => l.trim().length));
                n.w = Math.max(maxLineLen * 7.5 + 24, 80);
                n.h = 24 + lines.length * 14;
            });

            // Layers are far enough apart for the longest edge label to sit between two nodes
            const labelRoom = Math.max(70, Math.max(0, ...links.map(l => (l.label||'').length)) * 6.2 + 50);

            // ELK layered layout: groups are compound nodes, so members stay together without overlaps
            const elkGraph = {
                id: 'root',
                layoutOptions: {
                    'elk.algorithm': 'layered',
                    'elk.direction': direction === 'TB' ? 'DOWN' : 'RIGHT',
                    'elk.hierarchyHandling': 'INCLUDE_CHILDREN',
                    'elk.layered.spacing.nodeNodeBetweenLayers': String(labelRoom),
                    'elk.spacing.nodeNode': '34',
                    'elk.spacing.edgeNode': '24',
                    'elk.layered.considerModelOrder.strategy': 'NODES_AND_EDGES',
                    'elk.padding': '[top=30,left=30,bottom=30,right=30]'
                },
                children: [],
                edges: links.map((l, i) => ({id: 'e' + i, sources: [l.source], targets: [l.target]}))
            };
            const elkNode = n => ({id: n.id, width: n.w, height: n.h});
            uniqueGroups.forEach(gName => {
                elkGraph.children.push({
                    id: 'group_' + gName,
                    layoutOptions: {'elk.padding': '[top=34,left=18,bottom=18,right=18]',
                                    'elk.layered.spacing.nodeNodeBetweenLayers': String(labelRoom), 'elk.spacing.nodeNode': '34'},
                    children: nodes.filter(n => n.group === gName).map(elkNode)
                });
            });
            nodes.filter(n => !n.group).forEach(n => elkGraph.children.push(elkNode(n)));

            const layoutDone = new ELK().layout(elkGraph).then(laid => {
                // Absolute centers: ELK positions are relative to the parent group.
                const place = (items, ox, oy) => (items || []).forEach(item => {
                    if (item.id.startsWith('group_')) {
                        const gName = item.id.slice(6);
                        groupBoxes[gName] = {x: ox + item.x, y: oy + item.y, w: item.width, h: item.height};
                        place(item.children, ox + item.x, oy + item.y);
                    } else {
                        const n = nodeById0[item.id];
                        if (n) { n.x = ox + item.x + item.width / 2; n.y = oy + item.y + item.height / 2; }
                    }
                });
                place(laid.children, 0, 0);
            });
            const draw = function() {
            const w = container.clientWidth || 800;
            const h = container.clientHeight || 600;
            container.innerHTML = '';

            // Popup element
            const popup = document.createElement('div');
            popup.className = 'canvas-popup';
            popup.id = 'popup-'+container.id;
            container.appendChild(popup);

            const svg = d3.select(container).append('svg')
                .attr('width','100%').attr('height','100%').style('background',bg);
            const g = svg.append('g');

            // Arrow marker
            svg.append('defs').append('marker')
                .attr('id','arr-'+container.id).attr('viewBox','0 -5 10 10')
                .attr('refX',9).attr('refY',0).attr('markerWidth',6).attr('markerHeight',6)
                .attr('orient','auto').append('path').attr('d','M0,-5L10,0L0,5').attr('fill',linkColor);

            // Group backgrounds (boxes from the layout)
            uniqueGroups.forEach(gName => {
                const box = groupBoxes[gName];
                if (!box) return;
                g.append('rect').attr('x',box.x).attr('y',box.y).attr('width',box.w).attr('height',box.h)
                    .attr('rx',8).attr('ry',8).attr('fill',groupColorMap[gName]||'#333')
                    .attr('fill-opacity',0.12).attr('stroke',groupColorMap[gName]||'#555').attr('stroke-opacity',0.3);
                g.append('text').attr('x',box.x+10).attr('y',box.y+20).attr('font-size',11)
                    .attr('fill','#9a9a9a').attr('font-weight','bold').text(gName);
            });

            // Build node map for quick lookup
            const nodeById = {};
            nodes.forEach(n => { nodeById[n.id] = n; });

            // Resolve link source/target to node objects
            links.forEach(l => {
                if (typeof l.source === 'string') l.srcNode = nodeById[l.source];
                else l.srcNode = l.source;
                if (typeof l.target === 'string') l.tgtNode = nodeById[l.target];
                else l.tgtNode = l.target;
            });

            // Edge ends sit on the node borders, not the centers (nodes are translucent)
            function endpoints(l) {
                const a = l.srcNode, b = l.tgtNode;
                const dx = b.x - a.x, dy = b.y - a.y;
                function clip(n, ux, uy) {
                    const hw = (n.w||70)/2, hh = (n.h||32)/2;
                    const t = Math.min(ux ? hw/Math.abs(ux) : Infinity, uy ? hh/Math.abs(uy) : Infinity);
                    return [n.x + ux*t, n.y + uy*t];
                }
                const len = Math.hypot(dx, dy) || 1;
                const ux = dx/len, uy = dy/len;
                const p1 = clip(a, ux, uy), p2 = clip(b, -ux, -uy);
                return {x1:p1[0], y1:p1[1], x2:p2[0], y2:p2[1]};
            }

            // Edges
            const edgeGroup = g.append('g');
            const edgeElements = [];
            links.forEach((l,i) => {
                if (!l.srcNode || !l.tgtNode) return;
                const ep = endpoints(l);
                const line = edgeGroup.append('line')
                    .attr('x1',ep.x1).attr('y1',ep.y1)
                    .attr('x2',ep.x2).attr('y2',ep.y2)
                    .attr('stroke',linkColor).attr('stroke-width',1.5)
                    .attr('marker-end','url(#arr-'+container.id+')')
                    .style('cursor','pointer')
                    .attr('data-idx',i);

                const labelEl = l.label ? edgeGroup.append('text')
                    .attr('x',(ep.x1+ep.x2)/2).attr('y',(ep.y1+ep.y2)/2-4)
                    .attr('font-size',10).attr('fill',isDark?'#c0c0c0':'#444').attr('text-anchor','middle')
                    .attr('paint-order','stroke').attr('stroke',bg).attr('stroke-width',4).attr('stroke-linejoin','round')
                    .text(l.label).style('pointer-events','none').attr('data-idx',i) : null;

                edgeElements.push({line, labelEl, link: l});

                line.on('click', (event) => {
                    event.stopPropagation();
                    showPopup(popup, event.pageX-container.getBoundingClientRect().left,
                        event.pageY-container.getBoundingClientRect().top,
                        `<div class="popup-title">${esc(l.srcNode.label)} → ${esc(l.tgtNode.label)}</div>
                         <div class="popup-type">${esc(l.label||'depends on')}</div>
                         ${l.evidence?`<div class="popup-actions"><button class="popup-btn" onclick="openDiagramSource('${esc(l.evidence).replace(/'/g,'')}')">Evidence: ${esc(l.evidence)}</button></div>`:''}
                         <div class="popup-actions">
                           <input class="popup-input" id="edge-prompt-${container.id}" placeholder="Ask AI to change..." />
                           <button class="popup-btn" onclick="aiEditGraph('${container.id}','Change relationship between ${l.srcNode.label} and ${l.tgtNode.label}: '+document.getElementById('edge-prompt-${container.id}').value)">AI Edit</button>
                         </div>`);
                });
            });

            // Function to update all edges connected to a node
            function updateEdges() {
                edgeElements.forEach(({line, labelEl, link}) => {
                    if (!link.srcNode || !link.tgtNode) return;
                    const ep = endpoints(link);
                    line.attr('x1',ep.x1).attr('y1',ep.y1).attr('x2',ep.x2).attr('y2',ep.y2);
                    if (labelEl) labelEl.attr('x',(ep.x1+ep.x2)/2).attr('y',(ep.y1+ep.y2)/2-4);
                });
            }

            // Nodes — draggable with edge updates
            const nodeGroup = g.append('g');
            nodes.forEach(n => {
                const ng = nodeGroup.append('g')
                    .attr('transform',`translate(${n.x},${n.y})`)
                    .attr('data-id',n.id).attr('data-group',n.group||'')
                    .style('cursor','grab')
                    .call(d3.drag()
                        .on('drag', function(event) {
                            n.x = event.x; n.y = event.y;
                            d3.select(this).attr('transform',`translate(${n.x},${n.y})`);
                            updateEdges();
                        })
                    );

                ng.append('rect').attr('rx',6).attr('ry',6)
                    .attr('width',n.w||70).attr('height',n.h||32)
                    .attr('x',-(n.w||70)/2).attr('y',-(n.h||32)/2)
                    .attr('fill',n.color).attr('fill-opacity',0.15)
                    .attr('stroke',n.color).attr('stroke-width',1.5);

                // Multi-line label support: split on <br/> or <br>
                const labelLines = n.label.replace(/<br\s*\/?>/gi, '\n').split('\n');
                const textEl = ng.append('text').attr('text-anchor','middle')
                    .attr('font-size',11).attr('fill',textColor).style('pointer-events','none');
                labelLines.forEach((line, li) => {
                    textEl.append('tspan').attr('x',0)
                        .attr('dy', li === 0 ? -(labelLines.length-1)*6 + 4 : 13)
                        .text(line.trim());
                });

                ng.on('click', (event) => {
                    event.stopPropagation();
                    const rect = container.getBoundingClientRect();
                    showPopup(popup, event.pageX-rect.left, event.pageY-rect.top,
                        `<div class="popup-title">${esc(n.label)}</div>
                         <div class="popup-type">[${esc(n.type)}] ${n.group?'• '+esc(n.group):''}</div>
                         ${n.note?`<div class="popup-type">${esc(n.note)}</div>`:''}
                         ${n.source?`<div class="popup-actions"><button class="popup-btn" onclick="openDiagramSource('${esc(n.source).replace(/'/g,'')}')">Open ${esc(n.source)}</button></div>`:''}
                         <div class="popup-actions">
                           <input class="popup-input" id="node-prompt-${container.id}" placeholder="Ask AI: remove, replace, modify..." />
                           <button class="popup-btn" onclick="aiEditGraph('${container.id}','Regarding ${n.label}: '+document.getElementById('node-prompt-${container.id}').value)">AI Edit</button>
                           <button class="popup-btn danger" onclick="aiEditGraph('${container.id}','Remove ${n.label} from the diagram and adjust connections')">Delete</button>
                         </div>`);
                });
            });

            // Close popup on background click
            svg.on('click', () => { popup.style.display = 'none'; });

            // Zoom
            const zoom = d3.zoom().scaleExtent([0.1,5]).on('zoom', e => g.attr('transform', e.transform));
            svg.call(zoom);

            // Auto-fit
            const graphBounds = g.node().getBBox();
            if (graphBounds.width > 0) {
                const scale = Math.min(w/(graphBounds.width+60), h/(graphBounds.height+60), 1.5);
                const tx = (w - graphBounds.width*scale)/2 - graphBounds.x*scale;
                const ty = (h - graphBounds.height*scale)/2 - graphBounds.y*scale;
                svg.call(zoom.transform, d3.zoomIdentity.translate(tx,ty).scale(scale));
            }

            // Filter + controls bar
            const filterBar = document.createElement('div');
            filterBar.style.cssText = 'position:absolute;top:4px;left:4px;display:flex;gap:3px;flex-wrap:wrap;max-width:80%;';
            const btnStyle = `padding:2px 6px;border:1px solid #3c3c3c;background:${isDark?'#252526':'#f3f3f3'};color:${textColor};border-radius:3px;font-size:calc(9px * var(--ui-scale, 1));cursor:pointer;`;

            // "All" filter
            filterBar.innerHTML = `<button style="${btnStyle}" onclick="filterCanvasGroup('${container.id}','all')">All</button>`;

            // Group filter buttons
            uniqueGroups.forEach(gName => {
                const btn = document.createElement('button');
                btn.style.cssText = btnStyle;
                btn.textContent = gName;
                btn.onclick = () => filterCanvasGroup(container.id, gName);
                filterBar.appendChild(btn);
            });
            container.appendChild(filterBar);

            // Bottom controls
            const ctrl = document.createElement('div');
            ctrl.style.cssText = 'position:absolute;bottom:4px;right:4px;display:flex;gap:4px;align-items:center;';
            ctrl.innerHTML = `
                <span style="font-size:calc(8px * var(--ui-scale, 1));color:#808080;">${nodes.length} nodes, ${links.length} edges</span>
            `;
            container.appendChild(ctrl);

            // Store references for filtering
            container._canvasData = {nodes, links, edgeElements, nodeGroup, edgeGroup, uniqueGroups};
            };
            layoutDone.then(draw).catch(err => {
                container.innerHTML = '<div style="padding:20px;color:#f44747;font-size:11px;">Layout failed: ' + (err && err.message || err) + '</div>';
            });
        }

        function esc(t) {
            return String(t == null ? '' : t).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
        }

        // "path/File.swift:42" -> opens the project file (the line is not used yet)
        function openDiagramSource(ref) {
            const path = String(ref).split(':')[0];
            if (path) sendToSwift('canvasOpenFile', {path: path});
        }

        function showPopup(popup, x, y, html) {
            popup.innerHTML = html;
            popup.style.display = 'block';
            popup.style.left = Math.min(x, popup.parentElement.clientWidth - 200) + 'px';
            popup.style.top = Math.min(y, popup.parentElement.clientHeight - 150) + 'px';
        }

        function filterCanvasGroup(containerId, groupName) {
            const container = document.getElementById(containerId);
            if (!container || !container._canvasData) return;
            const {nodes, edgeElements, nodeGroup, edgeGroup} = container._canvasData;

            nodeGroup.selectAll('g').each(function() {
                const el = d3.select(this);
                const group = el.attr('data-group');
                const show = groupName === 'all' || group === groupName;
                el.style('opacity', show ? 1 : 0.08);
                el.style('pointer-events', show ? 'all' : 'none');
            });

            edgeElements.forEach(({line, labelEl, link}) => {
                const srcGroup = link.srcNode?.group || '';
                const tgtGroup = link.tgtNode?.group || '';
                const show = groupName === 'all' || srcGroup === groupName || tgtGroup === groupName;
                line.style('opacity', show ? 1 : 0.05);
                if (labelEl) labelEl.style('opacity', show ? 1 : 0.05);
            });
        }

        function aiEditGraph(containerId, instruction) {
            const container = document.getElementById(containerId);
            if (!container) return;
            const source = container.getAttribute('data-source');
            // Close popup
            container.querySelector('.canvas-popup').style.display = 'none';
            // Send mermaid source + instruction to AI
            sendToSwift('generateGraph', {
                type: 'edit',
                editInstruction: instruction,
                currentMermaid: source
            });
        }

        // Parse mermaid code into {nodes, links, groups}
        function parseMermaid(code) {
            const nodes = [], links = [], groups = [];
            const nodeMap = {};
            const lines = code.split('\n');
            let currentGroup = null;
            let direction = 'LR';
            const meta = {src: {}, note: {}, evidence: []};

            // Declares a node from `id`, an optional label (quotes stripped) and an optional :::class
            function declare(id, label, kind) {
                if (label) label = label.replace(/^"(.*)"$/, '$1');
                let n = nodeMap[id];
                if (!n) { n = nodeMap[id] = {id, label: label || id, group: currentGroup}; nodes.push(n); }
                else { if (label) n.label = label; if (currentGroup && !n.group) n.group = currentGroup; }
                if (kind) n.kind = kind;
                return n;
            }

            for (const line of lines) {
                const trimmed = line.trim();
                // Metadata comments written by the diagram generator
                let m = trimmed.match(/^%%\s+src\s+(\w+)\s+(\S+)/);
                if (m) { meta.src[m[1]] = m[2]; continue; }
                m = trimmed.match(/^%%\s+note\s+(\w+)\s+(.+)/);
                if (m) { meta.note[m[1]] = m[2]; continue; }
                m = trimmed.match(/^%%\s+evidence\s+(\w+)\s+(\w+)\s+(\S+)/);
                if (m) { meta.evidence.push({from: m[1], to: m[2], ref: m[3]}); continue; }
                if (!trimmed || trimmed.startsWith('%%') || trimmed.startsWith('classDef') ||
                    trimmed.startsWith('class ') || trimmed.startsWith('pie')) continue;

                // Track subgroups: subgraph g1["Name"], subgraph "Name", subgraph Name
                const sgMatch = trimmed.match(/^subgraph\s+(?:\w+\s*\[\s*"([^"]+)"\s*\]|"([^"]+)"|(\S+))/);
                if (sgMatch) {
                    currentGroup = sgMatch[1] || sgMatch[2] || sgMatch[3];
                    groups.push(currentGroup);
                    continue;
                }
                if (trimmed === 'end') { currentGroup = null; continue; }
                const dirMatch = trimmed.match(/^(?:graph|flowchart)\s+(TB|TD|BT|LR|RL)/);
                if (dirMatch) { direction = (dirMatch[1] === 'LR' || dirMatch[1] === 'RL') ? 'LR' : 'TB'; continue; }
                if (trimmed.startsWith('graph') || trimmed.startsWith('flowchart') ||
                    trimmed.startsWith('erDiagram') || trimmed.startsWith('sequenceDiagram')) continue;

                // Match edges: A --> B, A -->|label| B (labels in [...] / ["..."] optional, :::class optional)
                const edgeMatch = trimmed.match(/^(\w+)(?:\[("[^"]*"|[^\]]*)\])?(?::::(\w+))?\s*(-+->|-->|==>|-.->|--)\s*(?:\|([^|]*)\|)?\s*(\w+)(?:\[("[^"]*"|[^\]]*)\])?(?::::(\w+))?/);
                if (edgeMatch) {
                    const [_, srcId, srcLabel, srcKind, arrow, edgeLabel, tgtId, tgtLabel, tgtKind] = edgeMatch;
                    declare(srcId, srcLabel, srcKind);
                    declare(tgtId, tgtLabel, tgtKind);
                    links.push({source:srcId, target:tgtId, label:(edgeLabel||'').replace(/^"(.*)"$/, '$1').trim()});
                    continue;
                }

                // Match standalone nodes: A["Label"]:::kind, A[Label], A{Label}, A(Label), A((Label))
                const nodeMatch = trimmed.match(/^(\w+)[\[({]+("[^"]*"|[^\]})]+)[\]})]+(?::::(\w+))?/);
                if (nodeMatch) {
                    declare(nodeMatch[1], nodeMatch[2], nodeMatch[3]);
                    continue;
                }

                // ER diagram: Entity ||--o{ Other : relation
                const erMatch = trimmed.match(/^(\w+)\s+(\|[|o{}<>-]+)\s+(\w+)\s*:\s*(.+)/);
                if (erMatch) {
                    const [_, src, rel, tgt, label] = erMatch;
                    declare(src); declare(tgt);
                    links.push({source:src, target:tgt, label:label.trim()});
                    continue;
                }

                // C4 syntax: Component(id, "Label", "Tech", "Description")
                const c4Match = trimmed.match(/^(?:Component|Container|System|Person|ComponentDb|ContainerDb|SystemDb|System_Ext|Container_Ext|Component_Ext)\((\w+),\s*"([^"]+)"(?:,\s*"([^"]*)")?(?:,\s*"([^"]*)")?\)/);
                if (c4Match) {
                    const [_, id, label, tech, desc] = c4Match;
                    if (!nodeMap[id]) { nodeMap[id] = {id, label: label + (tech ? ' ['+tech+']' : ''), group:currentGroup, description:desc||''}; nodes.push(nodeMap[id]); }
                    continue;
                }

                // C4 Container_Boundary / Boundary
                const boundaryMatch = trimmed.match(/^(?:Container_Boundary|Boundary|Enterprise_Boundary|System_Boundary)\((\w+),\s*"([^"]+)"\)/);
                if (boundaryMatch) {
                    currentGroup = boundaryMatch[2];
                    groups.push(currentGroup);
                    continue;
                }

                // C4 Relations: Rel(from, to, "label"), BiRel, Rel_D, Rel_U, Rel_L, Rel_R
                const relMatch = trimmed.match(/^(?:Rel|BiRel|Rel_D|Rel_U|Rel_L|Rel_R|Rel_Back)\((\w+),\s*(\w+),\s*"([^"]+)"(?:,\s*"([^"]*)")?\)/);
                if (relMatch) {
                    const [_, src, tgt, label] = relMatch;
                    if (nodeMap[src] && nodeMap[tgt]) {
                        links.push({source:src, target:tgt, label:label});
                    }
                    continue;
                }
            }
            nodes.forEach(n => { if (meta.src[n.id]) n.source = meta.src[n.id]; if (meta.note[n.id]) n.note = meta.note[n.id]; });
            meta.evidence.forEach(e => { const l = links.find(x => x.source === e.from && x.target === e.to && !x.evidence); if (l) l.evidence = e.ref; });
            return {nodes, links, groups, direction};
        }

        // Sentinel: posted only if execution reached the very end of the inline
        // <script> block. If init-checkpoint appears in diag but this end-checkpoint
        // does not, the script aborted somewhere in between.
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                window.webkit.messageHandlers.bridge.postMessage({
                    type: 'jsError',
                    payload: {
                        where: 'end-checkpoint',
                        message: 'reached end of <script> block — typeof loadInsightSkeleton=' + (typeof window.loadInsightSkeleton)
                            + ' updateInsightSection=' + (typeof window.updateInsightSection)
                            + ' setInsightStatus=' + (typeof window.setInsightStatus),
                        source: '', lineno: 0, colno: 0, stack: ''
                    }
                });
            }
        } catch (_) {}

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else {
            init();
        }
