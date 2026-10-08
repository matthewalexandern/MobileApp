# Local Security — native iOS runtime

Private, offline-first SwiftUI cybersecurity assistant. The M1 implementation
extends the M0 foundations with an opt-in llama.cpp backend, live iOS resource
admission, and a persistent verified model catalog. The four tabs are Chat,
Vulnerabilities, Assets, and Settings. Chat starts in an explicitly labeled
deterministic demonstration mode.

The native bridge is implemented; **physical-iPhone M1 acceptance remains open**.
Successful GGUF inference, Metal placement, Q8/Q4 memory fit and device performance
require the trials in [device verification](docs/device-verification.md). No models,
accounts, cloud calls, remote scans, or patch execution are bundled. The original
repository guidance remains intact.

## Build and test

Use macOS, Xcode 16.2 or later, Swift 6, and an iOS 17 or later destination.
No third-party Swift runtime packages or developer project generator are required.
SQLite/FTS5 comes from the operating system. Open `NativeRuntime.xcodeproj`, choose
the shared `NativeRuntimeApp` scheme and an iPhone simulator, then Run.

```sh
swift test --package-path Packages/NativeRuntime
python3 scripts/check-project.py
xcodebuild -project NativeRuntime.xcodeproj -scheme NativeRuntimeApp \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

For a device, select your personal/team signing identity and a unique bundle
identifier in Signing & Capabilities, enable Developer Mode, and choose the
connected iPhone. Keep signing credentials out of Git. The commands above build
the portable app, whose native adapter remains unavailable. CI uses no weights.

For the opt-in native build, prepare the local Apple artifact, then verify it:

```sh
scripts/prepare-llama-xcframework.sh
scripts/build-native-ci.sh
```

This requires full Xcode, CMake 3.28+ and Python 3. The verification script checks
source/build provenance, runs native package tests, builds unsigned simulator and
arm64 device apps, and verifies framework linkage and embedding. It sets
`NATIVE_RUNTIME_ENABLE_LLAMA=1` for package resolution and build. For other native
CLI builds, prefix `swift` or `xcodebuild` with that environment variable. A scheme
Run environment variable affects the launched app and does not enable the package
binary target. See [llama.cpp integration](docs/llama-cpp-metal.md) for signed
device builds and Xcode process setup. Simulator Metal inference is refused.

The package also supports Linux Swift 6 with SQLite headers and FTS5. This checks
the core, importer, adapter boundary, migrations, and feed normalization; SwiftUI
and Apple-specific file protection still require Xcode validation.

## Model import and llama.cpp

In Settings, select a reviewed JSON manifest, acknowledge its metadata, and choose
its matching local GGUF. The manifest requires an exact size and SHA-256 plus source
URL, immutable revision, license and quantization. [Model import instructions](docs/model-import.md)
describe the trust review and a deliberately incomplete template. Imports are
streamed into private UUID generations; reviewed manifests and explicit selection
survive restart. Restoration and native load rehash the file. Existing M0 imports
are left intact and need a reviewed catalog import before use.

The experimental community-pruned model named in the architecture is **not an
official OpenAI 6B model**. Q8_0 is a candidate to benchmark, not a guaranteed fit.
Q4_K_M is a separately verified, explicitly selected fallback. The importer checks
the GGUF envelope and artifact integrity; it does not prove model architecture,
quality, or a safe iPhone memory budget. Native contexts are capped at 2048 pending
device benchmarks. Admission uses actual available app memory, with provisional
file-size, runtime, context and reserve estimates; it cannot guarantee freedom
from jetsam. A Q8 refusal never selects Q4 automatically.

See [llama.cpp Metal integration](docs/llama-cpp-metal.md) for the pinned Apple
XCFramework build and opt-in package target. Never commit or upload weights.

## Implementation boundaries

| Component | Current behavior |
| --- | --- |
| SwiftUI application | Four tabs, transient single-turn chat, persistent model selection, resource readings and lifecycle handling |
| RuntimeCore | Actor state machine, bounded streaming, awaited cancellation, structured errors, mock, verified private catalog and resource policy |
| LlamaCppAdapter | Opt-in pinned native backend, serial handle ownership, template/tokenizer checks, measured token metrics; fail-closed portable build |
| RuntimeStorage | Ordered transactional migrations, foreign keys and FTS5 schema/tests |
| RuntimeIntelligence | Offline CISA KEV normalization, deduplication, authoritative citations and timestamps; applicability unknown |

Conversations are transient and each native request contains only its current user
message. GPT-OSS Harmony channel/control text stays inert; no tool interpreter
executes it. Unsupported templates and reserved input delimiters fail visibly.
SQLite is a tested schema foundation;
durable chat, retention/deletion, retrieval and inventory correlation are later
work. Vulnerabilities and Assets show honest empty states. No network feed refresh
or background schedule is implemented. iOS background execution is best-effort;
backgrounding, memory warnings and serious/critical thermal signals cancel work
and request unload. Recovery permits explicit reload. Former committed model
generations remain on disk; storage cleanup and power-loss durability are not
claimed in M1.

Read the [implementation plan](docs/implementation-plan.md),
[threat model](docs/threat-model.md), and [ADRs](docs/adr) for decisions and failure
modes. Treat model text and feed descriptions as untrusted data. Security actions
in future milestones require typed allowlists, explicit approval, and audit records.

## Validation status

Current evidence and open gates are recorded in
[docs/m1-validation.md](docs/m1-validation.md); [M0 validation](docs/validation.md)
remains historical. Portable tests, pinned-header compilation and four real native
CPU failure/template tests were executed. They used no model weights and do not
establish successful inference or Metal/device behavior. Exact counts and Apple CI
results are recorded in the pull request. Complete the physical-device checklist
before accepting M1.
Keep this repository private. Changes are proposed through a pull request; no
publication, deployment, automatic merge, or model upload is authorized.
