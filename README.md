# relais — an inbox your agent can block on

**Ephemeral and local agents have no public URL — so they can't receive anything.**
relais gives your agent a URL that catches any HTTP request (OAuth callbacks, webhooks,
payment confirmations, human approvals), and a long-poll it can `curl` and **block on**
until the thing arrives. No crypto, no OAuth, all curl. One static ~110 KB
[machin (MFL)](https://github.com/javimosch/machin) binary.

Live: **https://relais.intrane.fr** · the real docs: **[/llms.txt](https://relais.intrane.fr/llms.txt)** · JSON: **[/guide](https://relais.intrane.fr/guide)**

## The whole thing in 3 curls

```sh
# 1. make an inbox (save the token — shown once)
curl -s -X POST https://relais.intrane.fr/v1/inboxes -d '{"label":"oauth callback"}'
# -> {"inbox_id":"in_…","token":"rk_…","catch_url":"https://relais.intrane.fr/c/in_…"}

# 2. give catch_url to whatever should reach you (OAuth redirect_uri, webhook, form, another agent)

# 3. block until it lands (or read the backlog):
curl -s https://relais.intrane.fr/v1/wait -H 'Authorization: Bearer rk_…'      # blocks ~25s
curl -s https://relais.intrane.fr/v1/messages -H 'Authorization: Bearer rk_…'  # the backlog
```

A captured message is `{id, method, path, headers, body, ip, received_at}`. Secrets
(`Authorization`, `Cookie`) are never stored; the body is capped at 60 KB.

## Why this exists

Agents can *call* any API — that's the easy half. The hard half is being *called back*,
and a process running on a laptop, in a CI job, or inside a Claude Code session has no
address to be called back at. relais is the missing inbound URL, plus a `/wait` that
turns "poll in a loop" into "park on one curl until it happens."

## Free is ephemeral, persistent is paid (peage)

A free inbox expires in 1h and holds 100 messages — perfect for a one-shot OAuth dance.
Need a **stable URL** to register with Stripe/GitHub/an OAuth app? Buy a persistent inbox
(30-day TTL, 10k messages) with a [peage](https://peage.intrane.fr) wallet — one header,
no subscription:

```sh
curl -s -X POST https://relais.intrane.fr/v1/inboxes \
  -H 'X-Peage-Wallet: pw_…' -d '{"label":"stripe prod"}'
```

péage is the pay half of the agent web; relais is the receive half.

## Build & run

```sh
./build.sh     # machin encode + build -> ./relais
./test.sh      # 25-assertion end-to-end (mocked peage)
RELAIS_PUBLIC_URL=https://relais.intrane.fr PEAGE_MERCHANT_KEY=pm_… ./relais serve -port 8796
```

Env: `RELAIS_DB` (default `~/.relais/data.db`) · `RELAIS_PUBLIC_URL` · `RELAIS_FREE_TTL`
(default 3600) · `RELAIS_PAID_TTL` (default 2592000) · `RELAIS_PRICE_CENTS` (default 5) ·
`PEAGE_MERCHANT_KEY` · `PEAGE_URL`.

## Operator CLI (JSON out)

```
relais inbox-new [-label x]   relais inboxes [-limit n]   relais stats
```

Sibling of [peage](https://github.com/javimosch/peage) (pay), [grepapi](https://grepapi.intrane.fr) (find), [hart](https://github.com/javimosch/machin-hart) (show).
