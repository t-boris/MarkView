// Preserve classic-script global scope and the existing order while assembling the editor.
import { readFileSync } from 'node:fs';
import { transform } from 'esbuild';

const root = new URL('../../MarkView/Resources/Editor/', import.meta.url);
const inputs = JSON.parse(readFileSync(new URL('./editor-inputs.json', import.meta.url), 'utf8'));
if (inputs.length < 3 || inputs[0] !== 'js/markview-themes.js' || inputs[1] !== 'js/mv-kit.js' ||
    inputs.at(-1) !== 'js/markview-init.js' || new Set(inputs).size !== inputs.length ||
    inputs.some(path => !/^js\/[a-z0-9-]+\.js$/.test(path))) {
    throw new Error('Editor inputs must be unique classic scripts, with the early files first and initialization last');
}
const contents = inputs.map(path => readFileSync(new URL(path, root), 'utf8'));
const source = `if (!window[Symbol.for("markview.editor.early")]) {\n` +
    `window[Symbol.for("markview.editor.early")] = true;\n` +
    contents.slice(0, 2).join('\n;\n') + '\n}\n/*! MARKVIEW_EDITOR_EARLY_END */\n' +
    contents.slice(2).join('\n;\n');
const result = await transform(source, { target: 'safari15', legalComments: 'inline' });
process.stdout.write(result.code);
