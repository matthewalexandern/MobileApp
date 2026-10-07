# Codex implementation handoff

Date: 2026-10-07

Repository: `matthewalexandern/MobileApp` (private)

## Objective

Review this design, resolve the engineering decisions needed for the first milestone, and begin a native iPhone cybersecurity assistant. The app should feel like a familiar chat workspace while owning an embedded AI runtime, persistent memory, and tools. Its main use is keeping the user informed about vulnerabilities relevant to their environment and helping them find and apply supported remediation.

This is a design baseline, not an existing implementation. No app build, real inventory assessment, scheduled collector, or patch action has been performed as part of this handoff.

## Requirements expressed by the user

1. Start with Apple/iPhone; consider both iPhone Air and iPhone 17 Pro.
2. The local AI runs within the app's runtime rather than requiring a remote model for normal use.
3. Give the AI useful control over memory: recall, propose new memories, revise outdated information, and forget, with durable storage and user control.
4. Include web search and up-to-date cybersecurity knowledge.
5. Fetch current CVE information regularly, with hourly updates as the desired product behavior.
6. Show relevant CVEs in an introductory briefing above chat when the app opens.
7. During setup, ask about applicable endpoints, OS families, applications, and environments such as Windows, Linux/RHEL, Azure, and AWS.
8. Provide strong environment-aware searching and patching support.
9. Continue learning the user's environment, corrections, and outcomes over time.
10. Put this design in Git so Codex can review it and start development.

## Proposed implementation choices

These recommendations are reviewable, not additional user requirements:

| Area | Proposed starting point |
| --- | --- |
| UI | SwiftUI, with briefing above chat and dedicated Environment, Memory, and Tasks views |
| Runtime | Swift actor coordinating one inference session, tools, cancellation, and durable checkpoints |
| Model execution | Embedded llama.cpp, a compatible quantized GGUF model, and Metal acceleration |
| Memory | SQLite with FTS5; add a separately versioned local embedding model/index for semantic retrieval |
| Advisory updates | Optional always-available collector with incremental sync; phone-only mode with foreground and best-effort background refresh |
| Applicability | Deterministic version/configuration checks over normalized inventory and authoritative advisory data |
| Explanations | Local model summarizes structured evidence with source references |
| Remediation | Vendor-backed plans first, then selected authenticated management connectors |

The AI model must not be the source of truth for asset counts, installed versions, fixed versions, patch success, or applicability status. It explains results grounded in structured records.

## Review these constraints first

- iOS may suspend or terminate the app. No exact hourly background promise, permanent daemon assumption, or guaranteed push delivery.
- The model, KV cache, embeddings, application UI, and OS all consume memory. Validate the combined workload on actual phones.
- Watchlist selection establishes interest, not proof that a device is vulnerable. Affected status requires sufficiently fresh inventory and advisory conditions.
- Azure/AWS is a hosting/service dimension, not an OS. Distinguish provider-managed services from customer-managed workloads and responsibilities.
- New advisory ingestion is retrieval-based knowledge updating. Automatic model-weight training is not part of the initial product.
- General web content supplies evidence; it does not grant execution permissions or change memory policy.
- A patch installation result and verified vulnerability resolution are separate states.
- Preserve private repository visibility. Publication requires the user's explicit clearance.

## First implementation task

Create the native project and a portable Swift package for domain models and storage. Build the first end-to-end flow:

1. User selects OS families, relevant products, and hosting/service platforms.
2. The app persists that profile locally, including unknown versions.
3. Reopening the app restores the profile and shows a clearly labeled fixture briefing above a conversation shell.
4. Tapping an advisory shows the match reason, uncertainty, source metadata, and next action.
5. Users can change the profile; the briefing updates and never calls a watchlist-only match confirmed affected.

Use fixtures that are visibly test data; do not invent real CVE identifiers or present fixture counts as live findings. Build protocol seams for inference, memory, advisory sources, and inventory so production services can be added incrementally.

After this works, implement the model lifecycle and durable memory milestone, followed by ingestion and matching. The [implementation plan](docs/IMPLEMENTATION_PLAN.md) defines gates.

## Decisions to record during review

- Minimum supported iOS version and Xcode toolchain; capability checks for newer background APIs.
- Model candidates, tool-call format, license/distribution terms, context limits, and fallback behavior. No final model is selected.
- Model download/import UX, checksum validation, disk space checks, interrupted-download recovery, and removal.
- SQLite packaging and migration approach; embedding backend/index and deletion behavior.
- Collector implementation language and hosting. A small Go service is a possible choice, not a committed dependency.
- Source polling policies, rate limits, licensing/attribution, retention, and source-outage handling.
- Search provider and credential arrangement. Never ship a reusable provider secret in an app binary.
- First inventory source and first patch-management connector. Manual entry/CSV can establish the MVP before enterprise integrations.
- Product name, app identifier, signing team, and distribution route. Do not assume these from the repository name.

Record decisions without blocking unrelated local work. Ask the owner only for choices or access that materially block the next deliverable.

## Validation and review expectations

- Run meaningful domain/storage checks for correction, forgetting, uncertain applicability, stale inventory, duplicate ingestion, and interrupted task recovery.
- Verify the real iOS build and model execution with Xcode and physical devices. Simulator or Linux-only checks cannot establish on-device Metal, memory, battery, or background behavior.
- Report exactly which checks ran and which need a Mac/device. No claimed benchmark or connection without evidence.
- Keep incremental implementation reviewable and follow existing repository instructions if introduced later.

Start review with [product requirements](docs/PRODUCT_REQUIREMENTS.md), then [architecture](docs/ARCHITECTURE.md), [milestones](docs/IMPLEMENTATION_PLAN.md), and [sources](docs/SOURCES.md).
