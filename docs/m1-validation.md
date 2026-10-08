# M1 implementation and remaining acceptance gates

Implementation review date: 2026-10-07 (America/Los_Angeles).

The M1 branch adds a concrete native bridge, live resource admission, persisted
verified model selection, and opt-in native Apple build verification. It is
stacked on the unmerged M0 branch; neither pull request is merged or deployed.

The final local Swift 6.0.3 package run passed all 103 portable tests without
compiler warnings. Project references, app Swift syntax, shell syntax and staged
whitespace checks also passed. Actual pinned-header compilation and four tests
linked against the real pinned llama.cpp CPU library were executed. The latter
cover partial-load cleanup, context refusal, cancellation before stream opening,
and actual GPT-OSS Harmony template formatting/unknown-template refusal. No model
weights were downloaded, no successful model generation is claimed, and CPU
results are not Metal/device evidence. Exact final test counts and Apple CI
results are recorded in the pull request. The M1 bridge was linked against a
CPU-only build of the same immutable source commit in an isolated Linux package
snapshot; no substitute C API was used for those four tests.

## Reproduce Apple verification

On macOS with full Xcode selected, Swift 6, CMake 3.28+ and Python 3:

```sh
swift test --package-path Packages/NativeRuntime
python3 scripts/check-project.py
scripts/prepare-llama-xcframework.sh
scripts/build-native-ci.sh
```

The native script verifies provenance, runs package tests with the binary target
enabled, builds unsigned simulator and arm64 device apps, and checks framework
linkage/embedding. It creates three local slices; macOS/simulator architecture
matches the build host. Rebuild when moving between Intel and Apple Silicon.
This does not run the app on a physical device or satisfy M1 inference gates.

## Physical-iPhone gates still open

- Use independently reviewed Q8_0 and Q4_K_M manifests and actual compatible
  GGUFs. Verify full model load, quantization, tensor shape and template behavior.
- Verify Metal device/layer placement and offline streaming in airplane mode.
- Measure load time, time to first token, sampling/decode tokens per second,
  process resident peak and Instruments memory footprint, and thermal state.
- Calibrate provisional memory estimates against actual app budgets and peaks;
  test graceful Q8 refusal and explicit verified Q4 selection after unload.
- Exercise cancel during load/decode, immediate retry after join, background,
  foreground, memory warning, thermal throttling and repeated unload/reload.
- Verify data protection while locked, restart catalog restoration, storage
  exhaustion and crash recovery. Retained older generations increase disk use.

Follow [device-verification.md](device-verification.md). iOS background execution
is best-effort; jetsam/suspension cannot be promised as recoverable Swift errors.
Longer contexts remain disabled pending separate benchmarks. No M1 completion
or model-quality/remediation claim is made before physical-device evidence.
