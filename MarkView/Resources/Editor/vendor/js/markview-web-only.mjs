// Preview Web App for Electron projects: serves only the renderer (the web part) with the
// project's own Vite, and never starts Electron. Run by MarkView in the app's folder:
//   node markview-web-only.mjs electron-vite            (electron.vite.config.*: its renderer section)
//   node markview-web-only.mjs vite <config file>       (a Vite config; Electron plugins left out)
// Packages are resolved from the project, not from this file's folder.
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const projectRequire = createRequire(path.join(process.cwd(), 'package.json'));

// The package's ES module entry ("exports" → import), so Vite's deprecated CJS build is not used.
function esmEntry(name) {
  const manifestPath = projectRequire.resolve(`${name}/package.json`);
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const pick = (value) => {
    if (!value) return undefined;
    if (typeof value === 'string') return value;
    return pick(value.import) ?? pick(value.default) ?? pick(value.node);
  };
  const root = manifest.exports && (typeof manifest.exports === 'string' || !manifest.exports['.'] ? manifest.exports : manifest.exports['.']);
  const relative = pick(root) ?? manifest.module ?? manifest.main ?? 'index.js';
  return path.join(path.dirname(manifestPath), relative);
}

async function load(name) {
  let resolved;
  try {
    resolved = esmEntry(name);
  } catch {
    try {
      resolved = projectRequire.resolve(name);
    } catch {
      console.error(`MarkView web preview: "${name}" is not installed in ${process.cwd()}. Run the package manager's install first.`);
      process.exit(1);
    }
  }
  const module = await import(pathToFileURL(resolved).href);
  return module.createServer || module.resolveConfig ? module : (module.default ?? module);
}

// Plugins that start or build Electron (vite-plugin-electron and the like); renderer helpers stay.
// Plugin lists may nest arrays and promises (`vite-plugin-electron/simple` returns a promise).
async function withoutElectron(plugins) {
  const flat = [];
  const visit = async (item) => {
    item = await item;
    if (!item) return;
    if (Array.isArray(item)) { for (const child of item) await visit(child); return; }
    flat.push(item);
  };
  await visit(plugins);
  const kept = [];
  for (const plugin of flat) {
    const name = typeof plugin?.name === 'string' ? plugin.name : '';
    if (/electron/i.test(name) && !/renderer/i.test(name)) {
      console.log(`MarkView web preview: leaving out the plugin "${name}" (it starts Electron).`);
    } else {
      kept.push(plugin);
    }
  }
  return kept;
}

const [mode, configFile] = process.argv.slice(2);
const vite = await load('vite');
let config;

if (mode === 'electron-vite') {
  const electronVite = await load('electron-vite');
  const resolved = await electronVite.resolveConfig({ root: process.cwd() }, 'serve', 'development');
  config = resolved?.config?.renderer;
  if (!config) {
    console.error('MarkView web preview: electron.vite.config has no renderer section to serve.');
    process.exit(1);
  }
  // Its renderer presets (root, entry) stay: they serve the page and never start Electron.
  config = { ...config, configFile: false };
} else {
  const loaded = await vite.loadConfigFromFile({ command: 'serve', mode: 'development' }, configFile, process.cwd());
  const user = loaded?.config ?? {};
  config = { ...user, configFile: false, root: user.root ?? process.cwd(), plugins: await withoutElectron(user.plugins) };
}

const server = await vite.createServer(config);
await server.listen();
console.log('MarkView web preview: serving the renderer only (no Electron).');
server.printUrls();
