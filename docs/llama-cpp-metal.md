# llama.cpp Metal preparation

M0 provides `LlamaCppInferenceEngine`, an actor implementing `InferenceEngine`,
and the injectable `LlamaCppBackend` boundary. Its default backend throws
`nativeBackendUnavailable` on every platform. Selecting Native adapter does not
enable inference or substitute demonstration output. Native load, chat streaming,
offline behavior, memory fit and performance remain M1 device acceptance work.

The adapter forwards configuration, requests, tokens and backend metrics, bounds
queued events, cancels stream producers when the consumer cancels, joins in-flight
operations before unloading, and scopes native cancellation to generation IDs.
An injected test backend exercises these contracts without claiming Metal runs.
Backend errors remain structured errors; the adapter never fabricates timing or
silently turns Q8 weights into Q4 weights.

## Reviewed upstream integration

`ThirdParty/llama.cpp.lock.json` pins the MIT-licensed upstream source to tag
`b7110`, commit `3ae282a06f74f8a24fa1ac3b1ab6dc8dda4ea22c`. The immutable commit
is the authority; changing a tag upstream does not change the dependency.
This is a preparation pin, not a claim that this revision passes this app's device
acceptance gates. Review security fixes and compatibility before M1 or release.

The upstream [SwiftUI example README](https://github.com/ggml-org/llama.cpp/blob/3ae282a06f74f8a24fa1ac3b1ab6dc8dda4ea22c/examples/llama.swiftui/README.md)
documents building `build-apple/llama.xcframework` with
[`build-xcframework.sh`](https://github.com/ggml-org/llama.cpp/blob/3ae282a06f74f8a24fa1ac3b1ab6dc8dda4ea22c/build-xcframework.sh)
and adding it to an Xcode project. At this pin the script enables
`GGML_METAL=ON`, `GGML_METAL_EMBED_LIBRARY=ON`, disables example/server/tool
builds and builds iOS, macOS, visionOS and tvOS slices. The resulting module is
`llama`; its module map links Metal, Accelerate, Foundation and C++.
Embedded Metal kernels avoid relying on a separately downloaded shader file.

On macOS with full Xcode selected, CMake 3.28 or newer and Python 3 installed:

```bash
xcode-select -p
xcodebuild -version
scripts/prepare-llama-xcframework.sh --help
scripts/prepare-llama-xcframework.sh
```

Install all Apple SDKs named by the script; the unchanged upstream build requires
visionOS and tvOS SDKs even though this application targets iOS. The wrapper checks
tools and SDKs, fetches only the allowlisted upstream repository at the locked
commit into ignored `.build/llama.cpp-<commit>`, verifies the checkout and build
script SHA-256, then invokes the unchanged reviewed script in that scratch directory.
It downloads source only, accepts no custom URL or shell command, and does not
download a model, upload data, publish an artifact or edit the application project.
An existing modified checkout must be inspected manually; the wrapper does not
reset or delete developer changes. The upstream script rebuilds its own `build-*`
directories inside this disposable dependency checkout.

The output is
`.build/llama.cpp-3ae282a06f74f8a24fa1ac3b1ab6dc8dda4ea22c/build-apple/llama.xcframework`.
Keep it out of Git. M0 does not automatically link it or add a binary Swift package
target. In M1, add a local binary target in the NativeRuntime package, declare it
as a dependency of the adapter, and ensure the app embeds the dynamic framework
using the upstream documented Xcode integration. Review and execute a clean Xcode
build before committing the project/package wiring. Merely copying the framework
into the project does not implement `LlamaCppBackend` or enable inference.

## M1 native backend requirements

Use the pinned [`include/llama.h`](https://github.com/ggml-org/llama.cpp/blob/3ae282a06f74f8a24fa1ac3b1ab6dc8dda4ea22c/include/llama.h)
and [`LibLlama.swift`](https://github.com/ggml-org/llama.cpp/blob/3ae282a06f74f8a24fa1ac3b1ab6dc8dda4ea22c/examples/llama.swiftui/llama.cpp.swift/LibLlama.swift)
as API references. The latter is an upstream sample, not production ownership,
cancellation or correctness guidance. Confirm each imported Swift signature
against the generated module before implementation.

1. Own model, context, batch and sampler pointers on a serial native worker.
   Initialize the backend using `llama_backend_init`, load via
   `llama_model_load_from_file`, and create a context with
   `llama_init_from_model`. Keep process-wide backend initialization balanced
   when multiple engine instances exist. Free sampler/batch/context before the
   model, and join all decode operations before freeing pointers.
2. Map `contextSize` to `llama_context_params.n_ctx`, starting at 2048; query
   the actual context using `llama_n_ctx` before accepting requests. Configure
   `llama_model_params.n_gpu_layers` for measured device Metal offload. Verify
   backend selection and layer placement; compiling Metal does not prove it is
   used. Explicit CPU mode is for comparisons; a simulator run cannot establish
   device Metal support or performance.
3. Map temperature/top-p/seed using the sampler APIs in the pinned header.
   Verify GPT-OSS Harmony/chat-template handling and tokenization for the actual
   imported artifact, including control tokens and partial UTF-8 pieces. Check
   tokenized prompt plus output bounds against the actual context; a byte bound
   alone does not establish token fit. Detect end-of-generation with the actual
   vocabulary. Never treat model text as a tool instruction.
4. Make cancellation observable during model load and between decode batches.
   The pinned header provides a model progress callback and
   `llama_set_abort_callback`, with backend limitations documented in that header.
   Do not assume the abort callback preempts Metal work. Use a thread-safe flag,
   generation IDs and bounded decode steps; cancellation must join outstanding
   GPU work before teardown. Stop or unload on lifecycle/resource signals.
5. Report measured token count, time to first token and generation duration.
   Add device memory/thermal measurements separately and redact prompts and
   token content from logs. Return structured load/decode/resource failures;
   clean up partial native allocation on every failure.

## Q8 and Q4 policy

The architecture's initial artifact is the experimental community-pruned
`gpt-oss-6.0b-specialized-all-pruned-moe-only-7-experts` GGUF. It is not an
official OpenAI 6B model. This pin and the adapter make no claim that every pruned
GPT-OSS file or quantization loads correctly on an iPhone.

Accept independently imported, verified Q8_0 and Q4_K_M artifacts. Q8 is the
preferred candidate subject to the measured available app memory budget. If the
runtime rejects Q8 for resource pressure, offer a separately verified Q4_K_M
artifact through the model-selection policy. Keep source revision, size,
checksum, license and provenance for each quantization. Do not infer a URL or
filename from a quantization label, automatically fetch weights, relabel weights
or perform on-device conversion. A successful preflight estimate cannot prevent
all iOS OOM termination; use conservative headroom and physical-device evidence.

## Verification still required

No Apple XCFramework build or Metal inference was run in the Linux workspace.
Run the wrapper on the documented macOS/Xcode setup, inspect XCFramework slices
and embedded Metal setup, then build/sign the app. On a physical iPhone, import
each independently verified Q8 and Q4 artifact and exercise load, streaming,
consumer cancellation, background/foreground, repeated unload/reload and memory
pressure. Record device/OS, native commit, model SHA-256, actual context, Metal
offload, peak resident memory, time to first token, tokens/second and thermal
state. Verify airplane-mode conversations after import. M1 is complete only
after these device tests; mock tests and simulator builds do not qualify.
