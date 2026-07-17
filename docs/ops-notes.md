# relais ops notes

- **peage merchant:** `m_81278d2604c5` (email `relais@intrane.fr` — NOT `javi@`, which
  the grepapi merchant already took; peage `merchants.email` is UNIQUE and its CLI prints
  the key BEFORE the INSERT, so a duplicate-email create fails silently with a dead key —
  the exact bug hit on first deploy). Key lives in `/etc/relais/relais.env` on dk1.
- **SuperInsights project:** `relais-landing` (`pk_bc50b449…`), on landing.
- **Deploy:** dk1 `/opt/relais/relais`, systemd `relais.service` :8796, hotify
  `relais.intrane.fr` (HTTP challenge — first cert attempt timed out on DNS propagation,
  Traefik retried async).
- **Backup TODO:** add `/opt/relais/data.db` + `/etc/relais/relais.env` as a `dk1-relais`
  machin-vault target once the service holds inboxes worth keeping (same pattern as
  `dk1-peage`).
