#!/bin/bash
# Build the browser bundles MarkView ships (offline; nothing loads from a CDN).
#   npm ci && ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
OUT=../../MarkView/Resources/Editor/vendor/js

npx esbuild codemirror-entry.js --bundle --minify --format=iife --target=safari15 \
    --legal-comments=eof --outfile="$OUT/codemirror.bundle.js"

npx esbuild xterm-entry.js --bundle --minify --format=iife --target=safari15 \
    --legal-comments=eof --outfile="$OUT/xterm.bundle.js"
cp node_modules/@xterm/xterm/css/xterm.css ../../MarkView/Resources/Editor/vendor/css/xterm.css

cp node_modules/cytoscape/dist/cytoscape.min.js "$OUT/cytoscape.min.js"
cp node_modules/elkjs/lib/elk.bundled.js "$OUT/elk.bundled.js"
cp node_modules/cytoscape-elk/dist/cytoscape-elk.js "$OUT/cytoscape-elk.js"

ls -la "$OUT"/xterm.bundle.js "$OUT"/codemirror.bundle.js "$OUT"/cytoscape.min.js "$OUT"/elk.bundled.js "$OUT"/cytoscape-elk.js
