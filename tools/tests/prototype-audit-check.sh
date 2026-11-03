#!/bin/bash
# BUG-053: runs PrototypeAudit.script (the preview audit) in headless Chrome against Tests/Fixtures/prototype-audit and
# checks which screens it reports. Needs Google Chrome; skips with a note when it is missing.
set -euo pipefail
cd "$(dirname "$0")/../.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ ! -x "$CHROME" ]; then echo "Prototype audit script: skipped, Google Chrome not found"; exit 0; fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cat > "$out/main.swift" <<'SWIFT'
print(PrototypeAudit.script)
SWIFT
swiftc -o "$out/dump" MarkView/Models/PrototypeAudit.swift "$out/main.swift"
"$out/dump" > "$out/audit.js"
cp -R Tests/Fixtures/prototype-audit "$out/site"
cp "$out/audit.js" "$out/site/audit.js"
python3 -I - "$out/site/index.html" <<'PY'
import sys
path = sys.argv[1]
html = open(path, encoding="utf-8").read()
html = html.replace("<!--AUDIT-->", '<script src="audit.js"></script>')
html = html.replace("<!--RUN-->", """<script>
__mvAudit().then(function (r) { var pre = document.createElement('pre'); pre.id = 'mv-audit-result'; pre.textContent = JSON.stringify(r); document.body.appendChild(pre); },
                 function (e) { var pre = document.createElement('pre'); pre.id = 'mv-audit-result'; pre.textContent = JSON.stringify({ error: String(e) }); document.body.appendChild(pre); });
</script>""")
open(path, "w", encoding="utf-8").write(html)
PY
"$CHROME" --headless=new --disable-gpu --allow-file-access-from-files --virtual-time-budget=120000 --dump-dom "file://$out/site/index.html" > "$out/dom.html" 2>/dev/null
python3 -I - "$out/dom.html" <<'PY'
import html, json, re, sys
dom = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r'<pre id="mv-audit-result">(.*?)</pre>', dom, re.S)
if not match:
    sys.exit("FAIL: the audit never finished (no result in the page)")
report = json.loads(html.unescape(match.group(1)))
if "error" in report:
    sys.exit("FAIL: the audit failed: " + report["error"])
found = {p["id"]: p["kind"] for p in report["problems"]}
expected = {"settings": "unbuilt", "trade": "blank", "risky": "error", "stuck": "loading", "ghost": "unbuilt"}
if found != expected:
    sys.exit("FAIL: expected %s, got %s" % (expected, found))
if report["checked"] != 9 or report["skipped"] != 2:
    sys.exit("FAIL: checked %s skipped %s (want 9 and 2: routes with parameters and modals are skipped)" % (report["checked"], report["skipped"]))
print("Prototype audit script: blank, placeholder, error-card and stuck-loading screens are reported; the four real screens, the parameter route and the modal are not.")
PY
