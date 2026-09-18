        // INITIALIZATION
        // ============================================================================

        const state = {
            mode: 'source', // 'source' | 'preview' | 'structured' | 'structured-source' | 'insight'
            theme: localStorage.getItem('markview-theme') || 'light',
            markdown: '',
            headings: [],
            activeHeadingId: null,
            isRendering: false,
            documentBaseURL: null, // file:// URL of the current document's directory
            fileType: 'markdown', // 'markdown' | 'json' | 'xml' | 'yaml' | 'canvas'
            // Recursive Insight v2 — iframe-based session state.
            // See task 5 / tech-spec Decisions 2, 5, 11.
            insightIframe: null,                  // <iframe> DOM node (recreated on each loadInsightSkeleton)
            insightSessionId: null,               // string | null
            insightCurrentNodeId: null,           // string | null
            insightSkeleton: null,                // last skeleton object
            insightSectionLibsNeeded: new Set(),  // Set<string> — lib names in use for current skeleton
            insightBlobURLs: new Map(),           // Map<libName, blobURL>
            insightLibBytes: new Map(),           // Map<libName, sourceText> — fetch cache
            insightLoadTimer: null,               // setTimeout handle for 10s iframe-ready timeout
            insightIframeReady: false,            // true once iframe posts insightIframeReady
            insightPendingChunks: new Map(),      // Map<sectionId, [htmlChunk]> — buffered until iframe ready
        };

        const DOM = {
            container: document.querySelector('.editor-container'),
            toolbar: document.querySelector('.editor-toolbar'),
            editor: document.getElementById('editor-input'),
            editorPane: document.getElementById('editor-pane'),
            previewPane: document.getElementById('preview-pane'),
            rendered: document.getElementById('editor-rendered'),
            statusMode: document.getElementById('status-mode'),
            statusWords: document.getElementById('status-words'),
            statusChars: document.getElementById('status-chars'),
            btnToggleMode: document.getElementById('btn-toggle-mode'),
            tocStatus: document.getElementById('toc-status'),
            // Insight v2 chrome containers
            insightContainer: document.getElementById('insight-container'),
            insightBreadcrumbs: document.getElementById('insight-breadcrumbs'),
            insightIframe: document.getElementById('insight-iframe'),
            insightStatusBar: document.getElementById('insight-status-bar'),
        };

        // ============================================================================
        // MARKDOWN-IT CONFIGURATION
        // ============================================================================

        let md = null;
        try {
            md = window.markdownit({
                html: true,
                breaks: true,
                linkify: true,
                typographer: true,
            });

            // Add plugins (check availability — CDN may fail)
            if (window.markdownitFootnote) md.use(window.markdownitFootnote);
            if (window.markdownitTaskLists) md.use(window.markdownitTaskLists, { label: true });

            // Admonition containers
            if (window.markdownitContainer) {
                const containerConfig = {
                    info:    { emoji: 'ℹ️', label: 'Info' },
                    warning: { emoji: '⚠️', label: 'Warning' },
                    tip:     { emoji: '💡', label: 'Tip' },
                    danger:  { emoji: '🔴', label: 'Danger' },
                };
                Object.entries(containerConfig).forEach(([name, cfg]) => {
                    md.use(window.markdownitContainer, name, {
                        render: function (tokens, idx) {
                            if (tokens[idx].nesting === 1) {
                                return '<div class="admonition ' + name + '">\n<div class="admonition-title">' + cfg.emoji + ' ' + cfg.label + '</div>\n';
                            } else {
                                return '</div>\n';
                            }
                        }
                    });
                });
            }

            // Override image rendering for responsive sizing
            md.renderer.rules.image = function (tokens, idx, options, env, renderer) {
                const token = tokens[idx];
                return '<img src="' + token.attrGet('src') + '" alt="' + token.content + '" title="' + (token.attrGet('title') || '') + '" style="max-width: 100%; height: auto; border-radius: 6px;">';
            };
        } catch (e) {
            console.warn('markdown-it initialization failed:', e);
        }

        // ============================================================================
        // MERMAID CONFIGURATION
        // ============================================================================

        try {
            if (typeof mermaid !== 'undefined') {
                mermaid.initialize({ startOnLoad: false, theme: state.theme === 'dark' ? 'dark' : 'default' });
            }
        } catch (e) {
            console.warn('Mermaid initialization failed:', e);
        }

        // ============================================================================
