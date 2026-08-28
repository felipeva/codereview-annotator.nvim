# The plugin ships the checkout picker, as the default `pick_checkout` adapter

A **switch** needs a list of **checkouts** and a way to choose one from it. The plugin builds
the list itself, from `git worktree list`, and treats the chooser as the default
implementation of a `pick_checkout` adapter — the shape ADR-0003 gave the composer, not the
shape `pick_file` has, where the plugin ships nothing at all.

The split follows what each side knows. What a checkout *is* is the plugin's own knowledge,
and `git worktree list` does not move under it the way the agent tooling behind ADR-0001
does. How a list is put in front of a reviewer is the host's, and every configuration already
has a picker.

## Consequences

The listing is worktrees of the current repository only. Reviewing a checkout of a different
repository needs a host adapter until cross-repository listing exists, which is a deliberate
deferral and not an oversight.
