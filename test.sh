#!/usr/bin/env bash
# End-to-end smoke: inbox lifecycle, catch, read, long-poll (blocking), persistent
# inbox via a mocked peage /v1/charge, abuse caps. Exits non-zero on first failure.
set -euo pipefail
cd "$(dirname "$0")"

PORT=18796
MOCK_PORT=18797
DB=$(mktemp -d)/test.db
export RELAIS_DB="$DB" RELAIS_PUBLIC_URL="http://127.0.0.1:$PORT"
export PEAGE_MERCHANT_KEY="pm_test" PEAGE_URL="http://127.0.0.1:$MOCK_PORT"

# mock peage: /v1/charge -> 200 with a fake receipt unless the wallet is "broke"
python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get('content-length',0))).decode()
        broke = 'broke' in body
        obj = ({"ok":0,"error":"insufficient_funds","needed_cents":5} if broke
               else {"ok":1,"charge_id":"c_mock","receipt":"c_mock.deadbeef","amount_cents":5})
        b=json.dumps(obj).encode()
        self.send_response(402 if broke else 200)
        self.send_header('content-type','application/json'); self.send_header('content-length',str(len(b)))
        self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18797),H).serve_forever()
PY
MOCK=$!
./relais serve -port $PORT 2>/dev/null &
SRV=$!
trap 'kill $SRV $MOCK 2>/dev/null || true' EXIT
sleep 0.6

J(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(d$1)"; }
fail(){ echo "FAIL: $1"; exit 1; }
P=0; ok(){ P=$((P+1)); echo "ok $P - $1"; }

curl -sf "http://127.0.0.1:$PORT/_health" | grep -q '"ok":1' || fail health; ok health
curl -sf "http://127.0.0.1:$PORT/llms.txt" | grep -q "block on" || fail llms; ok llms.txt
curl -sf "http://127.0.0.1:$PORT/guide" | grep -q '"pay_rail":"peage"' || fail guide; ok guide
curl -sf "http://127.0.0.1:$PORT/" | grep -q relais || fail landing; ok landing

# free inbox
I=$(curl -sf -X POST "http://127.0.0.1:$PORT/v1/inboxes" -d '{"label":"t1"}')
IID=$(echo "$I" | J "['inbox_id']"); TOK=$(echo "$I" | J "['token']")
[ "$(echo "$I" | J "['plan']")" = "free" ] || fail free-plan; ok "free inbox ($IID)"
echo "$I" | grep -q "/c/$IID" || fail catch-url; ok "catch_url points at the inbox"

# empty read
[ "$(curl -sf "http://127.0.0.1:$PORT/v1/messages" -H "Authorization: Bearer $TOK" | J "['messages']")" = "[]" ] || fail empty; ok "empty inbox reads []"

# catch a POST webhook
curl -sf -X POST "http://127.0.0.1:$PORT/c/$IID?code=abc" -H "content-type: application/json" -H "X-GitHub-Event: push" -d '{"ref":"main"}' | grep -q '"captured":true' || fail catch; ok "catch a POST"
# catch a GET (OAuth-style redirect)
curl -sf "http://127.0.0.1:$PORT/c/$IID?state=xyz&code=oauthcode" | grep -q captured || fail catch-get; ok "catch a GET redirect"

# read returns both, newest first, with headers + body
M=$(curl -sf "http://127.0.0.1:$PORT/v1/messages" -H "Authorization: Bearer $TOK")
[ "$(echo "$M" | J "['messages'].__len__()")" = "2" ] || fail read-count; ok "read returns 2 messages"
echo "$M" | J "['messages'][1]['headers']['x-github-event']" | grep -q push || fail hdr; ok "captured a useful header (x-github-event)"
echo "$M" | J "['messages'][1]['body']" | grep -q '"ref":"main"' || fail body; ok "captured the body"
# secrets are NOT stored
curl -sf -X POST "http://127.0.0.1:$PORT/c/$IID" -H "Authorization: Bearer sekret" -H "Cookie: sid=nope" -d 'x' >/dev/null
curl -sf "http://127.0.0.1:$PORT/v1/messages" -H "Authorization: Bearer $TOK" | grep -qi "sekret\|sid=nope" && fail secret-leak; ok "auth/cookie headers not stored"

# long-poll: arrives while blocking
( sleep 1; curl -sf -X POST "http://127.0.0.1:$PORT/c/$IID" -d '{"async":"done"}' >/dev/null ) &
W=$(curl -sf "http://127.0.0.1:$PORT/v1/wait?timeout_ms=8000" -H "Authorization: Bearer $TOK")
[ "$(echo "$W" | J "['waiting']")" = "False" ] || fail wait; ok "long-poll returns the message"
echo "$W" | J "['message']['body']" | grep -q '"async":"done"' || fail wait-body; ok "long-poll body correct"
# long-poll timeout when nothing arrives
[ "$(curl -sf "http://127.0.0.1:$PORT/v1/wait?timeout_ms=1000" -H "Authorization: Bearer $TOK" | J "['timeout']")" = "True" ] || fail wait-timeout; ok "long-poll times out cleanly"

# bad token -> 401
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/messages" -H "Authorization: Bearer rk_nope")" = "401" ] || fail authz; ok "bad token -> 401"
# unknown inbox catch -> 404
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/c/in_nope" -d x)" = "404" ] || fail catch-404; ok "unknown inbox -> 404"

# persistent inbox via peage (mock charges 5c)
PI=$(curl -sf -X POST "http://127.0.0.1:$PORT/v1/inboxes" -H "X-Peage-Wallet: pw_funded" -d '{"label":"stripe"}')
[ "$(echo "$PI" | J "['plan']")" = "paid" ] || fail paid-plan; ok "peage inbox is persistent"
echo "$PI" | grep -q '"peage_receipt"' || fail receipt; ok "persistent inbox carries the peage receipt"
# broke wallet -> 402 passthrough
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/v1/inboxes" -H "X-Peage-Wallet: pw_broke" -d '{}')" = "402" ] || fail paid-402; ok "declined wallet -> 402"

# delete inbox
curl -sf -X DELETE "http://127.0.0.1:$PORT/v1/inbox" -H "Authorization: Bearer $TOK" | grep -q '"deleted":true' || fail delete; ok "delete inbox"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/c/$IID" -d x)" = "404" ] || fail delete-gone; ok "catch on deleted inbox -> 404"

# operator CLI
./relais inbox-new -label ops | grep -q '"ok":true' || fail cli-new; ok "cli inbox-new"
./relais stats | grep -q '"messages"' || fail cli-stats; ok "cli stats"

echo "ALL $P TESTS PASSED"
