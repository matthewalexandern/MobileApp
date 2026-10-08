# Native runtime threat model

The app is offline-first with no accounts, credentials, remote asset discovery,
shell execution, or patch deployment. Its inputs are user chat text, user-selected
model files/manifests, persisted catalog data, and feed data passed to normalizers.
The opt-in M1 backend introduces native parsing and device resource risks; physical
inference/Metal acceptance is still pending.

| Boundary or asset | Failure scenario | Implemented control | Remaining work |
| --- | --- | --- | --- |
| Model import/native parser | Corrupt, replaced or malicious GGUF; excessive size | Reviewed size/hash, GGUF envelope, staged private UUID generation; rehash before native load; tensor and declared quantization checks; sanitized native failures | Native parser fuzzing/audit, exact model compatibility and device allocation tests |
| Manifest/publisher | Attacker supplies matching hash and misleading provenance | Safe IDs, required HTTPS provenance/revision/license; independent trust review and explicit acknowledgement | Signed catalog or curated provenance policy; model quality evaluation |
| Private catalog | Metadata corruption, symlinks, concurrent writers, interrupted replacement | Validated schema and generation references; actor ownership/file lock; atomic metadata replacement; hash on restoration/selection; failures visible; previous committed generations retained | Device crash/power-loss tests, retention/cleanup and disk-usage controls |
| Native lifecycle | Concurrent access, use after free, early cancellation or stale tokens | Serial native handle ownership, global initialization reference counting, generation cancellation flags, awaited join, GPU synchronization before teardown, bounded streaming | Physical-device load/decode cancellation, repeated unload/reload and lifecycle profiling |
| UI/chat | Prompt injection or Harmony control text interpreted as actions; context overflow | No model-invoked tools; raw channel/control output inert; reserved input delimiters rejected; supported template and tokenizer budget; 2048 context cap | Artifact-specific template/quality evaluation; typed allowlist, exact approval and audit records in M4 |
| Device resources | Q8, context or sustained decode causes jetsam/thermal degradation | Actual iOS app budget, provisional checked load estimate and reserve recheck; missing-budget/serious-thermal refusal; memory/thermal cancellation and unload; explicit Q4 selection | Calibrate estimates, actual resident/footprint and thermal benchmarks; jetsam remains possible |
| Vulnerability intelligence | Malformed IDs, duplicate or stale feeds; invented applicability | Schema normalization, deduplication, authoritative references/timestamps and unknown applicability | TLS fetching, cache freshness, pagination, provenance and matching in M3 |
| Local storage/privacy | Leaked model metadata/chat or misleading metrics | App-private catalog, iOS metadata protection/backup exclusion, importer weight protection; transient single-turn chat; native logs disabled; measurements omit private text/paths | Device protection/backup checks; durable conversations, editing/deletion and migration evolution in M2 |
| Dependency/build | Upstream drift, accidental publication or incorrect linkage | Immutable llama.cpp pin, verified local source/build provenance and binary checksums; ignored weights/artifacts; private repository; native app linkage/embedding checks and PR review | Ongoing native dependency audit, reproducible Apple builds and physical-device evidence |

Model text and external feed descriptions are untrusted. Harmony channel/control
text is displayed as inert output, with no interpreter or tool execution. A future
action proposal must remain separate from approval and execution; approval must
bind to its exact target, parameters and effect. Local inference never establishes
authorization for a remote scan or mutation.

File integrity does not authenticate a publisher or prove safe tensors/model
behavior. A successful resource estimate cannot prevent jetsam. Reported resident
peak covers the process lifetime and is not the iOS dirty-memory footprint; actual
available app budget is not physical device RAM. Native metrics must use real
token counts and cannot be inferred from demonstration chunks.

The private catalog does not store external paths. M0's uncataloged weights remain
untouched and untrusted until a reviewed reimport. Older committed generations
remain to support catalog recovery, increasing disk use; interrupted imports can
leave orphans. Atomic catalog replacement provides process-level consistency,
without a general power-loss durability claim. Locked-device file protection and
crash/storage-exhaustion behavior need physical-device testing.

The repository stays private. Do not upload model weights, chat transcripts,
inventory, private device logs, signing credentials, or secrets as CI artifacts.
Store only inspected aggregate benchmark measurements. Native diagnostic logging
is disabled to avoid exposing paths or private text.

OS memory termination and suspension cannot be handled as ordinary Swift errors.
Background lifecycle behavior is best-effort; no continuous inference or hourly
refresh is promised. Portable builds remain unlinked; the opt-in native backend
requires the verification in [m1-validation.md](m1-validation.md) and
[device-verification.md](device-verification.md) before M1 device acceptance.
