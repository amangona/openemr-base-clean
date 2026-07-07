# AgentForge Clinical Co-Pilot — System Audit (AUDIT.md)

**System audited:** this fork of OpenEMR 8.2.0-dev, as configured by its
`docker/development-easy` stack (the base we build the Clinical Co-Pilot on).
**Method:** primary evidence — source read at `file:line`, live SQL against the
running MariaDB, and measured HTTP latency against the FHIR R4 API on the local
stack. **Owner:** Abe Mangona · **Date:** 2026-07-06.

> Stage 3 hard-gate deliverable. Traces to `PRD.md` §9 (the system we build on)
> and feeds `ARCHITECTURE.md`. Findings are the OpenEMR base as-is: the fork has
> no code changes yet (`git diff` from the import commit touches only docs), so
> every finding is upstream behavior or configuration, and the agent design in
> `ARCHITECTURE.md` is what must account for it.

---

## Executive Summary

OpenEMR gives us a workable, standards-based foundation — a certified FHIR R4 /
US Core / SMART-on-FHIR surface, default-on tamper-evident audit logging, and a
stateless API tier — but five findings dominate the design of the agent and are
the ones we defend.

**1. FHIR authorization is not patient-bound for provider tokens (Critical,
security).** OpenEMR enforces authorization as *scope-presence + the backing
user's ACL*, and only row-binds data to one patient for `patient`-role tokens or
an explicit SMART `launch/patient` context (`AuthorizationListener.php:189-207`;
`BearerTokenAuthorizationStrategy.php:224-231`). A `user/*.read` token — which
the dev stack already provisions — is unconstrained; if that user is the default
`admin` (an Administrators-group superuser), it reads *every* patient. This
directly shapes NFR-2: the agent must authenticate as a **dedicated, non-admin,
least-privilege service account** using **`patient/*.read` scopes with a
`launch/patient` context**, so the API itself — not the prompt — binds every
read to one patient.

**2. Unbounded FHIR reads blow the latency budget (High, performance).** There is
no default page size (`SearchQueryConfig.php:52`); an unfiltered
`Observation?patient=X` on a realistic Synthea patient returns **10.2 MB / ~8,400
resources in 4.4 s**, and `_count` trims the wire but *not* server work. Clinical
filters (`category`, `date`, `code`) are 4–17× faster, and parallelizing a
6-endpoint briefing drops it from 2.06 s to **1.01 s** (no session
serialization). The agent's tools must always filter and must fan out
concurrently to hit the <10 s briefing / <2–3 s first-token targets.

**3. The sample data is full of agent traps (High, data quality).** Absence ≠
negation: the entire database has **one** allergy row, so "no allergies" is
usually "not recorded." Lab result dates are all `0000-00-00` (real dates live in
`procedure_report.date_collected`), ~30% of lab results are literal
`{entry.value}` import garbage, problem lists are ~71% duplicate rows, and
`active` status flags are unreliable (688 "active" problems have a past end
date). The agent must defensively dedupe, derive activeness from dates, source
lab dates correctly, and phrase absence as "not documented."

**4. Sending PHI to the LLM requires a BAA + zero-retention, and the model choice
matters (High, compliance).** Every invocation ships full PHI (prompt content +
tool results) to Anthropic, making it a business associate: a signed BAA is a
precondition, and "no training" ≠ "no retention" — an explicit zero-data-
retention (ZDR) arrangement is needed. Critically, **Claude Fable 5 requires
30-day retention and is unavailable to ZDR orgs**, so our chosen **Opus 4.8 +
Haiku 4.5** stack (`DECISIONS.md` §6) is the compliant one — this is a
constraint to hold, not change. Self-hosted Langfuse keeps traces in-infra *only
if* treated as a PHI system (RBAC, encryption, retention).

