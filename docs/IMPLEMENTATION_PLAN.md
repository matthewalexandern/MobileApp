# Implementation plan

Status: proposed design and delivery gates. No application implementation, device benchmark, feed integration, or patch execution is claimed by this document.

Build an iPhone application for defensive vulnerability management: local AI chat and memory, environment-specific vulnerability briefings, evidence search, and vendor-supported remediation planning. Use iPhone Air as the baseline device and iPhone 17 Pro for comparative benchmarks. Confirm exact models, installed iOS versions, and supported deployment targets during the first milestone.

## Delivery rules

- Deliver one demonstrable vertical slice at a time. Keep unavailable integrations visibly unavailable rather than returning simulated success.
- Separate model suggestions from deterministic application decisions. The model explains evidence; structured rules determine applicability states, priority inputs, and action authorization.
- Keep model inference, personal memory, and imported environment data on the device by default. Document any data sent to search providers, synchronization services, or management connectors.
- Treat operating-system background execution as interruptible. Durable checkpoints, cancellation, and recovery are required.
- Hardware capability, throughput, memory consumption, battery cost, and thermal behavior remain unmeasured until physical-device tests run. Do not turn proposed goals into performance claims.

## Milestones and gates

### 0. Establish a buildable iOS foundation

Deliverables:

- A SwiftUI Xcode project with Chat, Briefing, Memory, Environment, and Settings entry points.
- Runtime and data-store interfaces with fixture implementations, visibly labeled as development fixtures.
- A documented build procedure, minimum supported iOS version, dependency policy, and configuration template without credentials.
- A hardware evaluation record for iPhone Air and iPhone 17 Pro, initially marked untested.

Acceptance gate:

- Build and launch the application using Xcode on macOS, first in a simulator and then on a physical iPhone Air. Record Xcode/iOS versions and commit identifier.
- Confirm navigation, cancellation, foreground/background transitions, and restoration of an unfinished fixture task.
- A non-Apple development environment may validate document or data logic, but cannot satisfy the native iOS build, signing, Metal, or physical-device gate.

### 1. Prove embedded local inference

Deliverables:

- A Swift actor that owns model lifecycle and serialized access to an embedded inference engine; llama.cpp with Metal is the initial candidate, subject to integration validation.
- Streaming responses, cancellation, model unload, explicit context limits, and recovery when the OS interrupts the app.
- A model manifest recording origin, license, revision, artifact checksum, expected storage size, and compatible runtime revision. Verify download integrity before loading.
- A benchmark harness for fixed representative prompts and context sizes on both target devices.

Acceptance gate:

- After installing model assets, demonstrate a complete conversation with networking disabled.
- Cancel generation without leaving a busy or corrupt runtime; repeated requests do not overlap unsafe access to the inference engine.
- Record cold/warm startup, time to first token, generation speed, peak memory, and thermal state on each device. Run a repeatable sustained-session test and document battery measurement limitations.
- Select the initial model and context budget from measured stability and task quality. No model size, speed, or battery target is accepted solely from desktop results.

### 2. Deliver durable and correct memory

Deliverables:

- SQLite persistence with schema migrations and FTS5 retrieval for conversations, confirmed environment facts, corrections, sourced research, and resumable tasks. Add semantic retrieval only after a measured need is established.
- Typed `recall`, `remember`, `revise`, and `forget` operations, validated by the runtime before persistence.
- Memory records with provenance, confirmation state, timestamps, project scope, and supersession relationships. Keep inferred claims distinguishable from confirmed facts.
- A Memory screen for inspection, correction, pinning, and deletion, plus explicit retention/export choices.

Acceptance gate:

- A corrected fact supersedes the previous value after restart and is the value retrieved in a later conversation.
- Deletion removes the fact from active records, derived summaries, search indexes, and any embedding store; clear affected in-memory context. Document backup/export limitations rather than claiming guaranteed physical erasure.
- A webpage or model response cannot promote its own contents to confirmed environment facts or silently overwrite pinned user facts.
- Interrupted writes preserve database consistency; a tested migration preserves existing records.

### 3. Build setup and evidence ingestion

Deliverables:

- Onboarding that independently captures operating systems, software, cloud providers, deployment locations, exposure, criticality, and maintenance preferences.
- A manual watchlist and a versioned inventory import format. Label manually selected products as watchlist coverage until asset/version evidence supports applicability.
- Source adapters for official CVE records, NVD enrichment, vendor advisories, CISA KEV, and EPSS, including source identifiers and retrieval timestamps. Validate current source documentation and usage requirements during implementation.
- An always-available collector with an hourly scheduling target, incremental updates, deduplication, retry/backoff, and per-source health. Fetch according to each source's supported cadence and limits.
- Phone synchronization on launch/manual refresh and opportunistically in the background. Offer cached offline access and a phone-only mode with explicit refresh limitations.

