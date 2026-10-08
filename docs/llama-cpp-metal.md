# llama.cpp Metal integration

M1 implements `NativeLlamaCppBackend` behind the actor-based
`LlamaCppInferenceEngine`. Native compilation is an explicit build choice:
`NATIVE_RUNTIME_ENABLE_LLAMA=1` adds the local `llama` binary target to the Swift
package. Without it, the portable application uses the unavailable native backend;
selecting Native adapter never substitutes demonstration output.

The default linked backend adds live resource admission. Successful inference,
the exact community GGUF's compatibility, Metal placement and physical-iPhone
performance remain acceptance gates, even when the framework builds and links.

## Reviewed dependency and local Apple build

`ThirdParty/llama.cpp.lock.json` pins MIT-licensed upstream tag `b7110` to immutable
commit `3ae282a06f74f8a24fa1ac3b1ab6dc8dda4ea22c`. The commit is the authority.
Review security fixes and compatibility before release. The pinned
[`include/llama.h`](https://github.com/ggml-org/llama.cpp/blob/3ae282a06f74f8a24fa1ac3b1ab6dc8dda4ea22c/include/llama.h),
[`SwiftUI example`](https://github.com/ggml-org/llama.cpp/blob/3ae282a06f74f8a24fa1ac3b1ab6dc8dda4ea22c/examples/llama.swiftui/README.md)
and [`Apple build script`](https://github.com/ggml-org/llama.cpp/blob/3ae282a06f74f8a24fa1ac3b1ab6dc8dda4ea22c/build-xcframework.sh)
are API/build references. The example is not production ownership or cancellation
guidance.

On macOS with full Xcode 16.2+ selected, CMake 3.28+ and Python 3:

```sh
xcode-select -p
xcodebuild -version
scripts/prepare-llama-xcframework.sh
scripts/build-native-ci.sh
```

The preparation script fetches only the allowlisted upstream source at the locked
commit, verifies the checkout and reviewed upstream script hash, and applies its
supported CMake/framework settings to three required slices: macOS, iOS Simulator,
and arm64 iOS device. macOS/simulator architecture matches the build host; rebuild
when moving between Intel and Apple Silicon. Unlike the upstream all-platform
wrapper, this app build needs no visionOS or tvOS SDK. It enables embedded Metal
and system Accelerate, disables upstream tools/server/network clients, retains
the MIT license, and verifies embedded Metal symbols.

The ignored local output is
`Packages/NativeRuntime/Artifacts/llama.xcframework`, with `BUILD-PROVENANCE.json`
recording the source pin, build script, host/toolchain and framework checksums.
Existing modified dependency checkouts require inspection; the script does not
reset them. No model download, artifact upload or publication occurs.

`build-native-ci.sh` verifies that provenance and checksums, runs package tests
with the binary target enabled, builds unsigned simulator and arm64 device apps,
and checks that each executable links and embeds `llama.framework`. It uses
separate native build directories. These builds do not run a physical-device app.

For an explicit native CLI build after preparation:

```sh
NATIVE_RUNTIME_ENABLE_LLAMA=1 swift test --package-path Packages/NativeRuntime \
  --scratch-path .build/native-package-tests
NATIVE_RUNTIME_ENABLE_LLAMA=1 xcodebuild \
  -project NativeRuntime.xcodeproj -scheme NativeRuntimeApp \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/native-device CODE_SIGNING_ALLOWED=NO build
```

For signed deployment, select your team, unique bundle identifier and connected
iPhone as described in [device-verification.md](device-verification.md). If using
the Xcode UI, quit Xcode and launch its executable with the build environment:

```sh
NATIVE_RUNTIME_ENABLE_LLAMA=1 /Applications/Xcode.app/Contents/MacOS/Xcode NativeRuntime.xcodeproj
```

Adjust the executable path if Xcode is installed elsewhere. A scheme's Run
environment applies to the launched application; it does not enable the package
manifest's binary target. Use an explicit CLI build environment or the Xcode
process environment, and fresh native DerivedData when changing build mode.

## Implemented native contracts

- A dedicated serial worker owns model, context, batch and sampler handles.
  Process-global backend initialization is reference counted. Partial failures
  release allocations; unload joins work and synchronizes the GPU before teardown.
- Load validates tensors and the declared quantization against reviewed metadata.
  Metal requests fail when unavailable and on the simulator. Explicit CPU mode
  is for comparisons; compiled Metal support does not establish layer placement.
- The backend uses a supported model chat template and the actual tokenizer.
  Missing/unknown templates fail. Prompt plus requested output must fit the loaded
  context, capped at 2048. Input containing NUL or reserved `<|` delimiters is
  refused. Partial UTF-8 output preserves real native token-event counts.
- Each request contains a single user message and clears native conversation
  state. GPT-OSS Harmony channel/control text remains raw, inert chat output.
  There is no tool interpreter or multi-turn conversation memory in M1.
- Callback-safe flags cancel loads and bounded decode work. Awaited cancellation
  joins stream opening and decode before readiness/unload. Native abort callbacks
  cannot be assumed to preempt Metal immediately; pointer teardown waits for work.
- Native diagnostic logs are disabled. Typed errors and measured load duration,
  time to first emitted token, native output-token count and sampling/decode
  throughput contain no paths, prompts or output. Demonstration chunks never
  become native performance measurements.

## Resource and quantization policy

The experimental community-pruned
`gpt-oss-6.0b-specialized-all-pruned-moe-only-7-experts` is not an official OpenAI
6B model. No compatibility or quality claim follows from the integration pin.
Import Q8_0 and Q4_K_M independently with reviewed revision, size, checksum,
license and provenance. Never infer an artifact URL, relabel weights, convert
them on-device, or fetch them automatically.

On iOS, admission reads actual remaining app memory using
`os_proc_available_memory`; physical RAM and system free memory are not app
budgets. A missing budget or serious/critical thermal state refuses a start.
The provisional load estimate is file bytes + 512 MiB runtime overhead +
128 KiB per context token + 512 MiB reserve, using checked arithmetic. Generation
rechecks the remaining reserve without charging loaded weights again. These
constants need device calibration; passing preflight cannot prevent jetsam.

Current resident memory and process-lifetime resident peak are reported separately
from the available app budget. They are not the iOS dirty-memory footprint; use
Instruments for that measure. Memory warnings, backgrounding and serious/critical
thermal signals request cancellation and unload. Q8 refusal requires explicit
selection of a separately verified Q4 artifact and a new admission check.

## Evidence and remaining verification

See [m1-validation.md](m1-validation.md) for executed portable tests, real pinned
header compilation and four native-linked CPU failure/template tests. No weights
were used and no successful model inference is claimed. Apple build results belong
in the pull request; CPU tests or unsigned app builds cannot establish Metal use.

On a physical iPhone, verify each exact Q8/Q4 artifact's load, tokenizer/template,
Metal layer placement, streaming, cancellation/retry, lifecycle behavior and
airplane-mode chat. Measure actual app budget, process resident peak, Instruments
footprint, load time, TTFT, tokens/s and thermal behavior. Follow
[device-verification.md](device-verification.md). M1 remains incomplete until
those physical-device gates pass.
