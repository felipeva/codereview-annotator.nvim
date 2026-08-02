# One queue, one entry shape, whichever path captured it

An annotation made from the **review path** and one made from the **capture path** produce
the same entry, join the same queue and render through the same code. An entry does not
record which way it was captured.

The two paths resolve their target differently — one from a rendered diff and its anchors,
the other from the buffer itself — and it would have been easier to let each own its own
representation. That was rejected: the moment an entry remembers its origin, every consumer
downstream of the queue grows a branch, and a reviewer starts having to care which way they
happened to annotate something.

## Consequences

Anything the review path can express, the capture path must be able to express too. Kinds
that only make sense in a diff (a hunk) and kinds that only make sense outside one (a **bare
note**) both have to be representable in the single shape.
