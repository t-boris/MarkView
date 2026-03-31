/**
 * Admonition/Callout plugin for markdown-it
 * Supports: :::info, :::warning, :::tip, :::danger containers
 */

import type MarkdownIt from 'markdown-it';

export type AdmonitionType = 'info' | 'warning' | 'tip' | 'danger';

export interface AdmonitionOptions {
  validate?: (params: string) => boolean;
  render?: (tokens: any[], idx: number) => string;
}

const ADMONITION_TYPES: Record<AdmonitionType, { icon: string; title: string; className: string }> = {
  info: { icon: 'ℹ️', title: 'Info', className: 'info' },
  warning: { icon: '⚠️', title: 'Warning', className: 'warning' },
  tip: { icon: '💡', title: 'Tip', className: 'tip' },
  danger: { icon: '🔴', title: 'Danger', className: 'danger' }
};

export function admonitionPlugin(md: MarkdownIt, options: AdmonitionOptions = {}): void {
  const validate = options.validate || ((params: string) => {
    return /^(info|warning|tip|danger)/.test(params.trim());
  });

  const render = options.render || ((tokens: any[], idx: number) => {
    const token = tokens[idx];
    const type = token.meta as AdmonitionType || 'info';
    const config = ADMONITION_TYPES[type] || ADMONITION_TYPES.info;

    if (token.nesting === 1) {
      return `<div class="admonition ${config.className}">
                <div class="admonition-title">${config.icon} ${config.title}</div>
                <div class="admonition-content">`;
    } else {
      return `</div></div>\n`;
    }
  });

  md.use(require('markdown-it-container'), 'info', { validate, render });
  md.use(require('markdown-it-container'), 'warning', { validate, render });
  md.use(require('markdown-it-container'), 'tip', { validate, render });
  md.use(require('markdown-it-container'), 'danger', { validate, render });
}

/**
 * Alternative implementation using block rule
 * If markdown-it-container is not available
 */
export function admonitionBlockRule(md: MarkdownIt): void {
  md.block.ruler.before(
    'fence',
    'admonition',
    (state, startLine, endLine, silent) => {
      const pos = state.bMarks[startLine] + state.tShift[startLine];
      const maximum = state.eMarks[startLine];

      if (pos + 3 > maximum) return false;
      if (state.src.charCodeAt(pos) !== 0x3a) return false; // :
      if (state.src.charCodeAt(pos + 1) !== 0x3a) return false; // :
      if (state.src.charCodeAt(pos + 2) !== 0x3a) return false; // :

      const rest = state.src.slice(pos + 3, maximum).trim();
      const typeMatch = rest.match(/^(info|warning|tip|danger)/i);

      if (!typeMatch) return false;

      const type = typeMatch[1].toLowerCase() as AdmonitionType;
      const config = ADMONITION_TYPES[type];

      if (silent) return true;

      // Find closing marker
      let nextLine = startLine + 1;
      let closed = false;

      while (nextLine < endLine) {
        const lineStart = state.bMarks[nextLine] + state.tShift[nextLine];
        const lineEnd = state.eMarks[nextLine];
        const lineText = state.src.slice(lineStart, lineEnd).trim();

        if (lineText === ':::') {
          closed = true;
          break;
        }
        nextLine++;
      }

      if (!closed) return false;

      const old_line_max = state.lineMax;
      state.line = nextLine + 1;

      const token = state.push('container_' + type + '_open', 'div', 1);
      token.markup = ':::';
      token.meta = type;
      token.info = rest;
      token.content = '';

      // Add title token
      const titleToken = state.push('paragraph_open', 'p', 1);
      titleToken.attrSet('class', 'admonition-title');

      const inlineToken = state.push('inline', '', 0);
      inlineToken.content = `${config.icon} ${config.title}`;
      inlineToken.children = [];

      state.push('paragraph_close', 'p', -1);

      // Process content
      const oldParent = state.parentType;
      state.parentType = 'admonition';

      state.push('container_' + type + '_close', 'div', -1);

      state.parentType = oldParent;
      state.lineMax = old_line_max;

      return true;
    }
  );

  // Add render rules
  Object.keys(ADMONITION_TYPES).forEach(type => {
    md.renderer.rules['container_' + type + '_open'] = (tokens, idx) => {
      const config = ADMONITION_TYPES[type as AdmonitionType];
      return `<div class="admonition ${config.className}">`;
    };

    md.renderer.rules['container_' + type + '_close'] = () => '</div>\n';
  });
}
