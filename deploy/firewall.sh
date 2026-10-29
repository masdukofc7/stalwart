#!/usr/bin/env bash
# Mail-server firewall rules (run as root on the VPS). Safe to re-run: ufw skips existing rules.
set -euo pipefail

CADDY_NET="${CADDY_NET:-10.0.2.0/24}"

ufw allow 25/tcp comment 'Stalwart SMTP'
ufw allow 465/tcp comment 'Stalwart SMTPS'
ufw allow 993/tcp comment 'Stalwart IMAPS'
ufw allow 4190/tcp comment 'Stalwart ManageSieve'
ufw allow from "$CADDY_NET" to any port 10443 proto tcp comment 'Caddy (distrofy-net) -> Stalwart https-proxy'

# Kept closed on purpose: 587 (465 is used instead), 995 (no POP3), 8080 (localhost only), 8081 (old setup UI).
for port in 587 995 8080 8081; do
  ufw delete allow "$port/tcp" >/dev/null 2>&1 || true
done

ufw status | grep -E 'Stalwart|10443' || true
