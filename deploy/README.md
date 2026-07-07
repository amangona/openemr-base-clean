# Deploy (Stage 2 — Deploy It)

One-command deploy of the OpenEMR fork to a single cloud VM, fronted by Caddy
for automatic HTTPS. Satisfies the Stage 2 hard gate: a live, publicly reachable
URL.

**Active target: GCP Compute Engine** (`provision-gcp.sh`). The AWS variant
(`provision.sh`) is kept as a reference/fallback; the Docker Compose stack,
`Caddyfile`, and nip.io TLS are identical across both.

## What it stands up

- **GCE** `e2-standard-4` (4 vCPU / 16 GB), Ubuntu 24.04, 40 GB pd-balanced —
  per `DECISIONS.md` §15.
- **Docker stack** (`docker-compose.prod.yml`): `openemr` + `mariadb` + `caddy`.
- **HTTPS** via Caddy + Let's Encrypt on `<public-ip>.nip.io` — real cert, no
  domain purchase. Swap in a custom domain later by setting `DOMAIN`.

## Prerequisites

- `gcloud` authenticated (`gcloud auth login`) with a project set that has
  billing enabled and the Compute API on.
- SSH keys are managed automatically by `gcloud compute ssh`/`scp`.

## Run (GCP)

```sh
cd deploy
PROJECT=<your-project-id> ./provision-gcp.sh
```

The script creates the firewall rules (SSH locked to your current IP; 80/443
open) and the VM, computes the nip.io domain from the assigned public IP,
generates random secrets into `.env.prod`, ships the compose bundle to the box,
and runs `docker compose up`. `gcp-startup.sh` (VM startup-script) installs
Docker first. First boot pulls images and OpenEMR self-installs (~5–10 min).

Wait for readiness:

```sh
until curl -fsk https://<ip>.nip.io/meta/health/readyz >/dev/null; do sleep 15; done && echo LIVE
```

Login: `admin` / the `OE_PASS` value in `deploy/.env.prod` (gitignored).

Tear down: `gcloud compute instances delete agentforge-openemr --zone=us-central1-a`.

## Run (AWS — fallback)

`./provision.sh` does the equivalent on AWS EC2 (`t3.xlarge`, Amazon Linux
2023, `cloud-init.sh` as user-data). Requires `aws` configured for the target
region. Kept for portability; GCP is the active path.

## Notes

- This deploys the OpenEMR **base** as a live target. When the `copilot/` agent
  service exists, it and Langfuse are added to this compose and OpenEMR switches
  to an image built from this fork.
- Hardening applied vs the dev image: ROPC password grant disabled
  (`oauth_password_grant: 0`), random DB/admin secrets. Further hardening
  (rotated admin, least-privilege API client, encrypted disk) tracked against
  `AUDIT.md` findings.
- `.env.prod` and `*.pem` are gitignored — never commit them.
