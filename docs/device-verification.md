# Apple and physical-iPhone verification

## Portable build and UI checks

Use macOS with Xcode 16.2+ (Swift 6); deployment target is iOS 17.

```sh
swift test --package-path Packages/NativeRuntime
python3 scripts/check-project.py
xcodebuild -project NativeRuntime.xcodeproj -scheme NativeRuntimeApp \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

Open the shared scheme, choose an available iPhone simulator, and Run. Check every
tab, accessible labels, empty states, demonstration labeling, streamed response,
Send/Stop, and background/foreground transitions. Invalid manifest, hash, size and
GGUF imports must surface errors without replacing an existing installation.
Native loading must say unavailable in this portable build. Verify imported files
stay in app-private Application Support and selected reviewed models restore after
restart only after checksum verification.

## Native Apple build and signed device setup

With full Xcode selected, CMake 3.28+ and Python 3:

```sh
scripts/prepare-llama-xcframework.sh
scripts/build-native-ci.sh
```

The second script enables `NATIVE_RUNTIME_ENABLE_LLAMA=1`, verifies provenance,
runs native package tests, builds unsigned simulator and arm64 device apps, and
checks framework linkage/embedding. No weights or signed device execution are
involved. The macOS/simulator slices match the host architecture; rebuild the
artifact when switching between Intel and Apple Silicon. Simulator Metal loading
is refused and cannot establish device performance.

For a signed physical-device Run, quit Xcode and start its process with the package
build environment (adjust the executable path for your installation):

```sh
NATIVE_RUNTIME_ENABLE_LLAMA=1 /Applications/Xcode.app/Contents/MacOS/Xcode NativeRuntime.xcodeproj
```

Choose the shared `NativeRuntimeApp` scheme, select your team and a unique bundle
identifier in Signing & Capabilities, connect/trust the iPhone, enable Developer
Mode, and choose it as destination. Use fresh DerivedData when changing between
portable and native builds. Confirm Settings reports that llama.cpp is linked
before continuing. A scheme Run environment variable does not activate the package
binary target. CLI builds must likewise inherit `NATIVE_RUNTIME_ENABLE_LLAMA=1`.
Do not commit signing profiles, certificates, team IDs or private device logs.

## Physical-iPhone M1 acceptance

The bridge is implemented, but successful model inference and Metal execution
remain unverified. Linux/CPU tests and simulator/device builds do not satisfy M1.
Use the exact independently reviewed artifacts from [model-import.md](model-import.md)
and preserve each artifact's source revision/license/hash in the trial record.

For each Q8_0 and Q4_K_M artifact on each supported iPhone:

1. Record device, iOS version, app/native commit, artifact hash, actual context
   (start at 2048), sampling, output-token budget, and build configuration. Verify
   native parsing, declared quantization and supported chat template. Confirm
   actual Metal backend/layer placement with local profiling; a linked Metal
   framework is insufficient evidence.
2. Import the reviewed manifest and file, choose Native adapter, then explicitly
   verify/load. Check missing or tampered catalog/artifact errors, restart selected
   model restoration, and that restoration/foregrounding never auto-load weights.
   The app's latest load timing excludes the preceding checksum pass.
3. Record actual remaining app memory via `os_proc_available_memory` before load,
   current resident memory, process-lifetime resident peak, and Instruments dirty
   memory footprint. These are distinct measurements. Physical RAM is not an app
   budget and the lifetime peak is not a per-generation peak or jetsam footprint.
4. Measure load time, time to first emitted token, real output-token count and
   sampling/decode tokens/s across at least three cold and warm trials. Separate
   prompt evaluation from generation; use fixed prompts containing no private
   data. Demonstration chunk timings must never enter native benchmark reports.
5. Record thermal state before/during/after sustained generation. Calibrate the
   provisional file + 512 MiB runtime + 128 KiB/context-token + 512 MiB reserve
   admission estimate against actual budgets/peaks. Verify missing-budget and
   serious/critical thermal refusals. Passing preflight cannot guarantee fit.
6. Cancel during load, prompt evaluation and decode; cancel before stream opening
   and retry immediately after cancellation joins. Exercise repeated unload/load,
   background/foreground, memory warning and serious thermal signals. Confirm no
   stale tokens mutate a newer session and no active GPU resources are freed.
7. Test malformed/incompatible GGUF, unsupported templates, reserved input
   delimiters, tokenized prompt/output overflow and storage exhaustion. Verify
   graceful Q8 admission refusal, then unload and explicitly select/verify/load
   Q4. Quantization must never change automatically. Jetsam is a failed trial.
8. Verify data protection while locked and after restart; exercise interrupted
   import/catalog replacement and recovery. Confirm old committed generations are
   retained, measure their disk cost, and record orphaned generations after crash.
   Atomic replacement does not establish power-loss durability or cleanup safety.
9. Enable airplane mode after import and verify real streamed single-turn chat
   without an account/service/model upload. Harmony channel/control text must stay
   inert and no model output may invoke tools. Messages remain transient; previous
   visible messages are not supplied as native conversation history.

Longer contexts remain disabled pending separate benchmarks. OS suspension and
jetsam cannot be promised as recoverable Swift errors; background execution is
best-effort. Retain only reviewed aggregate measurements, never prompts, outputs,
paths, credentials or inventory. Native diagnostic logging is disabled; use
profiling for Metal verification without enabling private-text logs.

| Artifact/hash | Device/iOS | Context | Available budget | Resident peak since launch | Instruments footprint | Load ms | TTFT ms | Tokens/s | Thermal | Outcome |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Fill after physical-device trial | | 2048 | | | | | | | | Pending |

Executed implementation evidence and remaining gates are in
[m1-validation.md](m1-validation.md). Keep device results separate from CI build
and CPU test evidence.
