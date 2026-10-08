# ADR 0004: Opt-in native bridge with verified Apple slices

Status: Implemented; physical-iPhone acceptance pending.

Keep the immutable llama.cpp b7110 pin from M0. Implement its actual C API in
`NativeLlamaCppBackend`, compiled only when the `llama` module is linked. Use a
dedicated serial worker for every native handle, process-global initialization
reference counting, callback-safe cancellation flags, and GPU synchronization
before pointer teardown. Disable native diagnostic logging because it may expose
paths or private text; return typed, sanitized errors instead.

The backend validates tensors, checks the native quantization declaration against
the reviewed manifest, uses the model's supported chat template, and enforces
the actual tokenizer/context budget. Unsupported templates fail instead of
falling back to a raw prompt. Context is capped at 2048 pending device evidence.
Harmony channel/control output remains inert text; there is no tool interpreter.
Conversations are still transient, and requests are single-turn in M1.

An explicit `NATIVE_RUNTIME_ENABLE_LLAMA=1` build enables a local binary target.
The portable graph remains weight-free and usable without Apple artifacts.
The upstream all-platform wrapper has no platform-selection switch and builds
platforms this app does not use. The reviewed app build applies its supported
CMake/framework settings to macOS, iOS Simulator and arm64 device slices, with
embedded Metal and system Accelerate. It records source/build provenance and
binary checksums, retains the MIT license, and verifies app linkage/embedding.
Artifacts remain ignored and local; CI does not upload frameworks or weights.

Native compilation and CPU failure-path tests do not establish successful model
inference. Real Q8/Q4 loading, tokenizer/template correctness, Metal placement,
offline device chat, memory fit and thermal behavior remain physical-iPhone gates.
