# Deploy — dk1

Live at **https://relais.intrane.fr** → 127.0.0.1:8796 (hotify/Traefik terminates TLS).

- `/opt/relais/relais` (binary, dir owned dk1 for SQLite), `/opt/relais/data.db` (WAL)
- `/etc/relais/relais.env` (root:dk1 640): RELAIS_DB, RELAIS_PUBLIC_URL, PEAGE_URL,
  PEAGE_MERCHANT_KEY (peage merchant m_c50532b8c4b2), RELAIS_PRICE_CENTS
- systemd `relais.service` (User=dk1, `serve -port 8796`, Restart=always)

## Update
```sh
./build.sh && ./test.sh
scp relais dk1:/tmp/relais
ssh dk1 'sudo install -m0755 /tmp/relais /opt/relais/relais && sudo systemctl restart relais && sleep 1 && curl -sf 127.0.0.1:8796/_health'
```
hotify used HTTP challenge (`setup-traefik --challenge-type http`); first cert attempt
may time out while DNS propagates — Traefik retries async, wait ~1 min.