**5. The integration surface is clean and needs zero core changes (Architecture).**
The agent runs as a standalone `copilot/` service talking only to
`/apis/default/fhir/*` over OAuth2; the API tier is effectively stateless behind
MariaDB (tokens resolve via the `api_token` table), which is also our
MariaDB→RDS / agent→ECS scaling story. The FHIR API is read-mostly (only
Patient/Practitioner/Organization accept writes) — irrelevant to us because the
agent is read-only by design.

**Cross-cutting must-fix hygiene before any real PHI:** a hardcoded GitHub PAT is
committed in `docker-compose.yml:75-77`, the ROPC password grant is on
(`oauth_password_grant=3`), and default `admin/pass` works — all dev-image
defaults our production deploy already begins to harden (`deploy/`), and all
disqualifying if carried forward.

---

## 1. Security Audit

Authorization, data exposure, and PHI-handling risks in the OpenEMR base,
weighted toward the FHIR R4 + OAuth2 surface the agent depends on. Positive
finding up front: the fork introduces **no** custom code on the auth/API path
(`git log`: one import commit + docs), so the surface is upstream OpenEMR, and
core primitives are sound — bcrypt/argon2 password hashing
(`AuthHash.php:47-66`), PKCE enforced **S256-only** (`CustomAuthCodeGrant.php:53`,
`:253-266`), and DB-backed bearer-token revocation checks
(`BearerTokenAuthorizationStrategy.php:141-195`).

| # | Sev | Finding | Evidence | Remediation |
|---|-----|---------|----------|-------------|
| S-1 | **Critical** | `user/*` and `system/*` FHIR scopes are **not patient-bound**; authz = scope-presence + backing-user ACL. An `admin`-backed `user/*` token reads the whole database. | `AuthorizationListener.php:189-207` (scope-presence check only); patient binding only at `BearerTokenAuthorizationStrategy.php:224-231` (patient role) / `:440-449` (`launch/patient`). Live: one enabled client holds the full `user/*` scope set; `admin` ∈ Administrators. | Agent uses a **non-admin least-privilege service account** + **`patient/*.read` scopes + `launch/patient`** so the API row-binds to one patient. Never rely on `user/*`. Treat "scope present" as necessary, not sufficient. |
| S-2 | **Critical** | Live GitHub PAT committed in compose. | `docker/development-easy/docker-compose.yml:75-77` — `GITHUB_COMPOSER_TOKEN` + base64 `ghp_…` copy. | Revoke at GitHub, purge from file + history, inject via untracked secret. Unused by the agent — remove. |
| S-3 | High | ROPC password grant enabled for providers **and** patients (`=3`). | `globals.gl_value=3` (live); set at `docker-compose.yml:84`; wired `AuthorizationController.php:736-748`. | Agent uses auth-code+PKCE (or client-credentials/JWT). Deploy sets `oauth_password_grant=0` (done in `deploy/docker-compose.prod.yml`). |
| S-4 | High | Default `admin/pass` works; via S-3 that's a one-POST full-scope admin token. | `docker-compose.yml:66-67`; login verified. Hashing itself is sound. | Rotate on deploy (random `OE_PASS`, done); dedicated service account for the agent. |
| S-5 | High | FHIR + OAuth served over plaintext HTTP (`:8300`), no redirect to TLS. | `curl http://…/fhir/metadata` → 200; `…/.well-known/openid-configuration` → 200. | Agent talks only to `https://`. Deploy terminates TLS at Caddy and should force HTTP→HTTPS. |
| S-6 | Medium | Refresh tokens live **3 months** (access tokens 1 h). | `AuthorizationController.php:110-111`, applied `:718-733`. | Store refresh tokens encrypted, rotate on use, support revocation; prefer short-lived per-session tokens. |
| S-7 | Medium | Prompt-injection surface: untrusted free-text PHI the agent reads. | Live schema: `pnotes.body`, `form_soap`, `form_dictation`, `form_clinical_notes`, `form_encounter.reason`, `history_data.*`, surfaced via FHIR DocumentReference/Observation/Condition/Encounter. | Treat record free-text as data, never instructions; delimit in prompts; **API-level patient binding (S-1 fix) is the backstop that makes injection non-catastrophic.** |
| S-8 | Info (good) | Dynamic-registration auto-disables clients requesting `user/`/`system/` scopes (manual admin approval). | `ClientRepository.php:78-88`; `ScopeRepository.php:334-359`. | Keep on. Register the agent client with the **narrowest** scopes (ideally `patient/*.read` + `launch/patient`) so it auto-enables without a broad grant. |

