import { defineConfig } from 'vite';
import { resolve } from 'path';

export default defineConfig({
  build: {
    target: 'es2020',
    lib: {
      entry: resolve(__dirname, 'src/editor.ts'),
      name: 'MarkViewEditor',
      fileName: (format) => {
        if (format === 'es') {
          return 'index.es.js';
        }
        return 'index.js';
      }
    },
    rollupOptions: {
      output: {
        // Externalize dependencies that will be loaded via CDN
        external: ['mermaid', 'prismjs', 'markdown-it'],
        globals: {
          mermaid: 'mermaid',
          prismjs: 'Prism',
          'markdown-it': 'markdownit'
        }
      }
    },
    minify: 'terser',
    sourcemap: true,
    outDir: 'dist',
    emptyOutDir: true
  },
  server: {
    port: 5173,
    strictPort: false,
    open: true
  },
  preview: {
    port: 4173
  }
});
