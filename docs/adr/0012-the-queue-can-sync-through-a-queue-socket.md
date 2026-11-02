# The queue can sync through a queue socket

The plugin can share its **queue** with a **queue owner**: a process at the far end of a
Unix socket that speaks the queue socket protocol (version 1). This is the **sync**. While a
queue owner listens, each capture goes to it with `keep`, and the `queue` event that it
sends back becomes the plugin's queue. When no queue owner listens, the plugin keeps its own
queue, as before. The protocol names no tool, so the plugin does not name one either.

This is the first transport that the plugin ships. ADR-0001 keeps every transport out of the
plugin, so this ADR says why the sync is not an **adapter**, and what the host still says.

**Not an adapter, because a snapshot can only become entries with the plugin's own knowledge
of an entry.** An adapter takes a **payload** and gives nothing back that the plugin must
read. A sync is the opposite: the queue owner sends the queue back, and each note in it must
become an **entry** again, with its **anchor**, its **blob**, its **kind** and its **range**.
Only the plugin knows that shape. A host that wrote this transport would have to write the
plugin's entry shape too, and keep it true each time that shape changes. So the plugin
writes `origin` into each note that it makes, and it is the only one that reads it back.

**The host still says where and who, in the spirit of ADR-0001.** The plugin finds no socket
by itself: the host gives the path, `sync.socket`. And the plugin chooses no agent: the host
gives the `target` adapter, which turns its own target into the queue owner's
`{ tool, address, cwd }`. Without `sync`, the plugin does not connect, and nothing changes.

**One module speaks the protocol.** `sync.lua` owns the connection, the framing, the
replies, the events and the retry. The queue stays a leaf that requires nothing; the sync
tells it what the queue is.

## Considered options

- **A `send` adapter that a host points at the socket.** Rejected: it delivers a batch, but
  it cannot bring back the queue of another tool, and it cannot tell the plugin which of its
  entries the other tool changed or dropped.
- **The host writes the whole sync as an adapter.** Rejected, for the reason above: the host
  would have to rebuild entries, which is the plugin's own knowledge.
- **Find the socket of a known tool by itself.** Rejected: that names a tool, and ADR-0001
  says the host chooses.

## Consequences

The plugin now has code that opens a socket. It is off by default, and a failed connect is
silent, so a host without a queue owner sees no change. The tests run the sync against a
fake queue owner on a real socket (`tests/fake_queue_owner.lua`); the real queue owner has
its own suite, and no test here starts it.

A queue owner holds the queue while it listens, so the plugin's entries can change in
another process. The integer id of an entry stays the plugin's own: a uuid that the plugin
has not seen gets the next id, in snapshot order.

A submit while the sync runs goes to the queue owner as `send`, and its reply is the
dispatch of ADR-0005. The reply does not empty the queue and does not write the archive:
the queue owner's next snapshot empties the queue, and its `sent` event writes the
archive, whoever caused it. So a reply that comes after the submit's wait cannot send a
batch twice or lose one.

An edit of a note, a change of type and a drop go to the queue owner too, as `update` and
`remove`, and so does each **stale** mark that a reconcile changes. The plugin changes its
own queue at once, and the next snapshot confirms the change. An edit, a change of type or
a stale mark that the queue owner refuses, or does not answer, wins in Neovim over each
snapshot until the next connect, which sends it again: a note that the reviewer typed is
not lost for a reply that did not come. A refused drop is undone, because the entry is
still in the queue that the queue owner submits.
