// Check every input in its existing classic-script scope. Ratchet diagnostics by
// file, code and message; line numbers are intentionally omitted so moves are stable.
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const config = JSON.parse(readFileSync(new URL('./tsconfig.editor.json', import.meta.url), 'utf8'));
const inputs = JSON.parse(readFileSync(new URL('./editor-inputs.json', import.meta.url), 'utf8'));
if (JSON.stringify(config.files) !== JSON.stringify(inputs.map(path => '../../MarkView/Resources/Editor/' + path))) {
    throw new Error('Type-check inputs must match editor-inputs.json in the same order');
}
const result = spawnSync(process.execPath, [new URL('./node_modules/typescript/bin/tsc', import.meta.url).pathname,
    '-p', new URL('./tsconfig.editor.json', import.meta.url).pathname, '--pretty', 'false'], { encoding: 'utf8' });
if (result.error || ![0, 2].includes(result.status)) throw result.error || new Error(result.stderr || 'tsc failed');
const diagnostics = {};
for (const line of result.stdout.split('\n')) {
    const match = line.match(/(?:^|\/)MarkView\/Resources\/Editor\/(js\/[^ (]+)\(\d+,\d+\): error (TS\d+): (.*)$/);
    if (match) {
        const key = `${match[1]} ${match[2]} ${match[3]}`;
        diagnostics[key] = (diagnostics[key] || 0) + 1;
    } else if (/error TS\d+:/.test(line)) {
        throw new Error(`Unrecognized diagnostic: ${line}`);
    }
}
const sorted = Object.fromEntries(Object.entries(diagnostics).sort(([a], [b]) => a.localeCompare(b, 'en')));
const baseline = new URL('./editor-type-errors.json', import.meta.url);
if (process.argv.includes('--record')) {
    writeFileSync(baseline, JSON.stringify(sorted, null, 2) + '\n');
} else {
    const allowed = JSON.parse(readFileSync(baseline, 'utf8'));
    let changed = false;
    for (const key of new Set([...Object.keys(allowed), ...Object.keys(sorted)])) {
        if ((allowed[key] || 0) !== (sorted[key] || 0)) {
            console.error(`${key}: allowed ${allowed[key] || 0}, actual ${sorted[key] || 0}`);
            changed = true;
        }
    }
    if (changed) process.exitCode = 1;
}
console.log(`Editor type diagnostics: ${Object.values(sorted).reduce((a, b) => a + b, 0)} in ${Object.keys(sorted).length} categories`);
