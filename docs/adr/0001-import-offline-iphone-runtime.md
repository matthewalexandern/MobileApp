# ADR 0001: Import the offline iPhone runtime

Date: 2026-10-16

Status: Accepted for the initial source import.

## Context

The user requested copying the relevant iPhone app work from the private
`matthewalexandern/Model` repository into `matthewalexandern/MobileApp`.
The source snapshot is commit `d471394f9c29588b501534c18413370c6f9c23f4`.
MobileApp already contains architecture and contributor guidance but no app
implementation at the inspected base commit
`ddbd2ce173be381d9f62c014acaca14a8a21693c`.

## Decision

Copy the tracked `apps/iphone` tree, `configs/llama-source.lock.json`, source
exclusions and manually triggered simulator workflow. Preserve the existing
architecture and contributor guidance. Keep the app's directory layout because
the framework builder and native smoke harness resolve the engine pin relative
to that layout. Copy source files without modifying runtime behavior.

Use a feature branch and a pull request for review, as required by AGENTS.md.
Keep repository visibility private. Do not copy model weights, datasets, private
chat databases, credentials, generated frameworks, caches or local test receipts.

## Implemented scope and differences from the roadmap

The imported SwiftUI app has Chat, Memory, Workspace and Settings screens.
It includes embedded llama.cpp/Metal integration, safe single-file GGUF import,
local SQLite/FTS5 conversations and preference memory, cancelable generation,
correction, forgetting and per-turn memory opt-out. It uses Swift 5 language
mode with concurrency actors and explicit native interop.

The import is an offline starter. Vulnerabilities and Assets screens, CVE feed
ingestion, inventory matching and remote security integrations remain roadmap
work. The RuntimeCoordinator/InferenceEngine naming in ARCHITECTURE.md is a
design target; the starter uses OfflineRuntime and its existing bridge.

The user required the model's default context earlier in the source project.
The implementation therefore uses `n_ctx = 0` and refuses an unsupported or
unaffordable native context. It does not apply the roadmap's proposed 2048-token
default. Model imports are limited to 2 GiB, generation to 256 output tokens,
and supported model/cache layouts are deliberately limited. The 5.98 GB
GPT-OS3 PocketPal model cannot be imported under those limits. Updating that
policy requires separate implementation and physical-device measurement.

Automatic memory extraction is limited to explicit user statements of coding
language and response length preferences. It does not import the server's
cybersecurity corpus or provide generalized learning. The app provides no
terminal, VM, headless browser or live web retrieval on the phone.

## Verification and failure modes

Linux can verify the generated Xcode project, JSON/plist/XML assets, Python
scripts and the C++ bridge against existing pinned host CPU libraries. Source
project receipts recorded 14 native host smoke checks and ten XCTest cases
written but not executed. The same 14 host smoke checks passed again from this
imported source. The new private receipt is at
`runs/iphone-import-native-20261016/receipt.json`, excluded from Git.
Generated-project consistency, Python syntax, plist/JSON/XML assets, relative
documentation links and source-exclusion checks also passed here.

The next acceptance gate is Xcode compilation and XCTest on a Mac, followed by
physical iPhone tests for actual native-context memory use, cancellation,
foreground/background behavior, thermal effects and model quality. Host CPU
checks do not establish iOS/Metal compatibility. File size and estimated memory
admission cannot guarantee survival under iOS memory pressure.

The native bridge's chat-template support and output handling need separate
qualification for each intended model. PocketPal's observed raw Harmony marker
output is not a demonstrated fix in this app. App icons, framework privacy
metadata, signing and distribution review remain release tasks.
