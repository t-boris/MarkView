        // ============================================================================

        window.setDocumentBase = function(baseURL) {
            state.documentBaseURL = baseURL;
        };

        window.setTheme = function(theme) {
            applyTheme(theme);
        };

        window.toggleSourceMode = function() {
            toggleMode();
        };

        window.scrollToHeading = function(id) {
            const heading = document.getElementById(id);
            if (heading) {
                heading.scrollIntoView({ behavior: 'smooth' });
            }
        };

        window.scrollToText = function(searchText) {
            if (!searchText || !DOM.rendered) return;
            // Walk all text-containing elements and find one that contains the search text
            const elements = DOM.rendered.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,td,th,pre,blockquote,div');
            const needle = searchText.toLowerCase().trim();
            let found = null;
            for (const el of elements) {
                if (el.textContent && el.textContent.toLowerCase().includes(needle)) {
                    found = el;
                    break;
                }
            }
            if (found) {
                found.scrollIntoView({ behavior: 'smooth', block: 'center' });
                // Highlight briefly
                found.style.outline = '2px solid #569cd6';
                found.style.outlineOffset = '4px';
                found.style.transition = 'outline 0.3s';
                setTimeout(() => { found.style.outline = ''; found.style.outlineOffset = ''; }, 2500);
            }
        };

        window.getHTML = function() {
            return DOM.rendered.innerHTML;
        };

        window.getMarkdown = function() {
            return DOM.editor.value;
        };

        window.preparePrintLayout = function() {
            switchToPreview();

            // Hide chrome
            DOM.toolbar.style.display = 'none';
            document.querySelector('.editor-status').style.display = 'none';

            // Unlock ALL height/overflow constraints so content expands to full length.
            // Without this, webView.pdf() only sees one viewport = one page.
            document.documentElement.style.cssText += '; height: auto !important; overflow: visible !important;';
            document.body.style.cssText += '; height: auto !important; overflow: visible !important;';

            const container = document.querySelector('.editor-container');
            const content = document.querySelector('.editor-content');
            container.style.height = 'auto';
            container.style.overflow = 'visible';
            content.style.overflow = 'visible';
            content.style.height = 'auto';
            content.style.flex = 'none';
            DOM.previewPane.style.overflow = 'visible';
            DOM.previewPane.style.height = 'auto';
            DOM.previewPane.style.flex = 'none';
            DOM.rendered.style.overflow = 'visible';
            DOM.rendered.style.height = 'auto';
            DOM.rendered.style.flex = 'none';
            DOM.rendered.style.padding = '40px';

            // Inject print pagination rules
            const style = document.createElement('style');
            style.id = 'markview-print-styles';
            style.textContent = `
                img, .mermaid, table, pre, .admonition, blockquote {
                    break-inside: avoid !important;
                    page-break-inside: avoid !important;
                }
                h1, h2, h3, h4, h5, h6 {
                    break-after: avoid !important;
                    page-break-after: avoid !important;
                }
                table { table-layout: fixed !important; width: 100% !important; word-break: break-word !important; }
                pre { white-space: pre-wrap !important; word-break: break-word !important; }
                img { max-width: 100% !important; height: auto !important; }
                .mermaid, .mermaid svg { max-width: 100% !important; overflow: visible !important; }
            `;
            document.head.appendChild(style);
        };

        window.restoreEditLayout = function() {
            // Remove print styles
            const ps = document.getElementById('markview-print-styles');
            if (ps) ps.remove();

            // Restore chrome
            DOM.toolbar.style.display = '';
            document.querySelector('.editor-status').style.display = '';

            // Restore all layout constraints
            document.documentElement.style.height = '';
            document.documentElement.style.overflow = '';
            document.body.style.height = '';
            document.body.style.overflow = '';

            const container = document.querySelector('.editor-container');
            const content = document.querySelector('.editor-content');
            container.style.height = '';
            container.style.overflow = '';
            content.style.overflow = '';
            content.style.height = '';
            content.style.flex = '';
            DOM.previewPane.style.overflow = '';
            DOM.previewPane.style.height = '';
            DOM.previewPane.style.flex = '';
            DOM.rendered.style.overflow = '';
            DOM.rendered.style.height = '';
            DOM.rendered.style.flex = '';
            DOM.rendered.style.padding = '';

            switchToSource();
        };

        // ============================================================================
