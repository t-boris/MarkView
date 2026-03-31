/**
 * Main editor initialization and core functionality
 */

import { bridge, registerSwiftInterface } from './bridge';
import { themeManager } from './theme';
import { tocManager } from './toc';
import { pdfPreparer } from './pdf-prepare';
import { graphvizPlugin, renderGraphvizDiagrams, initGraphvizObserver } from './plugins/graphviz';
import { plantUMLPlugin } from './plugins/plantuml';
import { admonitionPlugin } from './plugins/admonition';

declare const markdownit: any;
declare const mermaid: any;
declare const renderMathInElement: any;
declare const Prism: any;

/**
 * Editor state
 */
interface EditorState {
  mode: 'source' | 'preview';
  markdown: string;
  headings: any[];
  activeHeadingId: string | null;
  isRendering: boolean;
}

/**
 * Main Editor class
 */
export class MarkViewEditor {
  private state: EditorState = {
    mode: 'source',
    markdown: '',
    headings: [],
    activeHeadingId: null,
    isRendering: false
  };

  private dom = {
    container: document.querySelector('.editor-container') as HTMLElement,
    editor: document.getElementById('editor-input') as HTMLTextAreaElement,
    editorPane: document.getElementById('editor-pane') as HTMLElement,
    previewPane: document.getElementById('preview-pane') as HTMLElement,
    rendered: document.getElementById('editor-rendered') as HTMLElement,
    statusMode: document.getElementById('status-mode') as HTMLElement,
    statusWords: document.getElementById('status-words') as HTMLElement,
    statusChars: document.getElementById('status-chars') as HTMLElement,
    btnToggleMode: document.getElementById('btn-toggle-mode') as HTMLElement,
    btnTheme: document.getElementById('btn-theme') as HTMLElement
  };

  private md: any;
  private graphvizObserver: IntersectionObserver | null = null;

  constructor() {
    this.initializeMarkdown();
    this.setupEventListeners();
    this.registerSwiftCallbacks();
    registerSwiftInterface();
    themeManager.setTheme(themeManager.getTheme());
  }

  /**
   * Initialize markdown-it with plugins
   */
  private initializeMarkdown(): void {
    this.md = markdownit({
      html: true,
      breaks: true,
      linkify: true,
      typographer: true
    });

    // Add standard plugins
    if (typeof require !== 'undefined') {
      try {
        this.md.use(require('markdown-it-footnote'));
        this.md.use(require('markdown-it-task-lists'), { label: true });
        this.md.use(require('markdown-it-container'));
      } catch (e) {
        console.warn('Some markdown-it plugins not available:', e);
      }
    }

    // Add custom plugins
    try {
      admonitionPlugin(this.md);
    } catch (e) {
      console.warn('Admonition plugin failed:', e);
    }

    try {
      graphvizPlugin(this.md);
    } catch (e) {
      console.warn('Graphviz plugin failed:', e);
    }

    try {
      plantUMLPlugin(this.md);
    } catch (e) {
      console.warn('PlantUML plugin failed:', e);
    }

    // Override image rendering
    const defaultImageRender = this.md.renderer.rules.image;
    this.md.renderer.rules.image = (tokens: any[], idx: number) => {
      const token = tokens[idx];
      return `<img src="${token.attrGet('src')}" alt="${token.content}" title="${token.attrGet('title') || ''}" style="max-width: 100%; height: auto; border-radius: 6px;">`;
    };
  }

