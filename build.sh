#!/usr/bin/env bash
# Build the single native binary: embed the landing, compose the MFL sources, compile.
set -euo pipefail
cd "$(dirname "$0")"

MACHIN="${MACHIN:-machin}"
command -v "$MACHIN" >/dev/null 2>&1 || { echo "error: '$MACHIN' not found (set MACHIN=/path/to/machin)"; exit 1; }

python3 - <<'PY' > src/landing_gen.src
import json
html = open('ui/landing.html').read()
print('func landing_html() (h) { h = ' + json.dumps(html, ensure_ascii=False) + ' }')
PY

"$MACHIN" encode framework/machweb.src src/*.src > app.mfl
"$MACHIN" build app.mfl -o relais

echo "built ./relais  (try: ./relais help)"
