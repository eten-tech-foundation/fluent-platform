# Add access accountability for licensed content

**Date:** 2026-09-11
**Repos affected:** `fluent-api`
**Parent:** [Licensed Content Protection Assessment §4 "Priority 2: Add access accountability"](../2026-09-02-licensed-content-protection-assessment.md#4-recommended-path-forward), [remediation plan](../plan.md)
**Priority:** P2 — do after Wave 1/2 land, since it audits access paths those waves change

## Problem

There is currently no way to answer "who accessed which licensed content,
how much, and why was it permitted" after the fact. Once Wave 1 closes the
anonymous endpoint and Wave 2 adds a license model, the system can make
correct real-time access decisions — but has no record of having made them,
and no way to detect abuse patterns (e.g. one account enumerating an unusual
number of chapters/Bibles in a short window) short of the existing rate
limiter tripping.

## Proposal

1. **Audit licensed-content reads** with user/project/Bible/license
   identifiers and request volume — explicitly **not** raw verse/resource
   text, per the assessment's own logging-exposure guidance (current
   request logs already avoid response bodies; keep that property in the
   new audit trail too).
2. **Alert on unusual access patterns** — e.g. a single account requesting
   an abnormal number of distinct Bibles/chapters in a short window, or
   sync volume far outside a normal project's assignment size.
3. **Distributed rate limits and per-user quotas**, replacing or
   supplementing the existing in-memory per-IP limiter
   (`fluent-api/src/middlewares/rate-limit.ts:68-114`) called out in the P0
   ticket as a known limitation (per-process state, resets on IP change).
4. **Record license decisions** — when content is served, log which license
   rule (from
   [the license-model ticket](2026-09-11-p1-bible-license-rights-model.md))
   authorized it, so the organization can reconstruct *why* a given piece of
   content was delivered to a given user, not just *that* it was.

## Scope

- `fluent-api`: new audit-log table or integration with existing logging
  infra (confirm whether `fluent-api` already has a structured audit-log
  mechanism elsewhere in the codebase to extend, rather than building a
  parallel one)
- `fluent-api/src/middlewares/rate-limit.ts` (distributed backing store —
  e.g. Redis — for the shared-limiter follow-up flagged in the P0 ticket)
- Alerting integration (wherever this org already routes operational
  alerts — Slack/PagerDuty/etc.; confirm the existing channel rather than
  standing up a new one)

## Testing / verification strategy

- Audit-log test: a licensed-content request produces a log entry with
  user/project/Bible/license identifiers and volume, and confirms no verse/
  resource text appears in the entry.
- Rate-limit test: requests from the same authenticated user across
  multiple API instances/processes share the same quota (proves the
  distributed store actually replaces the process-local limiter, not just
  adds a second one).
- Alerting test (can be a manual/staging exercise rather than full CI
  automation): simulate an abnormal-volume access pattern and confirm an
  alert fires.
