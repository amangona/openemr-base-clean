#!/usr/bin/env bash
# AgentForge Stage 2 — provision a GCE VM and deploy the OpenEMR + Caddy stack.
# GCP analog of provision.sh. Idempotent-ish: reuses firewall rules / instance
# by name. Requires: gcloud authenticated, project set, Compute API enabled,
# run from this deploy/ directory.
#
# Usage:  cd deploy && ./provision-gcp.sh
# Output: the live HTTPS URL once OpenEMR reports healthy.
set -euo pipefail

# ---- config (override via env) ----
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${ZONE:-us-central1-a}"
MACHINE="${MACHINE:-e2-standard-4}"          # 4 vCPU / 16 GB, ~ t3.xlarge
DISK_GB="${DISK_GB:-40}"
NAME="${NAME:-agentforge-openemr}"
TAG="agentforge"
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2404-lts-amd64}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
g() { gcloud --project="$PROJECT" "$@"; }

say "Project: $PROJECT  Zone: $ZONE  Machine: $MACHINE"
g compute networks list --format='value(name)' >/dev/null   # auth/API preflight

# ---- firewall (web open; SSH from this host's IP) ----
if ! g compute firewall-rules describe "${TAG}-allow-web" >/dev/null 2>&1; then
  say "Creating firewall rule ${TAG}-allow-web (tcp:80,443 from anywhere)"
  g compute firewall-rules create "${TAG}-allow-web" \
    --direction=INGRESS --action=ALLOW --rules=tcp:80,tcp:443 \
    --target-tags="$TAG" --source-ranges=0.0.0.0/0 >/dev/null
fi
MYIP=$(curl -fsSL https://checkip.amazonaws.com | tr -d '[:space:]')
if ! g compute firewall-rules describe "${TAG}-allow-ssh" >/dev/null 2>&1; then
  say "Creating firewall rule ${TAG}-allow-ssh (tcp:22 from ${MYIP}/32)"
  g compute firewall-rules create "${TAG}-allow-ssh" \
    --direction=INGRESS --action=ALLOW --rules=tcp:22 \
    --target-tags="$TAG" --source-ranges="${MYIP}/32" >/dev/null
else
  say "Updating ssh firewall source to ${MYIP}/32"
  g compute firewall-rules update "${TAG}-allow-ssh" --source-ranges="${MYIP}/32" >/dev/null || true
fi

# ---- create instance ----
if ! g compute instances describe "$NAME" --zone="$ZONE" >/dev/null 2>&1; then
  say "Creating instance $NAME"
  g compute instances create "$NAME" \
    --zone="$ZONE" --machine-type="$MACHINE" \
    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="${DISK_GB}GB" --boot-disk-type=pd-balanced \
    --tags="$TAG" \
    --metadata-from-file=startup-script=gcp-startup.sh \
    --labels=project=agentforge >/dev/null
else
  say "Instance $NAME already exists — reusing"
fi

PUBLIC_IP=$(g compute instances describe "$NAME" --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
DOMAIN="${PUBLIC_IP//./-}.nip.io"
say "Public IP $PUBLIC_IP  ->  https://$DOMAIN"

# ---- render .env.prod (random secrets) ----
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; }
cat > .env.prod <<EOF
DOMAIN=${DOMAIN}
MYSQL_ROOT_PASSWORD=$(gen)
MYSQL_PASS=$(gen)
OE_PASS=$(gen)
EOF
say "Wrote .env.prod (admin password is OE_PASS — gitignored, keep safe)"

# ---- wait for host to finish the startup-script (docker installed) ----
say "Waiting for SSH + docker install (startup-script)"
for i in $(seq 1 60); do
  if g compute ssh "$NAME" --zone="$ZONE" --command='test -f /opt/agentforge/.host-ready && docker --version' >/dev/null 2>&1; then
    break
  fi
  sleep 10
done

# ---- deliver bundle + bring up the stack ----
say "Copying deploy bundle"
g compute scp --zone="$ZONE" docker-compose.prod.yml Caddyfile .env.prod "$NAME":~ >/dev/null
g compute ssh "$NAME" --zone="$ZONE" --command='sudo cp ~/docker-compose.prod.yml ~/Caddyfile ~/.env.prod /opt/agentforge/'
say "Starting stack (docker compose up)"
g compute ssh "$NAME" --zone="$ZONE" \
  --command='cd /opt/agentforge && sudo docker compose --env-file .env.prod -f docker-compose.prod.yml up -d'

say "Deployed. OpenEMR self-installs on first boot (~5-10 min)."
echo
echo "  Instance : $NAME ($ZONE)"
echo "  SSH      : gcloud compute ssh $NAME --zone=$ZONE"
echo "  URL      : https://$DOMAIN   (admin / see OE_PASS in .env.prod)"
echo "  Health   : curl -sk https://$DOMAIN/meta/health/readyz"
echo
echo "Poll readiness:"
echo "  until curl -fsk https://$DOMAIN/meta/health/readyz >/dev/null; do sleep 15; done && echo LIVE"
