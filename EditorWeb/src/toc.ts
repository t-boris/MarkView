/**
 * Table of Contents generation and heading tracking
 */

import { bridge, HeadingInfo } from './bridge';

export class TOCManager {
  private headings: HeadingInfo[] = [];
  private observer: IntersectionObserver | null = null;
  private activeHeadingId: string | null = null;

  /**
   * Extract headings from rendered content
   */
  extractHeadings(container: HTMLElement): HeadingInfo[] {
    const headings: HeadingInfo[] = [];
    const headingMap = new Map<string, number>();
    let idCounter = 0;

    container.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(heading => {
      const level = parseInt(heading.tagName[1], 10);
      let id = heading.id;

      if (!id) {
        // Generate stable ID from text
        let text = heading.textContent?.trim() || '';
        id = this.generateId(text);

        // Ensure uniqueness
        if (headingMap.has(id)) {
          const count = (headingMap.get(id) || 0) + 1;
          headingMap.set(id, count);
          id = `${id}-${count}`;
        } else {
          headingMap.set(id, 1);
        }

        heading.id = id;
      }

      headings.push({
        id,
        level,
        text: heading.textContent?.trim() || ''
      });
    });

    this.headings = headings;
    return headings;
  }

  /**
   * Setup IntersectionObserver to track active heading
   */
  setupObserver(container: HTMLElement, onActiveChange?: (id: string | null) => void): void {
    if (this.observer) {
      this.observer.disconnect();
    }

    const options: IntersectionObserverInit = {
      root: container,
      rootMargin: '-80px 0px -66% 0px',
      threshold: 0
    };

    this.observer = new IntersectionObserver((entries) => {
      let activeId: string | null = null;

      for (const entry of entries) {
        if (entry.isIntersecting && entry.target.id) {
          activeId = entry.target.id;
          break;
        }
      }

      if (activeId !== this.activeHeadingId) {
        this.activeHeadingId = activeId;

        if (onActiveChange) {
          onActiveChange(activeId);
        }

        bridge.send('scrollPosition', { activeHeadingId: activeId });
      }
    }, options);

    // Observe all headings
    container.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(heading => {
      this.observer?.observe(heading);
    });
  }

  /**
   * Stop observing
   */
  dispose(): void {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
  }

  /**
   * Get all headings
   */
  getHeadings(): HeadingInfo[] {
    return [...this.headings];
  }

  /**
   * Get active heading ID
   */
  getActiveHeading(): string | null {
    return this.activeHeadingId;
  }

  /**
   * Scroll to heading
   */
  scrollToHeading(id: string, smooth: boolean = true): void {
    const heading = document.getElementById(id);
    if (heading) {
      heading.scrollIntoView({
        behavior: smooth ? 'smooth' : 'auto',
        block: 'start'
      });
    }
  }

  /**
   * Generate stable ID from text
   */
  private generateId(text: string): string {
    return text
      .toLowerCase()
      .replace(/\s+/g, '-')
      .replace(/[^a-z0-9-]/g, '')
      .replace(/--+/g, '-')
      .replace(/^-+|-+$/g, '');
  }

  /**
   * Create HTML structure for TOC
   */
  generateTOCHTML(headings: HeadingInfo[] = this.headings): string {
    if (headings.length === 0) {
      return '<div class="toc-empty">No headings found</div>';
    }

    let html = '<nav class="toc"><ul>';
    let lastLevel = 0;

    for (const heading of headings) {
      const level = heading.level;

      // Close lists if going up
      while (lastLevel > level) {
        html += '</ul></li>';
        lastLevel--;
      }

      // Open lists if going down
      while (lastLevel < level) {
        if (lastLevel > 0) {
          html += '<ul>';
        }
        lastLevel++;
      }

      // Add item
      html += `<li><a href="#${heading.id}" data-toc-id="${heading.id}">${this.escapeHtml(heading.text)}</a>`;
    }

    // Close remaining lists
    while (lastLevel > 0) {
      html += '</li></ul>';
      lastLevel--;
    }

    html += '</ul></nav>';
    return html;
  }

  /**
   * Escape HTML special characters
   */
  private escapeHtml(text: string): string {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }

  /**
   * Update TOC with active heading
   */
  updateTOCActive(id: string | null, container?: HTMLElement): void {
    const target = container || document;

    target.querySelectorAll('[data-toc-id]').forEach(link => {
      link.classList.toggle('active', link.getAttribute('data-toc-id') === id);
    });
  }
}

export const tocManager = new TOCManager();
