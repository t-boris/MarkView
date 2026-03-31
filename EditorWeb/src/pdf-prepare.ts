/**
 * PDF preparation and print layout utilities
 */

export interface PDFOptions {
  pageSize?: 'A4' | 'Letter';
  margins?: {
    top: number;
    right: number;
    bottom: number;
    left: number;
  };
  scale?: number;
}

export class PDFPreparer {
  private originalHTML: string = '';
  private originalStyle: string = '';
  private readonly DEFAULT_OPTIONS: PDFOptions = {
    pageSize: 'A4',
    margins: { top: 40, right: 40, bottom: 40, left: 40 },
    scale: 1
  };

  /**
   * Prepare document for PDF export
   */
  preparePrintLayout(
    container: HTMLElement,
    options: PDFOptions = {}
  ): HTMLElement {
    const opts = { ...this.DEFAULT_OPTIONS, ...options };

    // Store original state
    this.originalHTML = container.innerHTML;
    this.originalStyle = container.getAttribute('style') || '';

    // Clone container for modification
    const clone = container.cloneNode(true) as HTMLElement;

    // Apply print-friendly styles
    this.applyPrintStyles(clone, opts);

    // Process images and diagrams
    this.processImages(clone);
    this.processDiagrams(clone);

    // Add page breaks where appropriate
    this.addPageBreaks(clone);

    // Add page numbers
    this.addPageNumbers(clone);

    return clone;
  }

  /**
   * Restore original layout
   */
  restoreEditLayout(container: HTMLElement): void {
    container.innerHTML = this.originalHTML;
    if (this.originalStyle) {
      container.setAttribute('style', this.originalStyle);
    }
  }

  /**
   * Apply print-specific styles
   */
  private applyPrintStyles(element: HTMLElement, opts: PDFOptions): void {
    const style = document.createElement('style');
    const { margins, pageSize } = opts;

    let pageDimensions = { width: '210mm', height: '297mm' }; // A4
    if (pageSize === 'Letter') {
      pageDimensions = { width: '8.5in', height: '11in' };
    }

    style.textContent = `
      @media print {
        * {
          -webkit-print-color-adjust: exact !important;
          print-color-adjust: exact !important;
          color-adjust: exact !important;
        }

        body {
          margin: 0;
          padding: 0;
        }

        .print-container {
          width: ${pageDimensions.width};
          height: ${pageDimensions.height};
          margin: 0 auto;
          padding: ${margins?.top}px ${margins?.right}px ${margins?.bottom}px ${margins?.left}px;
          page-break-after: always;
        }

        h1, h2, h3 {
          break-after: avoid;
          widows: 3;
          orphans: 3;
        }

        img, pre, table, .admonition, .mermaid {
          break-inside: avoid;
          break-after: avoid;
        }

        p {
          widows: 3;
          orphans: 3;
        }

        .page-break {
          page-break-after: always;
        }

        .page-number {
          position: fixed;
          bottom: ${margins?.bottom}px;
          right: ${margins?.right}px;
          font-size: 12px;
          color: #999;
        }
      }
    `;

    element.appendChild(style);
  }

  /**
   * Process images for PDF (ensure they're embedded or accessible)
   */
  private processImages(element: HTMLElement): void {
    element.querySelectorAll('img').forEach((img) => {
      // Ensure max-width for printing
      img.style.maxWidth = '100%';
      img.style.height = 'auto';

      // Add page break avoidance
      const wrapper = document.createElement('div');
      wrapper.style.breakInside = 'avoid';
      wrapper.style.marginBottom = '1em';

      img.parentNode?.replaceChild(wrapper, img);
      wrapper.appendChild(img);
    });
  }

  /**
   * Process diagrams for PDF (convert SVG to raster if needed)
   */
  private processDiagrams(element: HTMLElement): void {
    element.querySelectorAll('.mermaid').forEach((diagram) => {
      // Mermaid diagrams should already be rendered as SVG
      // Ensure they have proper styling
      const svg = diagram.querySelector('svg') as SVGElement | null;
      if (svg) {
        svg.style.maxWidth = '100%';
        svg.style.height = 'auto';
      }

      // Add page break avoidance
      diagram.style.breakInside = 'avoid';
      diagram.style.marginBottom = '1em';
    });
  }

  /**
   * Add smart page breaks
   */
  private addPageBreaks(element: HTMLElement): void {
    let currentPage = document.createElement('div');
    currentPage.className = 'print-container';

    const children = Array.from(element.children);
    let pageHeight = 0;
    const maxPageHeight = 1000; // pixels, approximate

    children.forEach((child) => {
      const childHeight = (child as HTMLElement).offsetHeight || 200;

      if (pageHeight + childHeight > maxPageHeight) {
        // Start new page
        element.insertBefore(currentPage, child);
        currentPage = document.createElement('div');
        currentPage.className = 'print-container';
        pageHeight = 0;
      }

      const clone = child.cloneNode(true);
      currentPage.appendChild(clone);
      pageHeight += childHeight;
    });

    // Add last page
    if (currentPage.children.length > 0) {
      element.appendChild(currentPage);
    }
  }

  /**
   * Add page numbers
   */
  private addPageNumbers(element: HTMLElement): void {
    const pages = element.querySelectorAll('.print-container');
    pages.forEach((page, index) => {
      const pageNum = document.createElement('div');
      pageNum.className = 'page-number';
      pageNum.textContent = `Page ${index + 1}`;
      (page as HTMLElement).appendChild(pageNum);
    });
  }

  /**
   * Get printable HTML
   */
  getPrintableHTML(element: HTMLElement): string {
    return element.innerHTML;
  }

  /**
   * Trigger system print dialog
   */
  print(element: HTMLElement): void {
    const printWindow = window.open('', '', 'width=800,height=600');
    if (printWindow) {
      printWindow.document.write(element.innerHTML);
      printWindow.document.close();
      printWindow.print();
    }
  }
}

export const pdfPreparer = new PDFPreparer();
