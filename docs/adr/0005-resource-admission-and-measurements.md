# ADR 0005: Live app budget, conservative admission and bounded cancellation

Status: Implemented with provisional estimates; device calibration pending.

The default linked backend is wrapped by live resource admission. Read actual
iOS remaining app memory using `os_proc_available_memory`; never substitute
physical RAM or system free memory. Missing budgets refuse native starts. Monitor
resident memory and process-lifetime resident peak separately; these are not the
iOS dirty-memory footprint. Serious/critical thermal states refuse starts.

Before load, estimate file bytes plus 512 MiB runtime overhead, 128 KiB per
context token, and a 512 MiB reserve using checked arithmetic. These provisional
constants require conservative calibration for the artifact/device. A passing
estimate cannot guarantee allocation success or prevent jetsam. Generation checks
the remaining reserve without charging already-loaded weights twice. Q8 refusal
offers explicit selection of a separately reviewed Q4 artifact; no auto fallback.

The app cancels preparation/inference and unloads on memory warnings and serious
thermal signals. Backgrounding likewise requests cancellation/unload. The
inference protocol has an awaited cancellation barrier: readiness is published
after opening, decode and stream work has joined. Native callbacks may not preempt
Metal; cancellation waits for bounded work and synchronization rather than freeing
active GPU pointers. OS suspension/termination is not an ordinary catchable error.

Display measured load duration, time to first emitted token, native output-token
count and sampling/decode throughput. Preserve native timings only after checking
finite bounds and matching stream event counts. Empty UTF-8 fragments still count
as their real native token; demonstration chunks never become native throughput.
No measurements contain prompts, output, source paths, credentials or inventory.
