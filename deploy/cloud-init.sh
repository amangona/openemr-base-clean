#!/bin/bash
# EC2 user-data — bootstraps Docker and brings up the OpenEMR + Caddy stack.
# Runs as root on first boot (Amazon Linux 2023). Logs to /var/log/cloud-init-output.log.
set -euxo pipefail

# --- Docker + Compose plugin ---
dnf -y update
dnf -y install docker git
systemctl enable --now docker
DOCKER_CLI_PLUGINS=/usr/local/lib/docker/cli-plugins
mkdir -p "$DOCKER_CLI_PLUGINS"
curl -fsSL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-$(uname -m)" \
  -o "$DOCKER_CLI_PLUGINS/docker-compose"
chmod +x "$DOCKER_CLI_PLUGINS/docker-compose"

# --- Deploy files are dropped by provision.sh into /opt/agentforge before/after boot ---
APP=/opt/agentforge
mkdir -p "$APP"

# Wait until provision.sh has scp'd the compose bundle + .env.prod (public IP known only post-launch).
for i in $(seq 1 60); do
  [ -f "$APP/docker-compose.prod.yml" ] && [ -f "$APP/.env.prod" ] && break
  sleep 5
done

cd "$APP"
docker compose --env-file .env.prod -f docker-compose.prod.yml up -d
