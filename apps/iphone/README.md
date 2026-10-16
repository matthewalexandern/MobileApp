# Kernal Offline for iPhone

A native, single-user SwiftUI app with embedded llama.cpp/Metal inference and
local SQLite/FTS5 memory. The app has no server, account, telemetry, web requests
or model downloader. After installing it and importing a compatible GGUF from
Files, inference and memory stay on the iPhone.

The first version includes local chat sessions, cancelable generation, automatic
personal preference memory, per-turn opt-out, corrections, search and forgetting.
The Workspace screen explains the offline limits: it can help write code, but
there is no terminal executor, VM, headless browser or live current-events feed.
Preview mode is explicitly fixed sample content and performs no generation.

## Build on a Mac

Use full Xcode 15 or newer with iOS 17 or newer SDK/simulator, Git, Python 3.10+
and CMake 3.28+. No third-party Swift packages are needed. From the repository:

```sh
python3 apps/iphone/scripts/build_llama.py --jobs 2
python3 apps/iphone/scripts/generate_project.py --check
open apps/iphone/KernalMobile.xcodeproj
```

The framework builder downloads the exact official commit/tree from
`configs/llama-source.lock.json`, verifies actual tracked file hashes/modes and
runs upstream `build-xcframework.sh ios-device ios-sim` in a dedicated ignored
checkout. It preserves the upstream script and caps its inner CMake job count
through a narrowly scoped CPU-probe shim. Choose fewer jobs on a busy Mac.
Device/simulator slices are built sequentially. Frameworks, source, build state
and receipts stay outside ordinary Git commits; an existing framework is never
silently overwritten.

The Xcode project embeds/signs `Vendor/llama.xcframework`, links SQLite and
compiles the C++ bridge. Select the shared `KernalMobile` scheme and an installed
iPhone simulator. For a physical phone, select your development team, change the
example bundle identifiers and enable Developer Mode as required by Xcode.
Signing material stays outside Git. Re-generate after adding/removing sources:

```sh
python3 apps/iphone/scripts/generate_project.py
xcodebuild test -project apps/iphone/KernalMobile.xcodeproj \
  -scheme KernalMobile \
  -destination 'platform=iOS Simulator,name=YOUR_INSTALLED_IPHONE' \
  CODE_SIGNING_ALLOWED=NO
```

The optional `.github/workflows/iphone-manual.yml` is manually triggered only,
builds the pinned framework and runs simulator XCTest. It has no scheduled or
push trigger and was not run here. Runner usage is subject to your GitHub account.

## Import and capacity

Use Files to import a complete single-file GGUF already available on the phone.
The first version accepts at most 2 GiB per model and copies it into protected
app storage. It records a SHA-256 digest and verifies that digest when restoring
the selected model. That digest detects local changes; it is not independent
proof of the model publisher. Model weights are not included in this repository.

The bridge deliberately supports a limited set of ordinary transformer cache
layouts and supported chat templates. Unknown/hybrid/recurrent cache layouts,
split GGUF, missing templates, unsupported native context or insufficient budget
are refused. File size, metadata and estimated full-context KV/work buffers are
checked against a conservative share of currently available process memory.
This admission estimate is not measured peak-RSS evidence and cannot guarantee
that iOS will never terminate a process under pressure.

Context is explicitly `n_ctx = 0`: use the imported model's native metadata.
The actual context must match that value; the app does not silently reduce it.
The complete chat history plus memory, template and output reservation must fit.
If it does not, start a new chat or import a more suitable model. No intended
model has been qualified with this app on a physical iPhone.
GPT-OSS-20B's server target remains 131072; this starter does not qualify GPT-OSS
on an iPhone or claim server-model coding quality.

Model loading and generation use background workers. Generation uses a fresh
KV state and a maximum of 256 output tokens. Cancellation checks run between
bounded decode batches; Metal work already submitted may complete first.
Imported models must be from sources you trust: a native parser processes them.

## Local memory and privacy

One protected SQLite database stores sessions, committed turns and memories.
FTS5 uses bound, quoted literal searches. Successful replies and eligible
preference updates commit atomically; identical request retries return the
original reply and changed input conflicts. Limits are 100 sessions, 1000
messages per session, 10000 messages total and a 512 MiB database.

Automatic extraction is intentionally narrow: exact user statements of coding
language and concise/detailed response preferences. It needs no approval or
special remember command. Assistant text, quoted documents and tool/web text
cannot create facts. Corrections replace the matching preference; forgetting
adds a tombstone that prevents automatic relearning. This is a starting personal
memory implementation, not the full server's public cybersecurity corpus,
procedural learning or generalized episodic extraction.

Chat storage uses iOS Complete file protection; model files use
CompleteUnlessOpen. App storage is excluded from backups, and a privacy cover
hides inactive screens. Protection attributes are not a separate application
password or a promise that screenshots/physical access can never expose data.
The single-user boundary is the iOS app container and device unlock.
No private data enters training or a shared knowledge base.

The app manifest declares container/user-selected file metadata access. The final
embedded framework's own required-reason API manifest, signing, icons and
distribution privacy details must be audited on the Mac before distribution.
[Apple required-reason API guidance](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons).

## Verification boundary

This workspace is Linux without Swift, Xcode or an iOS SDK. Native bridge checks
compiled/linked against the pinned Linux llama.cpp build: **14 checks passed**,
including real eight-token generation on a tiny synthetic chat fixture, context
preservation, cancellation and budget/bounds refusals. The original model file
remained unchanged. `scripts/test_native_bridge.py --help` describes reproducing
that test with existing local CPU libraries and the verified tiny fixture.
The exact FTS5 schema/search/correction/forget checks also passed Python SQLite.
Those checks do not compile Swift or prove
iOS/Metal execution. The XCTest suite and generated project await an actual Mac
simulator/device run; **ten XCTest cases are written but have not run**. Historical
receipts remain in the source Model workspace at
`runs/iphone-offline-20261016/` and were not copied into this repository.
The native smoke harness was rerun successfully from this imported source:
14 checks passed, with the new private receipt at
`runs/iphone-import-native-20261016/receipt.json`, excluded from Git.
No framework binary, model weights, phone installation,
App Store/TestFlight submission or paid Mac runner run was produced here.
