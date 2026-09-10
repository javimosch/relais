#!/usr/bin/env bash

# A project's own test suite is not a user. It runs the binary many times in a
# fresh environment, which to usage telemetry is indistinguishable from many new
# machines — poche's suite alone put 363 fabricated events into the collector.
# cli-telemetry-spec §2.2.1: harnesses that run binaries must set this.
export DO_NOT_TRACK=1

# End-to-end smoke: inbox lifecycle, catch, read, long-poll (blocking), persistent
# inbox via a mocked peage /v1/charge, abuse caps. Exits non-zero on first failure.
set -euo pipefail
cd "$(dirname "$0")"

PORT=18796
MOCK_PORT=18797
UPDATE_PORT=18798
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
UPD=""
trap 'kill ${SRV:-} ${MOCK:-} ${UPD:-} 2>/dev/null || true; rm -f ./relais.bak ./relais.new' EXIT
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

# ---- cli-trial-spec v0.3: whoami + auto-provision + claim ----
echo "== cli-trial-spec =="
# whoami with no bearer -> 400
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/whoami")" = "400" ] || fail whoami-no-bearer; ok "whoami without bearer -> 400"
# whoami with short bearer -> 400
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/whoami" -H 'Authorization: Bearer short')" = "400" ] || fail whoami-short; ok "whoami with short bearer -> 400"

# whoami auto-provisions on unknown bearer (the core of the trial spec)
TRIAL_TOK="rk_trial_$(date +%s)_abcdef"
W=$(curl -sf "http://127.0.0.1:$PORT/v1/whoami" -H "Authorization: Bearer $TRIAL_TOK")
echo "$W" | grep -q '"ok":true' || fail whoami-ok; ok "whoami auto-provisions on unknown bearer"
echo "$W" | J "['email_attached']" | grep -q "False" || fail whoami-email; ok "whoami shows email_attached=false"
echo "$W" | J "['token_hash']" | grep -q "." || fail whoami-hash; ok "whoami returns token_hash"
TRIAL_IID=$(echo "$W" | J "['inbox_id']")
echo "$W" | grep -q "/c/$TRIAL_IID" || fail whoami-catch; ok "whoami returns catch_url"

# whoami is free — calling it again returns the same inbox, no new provision
W2=$(curl -sf "http://127.0.0.1:$PORT/v1/whoami" -H "Authorization: Bearer $TRIAL_TOK")
[ "$(echo "$W2" | J "['inbox_id']")" = "$TRIAL_IID" ] || fail whoami-idempotent; ok "whoami is idempotent (same inbox on re-call)"

# /v1/messages auto-provisions on unknown bearer
MTOK="rk_msg_$(date +%s)_ghijkl"
M=$(curl -sf "http://127.0.0.1:$PORT/v1/messages" -H "Authorization: Bearer $MTOK")
echo "$M" | grep -q '"ok":1' || fail msg-auto; ok "/v1/messages auto-provisions on unknown bearer"
echo "$M" | J "['messages']" | grep -q '\[\]' || fail msg-empty; ok "auto-provisioned inbox is empty"

