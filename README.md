# MobileApp

Private native iPhone app with offline llama.cpp inference and local
SQLite/FTS5 memory. The imported implementation lives in
[`apps/iphone`](apps/iphone/README.md), including the SwiftUI app, Xcode project,
native C++ bridge, tests and reproducible engine build scripts.

On a Mac with full Xcode, Python 3.10+ and CMake 3.28+, run from this repository:

```sh
python3 apps/iphone/scripts/build_llama.py --jobs 2
python3 apps/iphone/scripts/generate_project.py --check
open apps/iphone/KernalMobile.xcodeproj
```

See the [app README](apps/iphone/README.md) for signing, model import,
simulator tests, memory behavior and current limitations. The checked-in
[engine source pin](configs/llama-source.lock.json) is required by the builder.
The optional GitHub Actions workflow runs only when manually requested.

The starter provides local chat, model import, cancellation, automatic personal
preference memories, search, correction and forgetting. It currently limits
imports to **2 GiB**, requires the imported model's native context, and reserves
at most 256 output tokens per reply. The 5.98 GB GPT-OS3 GGUF discussed for
PocketPal exceeds this starter's import limit. Running it in PocketPal does not
qualify it for this app.

Swift/Xcode compilation, simulator/device execution and Metal inference still
need verification on a Mac. Models, generated frameworks, signing material,
personal databases and build output are excluded from source control.

[`ARCHITECTURE.md`](ARCHITECTURE.md) describes the broader cybersecurity app
roadmap; CVE feeds, inventory correlation and security integrations have not
been implemented in this imported offline starter. The import decision and
differences from that roadmap are recorded in
[`docs/adr/0001-import-offline-iphone-runtime.md`](docs/adr/0001-import-offline-iphone-runtime.md).
