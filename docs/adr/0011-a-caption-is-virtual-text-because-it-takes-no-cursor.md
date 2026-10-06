# A caption is virtual text, because it takes no cursor

ADR-0010 made the **overlay** a window: a **card** has to take a cursor, and right-aligned
virtual text draws over any line long enough to reach it. The overlay's second drawing, the
**caption**, is virtual text — one virtual line above the entry's anchor, wrapped to the
window's width — and ADR-0010's two reasons are why that is consistent rather than a
reversal. A caption is display only: every action on an entry goes through the queue float
or the **margin**, so no cursor has to land on it. And a virtual *line* takes a row of its
own above the code, so it draws over nothing.

The two drawings are one overlay: the same entries, the same skip rules, the same **stale**
flag, the same sign on each covered line, the same session-long toggle written nowhere. A
style setting picks the drawing, and nothing about the choice reaches the **payload** or the
**archive** (ADR-0009).

## Considered options

- **Below the anchor, as the review view draws a note.** Rejected: a note under a diff line
  reads as a reply to it, which is right for a diff; a caption above a line of a file reads
  as a title for what follows, which is what a reviewer wants while reading the file.
- **Both drawings at once.** Deferred: one toggle, two exclusive styles in version one. A
  third value can be added without changing either drawing.
- **A background tint on the covered lines.** Deferred: a line-wide background wins over the
  cursor line, so the cursor vanishes inside a tinted range. The sign on each covered line
  is enough to mark the range until that is solved.
  _Shipped in #277: the row the cursor is on is left untinted, so the cursor line shows, which
  answers the reason it was deferred._

## Consequences

ADR-0010 is narrowed, not reversed: its statement is true of the margin. A caption cannot be
acted on where it is drawn. A long note costs rows above the code, because the note is
wrapped in full rather than cut at the window's edge, and the rows are re-broken on resize.
