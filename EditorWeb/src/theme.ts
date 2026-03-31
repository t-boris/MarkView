/**
 * Theme management for the editor
 */

export type Theme = 'light' | 'dark';

export interface ThemeConfig {
  name: Theme;
  colors: {
    bgPrimary: string;
    bgSecondary: string;
    bgTertiary: string;
    textPrimary: string;
    textSecondary: string;
    textTertiary: string;
    borderColor: string;
    borderColorLight: string;
    accentPrimary: string;
    accentSecondary: string;
    accentTertiary: string;
    accentWarning: string;
    accentInfo: string;
    accentSuccess: string;
    accentDanger: string;
    codeBg: string;
    codeText: string;
    codeBorder: string;
  };
}

const LIGHT_THEME: ThemeConfig = {
  name: 'light',
  colors: {
    bgPrimary: '#ffffff',
    bgSecondary: '#f5f5f5',
    bgTertiary: '#efefef',
    textPrimary: '#1a1a1a',
    textSecondary: '#666666',
    textTertiary: '#999999',
    borderColor: '#e0e0e0',
    borderColorLight: '#f0f0f0',
    accentPrimary: '#0066cc',
    accentSecondary: '#00b386',
    accentTertiary: '#ff6b6b',
    accentWarning: '#ffa500',
    accentInfo: '#0066cc',
    accentSuccess: '#00b386',
    accentDanger: '#ff6b6b',
    codeBg: '#f5f5f5',
    codeText: '#1a1a1a',
    codeBorder: '#e0e0e0',
  }
};

const DARK_THEME: ThemeConfig = {
  name: 'dark',
  colors: {
    bgPrimary: '#1a1a2e',
    bgSecondary: '#16213e',
    bgTertiary: '#0f3460',
    textPrimary: '#e8e8e8',
    textSecondary: '#a0a0a0',
    textTertiary: '#707070',
    borderColor: '#2a2a3e',
    borderColorLight: '#1f1f3a',
    accentPrimary: '#4da6ff',
    accentSecondary: '#4ddbaa',
    accentTertiary: '#ff8787',
    accentWarning: '#ffb84d',
    accentInfo: '#4da6ff',
    accentSuccess: '#4ddbaa',
    accentDanger: '#ff8787',
    codeBg: '#0f3460',
    codeText: '#e8e8e8',
    codeBorder: '#2a2a3e',
  }
};

export class ThemeManager {
  private static instance: ThemeManager;
  private currentTheme: Theme;
  private readonly STORAGE_KEY = 'markview-theme';

  private constructor() {
    this.currentTheme = this.loadTheme();
  }

  static getInstance(): ThemeManager {
    if (!ThemeManager.instance) {
      ThemeManager.instance = new ThemeManager();
    }
    return ThemeManager.instance;
  }

  /**
   * Get current theme
   */
  getTheme(): Theme {
    return this.currentTheme;
  }

  /**
   * Get theme configuration
   */
  getConfig(): ThemeConfig {
    return this.currentTheme === 'dark' ? DARK_THEME : LIGHT_THEME;
  }

  /**
   * Set theme
   */
  setTheme(theme: Theme): void {
    this.currentTheme = theme;
    this.applyTheme(theme);
    this.saveTheme(theme);
  }

  /**
   * Toggle between light and dark
   */
  toggle(): Theme {
    const newTheme = this.currentTheme === 'light' ? 'dark' : 'light';
    this.setTheme(newTheme);
    return newTheme;
  }

  /**
   * Apply theme to document
   */
  private applyTheme(theme: Theme): void {
    const root = document.documentElement;
    root.setAttribute('data-theme', theme);

    // Trigger transition for smooth theme change
    root.style.transition = 'background-color 0.3s ease, color 0.3s ease';
  }

  /**
   * Load theme from localStorage
   */
  private loadTheme(): Theme {
    try {
      const stored = localStorage.getItem(this.STORAGE_KEY);
      if (stored === 'dark' || stored === 'light') {
        return stored;
      }
    } catch (e) {
      // localStorage might not be available
    }

    // Default to light or system preference
    return this.getSystemTheme();
  }

  /**
   * Save theme to localStorage
   */
  private saveTheme(theme: Theme): void {
    try {
      localStorage.setItem(this.STORAGE_KEY, theme);
    } catch (e) {
      // localStorage might not be available
      console.warn('Could not save theme preference:', e);
    }
  }

  /**
   * Get system theme preference
   */
  private getSystemTheme(): Theme {
    if (typeof window === 'undefined') {
      return 'light';
    }

    if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
      return 'dark';
    }

    return 'light';
  }

  /**
   * Listen for system theme changes
   */
  watchSystemTheme(callback: (theme: Theme) => void): () => void {
    if (!window.matchMedia) {
      return () => {};
    }

    const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
    const handleChange = (e: MediaQueryListEvent) => {
      callback(e.matches ? 'dark' : 'light');
    };

    mediaQuery.addEventListener('change', handleChange);

    return () => {
      mediaQuery.removeEventListener('change', handleChange);
    };
  }

  /**
   * Get CSS variable for a color
   */
  getColor(colorKey: keyof ThemeConfig['colors']): string {
    const config = this.getConfig();
    return config.colors[colorKey];
  }
}

/**
 * Global theme manager instance
 */
export const themeManager = ThemeManager.getInstance();
