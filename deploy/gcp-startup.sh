#!/bin/bash
# GCE startup-script (metadata) — installs Docker + Compose. Runs as root on
# first boot (Ubuntu 24.04). The compose bundle is delivered by provision-gcp.sh
# after boot; this only prepares the host. Logs: /var/log/syslog (google_metadata_script_runner).
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git docker.io
systemctl enable --now docker

# Docker Compose v2 plugin
DOCKER_CLI_PLUGINS=/usr/local/lib/docker/cli-plugins
mkdir -p "$DOCKER_CLI_PLUGINS"
curl -fsSL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-$(uname -m)" \
  -o "$DOCKER_CLI_PLUGINS/docker-compose"
chmod +x "$DOCKER_CLI_PLUGINS/docker-compose"

mkdir -p /opt/agentforge
# Signal readiness for provision-gcp.sh to poll.
touch /opt/agentforge/.host-ready
