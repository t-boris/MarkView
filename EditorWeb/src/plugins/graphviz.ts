/**
 * Graphviz diagram plugin for markdown-it
 * Supports ```dot and ```graphviz code blocks
 *
 * Uses @viz-js/viz for client-side Graphviz rendering via WebAssembly
 */

import type MarkdownIt from 'markdown-it';

export interface GraphvizOptions {
  useWasm?: boolean; // Use WebAssembly version (default: true)
  timeout?: number; // Rendering timeout in ms
}

/**
 * Load Graphviz WASM module
 */
let vizInstance: any = null;

async function loadViz(): Promise<any> {
  if (vizInstance) return vizInstance;

  try {
    // Dynamic import of @viz-js/viz
    const Viz = await import('@viz-js/viz').then(m => m.default);
    vizInstance = await Viz();
    return vizInstance;
  } catch (error) {
    console.warn('Could not load Graphviz WASM:', error);
    return null;
  }
}

/**
 * Graphviz plugin for markdown-it
 */
export function graphvizPlugin(md: MarkdownIt, options: GraphvizOptions = {}): void {
  const { useWasm = true, timeout = 5000 } = options;

  // Store original fence renderer
  const defaultFence = md.renderer.rules.fence ||
    function (tokens: any[], idx: number) {
      const token = tokens[idx];
      return md.utils.escapeHtml(token.content);
    };

  // Override fence renderer
  md.renderer.rules.fence = function (tokens: any[], idx: number, _options: any, env: any, self: any) {
    const token = tokens[idx];
    const { info, content } = token;
    const language = info.trim().split(/\s+/g)[0];

    // Handle Graphviz blocks
    if (language === 'dot' || language === 'graphviz') {
      return renderGraphviz(content, useWasm);
    }

    // Fall back to default fence rendering
    return defaultFence(tokens, idx, _options, env, self);
  };
}

/**
 * Render Graphviz diagram
 */
function renderGraphviz(source: string, useWasm: boolean): string {
  if (useWasm) {
    // Return a placeholder that will be rendered client-side
    return `
      <div class="graphviz-diagram" data-source="${escapeAttr(source)}">
        <div class="diagram-loading">Rendering diagram...</div>
        <svg class="diagram-svg" style="display: none;"></svg>
        <details class="diagram-details">
          <summary>Show Source</summary>
          <pre><code>${escapeHtml(source)}</code></pre>
        </details>
      </div>
    `;
  } else {
    // Fallback to text display
    return `
      <div class="graphviz-diagram" data-source="${escapeAttr(source)}">
        <pre><code>${escapeHtml(source)}</code></pre>
        <p class="diagram-note">Install @viz-js/viz to render diagrams</p>
      </div>
    `;
  }
}

/**
 * Render all Graphviz diagrams in a container
 */
export async function renderGraphvizDiagrams(container: HTMLElement): Promise<void> {
  if (!window.vizInstance) {
    window.vizInstance = await loadViz();
  }

  const diagrams = container.querySelectorAll('.graphviz-diagram');

  for (const diagram of diagrams) {
    const source = diagram.getAttribute('data-source');
    if (!source) continue;

    try {
      const svg = await window.vizInstance?.renderSVGElement(source);
      if (svg) {
        const svgContainer = diagram.querySelector('.diagram-svg');
        if (svgContainer) {
          svgContainer.innerHTML = '';
          svgContainer.appendChild(svg);
          svgContainer.style.display = 'block';

          const loading = diagram.querySelector('.diagram-loading');
          if (loading) {
            loading.remove();
          }
        }
      }
    } catch (error) {
      console.error('Failed to render Graphviz diagram:', error);

      const loading = diagram.querySelector('.diagram-loading');
      if (loading) {
        loading.textContent = 'Failed to render diagram';
        loading.className = 'diagram-error';
      }
    }
  }
}

/**
 * Initialize Graphviz rendering observer
 */
export function initGraphvizObserver(container: HTMLElement): IntersectionObserver {
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        const diagram = entry.target as HTMLElement;
        const source = diagram.getAttribute('data-source');

        if (source && !diagram.querySelector('svg').innerHTML) {
          renderGraphvizDiagrams(diagram);
        }
      }
    }
  });

  container.querySelectorAll('.graphviz-diagram').forEach(diagram => {
    observer.observe(diagram);
  });

  return observer;
}

/**
 * Escape HTML special characters
 */
function escapeHtml(text: string): string {
  const map: Record<string, string> = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#039;'
  };
  return text.replace(/[&<>"']/g, m => map[m]);
}

/**
 * Escape HTML attributes
 */
function escapeAttr(text: string): string {
  return escapeHtml(text).replace(/"/g, '&quot;');
}

/**
 * Type definitions
 */
declare global {
  interface Window {
    vizInstance?: any;
    renderGraphvizDiagrams?: typeof renderGraphvizDiagrams;
    initGraphvizObserver?: typeof initGraphvizObserver;
  }
}

// Export for global access
if (typeof window !== 'undefined') {
  window.renderGraphvizDiagrams = renderGraphvizDiagrams;
  window.initGraphvizObserver = initGraphvizObserver;
}