Acceptance gate:

- A fixture containing a new advisory, changed advisory, duplicate record, and rejected record produces the correct current view while retaining revision provenance.
- Repeated synchronization is idempotent. Collector downtime and source rate limits do not lose the last successful cursor or erase existing evidence.
- Each feed exposes last attempt, last successful refresh, and failure/staleness status. No interface describes an hourly phone refresh as guaranteed.
- Inventory import validates product/version identifiers and preserves unknown fields as unknown rather than manufacturing applicability.

### 4. Deliver personalized briefings and grounded search

Deliverables:

- An applicability engine producing affected, potentially affected, not affected, or unknown, with asset/version evidence and a source-backed explanation.
- A versioned deterministic priority policy using applicability, exploitation evidence, exposure, system importance, and fix availability. Show published severity separately from app priority and keep all priority inputs inspectable.
- A briefing above chat containing new relevant advisories, meaningful changes, outstanding urgent items, available fixes, and freshness indicators.
- Structured search plus natural-language retrieval over inventory and evidence. Web research retains source URLs and retrieval dates; outbound queries exclude unnecessary private inventory details.

Acceptance gate:

- Missing versions never become not affected. Product-name similarity alone never establishes affected status.
- Tests cover vendor version ranges, distribution-specific fixes/backports where supported, conflicting evidence, withdrawn advisories, and stale inventory. Unsupported comparisons remain unknown.
- Identical inputs under the same priority-policy version produce the same ranking. A displayed explanation identifies the factors responsible for that ranking.
- Each substantive advisory or remediation claim is traceable to retrieved evidence. Unsupported answers identify the missing evidence.
- Urgent unresolved items remain visible after they stop being new. Offline briefings show their last successful refresh.

### 5. Deliver reviewed patch plans

Deliverables:

- Vendor-supported remediation plans with exact proposed targets, applicability evidence, prerequisites, maintenance window, reboot expectations, test group, verification steps, and a recovery strategy where supported.
- Plan revision history and lifecycle states: draft, reviewed, scheduled, executing, verification pending, resolved, or failed. Enable execution states only when a working connector exists.
- Guidance for cases requiring mitigation, manual review, or unsupported-product replacement when no patch is available.

Acceptance gate:

- Every proposed fix maps to an authoritative vendor source and the relevant product/version. Missing prerequisites or ambiguous targets block execution readiness.
- Installation success alone cannot mark a finding resolved. Resolution requires current inventory/patch evidence and the planned health checks.
- The first release can export and track patch plans without holding endpoint execution credentials or claiming to have applied changes.

### 6. Add one approved management connector

Deliverables:

- Select one management platform after the planning workflow is validated. Begin with read-only inventory, then add its documented patch-management operations.
- Scoped credentials, organization policy enforcement, explicit target sets, approved change plans, staged deployment, cancellation where supported, and action audit records.
- Idempotent request handling and reconciliation for timeouts, disconnected phones, partial completion, and external changes.

Acceptance gate:

- An integration environment demonstrates inventory ingestion, reviewed plan submission, a small test group, health verification, and staged expansion.
- Connector-side authorization remains effective if the phone disconnects. Web content and model output cannot authorize a deployment or expand its targets.
- A timeout cannot silently submit duplicate changes. Partial failures remain visible with per-target outcomes and documented recovery options.
- Deployment stops when the defined health gate fails. Only verified targets are marked resolved.

## First coding task

Implement milestone 0 as a small reviewable pull request: the native project, typed `EnvironmentProfile`, `BriefingItem`, and `RuntimeStatus` models, persistence/runtime interfaces, and a fixture-backed opening briefing above chat. Include one setup flow distinguishing a watchlist from versioned inventory, a visible fixture-data label, and last-refresh/unknown states. Use no real environment credentials and execute no endpoint changes. Attach simulator evidence and record the physical-device gate as passed or explicitly pending; then begin the embedded-inference spike in milestone 1.

## Release readiness

The first usable release requires milestones 0–5 with physical-device evidence, source-grounded results, verified memory correction/deletion behavior, interruption recovery, and an honest freshness display. Milestone 6 is a separate capability gate. Release notes must state supported devices and inventories, measured model behavior, unsupported applicability cases, and which integrations are actually implemented.
