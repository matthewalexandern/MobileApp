# Mobile AI Runtime — Architecture v0.1

## Mission
Private, native iOS cybersecurity assistant with local model inference, durable memory, asset-aware vulnerability intelligence, and user-approved actions. Offline inference must work without an account or cloud service.

## Model policy
- Experimental initial model: community-pruned gpt-oss-6.0b-specialized-all-pruned-moe-only-7-experts GGUF.
- Support Q8_0 and Q4_K_M imports; never bundle model weights in Git.
- Do not assume a quantization filename or download URL is valid: inspect Hugging Face repository files and verify checksum, size, format, license and model provenance before download.
- This is NOT an official OpenAI 6B model; expert pruning without retraining can harm correctness. Never rely on unverified model output for remediation.
- Measure actual available app memory and handle memory pressure, OOM and thermal throttling. Start with 2048 context; benchmark longer contexts before enabling.
- Model abstraction must permit replacement with higher-quality compatible models.

## Runtime architecture
1. SwiftUI presentation: onboarding, conversation, CVE feed, assets, model manager, settings.
2. Swift actor-based RuntimeCoordinator: state machine (uninstalled/downloading/validating/loading/ready/unloading/failed), cancellation, background/foreground transitions, telemetry.
3. Inference adapter: llama.cpp with Metal acceleration via supported Apple integration; streaming tokens, configurable context and sampling, model load/unload; isolate native interop.
4. Persistence: SQLite with migrations, FTS5 search, conversations, sources, preferences, inventory, CVEs, patch status and audit trail. Optional on-device embeddings later; semantic recall must cite stored source and be user-editable/deletable.
5. Intelligence: CISA KEV and NVD CVE sources with schema validation, deduplication, source timestamps, pagination, retry/backoff and cached offline access. Use CVSS/KEV and environment relevance, never invent vulnerability applicability.
6. Environment onboarding: user selects OS/cloud/vendor/products and optionally imports inventory. Match CVEs against normalized CPE/version data, with confidence and explicit unknowns.
7. Tools: typed allowlisted actions with user confirmation and audit records; no arbitrary shell execution on iOS. Remote discovery/patching only through explicit credentials, authorization and secure integrations in later phases.

## iOS realities
- iOS background refresh is best-effort, not guaranteed hourly. Refresh on app activation and optionally use an external scheduled feed service with user opt-in.
- Device RAM is shared; app memory budget is lower than total physical memory. Q8 is a hypothesis to benchmark, not a guaranteed fit.
- Encrypt sensitive data at rest using iOS protection/keychain patterns. Never log credentials or private chat contents.
- All network endpoints use TLS; minimize telemetry; offline-first by default.

## Delivery milestones
M0: SwiftUI project, build instructions, tests, CI, threat model, ADRs.
M1: import/validate GGUF, load model, stream chat on physical iPhone; capture peak resident memory, time-to-first-token, tokens/s and thermal behavior.
M2: SQLite migrations, conversations, FTS5 retrieval, memory controls.
M3: CVE feeds, source citations, onboarding, inventory correlation.
M4: approved security integrations, confirmation UX, audit logs, hardening and performance.

## Acceptance gates
- Build reproducibly with documented Xcode/iOS deployment targets.
- M1 tested on real device; simulator-only success does not qualify.
- Graceful failure when model exceeds memory budget.
- Offline conversations work after initial model import.
- CVE claims link to authoritative source and show fetched timestamp.
- No public repository, production credentials, external model uploads or automatic patch execution.
