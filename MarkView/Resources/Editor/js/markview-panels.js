        // ============================================================================
        // Resizable side panels (code notes, X-Ray details): drag the handle on the
        // panel's left edge, double-click it to restore the default width. The width is
        // remembered per panel. Mouse events on the window, not pointer capture, so the
        // drag works in WKWebView and keeps going when the cursor leaves the thin handle.
        // ============================================================================
        window.MVPanels = {
            /**
             * @param {Object} o
             * @param {HTMLElement} o.handle   element the user drags
             * @param {HTMLElement} o.panel    element whose width changes (right-hand side)
             * @param {HTMLElement} o.host     row containing the panel; its right edge anchors the drag
             * @param {string} o.key           localStorage key for the width
             * @param {number} o.width         default width in px
             * @param {number} [o.min=200]     narrowest width
             * @param {number} [o.reserve=240] room always left for the rest of the row
             * @param {Function} [o.onResize]  called after every width change
             */
            resizable: function(o) {
                const min = o.min || 200, reserve = o.reserve || 240;
                function set(width, save) {
                    const max = Math.max(min, o.host.clientWidth - reserve);
                    const value = Math.round(Math.min(max, Math.max(min, width)));
                    o.panel.style.width = value + 'px';
                    if (save) { try { localStorage.setItem(o.key, value); } catch (e) {} }
                    if (o.onResize) o.onResize(value);
                }
                try {
                    const saved = parseInt(localStorage.getItem(o.key), 10);
                    if (saved > 0) o.panel.style.width = saved + 'px';
                } catch (e) {}
                o.handle.title = o.handle.title || 'Drag to resize · double-click to reset';
                o.handle.addEventListener('mousedown', function(e) {
                    if (e.button !== 0) return;
                    e.preventDefault();
                    document.body.classList.add('mv-resizing');
                    const right = o.host.getBoundingClientRect().right;
                    function move(ev) { ev.preventDefault(); set(right - ev.clientX, false); }
                    function up(ev) {
                        window.removeEventListener('mousemove', move, true);
                        window.removeEventListener('mouseup', up, true);
                        document.body.classList.remove('mv-resizing');
                        set(right - ev.clientX, true);
                    }
                    window.addEventListener('mousemove', move, true);
                    window.addEventListener('mouseup', up, true);
                });
                o.handle.addEventListener('dblclick', function() { set(o.width, true); });
                return { set: set };
            },
        };