**Implication for the agent:** S-1 is the load-bearing finding. NFR-2 ("authz at
the tool/API layer, never the prompt") is satisfiable *only* by the
patient-bound service-account + `launch/patient` pattern, backed by a
least-privilege ACL, over HTTPS, with every clinical free-text field treated as
untrusted.

## 2. Performance Audit

Measured on the dev stack (Colima VM, opcache off in the dev image); absolute
times differ in prod but the N+1 shapes and unbounded-query behavior are
structural. Full method and per-endpoint table in the working notes; headline
numbers below.

| # | Sev | Finding | Evidence |
|---|-----|---------|----------|
| P-1 | High | **No default page size.** `Observation?patient=X` on a heavy patient = **10.2 MB / ~8,400 resources / 4.4 s**. | `SearchQueryConfig.php:52`, `SearchConfigClauseBuilder.php:55-58` (LIMIT only if `_count>0`). |
| P-2 | High | `_count` trims the wire but **not** server work — `_count=10` on heavy Observation still 4.1–4.4 s. Clinical filters do the real work: `category=vital-signs` 0.26 s (17×), `date=ge2025-01-01` 0.94 s (4.5×), `code=` 0.36 s. | `ProcessingResult.php:118-124` (post-hoc trim); measured. |
| P-3 | Medium | **N+1 in MedicationRequest:** 670 SQL queries for 28 prescriptions (~24/row) — per-row `new FhirOrganizationService()` re-fetches the constant primary org + re-runs schema introspection. | `FhirMedicationRequestService.php:453-454`, `FacilityService.php:91`; MariaDB general-log trace. |
| P-4 | Medium | Observation fans out to 10 sub-services; vitals path runs one `uuid_mapping` query per row. `category` prunes it (4.4 s → 0.26 s). | `FhirObservationService.php:64-73`, `FhirObservationVitalsService.php:448/526/599`. |
| P-5 | Medium | **Fixed ~170–210 ms bootstrap tax per request**: full 526-row globals reload, RSA JWT verify + 5–7 DB lookups, an audit INSERT, ~14 UuidRegistry sweeps, a session per request. | `ApiApplication.php:76-103`, `interface/globals.php:450`, `BearerTokenAuthorizationStrategy.php:141-341`. |
| P-6 | Low | Zero HTTP caching (`Cache-Control: no-cache`, no ETag, `Connection: close`); no server-side query cache; opcache only in release image. | Response headers; `docker/release/php.ini`. |
| P-7 | Info (good) | DB layer is fine at scale — every agent-hit table is indexed on its patient-filter column + `uuid`. Bottlenecks are in PHP, not indexes. | `SHOW INDEX` across `lists`, `prescriptions`, `form_encounter`, `procedure_*`, `patient_data`. |

**Implication for the agent (design constraints):** (1) **never** issue an
unfiltered Observation — always scope by `category`+`date`/`code`; (2)
**parallelize** tool calls (measured 6-endpoint briefing 2.06 s → 1.01 s); (3)
**cache within a session** (server memoizes nothing); (4) **pre-warm and refresh
the OAuth token** (0.47 s to mint; the expiry 401 is a misleading generic
"denied" — retry, don't treat as a permissions error); (5) summarize/truncate
payloads agent-side before the model context. If prod volumes degrade
MedicationRequest/vitals, the fix is a localized fork patch (hoist the org
lookup; push a default `_count` into SQL).

## 3. Architecture Audit

**Layering.** OpenEMR is two eras in one tree: modern `/src` (PSR-4, Symfony,
strict types) and legacy `/library` (procedural, globals). Crucially the **API
tier is entirely modern** — `apis/dispatch.php` builds a Symfony `HttpKernel`
with a subscriber chain (`ApiApplication.php:71-123`): site setup → CORS →
OAuth2 auth → ACL → route dispatch → view render. The legacy UI never touches
this path.

**Data flow (agent's path):**
```
copilot/ (TS/Node)  ──OAuth2──▶  /oauth2/default/*   (auth server, in-app)
                    ──FHIR────▶  /apis/default/fhir/* ──▶ ApiApplication
                                   (auth → ACL → route)
                                 FhirXRestController ──▶ FhirXService
                                   parseOpenEMRRecord(): DB row → FHIR
                                 ──▶ MariaDB (patient_data, lists, form_encounter,
                                     prescriptions, procedure_*, uuid_registry,
                                     api_token, oauth_clients)
```
FHIR UUIDs map onto legacy integer PKs via `uuid_registry` /
`UuidRegistry` (services lazily backfill). Condition and AllergyIntolerance both
derive from the `lists` table by `type` (`ConditionService.php:27`).

**Integration surface (what we depend on).** Routes in `_rest_routes.inc.php` →
`apis/routes/_rest_routes_fhir_r4_us_core_3_1_0.inc.php`; base URL
`https://host/apis/default/fhir`; conformance FHIR R4 / US Core 8.0 / SMART v2.2 /
Bulk Data 1.0. Read/search available for all resources the agent needs (Patient,
Condition, AllergyIntolerance, MedicationRequest, Observation, Encounter,
DocumentReference, Immunization, …). The API is **read-mostly** (only Patient/
Practitioner/Organization accept POST/PUT) — a non-issue since the agent is
read-only. Auth server is in-app (`OAuth2AuthorizationListener.php:124-182`):
authorization_code+PKCE, refresh, client_credentials+JWKS, and (gated) password;
every bearer token resolves via `api_token` to user+client+scopes, so the API
holds no in-memory auth state.

**Extension mechanisms we deliberately don't need:** module system
(`ModulesApplication.php`), Symfony EventDispatcher, `RestApiCreateEvent`. The
agent requires **zero PHP changes** — dynamic client registration + FHIR is a
fully external, supported surface, keeping the fork rebasable against upstream.

**Scaling inputs (interview narrative):** API tier is **stateless behind
MariaDB** (`SessionCleanupListener`, `ApiApplication.php:85`); only the legacy UI
uses PHP sessions (optional Redis handler, `SessionUtil.php:44-58`). So
MariaDB→RDS is clean (single mandatory datastore; CouchDB optional), agent→ECS as
its own service, all in one VPC (PHI never leaves).

**Risks:** (A-1) read-mostly API means any future write path needs the
proprietary REST API or a module — keep the agent read-only; (A-2) UUID/pid
duality needs an explicit mapping layer if surfaces are ever mixed; (A-3)
hand-maintained route closures shift on upstream rebase — discover capabilities
at runtime from `/fhir/metadata`, don't hardcode; (A-4) self-signed dev TLS —
agent uses `https://` and handles the internal cert.

## 4. Data Quality Audit

All numbers from live SQL (13 patients: pids 1–3 built-in demo, 4–13 Synthea).
Integrity is clean: 0 orphaned rows, 0 forms without an encounter, **UUID
coverage 100%** across all 8 resource tables, 0 duplicate patients, 0 future-
dated encounters. The problems are completeness and consistency, and each is a
concrete agent failure mode.

| Resource | Count | Key gaps that bite the agent |
|----------|-------|------------------------------|
| Patients | 13 | phone/email 2/13 (demo only); pid 3 near-empty (blank race/lang/address); Synthea names carry numeric suffixes ("Curtis94"). |
| Allergies | **1 row total** | 12/13 patients have zero rows — "no known allergies" vs "not recorded" is indistinguishable. |
| Problems | 814 rows / ~241 distinct | **71% duplicates** (one patient: 101 copies of "Medication review due"); 60% are social `(finding)`/`(situation)` noise, not `(disorder)`. |
| Medications / Rx | 69 / 65 | `active=1` on all; 64/65 have NULL `start_date`; demo meds are free-text brand names, no codes. |
| Labs (procedure_result) | 14,960 | **date = `0000-00-00` on all** (real date in `procedure_report.date_collected`); **~30% are `{entry.value}` template garbage**; **0 reference ranges, 0 abnormal flags**. |
| Vitals | 13 (one row/patient ever) | Cannot trend; Synthea height in cm imported into an inches field (naive BMI → 15-foot patient); BP/weight NULL for Synthea. |
| Encounters | 1,011 | Demo charts frozen at 2014-02-01 (stale for "what changed"); Synthea recent through 2026. |
| Immunizations | 148 | Synthea only; demo = 0. |

**Coding is inconsistent across resource types:** problems `SNOMED-CT:…`, demo
`ICD9:…`, medication lists **bare** `866412` (no `RXNORM:` prefix) — a single
parser breaks.

**Agent must defensively:** (1) treat absence as "not documented," never "none";
(2) get lab dates from `procedure_report.date_collected` and drop
`{entry.value}`/`UNK` results; (3) ignore `active` flags, derive activeness from
`enddate`; (4) dedupe problems on (title, code) and prioritize `(disorder)`; (5)
state that no reference ranges exist rather than judge normality; (6) strip
numeric suffixes from Synthea names; (7) flag chart staleness before "what
changed."

**Demo-worthy patients for UC-1/UC-2:** **pid 5** (Curtis94 Schamberger479 —
23 distinct problems incl. MI/CABG, 16 coded meds, encounters through 2025-10,
manageable size) as the primary; **pid 4** (415 encounters incl. an ER admit
dated today, 6,033 labs) to demo dedup + "what changed"; **pid 3** as the
empty-chart edge case. Avoid demo pids 1–3 for labs (they have none).

## 5. Compliance & Regulatory Audit (HIPAA)

Assessed against the Security Rule (§164.302–318), Privacy Rule minimum-necessary
(§164.502(b)), Breach Notification (§§164.400–414), and BAA requirements
(§164.504(e)). The base provides a real §164.312(b) substrate — default-on audit
logging (`enable_auditlog=1`, live) writing who/what/when/patient to `log` with
per-entry SHA3-512 tamper checksums (`LogTablesSink.php:63-95`), plus full API
request/response capture in `api_log` (`api_log_option=2`) — but runtime drift
and the new LLM path need work.

| # | Sev | Finding | Evidence | Remediation |
|---|-----|---------|----------|-------------|
| C-1 | High | The Synthea/CCDA import **disables audit logging site-wide and isn't crash-safe** — a mid-import crash leaves auditing off with nothing flagging it. | `import_ccda.php:150-153` (`UPDATE globals SET gl_value=0 … enable_auditlog`), truncates `audit_master/details`, restore only at `:243-244` (not `finally`). | Dev-only tool; add a post-import check that `enable_auditlog=1`; never run against real PHI. |
| C-2 | High | **SELECT-query auditing is off** in the live instance despite a default of on — read access (the main snooping concern) partly unlogged. | `audit_events_query` blank in live `globals`; default `'1'` at `globals.inc.php:2832`. | Set `audit_events_query=1` in prod; add a startup check. |
| C-3 | High | **No data-retention/disposal capability**, yet `api_log` stores full FHIR request+response **PHI bodies** in plaintext `longtext`. | no retention globals/jobs; `sql/database.sql:101-102`. | Written retention schedule (audit ≥6 yr, §164.316(b)(2)(i)); treat `api_log` + Langfuse traces as PHI stores (encrypt, restrict, set retention). |
| C-4 | Medium | At-rest encryption partial (fields/documents yes, core clinical tables plaintext); dev DB "TLS" uses **repo-committed certs**. | `CryptoGen.php:188-195`; `docker/library/sql-ssl-certs-keys/easy/*`. | Prod: encrypted volumes/TDE + unique certs (deployment checklist). |
| C-5 | Medium | Audit **attribution breaks** for agent access — `api_log.user_id` = service account, not the clinician who asked. | `api_log` schema; live rows from Stage-1 verification. | Agent's own append-only invocation log: `{correlation_id, clinician_user, patient_id, tools, sources}`, joinable to `api_log` by client+timestamp. |
| C-6 | Medium | Breach **detection is passive** — good forensics, zero alerting; a runaway/injected agent enumerating charts would go unnoticed. | ATNA export off; no anomaly rules. | Rate/volume alerts on the agent's OAuth client; periodic log-review procedure (§164.308(a)(1)(ii)(D)). |

**BAA & PHI-to-LLM (the novel part).** Every invocation ships PHI to Anthropic
(prompt content + every `tool_result` re-sent each turn), making Anthropic a
**business associate** — a signed BAA is a precondition, not optional. "No
training" (already the commercial API default) is **not** "no retention": under
standard terms, prompts may be retained ~30 days for trust-and-safety, so an
explicit **zero-data-retention (ZDR)** arrangement is required. **Model
constraint:** Claude Fable 5 requires 30-day retention and errors for ZDR orgs;
**our `DECISIONS.md` §6 choice of Opus 4.8 + Haiku 4.5 is ZDR-compatible** —
this is a compliance constraint to *preserve* (don't "upgrade" to Fable 5 for
the clinical path). Alternative procurement: Claude via AWS Bedrock / GCP Vertex
under those platforms' BAAs. Residual risks to document in the §164.308(a)(1)
risk analysis: transient provider-side processing, abuse-detection metadata,
config drift (a key created outside the ZDR-scoped org silently loses the
posture — pin the org, audit keys), and prompt-injection causing over-fetch of
PHI into prompts (minimum-necessary applies to what we *put in* the prompt).

**Langfuse** keeps PHI in-infra *only if* treated as a PHI system in its own
right: its traces will contain full prompts/completions, so it needs authn/RBAC
(no shared viewer logins), encryption at rest for its Postgres/ClickHouse/blob
store, TLS, a configured trace-retention window, telemetry/export disabled, and
inclusion in backup/DR and breach-scope procedures.

---

## Traceability & What the Agent Must Build

The audit converts into concrete, defended requirements for `ARCHITECTURE.md`:

1. **Auth:** dedicated non-admin service account, `patient/*.read` + `launch/patient`, auth-code+PKCE, HTTPS only (S-1, S-3, S-4, S-5).
2. **Tools:** always-filtered FHIR reads (category/date/code), concurrent fan-out, session cache, pre-warmed token (P-1..P-5).
3. **Verification/data:** absence≠negation, correct lab-date sourcing, garbage/duplicate filtering, activeness from dates, no invented reference ranges (§4).
4. **Trust boundary:** record free-text is untrusted (S-7); PHI-to-LLM under BAA+ZDR on Opus 4.8/Haiku 4.5; Langfuse hardened as a PHI system (C-*).
5. **Audit trail:** agent invocation log (correlation ID, clinician, patient, tools, sources) as the only record of the human principal (C-5); runtime audit-config checks (C-1, C-2).

*Sources: security, performance, architecture, data-quality, and compliance
sub-audits (2026-07-06), each grounded in source `file:line`, live SQL, and
measured latency. Cross-cutting hygiene (committed PAT, password grant, default
creds) is remediated in `deploy/` for the Stage-2 target.*
