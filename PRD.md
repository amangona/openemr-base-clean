# AgentForge Clinical Co-Pilot — Product Requirements Document

**Status:** Draft · **Owner:** Abe Mangona · **Last updated:** 2026-07-06
**Program:** Gauntlet AI — Austin Admission Track, Week 1

> This PRD is the product source of truth for the project. The phased hard-gate
> documents trace back to it: `USERS.md` details the user and use cases named here,
> `AUDIT.md` audits the system this product depends on, and `ARCHITECTURE.md` is the
> technical realization of these requirements. Engineering-level decisions live in
> [`DECISIONS.md`](./DECISIONS.md); this document stays at the product level (what and why).

---

## 1. Problem

A primary care physician has roughly 90 seconds between patient rooms. In that window
they must reconstruct who they are about to see, why, what changed since the last visit,
what is on file, and what actually matters today. The information exists in the EHR but is
spread across dense notes, lab panels, and medication lists — too slow to assemble under
time pressure. The result is cognitive load, missed context, and decisions made on an
incomplete picture.

Existing EHR search and dashboards don't solve this: they return *where* information is,
not a synthesized answer to "what do I need to know about this patient right now."

## 2. Product summary

A **Clinical Co-Pilot**: a conversational AI agent embedded in OpenEMR that gives a
physician the context they need the moment they need it. It knows *this* patient — their
history, medications, and recent labs — and surfaces what is relevant to today's visit
through a multi-turn chat interface. Every statement it makes is traceable to a source in
the patient's actual record.

It is **not** a general medical chatbot, a search bar, or a dashboard. It is a grounded,
patient-specific, read-only briefing and Q&A agent.

## 3. Goals & non-goals

### Goals
- Cut pre-visit chart review from minutes to seconds for a primary care physician.
- Ground every claim in the patient's record; make hallucination structurally hard.
- Enforce that a user only ever sees data they are authorized to see.
- Degrade honestly and predictably when data is missing or a component fails.
- Be defensible to a hospital CTO — every capability traces to a real user need.

### Non-goals (Week 1)
- No writing to the chart, order entry, or documentation.
- No dosing recommendations, diagnoses, or treatment plans.
- No general medical knowledge Q&A untethered from the patient record.
- No specialties beyond ambulatory primary care; no inpatient/ED workflows.
- No mobile/native client; web chat embedded in OpenEMR is sufficient.

## 4. Target user

**Primary:** a primary care physician with a ~20-patient day, doing pre-visit preparation
in the seconds before entering each room. Detailed persona and workflow → `USERS.md`.

Not targeted in Week 1: nurses, residents-under-supervision, billing staff, patients. The
authorization model must still *account* for these roles (multi-user is the clinical norm),
but the product is designed for and evaluated against the PCP.

## 5. Use cases

Each capability the agent ships must map to one of these. If a capability can't be traced
to a use case here, it doesn't ship.

| # | Use case | Trigger | Why an agent (vs. a dashboard/list) |
|---|---|---|---|
| UC-1 | **Pre-visit briefing** — "What do I need to know about my 9:00?" | Physician opens the co-pilot before a room | Synthesis across notes + meds + labs into a narrative answer; follow-ups are natural. A dashboard shows fields, not "what changed and what matters today." |
| UC-2 | **Grounded chart Q&A** — "Is she still on metformin? What was her last A1c?" | Mid-review question | Conversational, multi-turn, resolves references ("she", "that lab") across turns; each answer cites its source. A search bar returns documents, not answers. |
| UC-3 | **Medication reconciliation support** — "Any conflicts in her current med list?" | Reviewing the medication list | Cross-references the structured med + allergy lists and flags conflicts with citations. Not a recommendation — a surfaced, sourced observation the physician judges. |

Multi-turn conversation is justified by UC-2 (reference resolution across turns). Tool
chaining is justified by UC-1 (a briefing pulls from several FHIR resources in one turn).

## 6. Requirements

### Functional
- **FR-1** Multi-turn conversational interface embedded in OpenEMR, scoped to a selected patient.
- **FR-2** Retrieve patient data through OpenEMR's FHIR R4 API using the physician's authenticated session.
- **FR-3** Every factual claim in a response is attributed to a specific FHIR resource; unattributable claims are withheld or visibly flagged.
- **FR-4** Detect and flag allergy/medication conflicts from structured data.
- **FR-5** Refuse queries the user is not authorized for, and questions the record can't answer, rather than guessing.
- **FR-6** Stream responses so the first useful content appears within a few seconds.

