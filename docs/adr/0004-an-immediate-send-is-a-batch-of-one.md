---
status: accepted
---

# An immediate send is a batch of one

An **immediate send** renders through the same payload renderer as a **batch**, producing a
one-annotation payload rather than a terser single-note format. The host therefore keeps no
renderer of its own, and a payload looks the same wherever it came from.

Two alternatives were considered and rejected. A second, terser render mode inside the
plugin would keep quick notes compact, but leaves two output shapes to maintain and test
forever. Leaving the host to render single notes — the status quo — is the smallest change,
but preserves the duplicated capture and path-resolution logic that motivated the work.

## Consequences

A one-line remark arrives as a structured review batch with a heading and a **directive**,
which is heavier than what it replaces. In exchange the host's delivery collapses to
"submit this text to this target": once every payload is pre-rendered, the host's reference
resolution, its reference deduplication and its diagnostics formatting all become dead code.

**Annotation type** becomes optional as a direct result. A typed batch-of-one would force a
type onto the fastest interaction available, so an **untyped annotation** has to be a
first-class state — which in turn means the queue and the payload both need somewhere to put
one, rather than silently dropping it as they do today.
