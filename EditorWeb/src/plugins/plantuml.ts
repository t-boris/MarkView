/**
 * PlantUML diagram plugin for markdown-it
 * Supports ```plantuml code blocks
 *
 * Note: This is a placeholder. Full implementation requires:
 * 1. PlantUML server integration (plantuml.com API or self-hosted)
 * 2. Or PlantUML.js for client-side rendering
 * 3. SVG rendering for display
 */

import type MarkdownIt from 'markdown-it';

export interface PlantUMLOptions {
  serverUrl?: string; // PlantUML server URL for rendering
  useWasm?: boolean; // Use WebAssembly version if available
}

/**
 * PlantUML plugin for markdown-it
 */
export function plantUMLPlugin(md: MarkdownIt, options: PlantUMLOptions = {}): void {
  const defaultServerUrl = 'https://www.plantuml.com/plantuml/svg';

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

    // Handle PlantUML blocks
    if (language === 'plantuml' || language === 'puml') {
      return renderPlantUML(content, defaultServerUrl, options);
    }

    // Fall back to default fence rendering
    return defaultFence(tokens, idx, _options, env, self);
  };
}

/**
 * Render PlantUML diagram
 */
function renderPlantUML(source: string, serverUrl: string, options: PlantUMLOptions): string {
  // Placeholder implementation
  // In production, this would:
  // 1. Encode the PlantUML source
  // 2. Send to server or use WASM
  // 3. Return SVG or image

  const encoded = encodeBase64(deflate(source));
  const svgUrl = `${serverUrl}/${encoded}`;

  return `
    <div class="plantuml-diagram" data-source="${escapeAttr(source)}">
      <img src="${svgUrl}" alt="PlantUML Diagram" class="diagram-image" onerror="loadPlantUMLFallback(this)">
      <details class="diagram-details">
        <summary>Show Source</summary>
        <pre><code>${escapeHtml(source)}</code></pre>
      </details>
    </div>
  `;
}

/**
 * Encode to base64 (placeholder - would use proper compression)
 */
function encodeBase64(data: string): string {
  if (typeof window !== 'undefined') {
    return btoa(encodeURIComponent(data).replace(/%([0-9A-F]{2})/g, (match, p1) => {
      return String.fromCharCode(parseInt(p1, 16));
    }));
  }
  return '';
}

/**
 * Deflate compression (placeholder - would use real deflate)
 */
function deflate(data: string): string {
  // This is a simplified placeholder
  // In production, use pako or zlib library
  return data;
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
 * Fallback rendering (display as text if image fails to load)
 */
export function loadPlantUMLFallback(imgElement: HTMLImageElement): void {
  const container = imgElement.parentElement;
  if (!container) return;

  const source = container.getAttribute('data-source');
  if (source) {
    imgElement.style.display = 'none';
    const pre = container.querySelector('pre');
    if (pre) {
      pre.style.display = 'block';
    }
  }
}

/**
 * Initialize PlantUML rendering (would be called after DOM loads)
 */
export function initPlantUML(serverUrl?: string): void {
  // This would set up any necessary event listeners or polling
  // for dynamically loaded PlantUML diagrams
}

/**
 * Type definitions
 */
declare global {
  interface Window {
    loadPlantUMLFallback?: typeof loadPlantUMLFallback;
    initPlantUML?: typeof initPlantUML;
  }
}

// Export for global access
if (typeof window !== 'undefined') {
  window.loadPlantUMLFallback = loadPlantUMLFallback;
  window.initPlantUML = initPlantUML;
}
