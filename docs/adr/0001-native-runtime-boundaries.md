# ADR 0001: Native application and isolated inference boundary

Status: Accepted for M0; device validation pending.

Use Swift 6, SwiftUI, iOS 17, and actor-based concurrency. Keep testable lifecycle,
model-import, feed, and storage code in a local Swift package. The app is a thin
composition and presentation layer. Foundation and system SQLite are the only
runtime dependencies in M0; llama.cpp is prepared as a separately built native
dependency rather than imported transitively from an unreviewed package.

`InferenceEngine` abstracts load, unload, and asynchronous token streaming.
`RuntimeCoordinator` owns lifecycle and cancellation. Native interop is isolated
in `LlamaCppAdapter`; its default backend fails explicitly as unavailable.
The deterministic mock is for demonstration and tests only. It must never present
generated text as verified security advice or label itself as a loaded GGUF.

This permits Apple-independent unit tests and replacement of the experimental
model. It also creates a deliberate M1 task: implement the concrete native bridge
and validate it with the pinned headers and a physical iPhone. M0 passing tests
cannot imply successful Metal inference.

Backgrounding cancels current work and requests unload. Foregrounding does not
silently reload a multi-gigabyte model. There are no background execution or
hourly feed-refresh guarantees, accounts, cloud fallback, or remote actions.

Generation timeouts require a cancellation-cooperative engine; Swift cannot
forcibly terminate faulty native code. Prompt-byte and event-count limits bound
the coordinator, while actual context admission belongs to the native tokenizer.
The mock emits text chunks, so its event counts and timings are not model benchmarks.
