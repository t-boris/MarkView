        // X-Ray tab, part 2 of 5: the Cytoscape graph: stylesheet, layered bands, layout, render, selection and expand/collapse.
        (function (A) {
            if (!A.ready) return;   // no #arch-container on this page (the first part returned early): nothing to set up
            const {
                bandRoles, buildElements, codeOverview, crossRoles, currentView, el, expandedSet, indexView, isBook,
                isHidden, palette, post, representative, stateKey, ui
            } = A;
            Object.assign(A, {
                activate, autoExpand, collapse, ensureCy, entityTarget, highlightNeighbourhood, openPRFile, render,
                renderEmpty, restyle, sectionTarget, stylesheet
            });

            function stylesheet() {
                const c = palette();
                return [
                    { selector: 'node', style: {
                        'shape': 'round-rectangle', 'width': 'data(w)', 'height': 'data(h)',
                        'background-color': c.node, 'border-width': 1, 'border-color': c.line,
                        'label': 'data(label)', 'color': c.text, 'font-size': 10.5,
                        'font-family': '-apple-system, "SF Pro Text", sans-serif',
                        'text-valign': 'center', 'text-halign': 'center', 'text-wrap': 'wrap', 'text-max-width': 'data(tw)',
                        'line-height': 1.3 } },
                    { selector: 'node[fill != ""]', style: { 'border-color': 'data(fill)', 'border-width': 2,
                        'background-color': 'data(fill)', 'background-opacity': 0.14 } },
                    { selector: 'node.expandable', style: { 'border-style': 'solid', 'border-width': 1.5 } },
                    { selector: 'node.file, node.doc', style: { 'font-size': 10, 'font-family': '"SF Mono", Menlo, monospace' } },
                    // A path has no spaces to wrap at. In the layered Code view its label breaks inside the word, so it stays in its
                    // cell: a label wider than the cell widens the container around it (BUG-085).
                    { selector: 'node.fitLabel', style: { 'text-overflow-wrap': 'anywhere' } },
                    { selector: 'node.section', style: { 'font-size': 10, 'border-style': 'dotted' } },
                    // Contents of a file: collection → type → item.
                    { selector: 'node.collection', style: { 'font-weight': 600, 'border-style': 'double', 'border-width': 3 } },
                    { selector: 'node.group', style: { 'font-size': 10, 'border-style': 'solid' } },
                    { selector: 'node.entity', style: { 'font-size': 9.5, 'border-style': 'dotted', 'text-max-width': 200 } },
                    // Boxes that carry their description: smaller type, so the whole text is read in place.
                    { selector: 'node.described', style: { 'font-size': 8.5, 'line-height': 1.2, 'text-max-width': 'data(tw)' } },
                    // What changed inside a file (PR X-Ray).
                    { selector: 'node.changePart', style: { 'font-size': 10, 'border-style': 'solid' } },
                    { selector: 'node.change', style: { 'font-size': 9.5, 'border-color': '#d29922', 'border-width': 1.5, 'text-max-width': 220 } },
                    { selector: 'node.external, node.externalGroup', style: { 'border-style': 'dashed', 'color': c.mute } },
                    { selector: 'node.moduleRef', style: { 'border-style': 'dotted' } },
                    { selector: 'node.box', style: {
                        'shape': 'round-rectangle', 'background-color': c.box, 'background-opacity': c.boxAlpha,
                        'border-color': c.boxLine, 'border-width': 1, 'text-valign': 'top', 'text-halign': 'center',
                        'text-margin-y': -4, 'font-weight': 600, 'padding': 14, 'color': c.mute } },
                    // Containers keep a light fill; the overlay colour goes on the outline.
                    { selector: 'node.box[fill != ""]', style: { 'background-color': c.box, 'background-opacity': c.boxAlpha, 'border-color': 'data(fill)', 'border-width': 2 } },
                    // Layered Code overview: a band wears the colour of its layer and names itself above.
                    { selector: 'node.layer.box', style: { 'background-color': 'data(fill)', 'background-opacity': 0.08,
                        'border-color': 'data(fill)', 'border-width': 1.5, 'color': c.text, 'font-size': 11.5, 'text-margin-y': -6 } },
                    // Who the system serves: a caption above the stack, not a part of the model.
                    { selector: 'node.actors', style: { 'background-opacity': 0, 'border-style': 'dashed', 'border-color': c.mute,
                        'color': c.mute, 'font-weight': 600, 'events': 'no' } },
                    { selector: 'node[dimmed = 1]', style: { 'opacity': c.dim } },
                    // A change is marked whatever overlay colours the node: a halo behind a changed part, and a removed
                    // file with a dashed red outline (its name carries a cross), so neither depends on the fill.
                    { selector: 'node[changed = 1]', style: { 'underlay-color': c.info, 'underlay-opacity': 0.3, 'underlay-padding': 5,
                        'underlay-shape': 'round-rectangle', 'underlay-corner-radius': 8 } },
                    { selector: 'node[removed = 1]', style: { 'border-style': 'dashed', 'border-color': c.bad, 'border-width': 2,
                        'underlay-color': c.bad, 'underlay-opacity': 0.22 } },
                    // Replace Cytoscape's default selection fill (solid blue) with an accent outline.
                    { selector: 'node:selected', style: { 'border-color': c.accent, 'border-width': 2.5, 'background-color': c.node, 'background-opacity': 1 } },
                    { selector: 'node.box:selected', style: { 'background-color': c.box, 'background-opacity': c.boxAlpha, 'border-color': c.accent } },
                    { selector: 'node[fill != ""]:selected', style: { 'background-color': 'data(fill)', 'background-opacity': 0.2 } },
                    { selector: 'node:active, edge:active', style: { 'overlay-opacity': 0 } },
                    { selector: 'edge', style: {
                        'width': 'mapData(weight, 1, 20, 1, 3.5)', 'line-color': c.line, 'target-arrow-color': c.line,
                        'target-arrow-shape': 'triangle', 'arrow-scale': 0.7, 'curve-style': 'bezier', 'opacity': ui.view === 'code' ? 0 : 0.85, 'events': ui.view === 'code' ? 'no' : 'yes' } },
                    { selector: 'edge[label != ""]', style: { 'label': 'data(label)', 'font-size': 9, 'color': c.mute,
                        'text-background-color': c.bg, 'text-background-opacity': 1, 'text-background-padding': 2 } },
                    { selector: 'edge.faded', style: { 'opacity': ui.view === 'code' ? 0 : 0.12 } },
                    { selector: 'node.appearing', style: { 'opacity': 0 } },
                    // Links a pull request adds (green) or removes (red, dashed).
                    { selector: 'edge[kind = "added"]', style: { 'line-color': c.ok, 'target-arrow-color': c.ok, 'width': 2.5, 'opacity': 1 } },
                    { selector: 'edge[kind = "removed"]', style: { 'line-color': c.bad, 'target-arrow-color': c.bad, 'width': 2.5, 'line-style': 'dashed', 'opacity': 1 } },
                    { selector: 'node[provisional = 1]', style: { 'border-style': 'dashed' } },
                    // Code view: draft layers dotted, AI-inferred dependencies dashed; scanner facts stay solid.
                    { selector: 'node.draft', style: { 'border-style': 'dotted' } },
                    { selector: 'edge.inference', style: { 'line-style': 'dashed' } },
                    // Related sections the AI found in the Book: dashed, muted, their reason in the panel.
                    { selector: 'edge[kind = "related"]', style: { 'line-style': 'dashed', 'line-color': c.mute, 'target-arrow-color': c.mute, 'label': '', 'opacity': 0.7 } },
                    { selector: 'edge.hot', style: { 'line-color': c.accent, 'target-arrow-color': c.accent, 'opacity': 1, 'events': 'yes' } },
                ];
            }

            /** The Code overview as a layered diagram: full-width bands for the layers of the
             *  flow, stacked in order, with the cross-cutting layers as columns running down
             *  beside them; Users sit above the stack and the external dependencies below it.
             *  Every box is placed by hand so the picture stays the same between redraws. */
            function layeredBands(keepView, fitTo) {
                const tops = A.cy.nodes().orphans().filter(function(n) { return n.data('kind') === 'layer'; });
                if (!tops.length) return false;
                const byRole = function(roles) {
                    return roles.map(function(r) { return tops.filter(function(n) { return n.data('role') === r; }).toArray(); })
                        .reduce(function(a, b) { return a.concat(b); }, []);
                };
                const bands = byRole(bandRoles);
                const columns = byRole(crossRoles);
                const known = new Set(bands.concat(columns).map(function(n) { return n.id(); }));
                tops.forEach(function(n) { if (!known.has(n.id())) bands.push(n); });
                if (!bands.length) return false;

                // Room between bands, where the next band's title sits: two lines (name, then
                // files and lines) of 11.5 px type, its 6 px margin, and air above it.
                const gap = 50;
                const pad = 14;            // matches the box padding of the stylesheet
                const cellGap = 12;
                // An opened part is drawn this much larger than its closed neighbours (the box wraps its parts'
                // borders), so it is placed this much smaller and the layer's edges stay in line (BUG-085).
                const nest = 2.5;
                // While the width of the bands is chosen, opened parts count as closed: opening a part must not
                // change the columns the closed parts stand in, only make its layer taller.
                let closedOnly = false;
                const holdsOpened = function(kids) { return !closedOnly && kids.some(function(kid) { return kid.isParent(); }); };
                // The readable width of a cross-cutting column with one part per row.
                const colWidth = columns.length > 3 ? 144 : 168;
                const colGap = 24;
                // A column with many parts grows sideways, up to this many parts per row.
                const columnGridLimit = 4;

                /** Every part of a container is the same size: the tallest label at `cellW` sets it. */
                const partHeight = function(kids, cellW) {
                    return kids.reduce(function(m, kid) {
                        const lines = String(kid.data('label') || '').split('\n').reduce(function(a, line) {
                            return a + Math.max(1, Math.ceil((line.length * 6.2) / Math.max(40, cellW - 18)));
                        }, 0);
                        return Math.max(m, 14 + lines * 13);
                    }, 40);
                };

                /** Place a container's parts on a grid inside `width`, and return its height.
                 *  `gridCols` fixes the parts per row; otherwise as many as fit 180 px each. */
                const fill = function(node, left, top, width, minHeight, gridCols) {
                    const kids = node.children();
                    if (!kids.length) {
                        const h = Math.max(44, minHeight || 44);
                        node.data({ w: width, h: h, tw: width - 24 }).addClass('fitLabel');
                        node.position({ x: left + width / 2, y: top + h / 2 });
                        return h;
                    }
                    // A part that is open holds parts of its own: it is laid out inside its container (BUG-085).
                    if (holdsOpened(kids)) return fillOpened(node, kids, left, top, width, minHeight, gridCols);
                    const inner = width - pad * 2;
                    const fit = Math.max(1, Math.min(kids.length, gridCols || Math.floor((inner + cellGap) / 180)));
                    // Balance the grid: 5 parts over 2 columns are 3 + 2, never 2 + 2 + 1.
                    const rows = Math.ceil(kids.length / fit);
                    const cols = Math.ceil(kids.length / rows);
                    const cellW = (inner - cellGap * (cols - 1)) / cols;
                    const textH = partHeight(kids, cellW);
                    // A cross-cutting column is as tall as the stack, but its parts keep a readable
                    // size: the spare height goes between them rather than into giant boxes.
                    const spread = minHeight ? (minHeight - pad * 2 - cellGap * (rows - 1)) / rows : 0;
                    // One part alone fills its column; several keep a readable size and share the
                    // spare height between them, so the column still spans the whole stack.
                    const cellH = rows > 1 ? Math.max(textH, Math.min(spread, 132)) : Math.max(textH, spread);
                    const rowGap = rows > 1 && minHeight
                        ? Math.max(cellGap, (minHeight - pad * 2 - rows * cellH) / (rows - 1)) : cellGap;
                    kids.forEach(function(kid, i) {
                        const r = Math.floor(i / cols), c = i % cols;
                        // The last row may be short: its parts share the width, leaving no gap.
                        const inRow = Math.min(cols, kids.length - r * cols);
                        const rowW = (inner - cellGap * (inRow - 1)) / inRow;
                        kid.data({ w: rowW, tw: Math.max(40, rowW - 16), h: cellH }).addClass('fitLabel');
                        kid.position({ x: left + pad + c * (rowW + cellGap) + rowW / 2,
                                       y: top + pad + r * (cellH + rowGap) + cellH / 2 });
                    });
                    return Math.max(minHeight || 0, pad * 2 + rows * cellH + rowGap * (rows - 1));
                };

                /** Room above an opened part for its title, which is drawn over the top edge of its box. */
                const titleRoom = function(node, width) {
                    const lines = String(node.data('label') || '').split('\n').reduce(function(a, line) {
                        return a + Math.max(1, Math.ceil((line.length * 6.6) / Math.max(40, width - 24)));
                    }, 0);
                    return 2 + lines * 13.5;
                };

                /** A container that holds opened parts (BUG-085). Its closed parts keep the grid they have in a
                 *  container with nothing open. Each opened part takes a row of its own, the full width, after the
                 *  grid row its place falls in, and is laid out inside by these same rules. The layers stay where
                 *  they are relative to each other: opening a part only makes its own layer taller. */
                const fillOpened = function(node, kids, left, top, width, minHeight, gridCols) {
                    const inner = width - pad * 2;
                    const closed = kids.filter(function(kid) { return !kid.isParent(); }).toArray();
                    const fit = Math.max(1, Math.min(closed.length || 1, gridCols || Math.floor((inner + cellGap) / 180)));
                    const gridRows = closed.length ? Math.ceil(closed.length / fit) : 0;
                    const cols = closed.length ? Math.ceil(closed.length / gridRows) : 1;
                    const cellW = (inner - cellGap * (cols - 1)) / cols;
                    const cellH = closed.length ? partHeight(closed, cellW) : 0;
                    // The opened part goes after the grid row of the closed part before it, or first.
                    const opened = [];
                    let seen = 0;
                    kids.forEach(function(kid) {
                        if (kid.isParent()) opened.push({ part: kid, after: seen ? Math.floor((seen - 1) / cols) : -1 });
                        else seen++;
                    });
                    const sequence = [];
                    const push = function(after) {
                        opened.filter(function(o) { return o.after === after; }).forEach(function(o) { sequence.push({ part: o.part }); });
                    };
                    push(-1);
                    for (let r = 0; r < gridRows; r++) {
                        sequence.push({ cells: closed.slice(r * cols, (r + 1) * cols) });
                        push(r);
                    }
                    let y = top + pad;
                    sequence.forEach(function(row) {
                        if (row.cells) {
                            const inRow = row.cells.length;
                            const rowW = (inner - cellGap * (inRow - 1)) / inRow;
                            row.cells.forEach(function(kid, c) {
                                kid.data({ w: rowW, tw: Math.max(40, rowW - 16), h: cellH }).addClass('fitLabel');
                                kid.position({ x: left + pad + c * (rowW + cellGap) + rowW / 2, y: y + cellH / 2 });
                            });
                            y += cellH + cellGap;
                        } else {
                            y += titleRoom(row.part, inner);
                            row.part.data({ tw: Math.max(40, inner - 24) });
                            y += nest;
                            y += fill(row.part, left + pad + nest, y, inner - nest * 2, 0) + nest + cellGap;
                        }
                    });
                    return Math.max(minHeight || 0, y - cellGap + pad - top);
                };

                /** How many parts per row a cross-cutting column needs to stay within the stack's
                 *  height, and the width that takes: one part per row while they fit, more side by
                 *  side when they do not, so a long column never runs below the stack. */
                const columnGrid = function(column, stackHeight) {
                    const kids = column.children();
                    const cell = colWidth - pad * 2;
                    let cols = 1;
                    for (let fit = 1; fit <= Math.min(columnGridLimit, kids.length); fit++) {
                        const rows = Math.ceil(kids.length / fit);
                        cols = Math.ceil(kids.length / rows);
                        if (pad * 2 + rows * partHeight(kids, cell) + cellGap * (rows - 1) <= stackHeight) break;
                    }
                    // An opened part is laid out inside the column: two cells wide, so its parts are readable (BUG-085).
                    if (holdsOpened(kids)) cols = Math.max(cols, 2);
                    return { cols: cols, width: pad * 2 + cols * cell + cellGap * (cols - 1) };
                };

                /** One pass over the stack with the given band width: the stack's height, the
                 *  diagram's height (a column that still cannot fit may be taller) and the width
                 *  the cross-cutting columns take beside the stack. */
                const place = function(bandWidth) {
                    let y = 0;
                    bands.forEach(function(band) { y += fill(band, 0, y, bandWidth, 0) + gap; });
                    const stackHeight = Math.max(1, y - gap);
                    let x = bandWidth + 48, height = stackHeight;
                    columns.forEach(function(column) {
                        // A cross-cutting layer spans the whole stack: its parts share that height.
                        const grid = columnGrid(column, stackHeight);
                        height = Math.max(height, fill(column, x, 0, grid.width, stackHeight, grid.cols));
                        x += grid.width + colGap;
                    });
                    return { height: height, cross: columns.length ? x - colGap - bandWidth : 0 };
                };

                // Lay out once to learn how tall the diagram is, then choose a width that fills the
                // canvas instead of leaving the diagram a wide strip across an empty window.
                let bandWidth = Math.max(560, Math.min(1120, columns.length ? 860 : 1000));
                closedOnly = true;
                const first = place(bandWidth);
                const ratio = Math.max(0.6, A.cy.width() / Math.max(1, A.cy.height()));
                const wanted = Math.round(Math.max(520, Math.min(1200, ratio * first.height - first.cross)));
                if (Math.abs(wanted - bandWidth) > 40) bandWidth = wanted;
                closedOnly = false;
                const placed = place(bandWidth);
                const fullWidth = bandWidth + placed.cross;

                const actors = A.cy.getElementById('code:actors');
                if (actors.length) {
                    actors.data({ w: fullWidth, tw: fullWidth - 24, h: 30 });
                    actors.position({ x: fullWidth / 2, y: -(gap + 15) });
                }
                const external = A.cy.nodes().orphans().filter(function(n) { return n.data('kind') === 'externalGroup'; });
                // Below everything above it: the stack and every column.
                external.forEach(function(group, i) {
                    fill(group, 0, placed.height + gap + i * 80, fullWidth, 0);
                });
                const target = fitTo ? A.cy.getElementById(fitTo) : null;
                if (target && target.length) A.cy.fit(target.union(target.descendants()), 40);
                else if (!keepView) A.cy.fit(A.cy.nodes(), 28);
                return true;
            }

            /** Lay the graph out; `fitTo` zooms to that node afterwards, `keepView` leaves pan and zoom alone. */
            function layout(fitTo, keepView) {
                if (!A.cy) return;
                const count = A.cy.nodes().length;
                if (ui.view === 'code' && count && layeredBands(keepView, fitTo)) return;
                // Every box is laid out on its own: children with few links between them (a
                // notes folder, a list of files) are packed into a rectangle instead of one tall
                // column; linked ones follow the flow of their links. The top level is packed to
                // the window's shape. More than `flowLimit` children are packed even when linked:
                // a flow of dozens of files that reference one another spreads them over a huge
                // area (BUG-012: MarkView/Models, 73 files, filled 2% of its box; packed, 61%).
                const flowLimit = 20;
                function sparse(children) {
                    if (children.length > flowLimit) return true;
                    const ids = new Set(children.map(function(n) { return n.id(); }));
                    const links = children.connectedEdges().filter(function(e) { return ids.has(e.source().id()) && ids.has(e.target().id()); }).length;
                    return links < 0.25 * children.length;
                }
                const topSparse = sparse(A.cy.nodes().orphans());
                const packed = function(ratio) {
                    return { 'elk.algorithm': 'rectpacking', 'elk.aspectRatio': String(ratio), 'elk.spacing.nodeNode': 14,
                             'elk.padding': '[top=30,left=14,bottom=14,right=14]' };
                };
                const layeredFor = function(direction) {
                    return {
                        'elk.algorithm': 'layered', 'elk.direction': direction,
                        'elk.layered.spacing.nodeNodeBetweenLayers': 46, 'elk.spacing.nodeNode': 18,
                        'elk.padding': '[top=30,left=14,bottom=14,right=14]',
                        'elk.layered.crossingMinimization.strategy': 'LAYER_SWEEP',
                        // Keep document order (sections, files) where edges allow it.
                        'elk.layered.considerModelOrder.strategy': 'NODES_AND_EDGES',
                    };
                };
                const bands = ui.view === 'code' && A.cy.nodes().every(function(n) { return n.data('kind') === 'layer' || n.data('kind') === 'externalGroup'; });
                // Boxes inside a box flow to the right, as they always did.
                const layered = layeredFor(bands ? 'DOWN' : 'RIGHT');
                // The top level of a connected graph flows to the right or downwards, whichever fills the canvas better (BUG-111):
                // a chain of components laid out to the right is as wide as the chain is long and as high as one box, so on a
                // canvas that is nearly as tall as it is wide the fit shrank it to a thin strip of unreadable labels.
                const options = function(direction) {
                    return {
                        name: 'elk', nodeDimensionsIncludeLabels: false,
                        elk: Object.assign({ 'elk.hierarchyHandling': 'SEPARATE_CHILDREN' },
                            topSparse ? packed(Math.max(0.5, A.cy.width() / Math.max(1, A.cy.height()))) : direction ? layeredFor(direction) : layered),
                        nodeLayoutOptions: function(node) {
                            if (!node.isParent()) return {};
                            return sparse(node.children()) ? packed(1.6) : layered;
                        },
                    };
                };
                const run = function(direction) {
                    A.cy.layout(Object.assign(options(direction), {
                        fit: !fitTo && !keepView, padding: 28, animate: ui.view !== 'code' && count < 200, animationDuration: 420,
                        stop: function() {
                            A.cy.nodes('.appearing').animate({ style: { opacity: 1 } }, { duration: 350, complete: function() {
                                A.cy.nodes('.appearing').removeClass('appearing').removeStyle('opacity');
                            } });
                            if (fitTo) {
                                const target = A.cy.getElementById(fitTo);
                                if (target.length) {
                                    const elements = target.union(target.descendants()).union(target.neighborhood());
                                    if (ui.view === 'code') A.cy.fit(elements, 40);
                                    else A.cy.animate({ fit: { eles: elements, padding: 40 }, duration: 260 });
                                }
                            }
                        },
                    })).run();
                };
                const choosing = !topSparse && !bands && ui.view !== 'code' && !fitTo && !keepView
                    && A.cy.nodes().orphans().length > 2 && count <= 150;
                if (!choosing) { run(bands ? undefined : ui.flow); return; }
                const token = ++A.flowToken;
                const width = A.cy.width(), height = A.cy.height();
                // Each direction is tried on a copy of the graph that is never drawn; the one that can be shown larger wins.
                const scaleOf = function(direction) {
                    return new Promise(function(resolve) {
                        let copy = null;
                        try {
                            copy = cytoscape({ headless: true, styleEnabled: true, style: A.cy.style().json(), elements: A.cy.elements().jsons() });
                            const trial = copy.layout(Object.assign(options(direction), { fit: false, animate: false }));
                            trial.one('layoutstop', function() {
                                const box = copy.nodes().boundingBox({ includeLabels: false });
                                copy.destroy();
                                resolve(Math.min((width - 56) / Math.max(1, box.w), (height - 56) / Math.max(1, box.h)));
                            });
                            trial.run();
                        } catch (e) { if (copy) copy.destroy(); resolve(0); }
                    });
                };
                scaleOf('RIGHT').then(function(right) {
                    return scaleOf('DOWN').then(function(down) { return down > right * 1.15 ? 'DOWN' : 'RIGHT'; });
                }).then(function(direction) {
                    if (token !== A.flowToken || !A.cy) return;
                    ui.flow = direction;
                    run(direction);
                });
            }

            /** Message over the canvas when the chosen view does not exist yet. */
            function renderEmpty() {
                const snap = ui.payload && ui.payload.snapshot;
                if (ui.view === 'pr') {
                    el.empty.hidden = !!ui.prView;
                    el.empty.textContent = !snap ? 'The X-Ray is still being built…' : 'Choose a pull request, your branch or your uncommitted changes above.';
                    return;
                }
                const missing = snap && !snap.views.some(function(v) { return v.id === ui.view; });
                if (ui.view === 'code' && currentView() && !currentView().nodes.some(function(n) { return n.kind === 'file'; })) {
                    el.empty.hidden = false;
                    el.empty.textContent = 'No source code was found in this folder. Structure and Book show its other files.';
                    return;
                }
                if (ui.view === 'code' && currentView() && currentView().nodes.some(function(n) { return n.kind === 'file'; })) {
                    const view = currentView(), idx = indexView(view);
                    if (view.nodes.filter(function(n) { return n.kind === 'file'; }).every(function(n) { return isHidden(n, idx); })) {
                        el.empty.hidden = false;
                        el.empty.textContent = 'All source code is hidden by the current filter. Choose Show all to see it.';
                        return;
                    }
                }
                const bookView = isBook() && !missing && currentView();
                if (bookView && !bookView.nodes.some(function(n) { return n.kind === 'doc'; })) {
                    el.empty.hidden = false;
                    el.empty.textContent = 'No text documents in this folder.';
                    return;
                }
                el.empty.hidden = !missing;
                if (!missing) return;
                const step = { logical: 2, deployment: 3 }[ui.view];
                const name = { logical: 'Logical components', deployment: 'The deployment map', docs: 'The book' }[ui.view] || 'This view';
                const p = ui.progress;
                el.empty.textContent = p && step
                    ? name + ' will appear after step ' + step + ' of ' + p.steps + (p.step < step ? '.' : ' (running now).')
                        + ' Structure and the Book are available meanwhile.'
                    : step ? name + ' is built by the AI analysis. Press Analyze to create it.'
                    : name + ' is empty. Press Rescan.';
            }

            function render(fitTo) {
                renderEmpty();
                if (!A.cy) return;
                // Keep where boxes were, so a redraw moves them instead of starting over;
                // new boxes appear at their parent and fade in.
                const previous = {};
                A.cy.nodes().forEach(function(n) { if (!n.isParent()) previous[n.id()] = Object.assign({}, n.position()); });
                const hadNodes = Object.keys(previous).length > 0;
                A.cy.startBatch();
                A.cy.elements().remove();
                A.cy.add(buildElements());
                if (hadNodes) {
                    A.cy.nodes().forEach(function(n) {
                        if (n.isParent()) return;
                        let at = previous[n.id()];
                        for (let p = n.parent(); !at && p.length; p = p.parent()) at = previous[p.id()];
                        if (at) n.position(at);
                        if (!previous[n.id()] && ui.view !== 'code') n.addClass('appearing');
                    });
                }
                A.cy.style(stylesheet());
                A.cy.endBatch();
                if (ui.selected && A.cy.getElementById(ui.selected).length) A.cy.getElementById(ui.selected).select();
                if (ui.view === 'code') highlightNeighbourhood(ui.selected ? A.cy.getElementById(ui.selected) : null);
                else showRelated(ui.selected);
                layout(fitTo);
                A.renderCrumbs();
                A.renderLegend();
                A.renderDetails();
            }

            function restyle() {
                // Overlay, ratings or theme changed: update labels and colours. Positions are
                // kept unless a box changed size — then lay out again so nothing overlaps.
                if (!A.cy) return;
                const fresh = new Map(buildElements().filter(function(e) { return e.group === 'nodes'; })
                    .map(function(e) { return [e.data.id, e.data]; }));
                let resized = false;
                A.cy.batch(function() {
                    A.cy.nodes().forEach(function(n) {
                        const d = fresh.get(n.id());
                        if (!d) return;
                        if (n.data('w') !== d.w || n.data('h') !== d.h) resized = true;
                        n.data({ label: d.label, fill: d.fill, dimmed: d.dimmed, changed: d.changed, removed: d.removed, w: d.w, h: d.h });
                    });
                    A.cy.style(stylesheet());
                });
                if (resized) layout(null, true);
                A.renderLegend();
                A.renderDetails();
            }

            function ensureCy() {
                if (A.cy) return;
                A.cy = cytoscape({ container: el.graph, elements: [], style: stylesheet(), wheelSensitivity: 0.25,
                                 minZoom: 0.05, maxZoom: 3, boxSelectionEnabled: false });
                A.cy.on('tap', 'node', function(evt) {
                    ui.selectedEdge = null;
                    ui.selected = evt.target.id();
                    highlightNeighbourhood(evt.target);
                    A.renderDetails();
                    // In the PR X-Ray a click on a file opens it (on its change when it has one). On the full map only the
                    // files of the change do: the others are read here first, and open with a double click as anywhere.
                    if (ui.view === 'pr' || ui.prTab) {
                        const shown = currentView();
                        const node = shown && shown.nodes.find(function(n) { return n.id === evt.target.id(); });
                        const pr = ui.payload && ui.payload.pr;
                        const inChange = ui.view === 'pr' || (pr && node && pr.files.some(function(f) { return f.path === node.path; }));
                        if (node && node.path && (node.kind === 'file' || node.kind === 'doc') && inChange) openPRFile(node.path);
                    }
                });
                // An arrow: why the link exists (the AI reads the code behind it).
                A.cy.on('tap', 'edge', function(evt) {
                    const e = evt.target;
                    ui.selected = null;
                    ui.selectedEdge = { view: ui.view, source: e.data('source'), target: e.data('target'),
                                        kind: e.data('kind') || 'uses', label: e.data('label') || '', evidence: e.data('evidence') || [] };
                    A.cy.edges().removeClass('faded hot'); A.cy.edges().not(e).addClass('faded'); e.addClass('hot');
                    A.renderDetails();
                    if (ui.view !== 'code' && ui.selectedEdge.kind !== 'related') post('explainEdge', { view: ui.view, source: ui.selectedEdge.source, target: ui.selectedEdge.target,
                                          kind: ui.selectedEdge.kind, label: ui.selectedEdge.label || undefined });
                });
                A.cy.on('tap', function(evt) {
                    if (evt.target === A.cy) { ui.selected = null; ui.selectedEdge = null; highlightNeighbourhood(null); A.renderDetails(); }
                });
                A.cy.on('dbltap', 'node', function(evt) { activate(evt.target.id()); });
            }

            /** The Book draws the AI's related links only for the selected box: added here when a
             *  box is selected, removed when the selection goes, without laying the graph out again. */
            function showRelated(selectedId) {
                if (!A.cy) return;
                A.cy.remove(A.cy.edges('.related-live'));
                if (!isBook() || !selectedId) return;
                const view = currentView(); if (!view) return;
                const idx = indexView(view);
                const expanded = ui.expanded[stateKey()];
                const seen = new Set();
                const added = [];
                view.edges.forEach(function(e) {
                    if (e.kind !== 'related' || !idx.byId.has(e.source) || !idx.byId.has(e.target)) return;
                    const s = representative(e.source, idx, expanded), t = representative(e.target, idx, expanded);
                    if (!s || !t || s === t || (s !== selectedId && t !== selectedId)) return;
                    if (!A.cy.getElementById(s).length || !A.cy.getElementById(t).length) return;
                    const key = s + '→' + t;
                    if (seen.has(key)) return;
                    seen.add(key);
                    added.push({ group: 'edges', data: { id: 'rl:' + key, source: s, target: t, weight: e.weight || 1, label: '', kind: 'related' }, classes: 'related-live' });
                });
                if (added.length) A.cy.add(added);
            }

            function highlightNeighbourhood(node) {
                showRelated(node ? node.id() : null);
                A.cy.edges().removeClass('faded hot');
                if (!node) return;
                const connected = node.union(node.descendants()).connectedEdges();
                A.cy.edges().not(connected).addClass('faded');
                connected.addClass('hot');
            }

            /** Double-click: expand/collapse containers, open files and documents. */
            /** While the analysis builds the Logical view, open the subsystems that have parts,
             *  so the structure is seen growing — until the user opens or closes something. */
            function autoExpand(snap) {
                // The Book: every part open, so all chapter blurbs are on one screen (top-level
                // parts only for a big book); chapters stay closed until opened.
                if (isBook()) {
                    if (ui.userNavigated) return;
                    const book = snap.views.find(function(v) { return v.id === 'docs'; });
                    if (!book) return;
                    // A small book shows its chapters at once; a larger one its parts, each with
                    // its blurb — one double-click opens a part's chapters.
                    const chapters = book.nodes.filter(function(n) { return n.kind === 'doc'; }).length;
                    const parts = book.nodes.filter(function(n) { return n.kind === 'dir'; });
                    if (chapters <= 20) parts.forEach(function(n) { ui.expanded.docs.add(n.id); });
                    return;
                }
                if (!ui.progress || ui.progress.steps < 2 || ui.view !== 'logical' || ui.userNavigated) return;
                const view = snap.views.find(function(v) { return v.id === 'logical'; });
                if (!view) return;
                const idx = indexView(view);
                (snap.components || []).forEach(function(c) {
                    if (c.parent) return;
                    const kids = (idx.children.get('l:c:' + c.id) || []).map(function(k) { return idx.byId.get(k); });
                    const parts = kids.filter(function(k) { return k && k.kind === 'component'; }).length;
                    if (parts && kids.length - parts <= 40) ui.expanded.logical.add('l:c:' + c.id);
                });
            }

            function activate(id) {
                ui.userNavigated = true;
                const view = currentView(); if (!view) return;
                const idx = indexView(view);
                // Leaving the layered overview: keep the bands that were open on their own,
                // so opening one part does not hide the rest of the diagram.
                if (codeOverview()) expandedSet(idx).forEach(function(open) { ui.expanded.code.add(open); });
                const node = idx.byId.get(id); if (!node) return;
                const kids = idx.children.get(id) || [];
                const expanded = ui.expanded[stateKey()];
                if (kids.length) {
                    if (expanded.has(id)) collapse(id, idx); else { expanded.add(id); ui.focus[stateKey()] = id; }
                    ui.selected = id;
                    render(expanded.has(id) ? id : null);
                } else if (node.kind === 'section') {
                    post('openFile', sectionTarget(node));
                } else if (node.kind === 'entity') {
                    post('openFile', entityTarget(node));
                } else if (node.path && (node.kind === 'file' || node.kind === 'doc' || node.kind === 'moduleRef')) {
                    post('openFile', { path: node.path });
                }
            }

            /** Open a file from the PR X-Ray: a changed one at its first change, in the change's
             *  own version (removed files as they were), any other one as it is. */
            function openPRFile(path) {
                const pr = ui.payload && ui.payload.pr;
                const f = pr && pr.files.find(function(x) { return x.path === path; });
                const first = f && !f.deleted && f.ranges && f.ranges[0];
                post('openFile', first ? { path: path, line: first[0], endLine: first[1] } : { path: path });
            }

            /** Where a Book section starts: its line, and its heading to find in a preview. */
            function sectionTarget(node) {
                const target = { path: node.path, find: node.anchor || node.name };
                if (node.line) target.line = node.line;
                return target;
            }

            /** Where an item of a file's contents is: its line (code) and its text (markdown). */
            function entityTarget(node) {
                const target = { path: node.path };
                if (node.line) target.line = node.line;
                if (node.anchor) target.find = node.anchor;
                return target;
            }

            function collapse(id, idx) {
                ui.userNavigated = true;
                const expanded = ui.expanded[stateKey()];
                (function walk(n) { expanded.delete(n); (idx.children.get(n) || []).forEach(walk); })(id);
                const node = idx.byId.get(id);
                ui.focus[stateKey()] = node && node.parent != null && expanded.has(node.parent) ? node.parent : null;
            }

            // ---------------------------------------------------------------- chrome
        })(window.MVArchitecture);
