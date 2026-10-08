# Local Security — native iOS runtime

Private, offline-first SwiftUI cybersecurity assistant. This pull request delivers
M0 from [ARCHITECTURE.md](ARCHITECTURE.md): an application scaffold and tested
runtime foundations. The four tabs are Chat, Vulnerabilities, Assets, and Settings.
Chat starts in an explicitly labeled deterministic demonstration mode.

Native inference is prepared behind an adapter and **remains unavailable in M0**.
Real GGUF loading, Metal token streaming, device memory admission, and physical
iPhone benchmarks are M1 work. No models, accounts, cloud calls, remote scans, or
patch execution are bundled. The original repository guidance remains intact.

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
connected iPhone. Keep signing credentials out of Git. See
[device verification](docs/device-verification.md) for UI checks and exact M1
benchmark steps. CI runs package tests and a simulator build; it uses no weights.

The package also supports Linux Swift 6 with SQLite headers and FTS5. This checks
the core, importer, adapter boundary, migrations, and feed normalization; SwiftUI
and Apple-specific file protection still require Xcode validation.

## Model import and llama.cpp

In Settings, select a reviewed JSON manifest and its matching local GGUF. The
manifest requires an exact size and SHA-256 plus source URL, immutable revision,
license and quantization. [Model import instructions](docs/model-import.md)
describe the trust review and a deliberately incomplete template. Imports are
streamed and staged privately; validation failure preserves existing weights.

The experimental community-pruned model named in the architecture is **not an
official OpenAI 6B model**. Q8_0 is a candidate to benchmark, not a guaranteed fit.
Q4_K_M is a separately verified, explicitly selected fallback. The importer checks
the GGUF envelope and artifact integrity; it does not prove model architecture,
quality, or a safe iPhone memory budget. Start at 2048 context.

See [llama.cpp Metal preparation](docs/llama-cpp-metal.md) for the pinned upstream
Apple XCFramework build path and remaining bridge work. Building that framework
alone does not activate native inference. Never commit or upload weights.

## Implementation boundaries

| Component | M0 behavior |
| --- | --- |
| SwiftUI application | Four tabs, transient demo chat, local model manager and lifecycle handling |
| RuntimeCore | Actor state machine, bounded streaming, cancellation, structured errors, deterministic mock, local import |
| LlamaCppAdapter | Injectable backend boundary, fail-closed default, pinned upstream Metal build preparation |
| RuntimeStorage | Ordered transactional migrations, foreign keys and FTS5 schema/tests |
| RuntimeIntelligence | Offline CISA KEV normalization, deduplication, authoritative citations and timestamps; applicability unknown |

Conversations in the scaffold are transient. SQLite is a tested schema foundation;
durable chat, retention/deletion, retrieval and inventory correlation are later
work. Vulnerabilities and Assets show honest empty states. No network feed refresh
or background schedule is implemented. iOS background execution is best-effort;
backgrounding cancels work and requests unload, and foregrounding permits explicit
reload without promising continuous inference.

Read the [implementation plan](docs/implementation-plan.md),
[threat model](docs/threat-model.md), and [ADRs](docs/adr) for decisions and failure
modes. Treat model text and feed descriptions as untrusted data. Security actions
in future milestones require typed allowlists, explicit approval, and audit records.

## Validation status

Validation results are recorded in [docs/validation.md](docs/validation.md).
This implementation workspace is Linux and has no Xcode or physical iPhone;
package tests cannot establish an iOS build or native-device performance. Review
the Apple CI result and complete the device checklist before accepting those gates.
Keep this repository private. Changes are proposed through a pull request; no
publication, deployment, automatic merge, or model upload is authorized.
