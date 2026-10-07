# MobileApp

An Apple-first cybersecurity assistant with an embedded local AI runtime, durable memory, personalized vulnerability briefings, web research, and evidence-backed patch planning.

**Status: design handoff for Codex review and implementation.** This repository change contains specifications only. There is no runnable app, deployed collector, connected environment, or completed device benchmark yet.

## Start here

Read [CODEX_HANDOFF.md](CODEX_HANDOFF.md) first. It identifies the user's requirements, proposed engineering decisions, open questions, and the first implementation task.

| Document | Purpose |
| --- | --- |
| [Product requirements](docs/PRODUCT_REQUIREMENTS.md) | Setup, briefing, chat, search, memory, and patching behavior |
| [Architecture](docs/ARCHITECTURE.md) | Process ownership, local storage, ingestion, matching, and execution boundaries |
| [Implementation plan](docs/IMPLEMENTATION_PLAN.md) | Delivery milestones and acceptance gates |
| [Primary sources](docs/SOURCES.md) | Platform constraints and upstream documentation |

## Product direction

- Run model inference locally inside the iPhone app, using a native SwiftUI interface.
- Support iPhone Air and iPhone 17 Pro, with actual on-device benchmarking before setting model and performance commitments.
- During setup, ask which operating systems, applications, endpoints, and cloud services matter to the user.
- Show a security briefing above the conversation when the app opens: relevant new advisories, changed risk, available fixes, and unresolved priorities.
- Refresh advisory knowledge regularly. Use an optional always-available collector for hourly update preparation; phone-only background refresh remains opportunistic.
- Remember user corrections, environment facts, maintenance preferences, and verified outcomes with provenance and user-visible controls.
- Progress from guided patch plans to supported management integrations with verification of results.

The intended initial implementation is a working vertical slice: environment setup, persistent profile, a clearly labeled fixture briefing, and a conversation shell. Follow it with embedded inference and real advisory ingestion.

## Repository handling

This project is currently private. The user has requested that work stay out of public repositories until explicitly cleared. Keep credentials, production inventory, downloaded model weights, and personal conversation exports out of Git.

Design baseline: 2026-10-07. Proposed choices remain subject to engineering review; no marketing or performance claims are implied.