  /**
   * Setup event listeners
   */
  private setupEventListeners(): void {
    // Editor input
    this.dom.editor.addEventListener('input', () => this.onInput());

    // Toolbar buttons
    this.dom.btnToggleMode.addEventListener('click', () => this.toggleMode());
    this.dom.btnTheme.addEventListener('click', () => this.toggleTheme());

    // Keyboard shortcuts
    document.addEventListener('keydown', (e) => {
      // Cmd/Ctrl+Shift+P to toggle mode
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.code === 'KeyP') {
        e.preventDefault();
        this.toggleMode();
      }
      // Cmd/Ctrl+Shift+T to toggle theme
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.code === 'KeyT') {
        e.preventDefault();
        this.toggleTheme();
      }
    });
  }

  /**
   * Register callbacks from Swift
   */
  private registerSwiftCallbacks(): void {
    if (!window.__editorCallbacks) {
      window.__editorCallbacks = {};
    }

    window.__editorCallbacks.setContent = (markdown: string) => {
      this.dom.editor.value = markdown;
      this.state.markdown = markdown;
      this.render();
    };

    window.__editorCallbacks.setTheme = (theme: 'light' | 'dark') => {
      themeManager.setTheme(theme);
    };

    window.__editorCallbacks.toggleSourceMode = () => {
      this.toggleMode();
    };

    window.__editorCallbacks.scrollToHeading = (id: string) => {
      tocManager.scrollToHeading(id);
    };

    window.__editorCallbacks.getHTML = () => {
      return this.dom.rendered.innerHTML;
    };

    window.__editorCallbacks.getMarkdown = () => {
      return this.dom.editor.value;
    };

    window.__editorCallbacks.preparePrintLayout = () => {
      this.switchToPreview();
      const clone = pdfPreparer.preparePrintLayout(this.dom.rendered);
      return clone.innerHTML;
    };

    window.__editorCallbacks.restoreEditLayout = () => {
      pdfPreparer.restoreEditLayout(this.dom.rendered);
      this.switchToSource();
    };
  }

  /**
   * Handle editor input
   */
  private onInput(): void {
    this.state.markdown = this.dom.editor.value;
    this.render();
    this.updateStats();
  }

  /**
   * Render markdown to HTML
   */
  private render(): void {
    if (this.state.isRendering) return;
    this.state.isRendering = true;

    try {
      const markdown = this.state.markdown;
      let html = this.md.render(markdown);
      html = '<div class="markdown-body">' + html + '</div>';

      this.dom.rendered.innerHTML = html;

      // Highlight code blocks
      setTimeout(() => {
        this.dom.rendered.querySelectorAll('pre code').forEach((el: HTMLElement) => {
          Prism.highlightElement(el);
        });
      }, 0);

      // Render mermaid diagrams
      setTimeout(() => {
        if (typeof mermaid !== 'undefined') {
          mermaid.contentLoaded();
        }
      }, 0);

      // Render KaTeX
      setTimeout(() => {
        if (typeof renderMathInElement !== 'undefined') {
          renderMathInElement(this.dom.rendered, {
            delimiters: [
              { left: '$$', right: '$$', display: true },
              { left: '$', right: '$', display: false },
              { left: '\\(', right: '\\)', display: false },
              { left: '\\[', right: '\\]', display: true }
            ]
          });
        }
      }, 100);

      // Render Graphviz
      setTimeout(() => {
        renderGraphvizDiagrams(this.dom.rendered);
      }, 150);

      // Extract headings
      this.state.headings = tocManager.extractHeadings(this.dom.rendered);
      this.state.activeHeadingId = null;

      // Setup heading observer if in preview mode
      if (this.state.mode === 'preview') {
        setTimeout(() => {
          tocManager.setupObserver(this.dom.rendered, (id) => {
            this.state.activeHeadingId = id;
          });
        }, 200);
      }

      // Send to Swift
      bridge.send('contentChanged', {
        markdown: this.state.markdown,
        html: this.dom.rendered.innerHTML
      });

      bridge.send('headingsUpdated', this.state.headings);
    } catch (error) {
      console.error('Render error:', error);
    } finally {
      this.state.isRendering = false;
    }
  }

  /**
   * Update statistics
   */
  private updateStats(): void {
    const text = this.dom.editor.value;
    const words = text.trim().split(/\s+/).filter(w => w.length > 0).length;
    const chars = text.length;

    this.dom.statusWords.textContent = `Words: ${words}`;
    this.dom.statusChars.textContent = `Chars: ${chars}`;
  }

  /**
   * Toggle between source and preview modes
   */
  private toggleMode(): void {
    if (this.state.mode === 'source') {
      this.switchToPreview();
    } else {
      this.switchToSource();
    }
  }

  /**
   * Switch to preview mode
   */
  private switchToPreview(): void {
    this.state.mode = 'preview';
    this.dom.editorPane.style.display = 'none';
    this.dom.previewPane.style.display = 'flex';
    this.dom.btnToggleMode.textContent = '✏️ Edit';
    this.dom.statusMode.textContent = 'Preview';

    if (!this.dom.rendered.innerHTML.includes('markdown-body')) {
      this.render();
    }

    // Setup observer for Graphviz
    if (this.graphvizObserver) {
      this.graphvizObserver.disconnect();
    }
    this.graphvizObserver = initGraphvizObserver(this.dom.rendered);

    // Setup heading observer
    setTimeout(() => {
      tocManager.setupObserver(this.dom.rendered, (id) => {
        this.state.activeHeadingId = id;
      });
    }, 100);
  }

  /**
   * Switch to source mode
   */
  private switchToSource(): void {
    this.state.mode = 'source';
    this.dom.editorPane.style.display = 'flex';
    this.dom.previewPane.style.display = 'none';
    this.dom.btnToggleMode.textContent = '👁️ Preview';
    this.dom.statusMode.textContent = 'Source';

    if (this.graphvizObserver) {
      this.graphvizObserver.disconnect();
      this.graphvizObserver = null;
    }

    tocManager.dispose();
  }

  /**
   * Toggle theme
   */
  private toggleTheme(): void {
    const newTheme = themeManager.toggle();
    bridge.send('themeChanged', { theme: newTheme });
  }

  /**
   * Initialize editor
   */
  initialize(): void {
    this.dom.editor.focus();
    bridge.send('ready', {});
  }
}

/**
 * Global initialization
 */
let editor: MarkViewEditor;

function initializeEditor(): void {
  editor = new MarkViewEditor();
  editor.initialize();

  // Make available globally
  if (typeof window !== 'undefined') {
    (window as any).__markviewEditor = editor;
  }
}

// Initialize when DOM is ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initializeEditor);
} else {
  initializeEditor();
}

// Export for module usage
export default MarkViewEditor;
