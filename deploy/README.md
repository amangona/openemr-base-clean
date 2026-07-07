# Deploy (Stage 2 — Deploy It)

One-command deploy of the OpenEMR fork to a single EC2 instance, fronted by
Caddy for automatic HTTPS. Satisfies the Stage 2 hard gate: a live, publicly
reachable URL.

## What it stands up

- **EC2** `t3.xlarge` (4 vCPU / 16 GB), Amazon Linux 2023, 40 GB gp3 — per
  `DECISIONS.md` §15.
- **Docker stack** (`docker-compose.prod.yml`): `openemr` (stock
  `openemr/openemr:latest`) + `mariadb` + `caddy`.
- **HTTPS** via Caddy + Let's Encrypt on `<public-ip>.nip.io` — real cert, no
  domain purchase. Swap in a custom domain later by setting `DOMAIN`.

## Prerequisites

- `aws` CLI configured for `us-east-1` (`aws configure`).
- An SSH keypair is created automatically (`~/.ssh/agentforge-key.pem`).

## Run

```sh
cd deploy
./provision.sh
```

The script: creates the key pair + security group (SSH locked to your current
IP; 80/443 open), launches the instance, computes the nip.io domain from the
assigned public IP, generates random secrets into `.env.prod`, and copies the
compose bundle to the box. `cloud-init.sh` (EC2 user-data) installs Docker and
runs `docker compose up`. First boot pulls images and OpenEMR self-installs
(~5–10 min).

Then wait for readiness:

```sh
until curl -fsk https://<ip>.nip.io/meta/health/readyz >/dev/null; do sleep 15; done && echo LIVE
```

Login: `admin` / the `OE_PASS` value in `deploy/.env.prod` (gitignored).

## Notes

- This deploys the OpenEMR **base** as a live target. When the `copilot/` agent
  service exists, it and Langfuse are added to this compose and OpenEMR switches
  to an image built from this fork.
- Hardening applied vs the dev image: ROPC password grant disabled
  (`oauth_password_grant: 0`), random DB/admin secrets. Further hardening
  (rotated admin, least-privilege API client, encrypted volume) tracked against
  `AUDIT.md` findings.
- `.env.prod` and `*.pem` are gitignored — never commit them.
- Tear down: `aws ec2 terminate-instances --instance-ids <id>` (data is on the
  instance's EBS volume; back up first if needed).