# /v1/wait auto-provisions on unknown bearer (times out cleanly)
WTOK="rk_wait_$(date +%s)_mnopqr"
[ "$(curl -sf "http://127.0.0.1:$PORT/v1/wait?timeout_ms=1000" -H "Authorization: Bearer $WTOK" | J "['timeout']")" = "True" ] || fail wait-auto; ok "/v1/wait auto-provisions and times out cleanly"

# catch + read on a trial-provisioned inbox
curl -sf -X POST "http://127.0.0.1:$PORT/c/$TRIAL_IID" -d '{"trial":"works"}' | grep -q captured || fail trial-catch; ok "catch on trial-provisioned inbox"
M3=$(curl -sf "http://127.0.0.1:$PORT/v1/messages" -H "Authorization: Bearer $TRIAL_TOK")
echo "$M3" | J "['messages'].__len__()" | grep -q '1' || fail trial-read; ok "read returns the caught message on trial inbox"

# /app/claim GET returns the HTML form
curl -sf "http://127.0.0.1:$PORT/app/claim" | grep -q 'name="token"' || fail claim-form; ok "GET /app/claim returns the HTML form"
# /app/claim POST with empty fields re-renders (200, not error)
[ "$(curl -s -o /dev/null -w '%{http_code}' -d "token=&email=" "http://127.0.0.1:$PORT/app/claim")" = "200" ] || fail claim-empty; ok "POST /app/claim empty fields re-renders (200)"
# /app/claim POST attaches email
CLAIM=$(curl -sf -d "token=$TRIAL_TOK&email=human@example.com" "http://127.0.0.1:$PORT/app/claim")
echo "$CLAIM" | grep -q 'Email attached' || fail claim-attach; ok "POST /app/claim attaches email"
# whoami after claim shows email_attached=true
W3=$(curl -sf "http://127.0.0.1:$PORT/v1/whoami" -H "Authorization: Bearer $TRIAL_TOK")
echo "$W3" | J "['email_attached']" | grep -q "True" || fail whoami-after-claim; ok "whoami after claim shows email_attached=true"
# re-claim with a different email updates (not a conflict)
curl -sf -d "token=$TRIAL_TOK&email=updated@example.com" "http://127.0.0.1:$PORT/app/claim" | grep -q 'Email attached' || fail claim-reclaim; ok "re-claim with new email updates"
# claim with bad token re-renders with error
curl -sf -d "token=rk_nonexistent_token_x&email=x@y.com" "http://127.0.0.1:$PORT/app/claim" | grep -q 'no inbox found' || fail claim-bad; ok "claim with bad token shows error"

# operator CLI
./relais inbox-new -label ops | grep -q '"ok":true' || fail cli-new; ok "cli inbox-new"
./relais stats | grep -q '"messages"' || fail cli-stats; ok "cli stats"

echo "== agent-first CLI contract =="
./relais version | grep -q '"tool":"relais"' || fail version-tool; ok "version identifies relais"
./relais help-json | grep -q '"feedback"' || fail help-feedback; ok "help-json lists feedback"
./relais help-json | grep -q '"update"' || fail help-update; ok "help-json lists update"
FEEDBACK_RELAY=off ./relais feedback "smoke feedback" -kind note -context test | grep -q '"relayed":0' || fail feedback; ok "feedback relay opt-out"

# Local feedback endpoint and dual-write: the running app owns /v1/feedback.
LOCAL_FEEDBACK=$(curl -sf -X POST "http://127.0.0.1:$PORT/v1/feedback" -d '{"id":"smoke-fb-1","message":"hello"}')
echo "$LOCAL_FEEDBACK" | grep -q '"stored":true' || fail feedback-http; ok "local feedback endpoint"

# Update contract: a real local HTTP manifest/artifact server exercises stale,
# hash rejection, candidate smoke rejection, and successful atomic replacement.
UPDATE_DIR=$(mktemp -d)
cp ./relais "$UPDATE_DIR/relais-new"
printf '\nrelais smoke candidate\n' >> "$UPDATE_DIR/relais-new"
chmod +x "$UPDATE_DIR/relais-new"
NEW_HASH=$(sha256sum "$UPDATE_DIR/relais-new" | awk '{print $1}')
cp "$UPDATE_DIR/relais-new" "$UPDATE_DIR/relais-valid"
printf '{"ok":true,"version":"%s","download":"http://127.0.0.1:%s/artifact","sha256":"%s"}\n' "${NEW_HASH:0:12}" "$UPDATE_PORT" "$NEW_HASH" > "$UPDATE_DIR/version.json"
python3 - "$UPDATE_DIR" "$UPDATE_PORT" <<'PY' &
import http.server, pathlib, sys
root = pathlib.Path(sys.argv[1])
port = int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/version.json':
            body = (root / 'version.json').read_bytes()
        elif self.path == '/artifact':
            body = (root / 'relais-new').read_bytes()
        else:
            self.send_error(404); return
        self.send_response(200)
        self.send_header('content-type', 'application/octet-stream')
        self.send_header('content-length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PY
UPD=$!
trap 'kill $SRV $MOCK $UPD 2>/dev/null || true; rm -rf "$UPDATE_DIR"' EXIT
sleep 0.2
export RELAIS_ALLOW_INSECURE_UPDATE=1
export RELAIS_VERSION_URL="http://127.0.0.1:$UPDATE_PORT/version.json"
set +e
./relais update --check > /tmp/relais-update-check.json 2>/tmp/relais-update-check.err
URC=$?
set -e
[ "$URC" = 5 ] || fail update-stale-exit; ok "update check reports stale with exit 5"
grep -q '"up_to_date":false' /tmp/relais-update-check.json || fail update-stale-json; ok "stale update JSON is machine-readable"

# Advertise a bad full hash: update must reject and leave the running binary intact.
BEFORE=$(sha256sum ./relais | awk '{print $1}')
printf '{"ok":true,"version":"%s","download":"http://127.0.0.1:%s/artifact","sha256":"%064d"}\n' "${NEW_HASH:0:12}" "$UPDATE_PORT" 0 > "$UPDATE_DIR/version.json"
set +e
./relais update > /tmp/relais-update-bad.json 2>/tmp/relais-update-bad.err
BRC=$?
set -e
[ "$BRC" = 100 ] || fail update-bad-hash-exit
[ "$(sha256sum ./relais | awk '{print $1}')" = "$BEFORE" ] || fail update-bad-hash-preserved
ok "bad full hash is rejected without replacement"

# A self-consistent but non-executable artifact must fail the version smoke test.
printf 'not an executable artifact\n' > "$UPDATE_DIR/relais-new"
head -c 12000 /dev/zero >> "$UPDATE_DIR/relais-new"
chmod +x "$UPDATE_DIR/relais-new"
BAD_CANDIDATE_HASH=$(sha256sum "$UPDATE_DIR/relais-new" | awk '{print $1}')
printf '{"ok":true,"version":"%s","download":"http://127.0.0.1:%s/artifact","sha256":"%s"}\n' "${BAD_CANDIDATE_HASH:0:12}" "$UPDATE_PORT" "$BAD_CANDIDATE_HASH" > "$UPDATE_DIR/version.json"
set +e
./relais update > /tmp/relais-update-smoke.json 2>/tmp/relais-update-smoke.err
SRC=$?
set -e
[ "$SRC" = 100 ] || fail update-smoke-exit
[ "$(sha256sum ./relais | awk '{print $1}')" = "$BEFORE" ] || fail update-smoke-preserved
ok "candidate version smoke failure preserves the binary"

# Restore the valid candidate and verify atomic replacement plus rollback backup.
cp "$UPDATE_DIR/relais-valid" "$UPDATE_DIR/relais-new"
chmod +x "$UPDATE_DIR/relais-new"
NEW_HASH=$(sha256sum "$UPDATE_DIR/relais-new" | awk '{print $1}')
printf '{"ok":true,"version":"%s","download":"http://127.0.0.1:%s/artifact","sha256":"%s"}\n' "${NEW_HASH:0:12}" "$UPDATE_PORT" "$NEW_HASH" > "$UPDATE_DIR/version.json"
# The failed paths must not have created a backup; successful update creates it.
rm -f ./relais.bak
./relais update > /tmp/relais-update-good.json || fail update-good
[ -f ./relais.bak ] || fail update-backup
[ "$(./relais version | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["content_hash"])')" = "${NEW_HASH:0:12}" ] || fail update-version
ok "successful update swaps atomically and leaves .bak"
# Restore the test binary so the smoke suite leaves the worktree unchanged.
[ -f ./relais.bak ] && mv ./relais.bak ./relais

rm -f /tmp/relais-update-check.json /tmp/relais-update-check.err /tmp/relais-update-bad.json /tmp/relais-update-bad.err /tmp/relais-update-smoke.json /tmp/relais-update-smoke.err /tmp/relais-update-good.json

echo "ALL $P TESTS PASSED"
