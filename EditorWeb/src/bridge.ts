/**
 * Bridge module for typed message passing between web editor and Swift
 */

export interface BridgeMessage {
  type: string;
  payload: any;
}

export interface ContentChangedPayload {
  markdown: string;
  html: string;
}

export interface HeadingInfo {
  id: string;
  level: number;
  text: string;
}

export interface ScrollPositionPayload {
  activeHeadingId: string | null;
}

export interface ReadyPayload {}

export type BridgeMessageType =
  | 'contentChanged'
  | 'headingsUpdated'
  | 'scrollPosition'
  | 'ready'
  | 'error';

/**
 * Swift bridge for communication with native code
 */
export class EditorBridge {
  private static instance: EditorBridge;

  private constructor() {}

  static getInstance(): EditorBridge {
    if (!EditorBridge.instance) {
      EditorBridge.instance = new EditorBridge();
    }
    return EditorBridge.instance;
  }

  /**
   * Send message to Swift
   */
  send(type: BridgeMessageType, payload: any): void {
    const message: BridgeMessage = { type, payload };

    // Check if webkit bridge is available
    if (this.hasWebKitBridge()) {
      try {
        window.webkit?.messageHandlers?.bridge?.postMessage(message);
      } catch (error) {
        console.error('Failed to send message to Swift:', error);
      }
    } else {
      // Fallback for development
      console.log('[BRIDGE]', message);
    }
  }

  /**
   * Register callback for content changes
   */
  onContentChanged(callback: (payload: ContentChangedPayload) => void): void {
    this.registerHandler('contentChanged', callback);
  }

  /**
   * Register callback for heading updates
   */
  onHeadingsUpdated(callback: (headings: HeadingInfo[]) => void): void {
    this.registerHandler('headingsUpdated', callback);
  }

  /**
   * Register callback for scroll position changes
   */
  onScrollPosition(callback: (payload: ScrollPositionPayload) => void): void {
    this.registerHandler('scrollPosition', callback);
  }

  /**
   * Check if webkit bridge is available
   */
  private hasWebKitBridge(): boolean {
    return typeof window !== 'undefined' &&
           window.webkit !== undefined &&
           window.webkit.messageHandlers !== undefined &&
           window.webkit.messageHandlers.bridge !== undefined;
  }

  /**
   * Register a handler (for development/testing)
   */
  private registerHandler(type: string, callback: (payload: any) => void): void {
    // This would be called when messages arrive from Swift
    // Implementation depends on how Swift sends messages back
    if (!window.__bridgeHandlers) {
      window.__bridgeHandlers = {};
    }
    window.__bridgeHandlers[type] = callback;
  }
}

/**
 * Global bridge instance
 */
export const bridge = EditorBridge.getInstance();

/**
 * Global functions called from Swift
 */
export function registerSwiftInterface(): void {
  window.editorInterface = {
    setContent: (markdown: string) => {
      if (window.__editorCallbacks?.setContent) {
        window.__editorCallbacks.setContent(markdown);
      }
    },

    setTheme: (theme: 'light' | 'dark') => {
      if (window.__editorCallbacks?.setTheme) {
        window.__editorCallbacks.setTheme(theme);
      }
    },

    toggleSourceMode: () => {
      if (window.__editorCallbacks?.toggleSourceMode) {
        window.__editorCallbacks.toggleSourceMode();
      }
    },

    scrollToHeading: (id: string) => {
      if (window.__editorCallbacks?.scrollToHeading) {
        window.__editorCallbacks.scrollToHeading(id);
      }
    },

    getHTML: (): string => {
      return window.__editorCallbacks?.getHTML?.() || '';
    },

    getMarkdown: (): string => {
      return window.__editorCallbacks?.getMarkdown?.() || '';
    },

    preparePrintLayout: (): string => {
      return window.__editorCallbacks?.preparePrintLayout?.() || '';
    },

    restoreEditLayout: () => {
      if (window.__editorCallbacks?.restoreEditLayout) {
        window.__editorCallbacks.restoreEditLayout();
      }
    }
  };
}

/**
 * Type definitions for Swift interface
 */
declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        bridge?: {
          postMessage: (message: BridgeMessage) => void;
        };
      };
    };
    __bridgeHandlers?: Record<string, (payload: any) => void>;
    __editorCallbacks?: {
      setContent?: (markdown: string) => void;
      setTheme?: (theme: 'light' | 'dark') => void;
      toggleSourceMode?: () => void;
      scrollToHeading?: (id: string) => void;
      getHTML?: () => string;
      getMarkdown?: () => string;
      preparePrintLayout?: () => string;
      restoreEditLayout?: () => void;
    };
    editorInterface?: any;
  }
}
