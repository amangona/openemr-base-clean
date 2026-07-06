# Local Development Setup (Stage 1 — Run It Locally)

How this fork of OpenEMR is run locally for the AgentForge Clinical Co-Pilot project,
from a clean macOS machine to a working EHR with realistic sample patient data and a
verified FHIR R4 API. Recorded as executed on 2026-07-06 (Apple Silicon, macOS).

## Prerequisites

| Requirement | What we used | Install |
|---|---|---|
| Container runtime | Colima 0.10 (4 vCPU / 8 GB RAM / 60 GB disk VM) | `brew install colima docker docker-compose` |
| Docker CLI + Compose | Docker 29.x client, Compose 5.x (as CLI plugin) | included above; see plugin note below |
| `openemr-cmd` | 1.0.50 — OpenEMR's canonical dev CLI | see below |

Docker Desktop is not required; any Docker-compatible runtime works. With the Homebrew
CLI-only install, register Compose as a Docker CLI plugin in `~/.docker/config.json`:

```json
{ "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"] }
```

Start the VM and install `openemr-cmd`:

```sh
colima start --cpu 4 --memory 8 --disk 60

curl -fsSL https://raw.githubusercontent.com/openemr/openemr-devops/master/utilities/openemr-cmd \
  -o /opt/homebrew/bin/openemr-cmd && chmod +x /opt/homebrew/bin/openemr-cmd
```

## Bring up the stack

From the repository root:

```sh
cd docker/development-easy
openemr-cmd up          # docker compose up -d, plus HOST_UID/GID alignment
```

First boot takes several minutes: it pulls images and runs OpenEMR's full in-container
install (composer, npm, database setup). Seven containers come up: `openemr`, `mysql`
(MariaDB), `couchdb`, `openldap`, `mailpit`, `phpmyadmin`, `selenium`.

Readiness check (login page serving):

```sh
curl -s 'http://localhost:8300/interface/login/login.php?site=default' | grep -q authUser && echo READY
```

| Service | URL | Credentials |
|---|---|---|
| OpenEMR | http://localhost:8300 (https on :9300) | `admin` / `pass` |
| phpMyAdmin | http://localhost:8310 | — |
| Mailpit (dev SMTP) | http://localhost:8320 | — |

## Load sample patient data

Two sources, both used deliberately (this resolves the PRD §11 open question):

1. **Built-in demo set** — includes several *users with distinct access-control
   profiles* (physician, clinician, front office, accounting) plus patient-portal
   logins. This is what exercises the authorization model (NFR-2).

   ```sh
   openemr-cmd dev-reset-install-demodata
   ```

2. **Synthea-generated patients** — richer longitudinal clinical data (encounters,
   conditions, medications, observations) imported via CCDA; this is what makes the
   pre-visit-briefing and chart-Q&A use cases (UC-1, UC-2) realistic.

   ```sh
   openemr-cmd import-random-patients 10
   ```

## Enable and verify the FHIR R4 API

The agent integrates exclusively through OpenEMR's FHIR R4 API (see
`ARCHITECTURE.md`), so Stage 1 ends by proving that surface works:

```sh
openemr-cmd register-oauth2-client   # returns client id/secret
```

**Gotcha:** the client is registered *disabled* (`oauth_clients.is_enabled = 0`) and
must be enabled by an admin — in the UI under Administration → System → API Clients,
or directly for dev:

```sh
openemr-cmd e "mysql -u openemr -popenemr openemr \
  -e \"UPDATE oauth_clients SET is_enabled=1 WHERE client_id='<client id>';\""
```

Then exercise an endpoint (see `FHIR_README.md` and `swagger` at
`http://localhost:8300/swagger` for the full flow):

```sh
# dev-only: password grant (oauth_password_grant is enabled in the easy-dev image)
curl -sk -X POST 'https://localhost:9300/oauth2/default/token' \
  --data-urlencode 'grant_type=password' \
  --data-urlencode "client_id=$CID" --data-urlencode "client_secret=$CSEC" \
  --data-urlencode 'scope=openid api:fhir user/Patient.read' \
  --data-urlencode 'user_role=users' \
  --data-urlencode 'username=admin' --data-urlencode 'password=pass'

curl -sk 'https://localhost:9300/apis/default/fhir/Patient?_count=3' \
  -H "Authorization: Bearer $TOKEN"
```

Verified 2026-07-06: token issued (expires 3600 s), `GET /apis/default/fhir/Patient`
returns a FHIR `Bundle` of demo patients. Note the password grant is a dev-environment
convenience only — the agent will use proper authorization flows, and the grant's
default-on status is an `AUDIT.md` finding.

## Day-to-day commands

```sh
openemr-cmd stop / start     # pause/resume containers (data preserved, fast)
openemr-cmd down             # tears down INCLUDING volumes — next up = fresh install
openemr-cmd php-log          # tail PHP error log
openemr-cmd ut / at / et     # unit / api / e2e tests in-container
```

## Notes & gotchas encountered

- `openemr-cmd --version` exits non-zero by design; not a failure.
- The compose file at `docker/development-easy/docker-compose.yml` contains hardcoded
  GitHub composer tokens upstream — flagged in `AUDIT.md` (Stage 3); do not reuse them.
- Quote URLs with `?` in zsh (`curl 'http://…?site=default'`) — zsh globs `?` otherwise.
