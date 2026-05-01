        // D3 INTERACTIVE CANVAS FOR MERMAID DIAGRAMS
        // ============================================================================

        function initMermaidCanvas(container, mermaidSource) {
            if (typeof d3 === 'undefined' || typeof dagre === 'undefined') {
                container.innerHTML = '<div style="padding:20px;color:#808080;">Loading libraries...</div>';
                return;
            }

            const isDark = document.documentElement.getAttribute('data-theme') !== 'light';
            const bg = isDark ? '#1e1e1e' : '#ffffff';
            const textColor = isDark ? '#d4d4d4' : '#1e1e1e';
            const linkColor = isDark ? '#555' : '#bbb';
            const tc = {service:'#4ec9b0',database:'#c586c0',api:'#569cd6',queue:'#ce9178',
                system:'#9cdcfe',gateway:'#dcdcaa',cache:'#d7ba7d',pipeline:'#dcdcaa',
                worker:'#ce9178',scheduler:'#c586c0',process:'#4ec9b0',strategy:'#569cd6',
                risk:'#f44747',instrument:'#c586c0',default:'#808080'};
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

            const {nodes, links, groups} = parseMermaid(mermaidSource);
            if (nodes.length === 0) { container.innerHTML = '<div style="padding:20px;color:#808080;font-size:11px;">No nodes found</div>'; return; }

            nodes.forEach(n => { n.type = guessType(n.label); n.color = tc[n.type] || tc.default; });
            const uniqueGroups = [...new Set(nodes.map(n=>n.group).filter(Boolean))];
            const groupColorMap = {};
            uniqueGroups.forEach((g,i) => { groupColorMap[g] = groupColors[i % groupColors.length]; });

            // Dagre layout — layered, no overlaps
            const dagreGraph = new dagre.graphlib.Graph({compound:true});
            dagreGraph.setGraph({rankdir:'TB', nodesep:40, ranksep:60, edgesep:20, marginx:30, marginy:30});
            dagreGraph.setDefaultEdgeLabel(() => ({}));

            // Add groups as parent nodes
            uniqueGroups.forEach(g => { dagreGraph.setNode('group_'+g, {label:g, clusterLabelPos:'top', style:'fill:none'}); });

            // Add nodes — calculate size based on label lines
            nodes.forEach(n => {
                const lines = n.label.replace(/<br\s*\/?>/gi, '\n').split('\n');
                const maxLineLen = Math.max(...lines.map(l => l.trim().length));
                const w = Math.max(maxLineLen * 7.5 + 20, 70);
                const h = 20 + lines.length * 14;
                dagreGraph.setNode(n.id, {label:n.label, width:w, height:h});
                if (n.group) dagreGraph.setParent(n.id, 'group_'+n.group);
            });

            // Add edges
            links.forEach(l => { dagreGraph.setEdge(l.source, l.target, {label:l.label||''}); });

            dagre.layout(dagreGraph);

            // Apply positions
            nodes.forEach(n => {
                const pos = dagreGraph.node(n.id);
                if (pos) { n.x = pos.x; n.y = pos.y; n.w = pos.width; n.h = pos.height; }
            });

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
                .attr('refX',16).attr('refY',0).attr('markerWidth',6).attr('markerHeight',6)
                .attr('orient','auto').append('path').attr('d','M0,-5L10,0L0,5').attr('fill',linkColor);

            // Group backgrounds
            uniqueGroups.forEach((gName,i) => {
                const members = nodes.filter(n=>n.group===gName);
                if (!members.length) return;
                const pad = 20;
                const x1 = d3.min(members, d=>d.x-d.w/2)-pad, y1 = d3.min(members, d=>d.y-d.h/2)-pad-12;
                const x2 = d3.max(members, d=>d.x+d.w/2)+pad, y2 = d3.max(members, d=>d.y+d.h/2)+pad;
                g.append('rect').attr('x',x1).attr('y',y1).attr('width',x2-x1).attr('height',y2-y1)
                    .attr('rx',8).attr('ry',8).attr('fill',groupColorMap[gName]||'#333')
                    .attr('fill-opacity',0.12).attr('stroke',groupColorMap[gName]||'#555').attr('stroke-opacity',0.3);
                g.append('text').attr('x',x1+6).attr('y',y1+10).attr('font-size',9)
                    .attr('fill','#808080').attr('font-weight','bold').text(gName);
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

            // Edges
            const edgeGroup = g.append('g');
            const edgeElements = [];
            links.forEach((l,i) => {
                if (!l.srcNode || !l.tgtNode) return;
                const line = edgeGroup.append('line')
                    .attr('x1',l.srcNode.x).attr('y1',l.srcNode.y)
                    .attr('x2',l.tgtNode.x).attr('y2',l.tgtNode.y)
                    .attr('stroke',linkColor).attr('stroke-width',1.5)
                    .attr('marker-end','url(#arr-'+container.id+')')
                    .style('cursor','pointer')
                    .attr('data-idx',i);

                const labelEl = l.label ? edgeGroup.append('text')
                    .attr('x',(l.srcNode.x+l.tgtNode.x)/2).attr('y',(l.srcNode.y+l.tgtNode.y)/2-4)
                    .attr('font-size',8).attr('fill','#808080').attr('text-anchor','middle')
                    .text(l.label).style('pointer-events','none').attr('data-idx',i) : null;

                edgeElements.push({line, labelEl, link: l});

                line.on('click', (event) => {
                    event.stopPropagation();
                    showPopup(popup, event.pageX-container.getBoundingClientRect().left,
                        event.pageY-container.getBoundingClientRect().top,
                        `<div class="popup-title">${l.srcNode.label} → ${l.tgtNode.label}</div>
                         <div class="popup-type">Relationship: ${l.label||'depends_on'}</div>
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
                    line.attr('x1',link.srcNode.x).attr('y1',link.srcNode.y)
                        .attr('x2',link.tgtNode.x).attr('y2',link.tgtNode.y);
                    if (labelEl) labelEl.attr('x',(link.srcNode.x+link.tgtNode.x)/2)
                        .attr('y',(link.srcNode.y+link.tgtNode.y)/2-4);
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
                    .attr('font-size',10).attr('fill',textColor).style('pointer-events','none');
                labelLines.forEach((line, li) => {
                    textEl.append('tspan').attr('x',0)
                        .attr('dy', li === 0 ? -(labelLines.length-1)*6 + 4 : 13)
                        .text(line.trim());
                });

                ng.on('click', (event) => {
                    event.stopPropagation();
                    const rect = container.getBoundingClientRect();
                    showPopup(popup, event.pageX-rect.left, event.pageY-rect.top,
                        `<div class="popup-title">${n.label}</div>
                         <div class="popup-type">[${n.type}] ${n.group?'• '+n.group:''}</div>
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
            const btnStyle = `padding:2px 6px;border:1px solid #3c3c3c;background:${isDark?'#252526':'#f3f3f3'};color:${textColor};border-radius:3px;font-size:9px;cursor:pointer;`;

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
                <span style="font-size:8px;color:#808080;">${nodes.length} nodes, ${links.length} edges</span>
            `;
            container.appendChild(ctrl);

            // Store references for filtering
            container._canvasData = {nodes, links, edgeElements, nodeGroup, edgeGroup, uniqueGroups};
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

            for (const line of lines) {
                const trimmed = line.trim();
                if (!trimmed || trimmed.startsWith('%%') || trimmed.startsWith('classDef') ||
                    trimmed.startsWith('class ') || trimmed.startsWith('pie')) continue;

                // Track subgroups
                const sgMatch = trimmed.match(/^subgraph\s+(?:"([^"]+)"|(\S+))/);
                if (sgMatch) {
                    currentGroup = sgMatch[1] || sgMatch[2];
                    groups.push(currentGroup);
                    continue;
                }
                if (trimmed === 'end') { currentGroup = null; continue; }
                if (trimmed.startsWith('graph') || trimmed.startsWith('flowchart') ||
                    trimmed.startsWith('erDiagram') || trimmed.startsWith('sequenceDiagram')) continue;

                // Match edges: A --> B, A -->|label| B
                const edgeMatch = trimmed.match(/^(\w+)(?:\[([^\]]*)\])?\s*(-+->|-->|==>|-.->|--)\s*(?:\|([^|]*)\|)?\s*(\w+)(?:\[([^\]]*)\])?/);
                if (edgeMatch) {
                    const [_, srcId, srcLabel, arrow, edgeLabel, tgtId, tgtLabel] = edgeMatch;
                    if (!nodeMap[srcId]) { nodeMap[srcId] = {id:srcId, label:srcLabel||srcId, group:currentGroup}; nodes.push(nodeMap[srcId]); }
                    else { if (srcLabel) nodeMap[srcId].label = srcLabel; if (currentGroup && !nodeMap[srcId].group) nodeMap[srcId].group = currentGroup; }
                    if (!nodeMap[tgtId]) { nodeMap[tgtId] = {id:tgtId, label:tgtLabel||tgtId, group:currentGroup}; nodes.push(nodeMap[tgtId]); }
                    else { if (tgtLabel) nodeMap[tgtId].label = tgtLabel; if (currentGroup && !nodeMap[tgtId].group) nodeMap[tgtId].group = currentGroup; }
                    links.push({source:srcId, target:tgtId, label:edgeLabel||''});
                    continue;
                }

                // Match standalone nodes: A[Label] or A{Label} or A(Label) or A((Label))
                const nodeMatch = trimmed.match(/^(\w+)[\[({]+([^\]})]+)[\]})]+/);
                if (nodeMatch) {
                    const [_, id, label] = nodeMatch;
                    if (!nodeMap[id]) { nodeMap[id] = {id, label, group:currentGroup}; nodes.push(nodeMap[id]); }
                    else { nodeMap[id].label = label; if (currentGroup) nodeMap[id].group = currentGroup; }
                    continue;
                }

                // ER diagram: Entity ||--o{ Other : relation
                const erMatch = trimmed.match(/^(\w+)\s+(\|[|o{}<>-]+)\s+(\w+)\s*:\s*(.+)/);
                if (erMatch) {
                    const [_, src, rel, tgt, label] = erMatch;
                    if (!nodeMap[src]) { nodeMap[src] = {id:src, label:src, group:currentGroup}; nodes.push(nodeMap[src]); }
                    if (!nodeMap[tgt]) { nodeMap[tgt] = {id:tgt, label:tgt, group:currentGroup}; nodes.push(nodeMap[tgt]); }
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
            return {nodes, links, groups};
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
