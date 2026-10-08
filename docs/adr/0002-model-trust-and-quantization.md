# ADR 0002: Local model trust and quantization policy

Status: Accepted for M0; memory and correctness benchmarks pending.

Import a user-selected GGUF only with independently reviewed metadata: exact
byte count, SHA-256, source repository URL, immutable revision, license, and
explicit quantization. Check the local file against that metadata before an
atomic move into private storage. SHA-256 establishes consistency with the
reviewed file, not publisher trust, model quality, or license approval.

Q8_0 is the preferred experimental candidate. Q4_K_M is an explicitly selected
fallback when Q8 does not fit or is unavailable. Each artifact needs its own
reviewed manifest and checksum. No automatic downloads, guessed filenames,
silent substitutions, or model uploads are allowed. Start with 2048 context.

The community-pruned
`gpt-oss-6.0b-specialized-all-pruned-moe-only-7-experts` is not an official OpenAI
6B release. Expert pruning may reduce correctness. The generic manifest can
describe replacements; a filename never proves architecture compatibility.
The importer checks the GGUF envelope; llama.cpp must validate the full metadata
and tensor layout at load time. Its tensor parsing must be treated as a native
untrusted-file boundary.

File size and total physical RAM do not establish an iOS app memory budget.
Before M1 readiness, add and validate available-app-memory admission, model/KV
cache estimates, memory-pressure handling, and thermal policies. Catchable load
errors permit explicit Q4 retry; OS termination due to OOM is not reliably
catchable, so admission and measurements are mandatory before claiming a fit.
