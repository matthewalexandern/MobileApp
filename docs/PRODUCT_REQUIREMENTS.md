# Product requirements

Status: proposed design, 2026-10-07. No features in this document are claimed as implemented.

## Product promise

Answer three questions each time the user opens the app: What changed? Does it affect my environment? What should I do next?

The app is a local AI workspace for defensive vulnerability management. It combines a personalized briefing, conversational research, durable memory, and remediation tracking.

## Setup and environment profiles

Support multiple named profiles so separate environments do not contaminate each other's advice or memory. Begin with manual selection and allow more precise inventory later.

| Profile dimension | Examples and meaning |
| --- | --- |
| Operating systems | Windows clients, Windows Server, macOS, Ubuntu, RHEL, other Linux distributions |
| Hosting and services | On-premises, Azure, AWS, hybrid; identify actual services when known |
| Products | Browsers, endpoint software, databases, virtualization, containers, network appliances |
| Version evidence | OS build, package release, application version, installed updates; unknown is valid |
| Operational context | Criticality, ownership, internet exposure, maintenance windows, reboot restrictions |
| Data source | Manual watchlist, inventory import, or a future authenticated management connector |

Keep onboarding short: ask broad questions first, then ask for missing information when it materially changes a decision. Explain why version information is useful. Never ask for production credentials in ordinary chat.

A profile can combine Windows Server, AWS, and a specific application. Cloud selection alone does not prove any CVE applies. Distinguish provider-managed fixes from customer-managed patches and configurations.

## Main experience

The main conversation opens with a compact security briefing above chat. It should include:

- Relevant new and materially changed advisories since the user's last viewed briefing.
- Changes in known exploitation or other prioritization signals.
- Outstanding high-priority findings that still require action.
- Available vendor fixes, temporary mitigations, and verification-pending work.
- Last successful advisory sync and inventory refresh, with stale or partial data clearly identified.

The briefing is built from structured results and can be rendered before the model finishes loading. AI summarization adds explanation without changing the underlying counts or statuses. Refresh failures must not produce an all-clear message. Empty, offline, syncing, stale, and partial-source states need explicit UX.

Opening a finding reveals its source, affected-product conditions, matched assets or watchlist entries, match reason, missing evidence, severity, environment priority, and supported remediation guidance.

## Applicability and remediation are different dimensions

| Applicability | Required interpretation |
| --- | --- |
| Affected | Fresh enough inventory and advisory conditions establish an affected-version/configuration match |
| Potentially affected | Product matches but version, configuration, or other evidence is incomplete |
| Not affected | Explicit evidence establishes the conditions do not apply |
| Unknown | Information is insufficient, stale, contradictory, or cannot be matched reliably |

Track remediation independently as not started, planned, applying, verification pending, verified resolved, failed, or an explicitly recorded exception. An exception is not a fix. Temporary mitigation is not automatically full resolution.

When inventory becomes stale or an advisory changes, reevaluate earlier findings and disclose the uncertainty. Preserve prior evidence for audit without reusing superseded facts as current truth.

## Advisory sources and prioritization

Use the CVE List for canonical records, NVD for available enrichment, CISA KEV for known exploitation, FIRST EPSS for its dated probability signal, and authoritative vendor advisories for affected products and fixes. Microsoft, Linux distribution vendors, Apple, and AWS sources are relevant candidates. Verify each source's API, cadence, terms, and attribution during implementation.

Do not wait for every enrichment source before showing a newly published relevant advisory. Mark absent enrichment as pending or unavailable. Handle advisory revisions and rejected records as updates, not permanent stale findings.

Published severity and environment-specific priority must remain separate. Priority should explain its inputs: applicability, exploitation evidence, exposure, asset importance, remediation availability, and freshness. Absence from KEV or a low EPSS value is not proof of safety. Do not manufacture precision with an unexplained AI-generated risk number.

## Search and web research

Support exact CVE/product/version searches and questions such as:

- Which advisories could affect our RHEL servers?
- What should we patch first on internet-facing Windows systems?
- Which findings still need version information?
- What changed since my last briefing, and which official fixes are available?

Search the local evidence store first, then fetch current authoritative material when needed. Return source URLs, retrieval times, relevant excerpts, and a distinction between fact and inference. Preserve user-selected profile boundaries. If no authoritative fix can be verified, say so and show the evidence gap.

Web search sends necessary queries to an external service; local inference does not make those requests offline or invisible to the provider. Avoid sending private inventory or conversational history by default. Present a clear offline mode using cached knowledge and freshness labels.

## Memory and continued learning

Support working context, conversation/task history, durable facts/preferences, and reusable procedures. Allow the model to request recall, remember, revise, and forget through typed tools. The runtime validates those operations and persists source, scope, timestamps, and supersession relationships.

Explicit corrections replace the active personal/environment memory record. Contradictory external evidence creates a visible unresolved conflict instead of silently overwriting verified data. User edits/deletions propagate to derived summaries and search indexes. Document backup retention and avoid restoring a deleted memory through replay or sync.

Users can inspect, edit, pin, remove, and disable personal memory. Refreshing CVEs and recalling prior outcomes updates the knowledge base; it does not automatically train the model weights. Prior successful procedures remain versioned and must be rechecked for the current environment.

## Patching

Initially deliver guided remediation plans based on official fix data. Plans identify exact targets, current/fixed versions or updates, prerequisites, supersedence, maintenance window, reboot implications, validation steps, and supported recovery options.

Later, selected management connectors can execute approved plans. Approval must refer to the exact plan revision and target set. A change in targets or action invalidates that approval. Use staged rollout, stop conditions, durable job state, and verification of both patch state and service health.

The phone displays and authorizes work; an existing management service or enrolled agent executes it. Closing the app must not lose the job's actual state. Mark success only after authoritative verification; pending reboot or missing follow-up evidence remains pending.

## Release boundaries

The first release centers on profiles, local inference, reliable memory, current evidence, briefings, and patch plans. Actual patch execution follows once a specific connector and its recovery behavior are verified. This design does not include exploit reproduction, autonomous offensive workflows, or an automatically retraining model.

Branding and distribution remain undecided. Keep this design and subsequent work private until the owner clears publication.
