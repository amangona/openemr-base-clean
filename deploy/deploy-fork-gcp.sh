#!/bin/bash
# Deploy the 8.2.0-dev fork FROM SOURCE onto the GCE instance, fronted by Caddy
# for HTTPS, and load demo + Synthea patients. Run ON the VM as root:
#
#   gcloud compute scp deploy/deploy-fork-gcp.sh agentforge-openemr:~ --zone=us-central1-a
#   gcloud compute ssh agentforge-openemr --zone=us-central1-a \
#     --command='sudo bash ~/deploy-fork-gcp.sh <ip-with-dashes>.nip.io'
#
# This is the ACTIVE deployment path: it serves the fork's actual source via the
# flex image (version-matched to local dev + AUDIT.md), unlike the stock-image
# docker-compose.prod.yml (kept as a slim reference). Idempotent-ish.
set -euxo pipefail

DOMAIN="$1"                                   # e.g. 35-238-138-105.nip.io
FORK_URL="${FORK_URL:-https://github.com/amangona/openemr-base-clean.git}"
FORK_DIR="${FORK_DIR:-/opt/openemr-fork}"
DE="$FORK_DIR/docker/development-easy"

# 1. Tear down any prior stock prod stack (safe if absent/empty).
if [ -f /opt/agentforge/docker-compose.prod.yml ]; then
  (cd /opt/agentforge && docker compose --env-file .env.prod -f docker-compose.prod.yml down -v) || true
fi

# 2. Tooling + fork source (apache in the flex image is uid 1000; match it).
apt-get update && apt-get install -y git
rm -rf "$FORK_DIR"
git clone --depth 1 "$FORK_URL" "$FORK_DIR"
chown -R 1000:1000 "$FORK_DIR"

# 3. Caddy override + Caddyfile (HTTPS front for the dev-easy openemr container).
cat > "$DE/docker-compose.caddy.yml" <<'YAML'
services:
  caddy:
    image: caddy:2
    restart: always
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile.deploy:/etc/caddy/Caddyfile:ro
      - caddydata:/data
      - caddyconfig:/config
    environment:
      DOMAIN: "${DOMAIN}"
    depends_on: [openemr]
volumes:
  caddydata: {}
  caddyconfig: {}
YAML
cat > "$DE/Caddyfile.deploy" <<'CADDY'
{$DOMAIN} {
	reverse_proxy https://openemr:443 {
		transport http { tls; tls_insecure_skip_verify }
		header_up Host {upstream_hostport}
		header_up X-Forwarded-Proto https
	}
}
CADDY

# 4. Bring up the stack (flex builds 8.2.0-dev from source; ~15-20 min first boot).
cd "$DE"
export DOMAIN
docker compose -f docker-compose.yml -f docker-compose.caddy.yml up -d

# 5. Wait for the app to finish building/installing.
for i in $(seq 1 120); do
  if curl -fsk --max-time 8 "https://${DOMAIN}/meta/health/readyz" >/dev/null 2>&1; then break; fi
  sleep 15
done

# 6. Load demo data + 10 Synthea patients (devtools ship in the flex image).
docker exec development-easy-openemr-1 /root/devtools dev-reset-install-demodata
docker exec development-easy-openemr-1 /root/devtools import-random-patients 10

echo "DEPLOYED: https://${DOMAIN}  (admin/pass — rotate before real use, see AUDIT.md)"
