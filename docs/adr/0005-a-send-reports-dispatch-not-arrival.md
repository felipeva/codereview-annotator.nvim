---
status: accepted
---

# A send reports dispatch, not arrival

A **send** adapter answers whether the payload was **handed off**, not whether it was
received: returning nothing or `true` means dispatched, `false` with a reason means it was
not, and raising is a non-dispatch whose reason is the error message. Exactly one of those
outcomes — a dispatch — empties the queue. What happens to a payload after the handoff is
the adapter's own business to report, which is what a host adapter already does.

The alternative was the honest-sounding one: have the adapter report completion, and hold
the batch until it does. It was rejected because the adapter hosts actually wire is
asynchronous — it hands off to a subprocess and learns the outcome from a callback up to
half a minute later. Waiting for that would keep the queue open for the length of an
agent's work, with the annotations that were just sent still counted, still drawn on the
diff, and still submittable a second time. The narrower promise is the one the plugin can
keep synchronously, and it is enough for the failure that motivated this: a batch that
never left.

## Consequences

A delivery that was dispatched and then failed downstream still empties the queue, and the
review is not recoverable from the plugin — the notification the adapter raises is all
there is. That is accepted: a **host** that wants a retry owns the payload by then, and the
plugin holding a copy against a failure it cannot observe would mean two places believing
they are responsible for the same batch.

Because a raise is caught and reported rather than propagated, a host adapter's bugs are
now reported as delivery failures. A `nil` field dereferenced inside a `send` reads as
"the batch did not go" plus a Lua error message, rather than as a traceback out of the
submit — which is the right trade for a plugin whose delivery is always someone else's
code, but it does mean the adapter is where such a message has to be diagnosed.
