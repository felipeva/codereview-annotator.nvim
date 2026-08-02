# The shipped composer is the default adapter, not a fallback

The plugin ships a **composer** and treats it as the default implementation of the `compose`
adapter — handed exactly what a host composer is handed, required to do exactly what one
must. A host that injects its own replaces it rather than upgrading from a lesser path.

The obvious alternative was what this replaced: a one-line prompt built in, with anything
better left to the host. That produced two behaviours to keep in step, and pushed every host
into reimplementing a floating buffer with a submit key before it could have drafts or
references.

## Consequences

There is no prompt path left. Anything that wants note text gets the composer, so an
interaction that only wanted a single line still opens a buffer — accepted, because a second
collection path is the thing this decision exists to avoid.
