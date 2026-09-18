        // DIAGRAM FULLSCREEN VIEWER
        // ============================================================================
        // Opens a rendered Mermaid SVG in a full-window overlay with pan/zoom.
        // Wheel = zoom around the cursor (pinch arrives as ctrlKey+wheel and zooms
        // too), shift+wheel = pan, dragging = pan — same scheme as the canvas
        // viewer. Esc, ✕ or a backdrop click closes.

        const dv = {
            overlay: null, viewport: null, world: null, zoomLabel: null,
            tx: 0, ty: 0, scale: 1, minScale: 0.05, maxScale: 10,
            naturalW: 0, naturalH: 0, pan: null, suppressClick: false
        };

        function dvApplyTransform() {
            dv.world.style.transform = 'translate(' + dv.tx + 'px,' + dv.ty + 'px) scale(' + dv.scale + ')';
            if (dv.zoomLabel) dv.zoomLabel.textContent = Math.round(dv.scale * 100) + '%';
        }

        function dvZoomFit() {
            const vp = dv.viewport.getBoundingClientRect();
            if (!dv.naturalW || !dv.naturalH || vp.width < 40 || vp.height < 40) return;
            // Fill the window (upscaling small diagrams is the point — SVG stays
            // crisp), but keep text from becoming comically huge.
            let s = Math.min(vp.width / dv.naturalW, vp.height / dv.naturalH) * 0.92;
            s = Math.min(s, 3);
            dv.scale = Math.max(dv.minScale, Math.min(dv.maxScale, s));
            dv.tx = (vp.width - dv.naturalW * dv.scale) / 2;
            dv.ty = (vp.height - dv.naturalH * dv.scale) / 2;
            dvApplyTransform();
        }

        function dvSetZoom(s, pivot) {
            const vp = dv.viewport.getBoundingClientRect();
            const p = pivot || { x: vp.width / 2, y: vp.height / 2 };
            s = Math.max(dv.minScale, Math.min(dv.maxScale, s));
            const wx = (p.x - dv.tx) / dv.scale, wy = (p.y - dv.ty) / dv.scale;
            dv.scale = s;
            dv.tx = p.x - wx * s;
            dv.ty = p.y - wy * s;
            dvApplyTransform();
        }

        function dvZoomBy(factor, pivot) { dvSetZoom(dv.scale * factor, pivot); }

        function dvZoomActual() {
            const vp = dv.viewport.getBoundingClientRect();
            dv.scale = 1;
            dv.tx = (vp.width - dv.naturalW) / 2;
            dv.ty = (vp.height - dv.naturalH) / 2;
            dvApplyTransform();
        }

        function closeDiagramViewer() {
            if (!dv.overlay) return;
            dv.overlay.classList.remove('visible');
            dv.world.innerHTML = '';
            dv.pan = null;
        }

        function dvPanMove(ev) {
            if (!dv.pan) return;
            const dx = ev.clientX - dv.pan.x, dy = ev.clientY - dv.pan.y;
            if (Math.abs(dx) > 3 || Math.abs(dy) > 3) dv.pan.moved = true;
            dv.tx = dv.pan.tx + dx;
            dv.ty = dv.pan.ty + dy;
            dvApplyTransform();
        }

        function dvPanEnd() {
            if (!dv.pan) return;
            // A drag that ends on the backdrop fires a click there — that click
            // must not close the overlay.
            dv.suppressClick = dv.pan.moved === true;
            dv.pan = null;
            dv.viewport.classList.remove('panning');
        }

        function dvEnsureOverlay() {
            if (dv.overlay) return;

            const overlay = document.createElement('div');
            overlay.className = 'diagram-viewer';
            overlay.innerHTML =
                '<div class="diagram-viewer-toolbar">'
                + '<button type="button" data-action="fit" title="Fit to window (0)">Fit</button>'
                + '<button type="button" data-action="actual" title="Actual size (1)">100%</button>'
                + '<button type="button" data-action="out" title="Zoom out (−)">−</button>'
                + '<span class="diagram-viewer-zoom-label">100%</span>'
                + '<button type="button" data-action="in" title="Zoom in (+)">+</button>'
                + '<button type="button" data-action="close" title="Close (Esc)">✕</button>'
                + '</div>'
                + '<div class="diagram-viewer-viewport"><div class="diagram-viewer-world"></div></div>';
            document.body.appendChild(overlay);

            dv.overlay = overlay;
            dv.viewport = overlay.querySelector('.diagram-viewer-viewport');
            dv.world = overlay.querySelector('.diagram-viewer-world');
            dv.zoomLabel = overlay.querySelector('.diagram-viewer-zoom-label');

            overlay.querySelector('.diagram-viewer-toolbar').addEventListener('click', ev => {
                const btn = ev.target.closest('button[data-action]');
                if (!btn) return;
                const action = btn.getAttribute('data-action');
                if (action === 'fit') dvZoomFit();
                else if (action === 'actual') dvZoomActual();
                else if (action === 'in') dvZoomBy(1.25);
                else if (action === 'out') dvZoomBy(0.8);
                else if (action === 'close') closeDiagramViewer();
            });

            dv.viewport.addEventListener('wheel', ev => {
                ev.preventDefault();
                const rect = dv.viewport.getBoundingClientRect();
                const pivot = { x: ev.clientX - rect.left, y: ev.clientY - rect.top };
                if (ev.shiftKey && !ev.ctrlKey && !ev.metaKey) {
                    dv.tx -= ev.deltaX;
                    dv.ty -= ev.deltaY;
                    dvApplyTransform();
                } else {
                    dvZoomBy(Math.exp(-ev.deltaY * 0.01), pivot);
                }
            }, { passive: false });

            dv.viewport.addEventListener('mousedown', ev => {
                if (ev.button !== 0 && ev.button !== 1) return;
                dv.pan = { x: ev.clientX, y: ev.clientY, tx: dv.tx, ty: dv.ty, moved: false };
                dv.viewport.classList.add('panning');
                ev.preventDefault();
            });
            window.addEventListener('mousemove', dvPanMove);
            window.addEventListener('mouseup', dvPanEnd);

            // Click on the empty backdrop (not on the diagram) closes; a drag
            // that ended on the backdrop does not.
            dv.viewport.addEventListener('click', ev => {
                if (dv.suppressClick) { dv.suppressClick = false; return; }
                if (ev.target !== dv.viewport && ev.target !== dv.world) return;
                closeDiagramViewer();
            });

            dv.viewport.addEventListener('dblclick', ev => {
                if (ev.target === dv.viewport || ev.target === dv.world) return;
                dvZoomFit();
            });

            document.addEventListener('keydown', ev => {
                if (!dv.overlay || !dv.overlay.classList.contains('visible')) return;
                if (ev.key === 'Escape') { closeDiagramViewer(); ev.preventDefault(); }
                else if (ev.key === '+' || ev.key === '=') { dvZoomBy(1.25); ev.preventDefault(); }
                else if (ev.key === '-') { dvZoomBy(0.8); ev.preventDefault(); }
                else if (ev.key === '0') { dvZoomFit(); ev.preventDefault(); }
                else if (ev.key === '1') { dvZoomActual(); ev.preventDefault(); }
            });
        }

        function openDiagramViewer(svgEl) {
            if (!svgEl) return;
            dvEnsureOverlay();

            // Clone at natural size. Mermaid sets width="100%" + max-width on the
            // inline SVG; the viewBox carries the diagram's intrinsic bounds.
            const clone = svgEl.cloneNode(true);
            let w = 0, h = 0;
            const vb = svgEl.viewBox && svgEl.viewBox.baseVal;
            if (vb && vb.width > 0 && vb.height > 0) {
                w = vb.width; h = vb.height;
            } else {
                const r = svgEl.getBoundingClientRect();
                w = r.width || 800; h = r.height || 600;
            }
            clone.setAttribute('width', w);
            clone.setAttribute('height', h);
            clone.style.maxWidth = 'none';
            clone.style.width = w + 'px';
            clone.style.height = h + 'px';

            dv.naturalW = w;
            dv.naturalH = h;
            dv.world.innerHTML = '';
            dv.world.appendChild(clone);
            dv.overlay.classList.add('visible');
            dvZoomFit();
        }

        // Inject a hover "expand" button into each rendered mermaid diagram.
        // Must run after mermaid.run() — mermaid replaces the div content with
        // the SVG, which would wipe a button injected earlier.
        function decorateMermaidDiagrams() {
            document.querySelectorAll('.mermaid').forEach(div => {
                if (div.querySelector('.mermaid-expand-btn')) return;
                const svg = div.querySelector('svg');
                if (!svg) return;
                const btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'mermaid-expand-btn';
                btn.title = 'Open full screen (or double-click the diagram)';
                btn.textContent = '⛶';
                btn.addEventListener('click', ev => {
                    ev.stopPropagation();
                    openDiagramViewer(div.querySelector('svg'));
                });
                div.appendChild(btn);
            });
        }

        // Fallback that also works if decoration hasn't run yet.
        document.addEventListener('dblclick', ev => {
            if (dv.overlay && dv.overlay.contains(ev.target)) return;
            const diagram = ev.target.closest && ev.target.closest('.mermaid');
            if (!diagram) return;
            const svg = diagram.querySelector('svg');
            if (!svg) return;
            ev.preventDefault();
            openDiagramViewer(svg);
        });