### Non-functional
- **NFR-1 Trust:** a response that contradicts the underlying record is a defect, not a limitation. Verification is in the response path.
- **NFR-2 Authorization:** enforced at the data/tool layer via OAuth2 scopes + OpenEMR ACLs — never by the prompt.
- **NFR-3 Latency:** first token < ~2–3 s; full briefing < ~10 s.
- **NFR-4 Security/HIPAA:** PHI treated as protected throughout — in transit, at rest, in logs, and in observability traces. Assumed BAA (no-training) with the LLM provider. Demo data only.
- **NFR-5 Observability:** from day one, logs answer: what did the agent do and in what order, how long each step took, which tools failed and why, tokens/cost per request.
- **NFR-6 Graceful degradation:** component failures produce honest partial answers, never crashes or silent wrong answers.
- **NFR-7 Auditability:** every invocation carries a correlation ID and records user, patient, tools, and sources — serving both debugging and the HIPAA audit trail.

## 7. Verification & trust model

The product's central claim is *trustworthiness*. Two mechanisms, both in the response path:

1. **Source attribution** — claims are emitted as structured items paired with FHIR
   resource references. A verifier confirms each cited resource exists and was fetched this
   session (mechanical, a hard guarantee) and that the claim is supported by the resource
   content (model-assisted, a confidence layer). Unverified claims are stripped or flagged.
2. **Domain constraints** — mechanical rules independent of the model: allergy/medication
   conflict flags, and hard policy boundaries (no dosing, no diagnosis, read-only).

**Documented limitation:** the claim-support step is model-assisted and therefore a
confidence layer, not a proof. The citation-existence check is the hard guarantee. This
honesty is itself a deliverable-grade design choice.

## 8. Success metrics

- **Groundedness:** ~100% of shipped factual claims carry a verified, existing source citation (measured by the eval suite).
- **Authorization:** 0 successful unauthorized-data retrievals across adversarial eval cases.
- **Latency:** p95 first-token and full-briefing within NFR-3 at 10 and 50 concurrent users.
- **Reliability:** no crash or silent wrong answer under injected component failures (boundary eval class passes).
- **Cost:** per-interaction cost within single-digit cents; documented projections at 100 / 1K / 10K / 100K users.

## 9. Constraints & assumptions

- Built on a fork of OpenEMR 8.2.0-dev (GPL-3); integrates via its existing FHIR/OAuth2 surface rather than modifying the core.
- Demo data only; act as if a signed BAA (no training) exists with the LLM provider.
- One-week sprint with hard-gated checkpoints; the audit is a gate before any AI build.
- Agent stack: TypeScript/Node; models: Claude Opus 4.8 + Haiku 4.5 (see `DECISIONS.md`).

## 10. Deliverables & schedule (all times CT)

| Checkpoint | Due | Product-relevant output |
|---|---|---|
| Architecture Defense | +24h | Defend this PRD's decisions and the architecture plan |
| MVP | Tue 11:59 PM | Deployed OpenEMR fork, `AUDIT.md`, `USERS.md`, `ARCHITECTURE.md`, demo video |
| Early Submission | Thu 11:59 PM | Deployed agent, eval framework, observability wired in, demo video |
| Final | Sun 12:00 PM | Production-ready agent, cost analysis, load tests, demo video, social post |

Standing hard gates: deployed URL with every submission; AI interview 24h after each.

## 11. Open questions

- Chat UI: native OpenEMR module/tab vs. a lightweight embedded panel served by the agent service? (Resolve during Stage 5 architecture write-up.)
- Demo data source: OpenEMR's built-in demo set vs. Synthea-generated patients — pick based on how well each exercises UC-1–UC-3 during Stage 1.
- Exact FHIR resource coverage for UC-1 briefing (which observations/encounters make the cut) — settle against real demo data.

---

*Traceability: `USERS.md` → §4/§5 · `ARCHITECTURE.md` → §6/§7 · `AUDIT.md` → §9 (the system we build on) · `DECISIONS.md` → engineering realization of §6–§7.*
