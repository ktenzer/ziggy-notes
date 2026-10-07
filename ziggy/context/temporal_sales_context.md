# Call Context (placeholder)

This file is a PLACEHOLDER for the per-call context that will eventually be
produced by another workflow or process (e.g. a CRM-enrichment workflow) and
passed into `MeetingWorkflow` as `MeetingInput.call_context`.

It gives the active-listening LLM situational awareness about *this specific*
Temporal sales conversation so its suggestions are grounded rather than generic.

When the upstream context pipeline exists, it should emit something like the
structure below. For now you can edit this by hand and pass it via
`starter.py --context-file ziggy/context/temporal_sales_context.md`.

---

## Account
- Company: <company name>
- Industry: <industry>
- Current architecture / relevant stack: <e.g. Kafka + cron + bespoke retries>
- Known pain points: <e.g. lost orders on partial failure, brittle sagas>

## Opportunity
- Stage: <discovery | technical validation | negotiation>
- Use cases in play: <e.g. order orchestration, payment processing, AI agents>
- Competing/incumbent solutions: <e.g. Airflow, Step Functions, homegrown>
- Decision criteria: <e.g. reliability SLAs, developer velocity, cost>

## Attendees
- <name, role> (e.g. Staff Engineer, platform team)
- <name, role> (e.g. Eng Director, economic buyer)

## Goals for this call
- <what "good" looks like for this meeting>

## Open questions / landmines to handle carefully
- <e.g. previously had a bad PoC experience; sensitive about migration cost>
