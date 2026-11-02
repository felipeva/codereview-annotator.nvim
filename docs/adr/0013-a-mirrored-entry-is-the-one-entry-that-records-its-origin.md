# A mirrored entry is the one entry that records its origin

ADR-0002 says that an entry never records which path captured it. That is true of each
entry that this plugin captured: the **review path** and the **capture path** give the same
entry, and no consumer asks which path it came from. While the **sync** runs, the queue also
holds the notes that other tools made. No path of this plugin captured them, so ADR-0002
cannot be about them. Each one is a **mirrored entry**, and it carries a mark: `mirrored`.

A mirrored entry is a loose entry of the **bare note** kind, with the note, the type and a
label made from the note's selection and source (for example `Area · Helium`). It has no
**anchor**, no path and no file. The reviewer can edit its note and its type, and can drop
it, through the paths of every entry: `update` and `remove`. It is in the queue only while
the sync runs, and it leaves the queue when the sync stops.

**Two consumers must keep it out, and one of them reads the mark.**

- **Persistence reads the mark.** The partition of the queue into stores (`state.lua`)
  gives a mirrored entry to no store, also not to the store with no root, and so to no
  archive. Written there, it would come back as a bare note of this plugin when no queue
  owner listens, and a submit without the queue owner would send a screenshot as a note.
- **Placement does not need to read it.** Jump, the **overlay** and the diff skip every
  bare note already: the kind has no file, and its key (`note:0`) is the key of no diff
  row. A mirrored entry has the same kind and the same key, so these paths skip it with
  no branch of their own.

The sync makes the mirrored entries, so it reads the mark too: a connect does not keep
them, a refused edit does not stay in Neovim, and the stop removes them. That is the
producer, not a consumer downstream of the queue. The three places that print `(no file)`
for a bare note (the queue float, the payload and the description of an entry) print the
label in its place. They read the label, not the mark.

## Considered options

- **No key, and a branch on the mark in each placement path.** Rejected: `queue.by_key`
  cannot index a nil key, so each reader of the queue's keys would need a guard, and each
  guard is a branch of the kind that ADR-0002 exists to avoid. The bare note's key costs
  nothing.
- **Leave the notes of other tools out of the queue.** Rejected: the reviewer must see the
  whole batch that a submit sends, and the count must say its real size.
- **Persist mirrored entries, as the queue owner's cache.** Rejected: when no queue owner
  listens, the plugin cannot render or deliver them, and the queue owner keeps them itself.

## Consequences

A future consumer that must treat a mirrored entry differently reads `mirrored`, and the
list above grows. A consumer that only needs "no file" reads the kind, as today.

A mirrored entry that the reviewer drops while its `remove` has no reply, and then the
connection closes, comes back with the next snapshot: the plugin records no pending
removal for it, because the queue owner holds it and can drop it in its own queue.
