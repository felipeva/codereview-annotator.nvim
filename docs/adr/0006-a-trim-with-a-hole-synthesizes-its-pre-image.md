---
status: accepted
---

# A trim with a hole in it synthesizes its pre-image

A **trim** is the commits taken out of a branch review, and they no longer have to be the
ones at the start. A review that keeps a commit and drops an older one reads from a tree that
never existed as a commit, so the review builds one: it anchors on the newest commit of the
run the trim takes off the start of the branch, and three-way merges each skipped commit
above that run onto the accumulation, oldest first, minting a commit object between steps. A
trim with no hole in it anchors on a real commit and assembles nothing, which is what leaves
the trim that already shipped reading exactly as it read. A merge that conflicts is
**refused rather than approximated**, at the moment the reviewer applies the pick and before
anything is stored.

Two alternatives were considered and rejected.

**Concatenating the skipped commits' patches out of the diff.** The review would run one
`git diff` per kept commit and paste the results together, which needs no merge and can never
conflict. It was rejected because the result is not a diff of anything: a file two kept
commits both touched appears once per commit, and the whole surface downstream is built on
one entry per file — the file tree, the anchor map an annotation is bound to, and the
per-file reviewed marks all count a file once. A reviewer would meet the same path twice in
one review with no way to say which of the two they had read.

**Attributing each diff line to the commit that last touched it, and hiding the skipped
ones.** There is no assembly, so there is nothing to conflict and no refusal to explain. It
was rejected for two reasons that compound. The attribution is *last touched* and therefore
lossy: a line the skipped commit reindented and a kept commit then rewrote is attributed to
one of them, and the reviewer reads a line the other one is responsible for. And it puts a
blame pass on a measured hot path — the rendering work that runs on every resize, expansion,
reviewed toggle and scope change — for a diff whose size is the reviewer's whole branch.

That second one is kept on the record deliberately, because it is what a reader who meets a
refusal would propose. If refusals turn out to be the norm rather than the exception, it is
the escape hatch, and it should be reopened as an issue rather than reinvented.

## Consequences

Some picks are refused, and the likeliest case is the one the feature exists for: a formatter
run touches the same lines every other commit touched. That is intrinsic — the reviewer is
asking for a tree that never existed — so the refusal is worded as an ordinary answer and not
as a failure. It names the skipped commit and the files it conflicts in, and no dependency
commit: which kept commit introduced the conflicting region takes a heuristic pass that can
name the wrong commit confidently.

The merge is `git merge-tree --write-tree`, which sets a floor of **git 2.38**. Only a trim
with a hole in it reaches it, so the floor gates the new selections and not the trim that
already ships, and the README states it that way.

The synthesized commit is **unreachable**: no ref is written, which is the same exposure the
**snapshot** minted at dispatch already accepts. git's default prune window is two weeks, so
an automatic collection cannot take a commit minted minutes ago, and an explicit prune costs
one rebuild.

The scope's `identity` stays the merge base, so a reviewer's progress is read back under the
same key however they narrow the review. Only `before` moves, and under a hole it moves to a
commit no ref names.
