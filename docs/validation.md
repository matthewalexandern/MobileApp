# M0 validation record

Validation date: 2026-10-08. Workspace: Linux x86_64; no macOS SDK, Xcode, or
physical iPhone attached. No real model or private data was downloaded or tested.

## Executed checks

Swift 6.0.3 in Docker `swift:6.0.3-bookworm`, image ID
`sha256:296f5866ac2918e24fd8d30a5f3bac1ea689014ab0c73339f8c0e7455572ec70`, with
system SQLite 3.40.1 and FTS5:

```sh
docker run --rm \
  --mount type=bind,src="$PWD",dst=/repo -w /repo \
  swift:6.0.3-bookworm \
  swift test --package-path Packages/NativeRuntime --parallel --jobs 4
```

The complete run passed 49 tests without compiler warnings:

| Area | Tests | Coverage |
| --- | ---: | --- |
| Runtime coordinator | 14 | Lifecycle, failed-load cleanup, concurrent load/unload, background cancellation, streaming/output/time bounds, request validation |
| Model import | 13 | Hash/size/GGUF checks, streaming across chunks, Q8/Q4 manifests, source/destination symlinks, safe IDs, atomic replacement, cancellation cleanup |
| Adapter contract | 9 | Unavailable backend, forwarded configuration/metrics, explicit Q4 retry, load/open/consumer cancellation, unload ownership and failure recovery |
| SQLite | 7 | Migration idempotence, gaps/downgrades, atomic rollback, foreign keys, bound values, FTS rebuild and insert/update/delete consistency |
| Feed normalization | 6 | Schema/count/identity/date checks, deduplication, citations/timestamps, unknown applicability, untrusted action text and payload bounds |

The first run exposed a directory-URL representation bug in import containment
and XCTest discovery isolation warnings. Both were corrected before the passing
run. Later adapter cancellation refinements passed a targeted rerun of all nine
adapter tests with `swift test --package-path Packages/NativeRuntime --filter
LlamaCppInferenceEngineTests --jobs 4` in the same container before the commit.

Also executed:

- `python3 scripts/check-project.py`: passed; six Swift sources, four package
  products and shared scheme references verified.
- `swiftc -frontend -parse Apps/NativeRuntimeApp/*.swift` in the same Swift
  container: passed syntax parsing. This does not type-check SwiftUI or Apple APIs.
- `bash -n scripts/prepare-llama-xcframework.sh` and its `--help`: passed.
- Apple preparation wrapper on Linux: refuses clearly before download/build.
- `git diff --check`: passed before staging; staged whitespace checked at commit.

Independent review addressed delayed unscoped chat cancellation and bounded
manifest reads. No test results here represent native model throughput or memory.

## Pending acceptance checks

The private pull-request workflow runs package tests on macOS and builds the app
for a generic iOS Simulator without signing. Its result must be reviewed; adding
CI is not proof that a build passed. In this workspace, the SwiftUI app was not
compiled against an Apple SDK, and the Apple XCFramework script was not built.

Follow [device-verification.md](device-verification.md) for exact Xcode commands,
device signing, UI interactions and protected-storage checks. M1 additionally
requires a concrete native backend, verified GPT-OSS artifact compatibility,
available-memory admission, memory/thermal handling, and physical-iPhone offline
streaming benchmarks for Q8_0 and explicit Q4_K_M fallback. No M1 success is claimed.
