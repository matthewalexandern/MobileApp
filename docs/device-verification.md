# Apple and physical-iPhone verification

## M0 build and UI checks

Use macOS with Xcode 16.2 or later (Swift 6); the deployment target is iOS 17.
Run `swift test --package-path Packages/NativeRuntime`, then:

```sh
xcodebuild -list -project NativeRuntime.xcodeproj
xcodebuild -project NativeRuntime.xcodeproj -scheme NativeRuntimeApp \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

Open the shared scheme in Xcode, choose an available iPhone simulator, and Run.
Check every tab, accessible labels, empty states, demonstration labeling,
streamed response, Send/Stop behavior, and inactive/background/foreground
transitions. Invalid manifest, hash, size and GGUF imports must surface errors
without replacing an existing installation. Native loading must say unavailable
in the M0 build. Verify imported files stay inside Application Support.

For a physical device, select your signing team in the app target's Signing &
Capabilities, choose a unique bundle identifier, connect and trust the iPhone,
enable Developer Mode, and run the same shared scheme. Do not commit team IDs,
signing profiles, certificates, credentials, or private device logs.

## M1 gates: native inference and benchmarks

Complete the native bridge described in `llama-cpp-metal.md` first. Simulator or
Linux results do not satisfy M1. The exact community model, full tensor parsing,
chat template, and quantization compatibility need validation at the pinned
llama.cpp revision; no supported-model claim is made by the M0 adapter.

For each reviewed Q8_0 and Q4_K_M artifact on each supported iPhone:

1. Record device, iOS version, app/native commit, artifact checksum, context (start
   at 2048), sampling, output-token budget, and build configuration.
2. Measure available app memory before load using supported Apple APIs (for
   example `os_proc_available_memory`), plus process footprint/peak resident
   memory with Instruments. Do not use total device RAM as the admission budget.
3. Measure load time, time to first token, generated tokens per second, and peak
   memory across at least three cold and warm trials. Separate prompt evaluation
   from generation. Repeated fixed prompts should contain no private data.
4. Record `ProcessInfo.thermalState` before/during/after and observe sustained
   generation. Define throttling/refusal thresholds from actual measurements.
5. Test cancel while loading, while generating, and on background entry. Confirm
   native resources free once and no stale token stream mutates a new session.
6. Test malformed/incompatible GGUF, storage exhaustion, memory warning, and an
   insufficient admitted budget. A graceful refusal is required; jetsam is a
   failed trial. Test explicit Q4 retry after unload and keep context bounded.
7. Enable airplane mode after import and confirm real streamed conversations
   work without an account, service, or model upload.

Longer contexts require separate measurements before enabling them. The current
mock metrics are demonstration timings and must never enter a native benchmark
report. No measured values are claimed in M0.

| Artifact/hash | Device/iOS | Context | Available budget | Peak memory | Load ms | TTFT ms | Tokens/s | Thermal | Outcome |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Fill after physical-device trial | | 2048 | | | | | | | Pending |
