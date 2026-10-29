# Distrofy mail server (Stalwart) – deployment

Internal mail server for our own brands (`@distrofyent.com` and others). Staff mailboxes only:
no public sign-up, admin UI not indexed by search engines.

The rest of this repository is upstream Stalwart source, kept unmodified so the fork can be synced
from upstream without conflicts. The server runs the official release binary; nothing here is built.

## What runs where

| Piece | Location on the VPS (`158.69.221.107`) |
| --- | --- |
| Stalwart 0.16.x | `/usr/local/bin/stalwart`, systemd unit `stalwart.service`, user `stalwart` |
| Store config | `/etc/stalwart/config.json` (RocksDB at `/var/lib/stalwart/`) |
| All other settings | Inside the data store; managed with `stalwart/plan.ndjson` |
| Logs | `/var/log/stalwart/` |
| Web access | Shared Caddy gateway of distrofy-webapp (`distrofy-gateway` container) via `infra/caddy/sites/mail.caddy` |

Network layout:

- Mail ports go straight to Stalwart: SMTP 25, SMTPS 465, IMAPS 993, ManageSieve 4190.
- HTTPS (`mail.`, `autoconfig.`, `autodiscover.`, `mta-sts.`, `ua-auto-config.` `distrofyent.com`) terminates
  at Caddy, which forwards to Stalwart's `https-proxy` listener on `:10443` with PROXY protocol, so
  Stalwart sees real client IPs (brute-force blocking works). Only the Docker network `10.0.2.0/24`
  may reach `:10443`.
- Plain HTTP `:8080` is bound to localhost only.
- Outbound delivery is IPv4-only (the IPv6 address has no reverse DNS).

DNS lives in Cloudflare. Stalwart manages the mail records itself through a scoped API token
(Zone:Read + DNS:Edit, IP-restricted to the server's IPv4 and IPv6): MX, SPF, DKIM (rotated every 90 days),
DMARC, MTA-STS, TLS-RPT, SRV and autoconfig. CAA is deliberately not published. `mail.distrofyent.com`
is an A record that must stay **DNS only** (grey cloud). TLS certificates come from Let's Encrypt via
DNS-01, so Stalwart never needs ports 80/443.

## Deploying

Prerequisites: SSH access as `ubuntu@158.69.221.107`, and [stalwart-cli](https://stalw.art/docs/management/cli/)
for the settings step.

```bash
export STALWART_USER='admin@distrofyent.com'
read -rsp 'Stalwart password: ' STALWART_PASSWORD && export STALWART_PASSWORD

deploy/deploy.sh all        # caddy + firewall + stalwart settings
```

Individual steps: `caddy`, `firewall`, `stalwart`, `service` (unit + config.json, restarts Stalwart).
The Caddy step validates the gateway config before reloading and restores the previous site file if
validation fails, so a bad edit never takes down the other sites behind the gateway.

The Caddy step requires the `import sites/*.caddy` line in distrofy-webapp's `infra/caddy/Caddyfile`
(the `sites/` directory is gitignored there).

## Changing settings

Either edit `stalwart/plan.ndjson` and run `deploy/deploy.sh stalwart`, or change things in the web UI
and run `deploy/deploy.sh snapshot` to pull them back into the repo, then commit. The plan only contains
`upsert`/`update` operations: re-applying it never deletes or duplicates anything. It never contains
secrets; the Cloudflare token is stored only on the server (WebUI › Settings › Network › DNS › DNS Providers).

## Common tasks

- **Add a staff mailbox:** WebUI › Management › Directory › Accounts. Users sign in with their full
  address; mail apps configure themselves from address + password.
- **Add a brand domain:** add the zone to the Cloudflare token, then WebUI › Management › Domains with
  DNS management *Automatic* (Cloudflare provider, every record type except CAA) and certificate
  management *Automatic*. Run `deploy/deploy.sh snapshot` afterwards.
- **Upgrade Stalwart:** follow the upstream `UPGRADING/` notes, replace `/usr/local/bin/stalwart`, restart.

## Recovery

If no administrator can sign in: add `STALWART_RECOVERY_ADMIN=admin:<temporary-password>` to
`/etc/stalwart/stalwart.env`, `sudo systemctl restart stalwart`, sign in at https://mail.distrofyent.com/admin
with `admin` and that password, fix the account, then remove the variable and restart again. While the
variable is set it is a full-access login.
