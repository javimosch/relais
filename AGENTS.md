# relais — agent notes

Single-binary machin (MFL) webhook-inbox for agents. The receive-half of the agent web;
sibling of peage (pay). Read `README.md`; the API contract is `src/guide.src` (`/llms.txt`).

- Build: `./build.sh` (embeds `ui/landing.html` into `src/landing_gen.src`). Test: `./test.sh` (25 assertions, mocked peage) — keep green.
- Never `parse()` a client body: absent fields nil → segfault. Use `json_get`+defaults.
- One type per variable name per function scope (MFL inference).
- `/v1/wait` long-polls via `sleep(1000)` in a goroutine-per-connection; `set_read_timeout(60000)` must exceed the max wait window (55s).
- Stored `headers` is JSON text — emit it RAW (nested object) via `row_to_json`, never return the sqlite row directly (double-encodes).
- Free inbox = ephemeral (RELAIS_FREE_TTL); X-Peage-Wallet on create = persistent (charges via peage, RELAIS_PRICE_CENTS). Expired inboxes swept lazily (`sweep_expired`).
- Deploy: dk1 `/opt/relais/relais`, env `/etc/relais/relais.env` (640, has PEAGE_MERCHANT_KEY), systemd `relais.service` :8796, hotify `relais.intrane.fr`. peage merchant m_c50532b8c4b2.
