# Reading one file at a time is a rendering choice, not a scope

A reviewer working through thirty changed files loses track of which one they are in. The
answer every hosted review tool gives is to read one file at a time, and **solo** is this
plugin's. It draws the file being read and none of the others.

The obvious implementation was a sixth **scope**. `git diff -- <path>` is one word of
plumbing, the scope machinery already exists, and `gs` already cycles five of them. It is
the wrong shape, and the reasons are not visible from the code.

## A scope is a git question

Every existing scope names a revision or a state of the working tree: a branch, the staged
or unstaged changes, the whole worktree, what changed since the last **batch**, any revspec.
"Show me one file" names neither. It is a statement about a reader's eyes, made after the
review already exists, and it is undone by moving the cursor.

## A scope decides what the review *is*

The file tree, the reviewed marks, the `✓2/7` on the **sticky header** and the meaning of
"done" all read off the scope. Under a single-file scope a review of one file reports `0/1`
and completes on that file. A reviewer who narrowed the view in order to read *more*
carefully would have silently narrowed the review they were doing, and the tree would stop
being the map of the work.

## And a scope reaches the receiving agent

[ADR-0002](0002-one-queue-one-entry-shape.md) keeps one entry shape and one queue, and which
**layout** was on screen never reaches the **target**. A scope is not like that — it is part
of what a **batch** is about. So a solo scope would tell the agent the reviewer looked at one
file, which would be false in every case solo exists for.

## Consequences

Solo changes nothing the plugin sends and nothing it stores. The **queue**, the **archive**,
the **payload**, the reviewed marks and the file tree are what they were, and no **entry**
records that solo was on. It is a config default with a session-long toggle and is written
nowhere, unlike a scope, which is kept per **checkout** — a scope says what a review is and
survives; solo says how one sitting is being read and does not.

One key changes meaning rather than merely repainting. `R` marks the file reviewed and
advances to the next unreviewed one, because collapsing the only file on screen leaves an
empty view. `]h` and `[h` stop at the file's last hunk and report it: a hunk key that silently
repaints the whole view is a surprise, and `]F` is one keystroke away.

## Rejected: a third `layout` value

Cheaper, and wrong. Solo and **layout** are orthogonal — a **split** diff can be soloed and
should be — so a third value would make `gl` cycle three states and would forbid the
combination outright.

## Rejected: collapsing every other file

Nearly free, and it needs no new concept: `za` already does it one file at a time. But a
collapsed file still occupies a header row, so thirty files still put thirty rows between the
reviewer and the code, which is the problem rather than a smaller version of it.
