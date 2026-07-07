# AgentForge Clinical Co-Pilot — Pre-Search Checklist Decisions

Decision record for the Week 1 project, produced by working through the PRD appendix
("Pre-Search Checklist") on 2026-07-06. Each decision is binding unless explicitly
revisited; deviations should be recorded here with a date and rationale.

Repos:
- Planning: `~/dev/gauntlet/agentforge` (this repo)
- Submission fork: [`amangona/openemr-base-clean`](https://github.com/amangona/openemr-base-clean) (upstream: `Gauntlet-HQ/openemr-base-clean`), cloned at `~/dev/gauntlet/openemr-base-clean`

---

## Phase 1 — Constraints

### 1. Domain Selection

| Question | Decision |
|---|---|
| Use cases | (1) Pre-visit patient briefing, (2) chart Q&A with citations, (3) medication reconciliation support. Nothing else in week 1. |
| Verification requirements | Every factual claim cites a specific FHIR resource; uncited claims are stripped or visibly flagged; allergy/medication conflicts checked mechanically from structured data. |
| Data sources | OpenEMR only, via its FHIR R4 API: Patient, Encounter, Condition, MedicationRequest, AllergyIntolerance, Observation, Immunization, DocumentReference. Closed world — no external sources. |

### 2. Scale & Performance

- **Latency targets:** first visible output < 2–3 s (streaming mandatory); complete briefing < 10 s. Driven by the 90-seconds-between-rooms scenario.
- **Concurrency:** load-tested at 10 and 50 concurrent users (graded requirement); design stateless so the "300 concurrent clinicians" interview answer is a scaling story, not a rewrite.
- **Cost ceiling:** single-digit cents per interaction; token usage logged per request from day one to feed the cost-analysis deliverable (100 / 1K / 10K / 100K users).

### 3. Reliability Requirements

- **Cost of a wrong answer:** maximal — potential patient harm. Verification sits *in the response path*, not alongside it.
- **Non-negotiable:** source attribution on every claim; authorization enforced at the tool/API layer (OAuth2 scopes + OpenEMR ACLs), never by the prompt; refusal on unauthorized or unanswerable queries.
- **Human-in-the-loop:** the physician is the loop. The agent is **strictly read-only** — it never writes to the chart, never recommends dosing, never diagnoses.
- **Audit:** every invocation logged with correlation ID, user identity, patient accessed, tools called, sources returned.

### 4. Team & Skill Constraints

- **Stack comfort:** TypeScript / Node (Abe's choice).
- Implication: Zod for schema contracts, official `@anthropic-ai/sdk`.

---

## Phase 2 — Architecture Discovery

### 5. Agent Framework

**Decision: plain `@anthropic-ai/sdk` with a hand-written (manual) tool loop.** Single agent, no multi-agent.

- Rationale: the verification layer is the core differentiator and must live *inside* the loop (intercept every response before display). Frameworks (LangGraph, Vercel AI SDK, SDK tool runner) put the loop behind an abstraction.
- State: conversation history keyed to (physician, patient, session), server-side.
- Rejected: multi-agent (no use case requires it — indefensible under "capability must trace to a use case").

### 6. LLM Selection

**Decision: Claude Opus 4.8 (`claude-opus-4-8`) for the main agent + Claude Haiku 4.5 (`claude-haiku-4-5`) for the verification pass.**

- Rationale: best-in-class tool use and instruction following for a safety-critical domain; strict structured outputs (`strict: true` tools) underpin the verification design; case study directs us to act as if a BAA (no-training) exists with the LLM provider.
- Pricing basis (2026-07): Opus 4.8 $5/$25 per MTok, Haiku 4.5 $1/$5. Typical briefing (~10K in / 1K out) ≈ $0.08. Two-tier design is the cost-analysis story.

### 7. Tool Design

Small, typed, **read-only** set; each tool maps to FHIR endpoints and traces to a use case:

| Tool | FHIR resources | Use case |
|---|---|---|
| `get_patient_summary` | Patient, Condition, AllergyIntolerance | 1 |
| `get_medications` | MedicationRequest | 1, 3 |
| `get_recent_labs` | Observation | 1, 2 |
| `get_encounters` | Encounter, DocumentReference | 1, 2 |

- All inputs/outputs defined as Zod schemas (satisfies the "canonical contracts" engineering requirement).
- Every call carries the correlation ID and the physician's OAuth token; typed errors, never silent failure.
- Real demo data only — no mocks (data-quality warts are part of the audit).

### 8. Observability

**Decision: Langfuse, self-hosted** (Docker, colocated with OpenEMR).

- Rationale: traces contain PHI; self-hosting keeps PHI inside our infrastructure — the strongest HIPAA answer.
- Required minimums wired in: request count, error rate, p50/p95 latency, tool call counts, retry counts, verification pass/fail rate, token cost per request; three alerts (p95 latency, error rate, tool failure rate).

### 9. Eval Approach

- Ground truth = the OpenEMR database itself (mechanically checkable answers per demo patient).
- Three test classes per the engineering requirements: **boundary** (empty patient, missing labs, malformed input), **invariant** (every claim cites an existing, supporting source; unauthorized queries always refused), **regression** (golden briefings).
- Citation-existence checks are pure code; claim-support checks use Haiku as judge; suite runs in CI.

### 10. Verification Design

Two layers, both in the response path:

1. **Source attribution:** agent emits structured claims paired with FHIR resource references → verifier confirms (a) each cited resource exists and was fetched this session (mechanical, hard guarantee), (b) the claim is supported by the resource content (Haiku, confidence layer). Failures are stripped/flagged, never silently passed.
2. **Domain constraints:** mechanical rules independent of the model — allergy-vs-medication conflict flags; hard policy: no dosing recommendations, no diagnoses, read-only.

Known limitation (documented deliberately): the claim-support check is model-based — a confidence layer, not a proof. The mechanical citation-existence check is the hard guarantee.

---

## Phase 3 — Post-Stack Refinement

### 11. Failure Modes

- Tool failure → explicit, labeled partial answers ("no lab data available"); one retry with backoff; degraded but honest.
- Ambiguous query → one-line clarifying question, never a guess.
- LLM outage / rate limit → SDK backoff; UI degrades to raw chart links, never a blank screen.
- Malformed model output → one re-prompt with the validation error, then degraded response.
- `/health` (process alive) and `/ready` (OpenEMR + Anthropic API + Langfuse reachable) as separate endpoints (graded requirement).

### 12. Security

- **Prompt injection:** record free-text is untrusted input. Defenses: authorization at the tool layer (token can't be overridden by prompt), record content delimited as data, adversarial eval cases.
- **Data leakage:** PHI in prompts covered by assumed BAA; PHI in traces covered by self-hosted Langfuse; logs structured, correlation-ID-keyed, no raw record dumps.
- **Keys:** env vars / Docker secrets only. (Audit exhibit A: upstream repo commits GitHub composer tokens in `docker/development-easy/docker-compose.yml`.)
- **Audit logging:** doubles as the HIPAA audit-trail requirement.

### 13. Testing Strategy

1. Unit tests per tool (schema validation, error paths, authorization refusals)
2. Integration tests: full agent loop against live local OpenEMR
3. Eval suite in CI (item 9)
4. Adversarial: injection via record content, authorization probes, PHI-extraction attempts
5. Load: k6/Artillery at 10 and 50 concurrent users; p50/p95/p99 + error rate + baseline CPU/memory recorded

### 14. Open Source / Licensing

- OpenEMR is GPL-3; the fork stays GPL-3. Agent lives as a separate service directory (`/copilot/`) inside the fork repo — one repo to submit; service boundary preserves future flexibility.

### 15. Deployment & Operations

**Decision: GCP Compute Engine, single instance (`e2-standard-4`, 4 vCPU/16 GB), running the full docker compose stack** (OpenEMR + MariaDB + agent + Langfuse + its Postgres), Caddy for TLS (Let's Encrypt via a `<ip>.nip.io` domain until a custom domain is set).

- History: (1) Railway/Render briefly selected 2026-07-06, reversed same day — Render has no managed MySQL and OpenEMR's stateful compose stack fits PaaS poorly. (2) AWS EC2 selected next, then reversed 2026-07-06 evening — Abe has more GCP experience (dominant factor in a 1-week sprint) and the AWS account hit `OptInRequired` (unactivated billing), while his GCP account was ready. GCP also *improves* the story: **Cloud SQL provides managed MySQL** (the exact gap that killed Render), and **Claude via Vertex AI** is a same-cloud HIPAA-eligible BAA path, so PHI never leaves GCP and there's one BAA counterparty instead of two.
- Deploy target: project `agentforge-clinical-28852` (under abemangona@gmail.com, billing "My Billing Account"). Provisioned by `deploy/provision-gcp.sh` + `deploy/gcp-startup.sh`.
- Scaling narrative for interviews: MariaDB → Cloud SQL (MySQL), agent → Cloud Run / GKE, all inside one VPC (PHI never leaves).
- CI/CD: GitHub Actions (lint → tests → evals → build → deploy on merge); rollback via tagged images.
- Budget: ~$60–70/month.
- LLM path note: with the agent on GCP, prefer Claude via Vertex AI for a same-cloud BAA (see `AUDIT.md` §5); the direct Anthropic API + BAA remains a fallback. Model choice (Opus 4.8 + Haiku 4.5) is unchanged and ZDR/retention-compatible.

### 16. Iteration Planning

- Eval-driven loop: regressions block merge; Langfuse traces of real sessions become new eval cases.
- Feedback: thumbs up/down per response, stored with correlation ID → links to full trace.
- Prioritization = the checkpoint schedule: MVP (Tue), Early Submission (Thu), Final (Sun noon CT).

### 17. Development Process (added 2026-07-06)

**Decision: BMAD-METHOD (v6), scoped to the build phase only (Wed–Sun).**

- Evaluated for full adoption on 2026-07-06; declined for the planning phase: PRD/decision
  work was already done, the hard-gate docs (`AUDIT.md`, `USERS.md`, `ARCHITECTURE.md`)
  have spec-mandated shapes BMAD's templates don't match, and adopting a 12-persona
  framework the day before Architecture Defense is process cost with no checkpoint payoff.
- Scoped use: install after MVP docs are committed (Tue night). Brownfield flow ingests the
  existing docs — never regenerates them. Architect-persona checklist as a *reviewer* of
  `ARCHITECTURE.md`; story-sharded dev cycle (SM → Dev → QA personas) for the `copilot/`
  service. Stories live under `copilot/docs/stories/`; BMAD scaffolding stays out of the
  graded repo root.
- Standing guardrail applies: every story must trace to UC-1..3 / FR / NFR in `PRD.md`.

---

## Change log

| Date | Change |
|---|---|
| 2026-07-06 | Initial record — all 16 items decided. |
| 2026-07-06 | Deployment changed Railway/Render → AWS EC2 (Render lacks managed MySQL; PaaS fit poor for stateful compose stack). |
| 2026-07-06 | BMAD-METHOD adopted for build phase only (Wed–Sun, `copilot/` service); declined for planning phase — hard-gate docs have spec-mandated shapes, planning already complete. |
