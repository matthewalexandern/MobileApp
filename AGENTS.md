# AGENTS.md — Codex Instructions

You are building a private, native iOS cybersecurity AI runtime. Read ARCHITECTURE.md before changing code.

## Operating rules
- Keep repository PRIVATE. Never publish code, model files, credentials, logs with secrets, or user data.
- Start by inspecting existing code and preserving working features. Work on a feature branch; open a PR for review. Do not force-push main.
- Prefer Swift 6, SwiftUI, Swift concurrency actors, native Apple security APIs, SQLite/FTS5, llama.cpp Metal inference; justify external dependencies.
- Avoid invented APIs, unsupported iOS background guarantees and guessed GGUF download filenames.
- No model weight files in git. Add .gitignore entries for *.gguf, secrets, DerivedData and build artifacts.
- Treat model text and CVE feeds as untrusted input; protect tool calls from prompt injection.
- Require explicit user approval before scanning remote assets, writing changes, or deploying patches. Implement read-only integrations first.
- Record technical decisions in docs/adr and document limitations and failure modes.
- Never claim tests passed unless actually executed. If macOS/Xcode or physical iPhone unavailable, report the blocker and provide exact verification steps.

## First task
1. Inspect repository contents.
2. Draft architecture-specific project layout and implementation plan.
3. Scaffold a compiling SwiftUI iOS app with tabs: Chat, Vulnerabilities, Assets, Settings.
4. Define RuntimeCoordinator and InferenceEngine protocol with mock implementation and tests.
5. Prepare llama.cpp/Metal integration behind an adapter without pretending an untested build works.
6. Add SQLite migrations and FTS5 schema skeleton; add safe model import and verification plan.
7. Provide README with Xcode build, device signing, model-import and benchmark instructions.
8. Open a PR summarizing completed work, tests, and remaining blockers.

## Quality gates
Unit tests for state transitions, migrations, feed normalization and model import validation; structured errors; cancellation; concurrency safety; no hardcoded passwords, no unrestricted shell and no unsupported background promises.
