# M0 threat model

The app is an offline-first scaffold with no accounts, credentials, remote asset
discovery, shell execution, or patch deployment. Its inputs are user chat text,
user-selected model files and manifests, and feed data passed to normalizers.

| Boundary or asset | Failure scenario | M0 control | Remaining work |
| --- | --- | --- | --- |
| Model import | Corrupt, replaced, or malicious GGUF; excessive size | Exact reviewed size/hash; GGUF envelope check; staged private copy; atomic commit; structured failure | Full native parsing, fuzzing, available-memory admission, device OOM tests |
| Manifest | Attacker supplies matching hash and misleading provenance | Safe IDs, required HTTPS provenance/revision/license; user must independently review trust anchor | Signed catalog or curated provenance policy |
| Inference lifecycle | Concurrent load/generation or stale stream overwrites state | Actor isolation, operation ownership, cancellation, background unload; injected test engines | Validate concrete native thread ownership and teardown |
| UI/chat | Generated claims or prompt injection treated as instructions | Demonstration label; no model-invoked tools, shell, network scans, or writes | Typed allowlist, explicit approval, immutable action proposal, audit records in M4 |
| Vulnerability intelligence | Malformed IDs, duplicate or stale feeds; invented applicability | Schema normalization, deduplication, authoritative references/timestamps, unknown applicability | TLS fetching, cache freshness, pagination, provenance and matching in M3 |
| Local storage | Lost migration data, FTS drift, leakage of sensitive text | Transactional versioning, FTS skeleton tests; private app storage; no chat/secret logging | User editing/deletion, backup policy, migration evolution, protected persistence wiring |
| Dependency/build | Upstream drift, accidental model/secret publication | Reviewed llama.cpp pin; ignored weights/artifacts; private repository; PR review | Native dependency audit and reproducible Apple/device build verification |
| Device resources | Q8 or long context causes jetsam or thermal degradation | Default 2048 context; structured native-unavailable response in M0 | Device admission policy, peak memory/thermal benchmarks, explicit Q4 retry |

Security model text and external feed descriptions are untrusted. A future action
proposal must remain separate from approval and execution, and approval must bind
to its exact target, parameters, and effect. The current interfaces expose only
local inference; no inferred authorization can start a remote scan or mutation.

The repository stays private. Do not upload model weights, chat transcripts,
inventory, device logs containing user data, signing credentials, or secrets as
CI artifacts. Store only aggregate benchmark measurements after inspecting them.

OS memory termination and suspension cannot be handled as ordinary Swift errors.
Background lifecycle behavior is best-effort; no persistent inference task or
scheduled hourly refresh is promised. Native inference remains disabled until
M1 verification establishes the concrete bridge's behavior.
