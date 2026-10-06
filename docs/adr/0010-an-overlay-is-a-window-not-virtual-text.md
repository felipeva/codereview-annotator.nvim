# An overlay is a window, not virtual text

_Narrowed by [ADR-0011](0011-a-caption-is-virtual-text-because-it-takes-no-cursor.md): true of the **margin**; the overlay's inline style is virtual text for the reasons given there._

The **review view** draws a queued **note** as virtual lines under its anchor row, and the
obvious way to show the **queue** on an ordinary buffer was the same mechanism, extracted
from the render. The **overlay** is a **margin** instead: a split to the right of the file's
window, holding one **card** per **entry** at the screen row of its anchor. The split was
chosen because a card has to be reachable — the cursor enters it, and the queue float's keys
work on it — and because a note beside a line is what the reviewer asked for, not under it.
Virtual text cannot be entered, and right-aligned virtual text draws over the code on any
line long enough to reach it.

## Considered options

- **Virtual lines under the anchor.** The review view's format, unchanged, at a third of
  the work. Rejected: the block cannot take a cursor, so every action on an entry has to
  go through a host-bound key or back to the float, and it sits under the line rather than
  beside it.
- **Right-aligned virtual text on the rows beside the anchor.** One extmark per card row,
  each on a real buffer line. Rejected: `right_align` draws over the code where a line is
  long, `eol_right_align` truncates the card instead, and a tall card hides more code than
  it explains.
- **A margin split.** Chosen. Costs window width while on, and a repaint from each anchor's
  screen row on every scroll, resize and fold change — the same work the sticky header
  already does. It is not scrollbound: scrollbind tracks line deltas, and with wrap on the
  code side screen rows diverge, so the margin is rebuilt from `screenpos` rather than
  bound.

## Consequences

Cards stack: a card taller than the gap to the next anchor pushes the next one down, so a
card can sit rows below its anchor. The header names the anchor's lines for that reason. A
card is drawn only while its anchor row is in the window, and the margin never scrolls on
its own. The buffer's content is never touched, and nothing an overlay draws reaches the
**payload** or the **archive**: like **solo**, it is a session-long toggle written nowhere.
