#!/usr/bin/env bash
# Deploy the mail-server configuration to the VPS. Run from Git Bash or any Linux/macOS shell.
#
#   deploy/deploy.sh all        caddy + firewall + stalwart (default)
#   deploy/deploy.sh caddy      push caddy/mail.caddy to the shared gateway and reload it
#   deploy/deploy.sh firewall   apply firewall.sh on the server
#   deploy/deploy.sh stalwart   apply stalwart/plan.ndjson through the management API
#   deploy/deploy.sh snapshot   pull the live Stalwart settings back into stalwart/plan.ndjson
#   deploy/deploy.sh service    install stalwart.service + config.json and RESTART Stalwart
#
# "stalwart" and "snapshot" need stalwart-cli and STALWART_USER + STALWART_PASSWORD (or STALWART_TOKEN).
set -euo pipefail
cd "$(dirname "$0")"

SSH_HOST="${SSH_HOST:-ubuntu@158.69.221.107}"
SITES_DIR="${SITES_DIR:-/var/www/distrofy-webapp/infra/caddy/sites}"
GATEWAY="${GATEWAY:-distrofy-gateway}"
export STALWART_URL="${STALWART_URL:-https://mail.distrofyent.com}"
SNAPSHOT_TYPES=(SystemSettings NetworkListener MtaRoute AcmeProvider DnsServer Domain)

need_cli() {
  command -v stalwart-cli >/dev/null || { echo "stalwart-cli not found: https://stalw.art/docs/management/cli/" >&2; exit 1; }
  [ -n "${STALWART_TOKEN:-}" ] || [ -n "${STALWART_USER:-}" ] || { echo "Set STALWART_USER and STALWART_PASSWORD (or STALWART_TOKEN)" >&2; exit 1; }
}

deploy_caddy() {
  echo "==> Caddy site (mail.distrofyent.com)"
  scp -q caddy/mail.caddy "$SSH_HOST:/tmp/mail.caddy.new"
  ssh "$SSH_HOST" "SITES_DIR='$SITES_DIR' GATEWAY='$GATEWAY' bash -s" <<'EOF'
set -euo pipefail
grep -q '^import sites/\*\.caddy' "$SITES_DIR/../Caddyfile" \
  || { echo "Caddyfile is missing 'import sites/*.caddy' (deploy distrofy-webapp first)" >&2; exit 1; }
mkdir -p "$SITES_DIR"
rm -f /tmp/mail.caddy.prev
[ -f "$SITES_DIR/mail.caddy" ] && cp "$SITES_DIR/mail.caddy" /tmp/mail.caddy.prev
mv /tmp/mail.caddy.new "$SITES_DIR/mail.caddy"
if docker exec "$GATEWAY" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/tmp/caddy-validate.log 2>&1; then
  docker exec "$GATEWAY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | grep -v 'not formatted' || true
  echo "Caddy reloaded"
else
  tail -5 /tmp/caddy-validate.log >&2
  if [ -f /tmp/mail.caddy.prev ]; then mv /tmp/mail.caddy.prev "$SITES_DIR/mail.caddy"; else rm -f "$SITES_DIR/mail.caddy"; fi
  echo "Caddy config invalid; previous mail site restored, gateway not reloaded" >&2
  exit 1
fi
EOF
}

deploy_firewall() {
  echo "==> Firewall"
  ssh "$SSH_HOST" 'sudo bash -s' < firewall.sh
}

deploy_stalwart() {
  echo "==> Stalwart settings"
  need_cli
  stalwart-cli apply --file stalwart/plan.ndjson --dry-run
  stalwart-cli apply --file stalwart/plan.ndjson
  stalwart-cli create Action/ReloadSettings >/dev/null
  echo "Settings applied. Listener (port) changes only take effect after: sudo systemctl restart stalwart"
}

snapshot() {
  echo "==> Snapshot live settings -> stalwart/plan.ndjson"
  need_cli
  stalwart-cli snapshot "${SNAPSHOT_TYPES[@]}" --allow-unresolved Certificate,Tenant,Directory --quiet --output stalwart/plan.ndjson
  # The snapshot strips secret values but leaves an empty placeholder; applying it would clear the stored token.
  sed -i 's/"secret":{"@type":"Value"},//g' stalwart/plan.ndjson
  echo "Review with: git diff -- deploy/stalwart/plan.ndjson"
}

deploy_service() {
  echo "==> systemd unit + config.json (restarts Stalwart)"
  scp -q stalwart/stalwart.service stalwart/config.json "$SSH_HOST:/tmp/"
  ssh "$SSH_HOST" 'sudo bash -s' <<'EOF'
set -euo pipefail
install -o root -g root -m 0644 /tmp/stalwart.service /etc/systemd/system/stalwart.service
install -o stalwart -g stalwart -m 0600 /tmp/config.json /etc/stalwart/config.json
rm -f /tmp/stalwart.service /tmp/config.json
systemctl daemon-reload
systemctl restart stalwart
sleep 5
systemctl is-active stalwart
EOF
}

case "${1:-all}" in
  caddy)    deploy_caddy ;;
  firewall) deploy_firewall ;;
  stalwart) deploy_stalwart ;;
  snapshot) snapshot ;;
  service)  deploy_service ;;
  all)      deploy_caddy; deploy_firewall; deploy_stalwart ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
