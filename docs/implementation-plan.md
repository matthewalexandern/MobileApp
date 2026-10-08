# M0 layout and implementation plan

The repository began with ARCHITECTURE.md, AGENTS.md, and a README. Preserve that
guidance and add the first delivery milestone on a feature branch.

## Layout

| Location | Responsibility |
| --- | --- |
| `Apps/NativeRuntimeApp` | SwiftUI tabs, app composition, foreground/background handling, local import UI |
| `NativeRuntime.xcodeproj` | Shared iOS application scheme, local Swift package dependencies |
| `Packages/NativeRuntime/Sources/RuntimeCore` | Inference contract, actor lifecycle, mock, verified local imports |
| `Packages/NativeRuntime/Sources/LlamaCppAdapter` | Isolated injectable native backend boundary |
| `Packages/NativeRuntime/Sources/RuntimeStorage` | Transactional SQLite migrations and FTS5 skeleton |
| `Packages/NativeRuntime/Sources/RuntimeIntelligence` | Validated offline feed normalization |
| `Packages/NativeRuntime/Tests` | Lifecycle, cancellation, import, migration, and feed tests |
| `ThirdParty` and `scripts` | Reviewed llama.cpp pin and local Apple build preparation |
| `docs/adr` | Technical decisions and limitations |

## Sequence and scope

1. Inspect existing guidance, create a branch, record layout and acceptance gates.
2. Scaffold an iOS 17 application in Swift 6 with Chat, Vulnerabilities, Assets,
   and Settings; default to an explicitly labeled offline demonstration.
3. Define asynchronous inference interfaces and a coordinator with structured
   failures, streaming cancellation, serialized lifecycle changes, and background
   unload. Keep native model loading behind the adapter.
4. Import only user-selected GGUFs against reviewed size, checksum, license, and
   provenance metadata. Stage files privately; fail validation before replacement.
   Prepare Q8_0 and explicitly selected Q4_K_M imports, starting at 2048 context.
5. Add transactional storage and FTS5 migrations plus offline KEV normalization
   tests. Live feed networking, retrieval, inventory correlation, and actions are
   later milestones.
6. Pin the supported upstream Apple XCFramework build path. Do not bundle model
   weights or claim native inference is working before Apple/device validation.
7. Run available automated tests and static project checks. Record the exact
   macOS, simulator, signing, and physical-iPhone verification commands.
8. Open a private draft pull request for review. Do not merge or deploy.

## Acceptance boundary

M0 is a reviewed scaffold and integration preparation. M1 still requires a real
native bridge, full GGUF compatibility checks by llama.cpp, and physical-iPhone
load/stream measurements: available memory, peak resident memory, time to first
token, tokens per second, and thermal state. Linux package tests do not establish
that the SwiftUI app compiles or that Q8 fits an iPhone. Neither quantization is
silently downloaded, substituted, or approved for remediation.
