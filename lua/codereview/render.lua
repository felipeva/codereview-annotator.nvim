---Turn a parsed diff into buffer lines, extmarks, and the anchor map.
---
---Pure: takes data and returns data. No buffers, no windows, no git. The anchor map it
---produces is the single source of truth that navigation, annotation targeting, collapse
---and the syntax replay all read -- every "which change is row 47?" question is answered
---here and nowhere else.
---
---`build` returns **two** renders from **one** walk: the after-pane render, and the
---before-pane render, which is nil in the unified layout. One walk rather than two calls is
---what makes row alignment a property of the returned data, guaranteed by construction,
---rather than an emergent property of two independent calls agreeing -- and it is what lets
---every property that makes the split layout correct be asserted with no window on screen.
---
---What a *file* is called is here too, in `file_label`, for surfaces that name one somewhere
---other than in the diff -- the winbar's **sticky header** is the second. Which icon it
---carries, how a rename is spelled in each layout and which files have a pre-image side are
---rules rather than formats, and two copies of them would answer differently on the first
---file only one of the two authors had in mind.
---
---And, for the same reason and the same surface, how a winbar is *assembled*: `bar` takes
---an ordered list of typed segments and returns the string a bar is set to, escaping every
---name the plugin did not choose. That a repository's own file name can never be read as a
---statusline item is a rule as well, and it is the one this module holds at the highest
---point it can be held at. What the bar *says* stays with the view.
local M = {}

---@class CRAnchor
---@field kind "file"|"hunk"|"line"|"pad"|"note"|"fill"
---@field file integer        Index into the file list
---@field hunk integer|nil    Index into that file's hunks
---@field line integer|nil    Index into that hunk's lines
---@field col integer|nil     Byte offset where code text starts, for the syntax replay

---@class CRRender
---@field lines string[]
---@field anchors table<integer, CRAnchor>  Keyed by 1-indexed buffer row
---@field marks table[]                     { row, col, opts } for nvim_buf_set_extmark
---@field file_rows table<integer, integer> File index -> its 1-indexed header row. Sparse
---                                         under **solo**: one entry, at the drawn file's
---                                         own index. A file it says nothing about is a
---                                         file this render did not draw, which is not a
---                                         failure -- see `build`'s `solo` option.
---@field hunk_rows integer[]               1-indexed row of every visible hunk header
---@field gutter integer                    Display columns before the code on a diff row

local SEP = " │ "

---The layouts a review can be rendered in. `unified` is what has always existed; `split`
---draws the same diff as two panes, the before-image beside the after-image.
M.LAYOUTS = { "unified", "split" }

---Explicit so the layers compose predictably: diff backgrounds sit underneath, the
---treesitter foregrounds `syntax.lua` adds sit on top. Leaving these at the extmark
---default makes the result depend on insertion order, which changes as the view repaints.
---
---`span` sits above the line's own background, so the emphasis is visible at all, and
---below the syntax replay, so code coloring survives inside an emphasized span.
M.PRIORITY = { diff = 100, gutter = 110, span = 120, syntax = 150 }

---The **frame**'s two rows, keyed by whether the file is reviewed.
---
---`top` fills the file's header row with the **band**, in place of the group that row would
---carry anyway, and `bottom` goes on the blank **pad** row that closes its body. `hl.lua`
---computes all four; this table is the only place that decides which pair a file takes.
---
---**`bottom` draws nothing on a true-colour terminal, and is emitted all the same.** The band
---is a beginning nobody can scroll past without seeing, so the rule that closed the file above
---it was retired with the doubled hairline it made. What the group still holds is that rule
---for the terminal that can compute no band, and the row it holds it on is a row the diff had
---anyway.
---
---A **collapsed** file takes `top` and never `bottom`. It has no body to bound, and out on
---that terminal two rules with nothing between them read as a broken frame rather than as a
---closed file.
---@type table<boolean, { top: string, bottom: string }>
local FRAME = {
  [false] = { top = "CodeReviewFrameHeader", bottom = "CodeReviewFramePad" },
  [true] = { top = "CodeReviewFrameReviewed", bottom = "CodeReviewFramePadReviewed" },
}

---Stable identity for an annotatable line, independent of buffer position.
---
---Sided because a deleted line and an added line can share a number: `foo.ts:o:20` and
---`foo.ts:n:20` are different places, and collapsing them would move annotations onto
---code they were never about.
---
---Also what decides which **pane** a note is drawn in, since the side is already in the
---key: no second rule is introduced for the split layout.
---@param path string
---@param line CRLine
---@return string
function M.line_key(path, line)
  if line.new then
    return ("%s:n:%d"):format(path, line.new)
  end
  return ("%s:o:%d"):format(path, line.old)
end

---Anchor key for an annotation about a whole file. Shares the `path:` prefix that the
---per-file note tally scans for, and cannot collide with a line key.
---@param path string
---@return string
function M.file_key(path)
  return path .. ":f:0"
end

---Whether a key names a place in the pre-image, and so belongs to the before pane.
---
---Only a pure deletion produces one: a context line exists on both sides and its key
---prefers the post-image, which is why context reads in the after pane.
---@param key string|nil
---@return boolean
function M.is_before_key(key)
  return key ~= nil and key:find(":o:%d+$") ~= nil
end

---Widest line number anywhere in the diff.
---
---Computed across all files, not just expanded ones, so the gutter does not resize --
---and every row shift -- when a file is expanded. Shared by both panes, so their gutters
---are the same width and their code starts at the same column.
---@param files CRFile[]
---@return integer
local function gutter_digits(files)
  local max = 1
  for _, file in ipairs(files) do
    for _, hunk in ipairs(file.hunks) do
      for _, ln in ipairs(hunk.lines) do
        local n = ln.new or ln.old or 0
        if n > max then
          max = n
        end
      end
    end
  end
  return #tostring(max)
end

---How many display columns a diff line row spends before its code starts.
---
---The change bar, the line number padded to `digits`, the separator and the sign -- the
---prefix `line_text` below assembles, measured rather than counted: the bar and the
---separator are both multibyte, and this answers a question about the screen.
---
---Reported on the render so that the view, which indents a folded line's continuation rows
---by exactly this, reads it rather than working it out again. Two answers about where the
---code starts would drift apart on the first review whose line numbers grew a digit.
---
---Measured against a *changed* row, whose prefix opens with the change bar. A context row
---opens with a single space instead, so a host that configures a bar wider than one column
---already draws its context code one column to the left of its changed code -- and this
---follows the changed rows, which are what the bar column is there for.
---@param icons table
---@param digits integer
---@return integer
local function gutter_width(icons, digits)
  return vim.fn.strdisplaywidth(icons.change_bar) + digits + vim.fn.strdisplaywidth(SEP) + 1
end

---@param n integer
---@param width integer
---@return string
local function rpad_num(n, width)
  local s = tostring(n)
  return (" "):rep(math.max(0, width - #s)) .. s
end

---@param text string
---@param width integer
---@return string
local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(1, width - 1)) .. "…"
end

---Exported for the queue float, which draws rows of its own into a window narrower than
---most paths. Fitting text into a column count is this module's job wherever the text goes;
---a second copy would be a second set of rules about what "too wide" means.
M.truncate = truncate

---`text`, followed by blanks until it has spent `width` display columns.
---
---By display width rather than by byte count, which is what `("%-8s"):format` does: a glyph
---or a name outside ASCII costs more bytes than it draws, and the column it is meant to hold
---collapses by the difference. `truncate`'s neighbour, and here for its reason -- fitting
---text into a column count is this module's job wherever the text goes.
---
---Right-padding only. `trim_float` pads the other way, to right-align a date under a date,
---and that is a different operation rather than this one with a flag.
---@param text string
---@param width integer Display columns
---@return string
function M.pad(text, width)
  return text .. (" "):rep(math.max(0, width - vim.fn.strdisplaywidth(text)))
end

---The last `width` display columns of `text`, with `…` where the head was cut.
---
---`truncate`'s mirror, and the **sticky header**'s: a path that has to give up columns
---gives up the directories above it, because the file's own name is at the end of it and
---that is the part being kept. Cutting the other way keeps the part every file in a
---directory shares and drops the only part that says which file this is.
---
---By display width, like everything else here: a path a reviewer's repository chose can
---hold anything, and counting its bytes overshoots the moment one of them is not ASCII.
---@param text string
---@param width integer
---@return string
local function keep_tail(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  -- One column goes to the ellipsis. Below two there is nothing left to say but that
  -- something was cut, which is still worth saying.
  if width <= 1 then
    return "…"
  end
  local chars = vim.fn.strchars(text)
  local lo, hi = 0, chars
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, chars - mid)) <= width - 1 then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return "…" .. vim.fn.strcharpart(text, chars - lo)
end

M.keep_tail = keep_tail

---`keep_tail` over typed segments: the last `width` columns of what they draw, still typed.
---
---The **sticky header** cuts a path from the left, and now that a path is styled the cut has
---to survive with its styling on it -- so what comes back is segments and not a string. What
---a narrow pane keeps is the file's own name, which is the bright segment at the end, and the
---`…` is chrome the plugin wrote rather than part of any name.
---
---Delegated to `keep_tail` rather than re-derived, so there is one rule about what "too wide"
---means and one about where a cut falls. The mapping back is by byte, and can be: `keep_tail`
---cuts on character boundaries, so the position it leaves is a position in the joined text and
---in exactly one segment of it.
---@param segments CRBarSegment[]
---@param width integer
---@return CRBarSegment[]
function M.keep_tail_segments(segments, width)
  local text = M.segment_text(segments)
  local kept = keep_tail(text, width)
  if kept == text then
    return segments
  end
  -- What `keep_tail` kept, as bytes taken off the head. Its own `…` is dropped here and put
  -- back below as a segment of its own, so it carries a kind like everything else on a bar.
  local drop = #text - (#kept - #"…")
  local out = {}
  local seen = 0
  for _, seg in ipairs(segments) do
    local from = math.max(drop - seen, 0)
    if from < #seg.text then
      if #out == 0 then
        -- The ellipsis takes the group of the segment it cut into, so the cut reads as part
        -- of the thing that was cut rather than as a mark of its own.
        out[1] = M.chrome("…", seg.hl)
      end
      out[#out + 1] = from > 0 and { kind = seg.kind, text = seg.text:sub(from + 1), hl = seg.hl } or seg
    end
    seen = seen + #seg.text
  end
  -- A pane too narrow to hold even one column of the name: `keep_tail` says so with the
  -- ellipsis alone, and so does this.
  return #out > 0 and out or { M.chrome("…") }
end

---Longest prefix of `text` that fits in `width` display columns, and what is left.
---
---By display width rather than by characters: a note containing CJK or an emoji occupies
---more columns than it has characters, and cutting by character count would overflow.
---@param text string
---@param width integer
---@return string head, string tail
local function take(text, width)
  local lo, hi = 0, vim.fn.strchars(text)
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, mid)) <= width then
      lo = mid
    else
      hi = mid - 1
    end
  end
  lo = math.max(1, lo)
  return vim.fn.strcharpart(text, 0, lo), vim.fn.strcharpart(text, lo)
end

---Break `text` into lines no wider than `width` display columns.
---
---Virtual lines clip at the window edge rather than wrapping, so a note that arrives
---unbroken is silently truncated in a narrow pane. Breaking on whitespace where there is
---one, and mid-word only when a single word is wider than the pane -- which loses nothing,
---where clipping loses the tail.
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
  if width < 1 then
    return vim.split(text, "\n", { plain = true })
  end
  local out = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    local rest = para
    if rest == "" then
      out[#out + 1] = ""
    end
    while rest ~= "" do
      if vim.fn.strdisplaywidth(rest) <= width then
        out[#out + 1] = rest
        rest = ""
      else
        local head, tail = take(rest, width)
        -- Last whitespace inside the part that fits. `head` is a byte-prefix of `rest`, so
        -- the position it reports is a position in `rest` too.
        local cut = head:match("^.*()%s")
        if cut and cut > 1 then
          out[#out + 1] = (head:sub(1, cut - 1):gsub("%s+$", ""))
          rest = (rest:sub(cut):gsub("^%s+", ""))
        else
          out[#out + 1] = head
          rest = tail
        end
      end
    end
  end
  return out
end

---Exported for the queue float, which wraps the same notes into rows of its own. By display
---width is the whole point of sharing it: splitting a note by byte passes every ASCII
---assertion and breaks the first CJK or emoji one it meets, which is the trap intra-line
---spans already walked into once.
M.wrap = wrap

---Split a hunk header into the halves each pane draws.
---@param header string "@@ -19,6 +19,8 @@ heading"
---@param hunk CRHunk
---@return string old, string new
local function header_ranges(header, hunk)
  local old, new = header:match("^@@ (%-[%d,]+) (%+[%d,]+) @@")
  return old or ("-%d"):format(hunk.old_start), new or ("+%d"):format(hunk.new_start)
end

---@param gutter integer Display columns every diff line row spends before its code
---@return table
local function new_pane(gutter)
  return { lines = {}, anchors = {}, marks = {}, file_rows = {}, hunk_rows = {}, gutter = gutter }
end

--- How a path is styled -------------------------------------------------------

---The group the directories above a file draw in: the part every sibling file shares, and
---the part that therefore stops competing for a reviewer's eye.
local DIR = "CodeReviewFileDir"

---The group a file's own name draws in: the part that says which file this is.
local NAME = "CodeReviewFileName"

---One path, as the ordered segments it is drawn as.
---
---**The split is at the last separator**: everything up to and including it is quiet, the
---rest is bright. A file at the repository root has no quiet half and is not a special case
---anybody notices -- the branch below simply does not fire, and one segment comes out.
---
---Literals, both halves, because a path is a name the reviewer's repository chose. That is
---the whole reason the kinds exist: a `%` in one would be read as a statusline item on the
---**sticky header** and expanded into something else. `M.literal` is defined below, with
---the rest of the winbar's vocabulary -- this reuses that vocabulary rather than inventing a
---second one, because the two surfaces that draw a path are the header row and that bar.
---@param path string
---@param out CRBarSegment[] Appended to, so a rename can spell two paths into one list
local function path_segments(path, out)
  local cut = path:match("^.*()/")
  if cut then
    out[#out + 1] = M.literal(path:sub(1, cut), DIR)
  end
  out[#out + 1] = M.literal(path:sub(cut and cut + 1 or 1), NAME)
end

---A host's own glyph for a file, and the group that colours it -- or nil when it has none.
---
---**Exported because three surfaces name a file and one rule decides what its glyph is.**
---The diff's header row and the **sticky header** read it through `file_label`; the **file
---tree** reads it here, because a tree row is not a label and needs the glyph alone. Two
---copies of this rule is two places for those surfaces to come to disagree about the same
---file, which is the whole of *one file, one icon*.
---
---**The group is carried out beside the glyph because both icon plugins answer with it.**
---`nvim-web-devicons.get_icon` answers with a glyph and the name of the group that colours
---it, and `MiniIcons.get` answers with the same pair. Reading the first and dropping the
---second is what drew every wired glyph in the surface's own foreground -- a Lua file's
---glyph measured on a tree row as `#e0e2ea`, the tree's own colour, where `mini.icons` had
---chosen `#8cf8f7`. Colour is most of what makes a tree readable at a glance, and it was
---being thrown away here rather than anywhere a reviewer could reach.
---
---**Two return values and not a table.** A table would be one allocation per file, and this
---is asked 601 times on a three-hundred-file paint and 301 more on every **file crossing**
---(see the performance notes). Two values allocate nothing at all, and they leave a caller
---that wants the glyph alone -- `file_label`'s does -- unchanged, because Lua truncates the
---second away on its own.
---
---**The guard is at the call site and it is the performance rule made structural.** There is
---no glyph shipped behind this adapter and therefore no default implementation of it to
---call: with nothing wired the answer is an absence, reached by a nil test rather than by a
---function, three hundred times on a large review. The nil test stays out there, at each
---caller, rather than moving in here: a nil adapter answered inside this function is still
---a call per file, and the tree is rebuilt on every file crossing as well as on every paint.
---
---`pcall` because a paint is the wrong place to raise from: a host's icon plugin is called
---once per file per paint, and an adapter that throws would take down every review rather
---than the one file it could not name. What comes back is checked as well as caught -- a
---number or a table would reach the header row as `123` or as `table: 0x...` and move every
---byte offset on the row behind it. Both failures answer the same way, which is the way no
---adapter answers: no glyph, and a row that reads exactly as it reads without one.
---
---**A group is checked the same way, and dropped on its own.** A group reaches an extmark
---as a name, and a number or a table there raises on the paint that emits it -- which would
---take down the review the glyph was there to help read. So a broken group costs the colour
---and never the glyph: the file draws as one whose adapter gave a glyph alone, which is a
---row a reviewer already knows how to read. An empty string is dropped with them, for the
---reason an empty glyph is: it is an absence spelled the expensive way, and no theme defines
---it. `MiniIcons.get` answers with a third value as well, a boolean, and a host handing the
---answer through in the wrong order arrives here -- as a dropped colour rather than an error.
---@param adapter fun(path: string): string|nil, string|nil
---@param path string
---@return string|nil glyph
---@return string|nil group The group the glyph is drawn in; nil for the row's own colour
function M.file_icon(adapter, path)
  local ok, glyph, group = pcall(adapter, path)
  if not ok or type(glyph) ~= "string" or glyph == "" then
    return nil
  end
  if type(group) ~= "string" or group == "" then
    return glyph
  end
  return glyph, group
end

---@class CRFileLabel
---@field reviewed boolean       Whether the file is marked reviewed
---@field expanded boolean       Whether its body is drawn, with the default already applied
---@field notes integer          Queued annotations anywhere in it
---@field icon string            The **state** mark: reviewed, annotated or unreviewed
---@field file_icon string|nil   A host's own glyph for the file, beside that mark; nil for none
---@field chevron string
---@field prefix string          Those three and their separators: what both surfaces draw
---                              in front of the path, and the bytes the path starts at
---@field name CRBarSegment[]    Its path as this layout spells it: `old → new` when unified
---@field before CRBarSegment[]|nil  The pre-image path; nil for a file with no pre-image
---@field stat string            `+N -M`, or `binary`
---@field right string           That stat, with the note count beside it when there is one

---How a file is named, wherever it is named.
---
---Everything here is a *rule* rather than a format: which icon a file carries, whether it
---counts as expanded when nothing has said, how a rename is spelled in each layout, and
---which files have a pre-image side to name at all. The in-buffer file header asks, and so
---does the **sticky header** on the winbar -- one function, because a second copy of these
---answers would drift on the first file whose status only one of the two surfaces had in
---mind, and a reviewer would then be told two things about one file at once.
---
---**The paths come back as typed segments rather than as a flat string**, and that is what
---keeps the two surfaces one answer now that a path is styled: the header row paints those
---segments at byte offsets and the winbar turns the same ones into markup. A string would
---have left each surface to split it again, which is two rules the moment either moved.
---@param file CRFile
---@param opts { icons: table, file_icon: (fun(path: string): string|nil, string|nil)|nil, reviewed: table<string, string>|nil, expanded: table<string, boolean>, notes: table<string, table[]>|nil, layout: string|nil }
---@return CRFileLabel
function M.file_label(file, opts)
  local icons = opts.icons
  local reviewed = opts.reviewed and opts.reviewed[file.path] ~= nil
  local expanded = opts.expanded[file.path]
  if expanded == nil then
    expanded = not reviewed
  end

  -- Count notes on this file so the header can advertise them even when collapsed --
  -- otherwise a reviewed file silently hides the comments you left on it.
  local notes = 0
  if opts.notes then
    for key, items in pairs(opts.notes) do
      if key:sub(1, #file.path + 1) == file.path .. ":" then
        notes = notes + #items
      end
    end
  end

  local stat = file.binary and "binary" or ("+%d -%d"):format(file.added, file.removed)
  local split = opts.layout == "split"

  local name = {}
  if not split and file.old_path then
    path_segments(file.old_path, name)
    -- The arrow is the plugin's own chrome, so it reads as punctuation rather than as part
    -- of either name -- and it takes the directories' quiet rather than a group of its own,
    -- which the muting and the fade would both have to carry for a distinction nobody could
    -- see. What is left bright either side of it is the two names, which is the point.
    name[#name + 1] = M.chrome(" → ", DIR)
  end
  path_segments(file.path, name)

  local before = nil
  if file.status ~= "A" and file.status ~= "U" then
    before = {}
    path_segments(file.old_path or file.path, before)
  end

  local icon = reviewed and icons.reviewed or (notes > 0 and icons.annotated or icons.unreviewed)
  local chevron = expanded and icons.expanded or icons.collapsed
  -- The **state** mark above keeps its column and its meaning; this is a second thing about
  -- the file rather than a replacement for it, so that a reviewer never loses *this file is
  -- reviewed* in exchange for *this file is TypeScript*. Nothing is wired is the common case
  -- and costs the comparison in front of the `and`: the adapter is the only implementation
  -- there is, so with none of it there is nothing to call.
  local file_icon = opts.file_icon and M.file_icon(opts.file_icon, file.path) or nil

  return {
    reviewed = reviewed,
    expanded = expanded,
    notes = notes,
    icon = icon,
    file_icon = file_icon,
    chevron = chevron,
    -- What both surfaces draw in front of the path, spelled once here rather than twice out
    -- there. The header row paints its path at `#prefix` bytes and the winbar puts the same
    -- string in one literal, so the offset a mark lands at and the columns a bar spends are
    -- the same answer -- and a glyph a host chose cannot reach either surface unescaped or
    -- at the wrong column because one of the two spellings was not updated.
    --
    -- **With nothing wired this is byte-for-byte the string it always was.** The separator
    -- rides with the glyph rather than standing beside it, so a file with no glyph
    -- contributes nothing here at all rather than a space -- which would shift every path
    -- offset on every header row in every review by one byte, and look right while doing it.
    prefix = ("%s %s %s"):format(icon, chevron, file_icon and file_icon .. " " or ""),
    -- A rename reads as a rename when each pane draws its own path; only the unified
    -- layout, which has one header to say it in, spells the arrow out. Both of its paths
    -- take the rule, because dimming one of them says the wrong thing about which is which.
    name = name,
    -- The half the before pane holds. A file that exists only on the after side has no
    -- pre-image path at all, and neither its header row nor its winbar names one.
    before = before,
    stat = stat,
    right = notes > 0 and ("%s  [%d note%s]"):format(stat, notes, notes == 1 and "" or "s") or stat,
  }
end

--- The winbar ------------------------------------------------------------------

-- How a bar is assembled, beside what a file on it is called. A winbar is a statusline, so
-- what reaches it is markup rather than text, and a bar is therefore built from segments
-- that each say what they are: chrome, which the plugin wrote and may carry a highlight
-- group, or a literal, which is a name the plugin did not choose and is escaped.
--
-- The view keeps saying *what* the bar says; what is here is *how a bar is assembled
-- safely*, which is a rule and not a format -- the same reason `file_label` is here.

---@class CRBarSegment
---@field kind "chrome"|"literal"
---@field text string
---@field hl string|nil          Highlight group, or nil to draw in the bar's own

---Chrome: a piece of the bar the plugin itself wrote.
---
---The one kind that is not escaped, which is what lets it carry statusline markup at all --
---a highlight group being the only markup this bar has any use for. `hl` is how to ask for
---one, and it ends where the segment does, so a group one segment carries never runs on
---into the next.
---@param text string
---@param hl string|nil
---@return CRBarSegment
function M.chrome(text, hl)
  return { kind = "chrome", text = text, hl = hl }
end

---A literal: text drawn exactly as it stands, whoever chose it.
---
---Every `%` in it is doubled, and **this is the rule the whole seam exists for**. A path is
---a name the reviewer's repository chose, and a `%f` in one would otherwise be read as a
---statusline item and expanded into something else -- the window's own file name, in that
---case, which is not even the file the bar is naming. The same holds for every other name
---the plugin did not choose: a **scope**'s label, a **target**'s short name, a base
---revision, and a glyph a host put in the icon table.
---
---A segment has to say which kind it is precisely so this cannot be forgotten. There is no
---way onto the bar that does not go through one of these two functions, and the one that
---takes a name is the one that escapes it.
---
---A literal takes a highlight group as chrome does, and for the reason the escape exists:
---most of what is worth coloring on this bar is a name -- the **target**, the base
---revision, a count carrying a configured glyph -- and the alternative is a caller writing
---the markers around one by hand, which is markup arriving from outside the one seam that
---decides what markup is. The escape is unchanged by it: the name is doubled, and the
---markers go outside what was doubled.
---@param text string
---@param hl string|nil
---@return CRBarSegment
function M.literal(text, hl)
  return { kind = "literal", text = text, hl = hl }
end

---@param seg CRBarSegment
---@return "chrome"|"literal"
local function kind_of(seg)
  local kind = type(seg) == "table" and seg.kind
  assert(kind == "chrome" or kind == "literal", "a winbar segment must say whether it is chrome or a literal")
  return kind
end

---One winbar, from the segments it is made of.
---@param segments CRBarSegment[]
---@return string
function M.bar(segments)
  local out = {}
  for i, seg in ipairs(segments) do
    local text = seg.text
    -- Escape by kind, color whatever asked for it: the two are separate questions, and a
    -- name that is colored is still a name.
    if kind_of(seg) == "literal" then
      text = (text:gsub("%%", "%%%%"))
    end
    if seg.hl then
      text = ("%%#%s#%s%%*"):format(seg.hl, text)
    end
    out[i] = text
  end
  return table.concat(out)
end

---The plain text those segments draw: no escaping, no markup, and no highlight groups.
---
---What the *header row* is built from, where the same segments are painted with extmarks
---rather than with statusline markup -- so a path is spelled once and both surfaces spell it
---the same way. Never what reaches a winbar: that goes through `M.bar`, which is where the
---escaping is.
---@param segments CRBarSegment[]
---@return string
function M.segment_text(segments)
  local out = {}
  for i, seg in ipairs(segments) do
    out[i] = seg.text
  end
  return table.concat(out)
end

---How many columns those segments take on the screen.
---
---The ruler everything that pads or fits a bar measures with, and it measures what is
---*drawn* rather than what is written. Two things separate the two, and they pull opposite
---ways: an escaped `%` is two characters and one column, and a highlight marker is several
---characters and no columns at all. A bar padded by the length of a string holding either
---one lands short of its pane -- which is the byte-versus-column trap the padding already
---walked into once, arriving from the other side.
---@param segments CRBarSegment[]
---@return integer
function M.bar_width(segments)
  local width = 0
  for _, seg in ipairs(segments) do
    local text = seg.text
    if kind_of(seg) == "chrome" and text:find("%", 1, true) then
      -- `%#Group#` and the `%*` that ends one, whichever way they got here.
      text = text:gsub("%%#[^#]*#", ""):gsub("%%%*", "")
    end
    width = width + vim.fn.strdisplaywidth(text)
  end
  return width
end

---How many characters of an object name a person reads it by.
---
---git's own default for `--short`, and what a log, a review tool and a commit message all
---shorten to. Not configurable: a bar naming seven characters while the reviewer's terminal
---names eight is a difference nobody can act on.
local ABBREV = 7

---The lengths a full object name has: sha-1's forty characters, and sha-256's sixty-four.
---
---**Both, because which one a repository uses is a question only git can answer.** This
---function must not ask it -- see below -- and a sha-256 repository drawing its object names
---whole is exactly the fault this export exists to remove. Accepting both costs a table
---lookup; accepting one costs the fault coming back in the repositories nobody here runs.
local OBJECT_NAME = { [40] = true, [64] = true }

---What a base revision is called on a bar.
---
---**What `file_label` is for a file, this is for a revision.** The before **pane**'s winbar
---names two things, and both are now a rule returned as data: it reads without a window
---behind it, and it is asserted without a repository behind it.
---
---Everything a reviewer would recognise -- a **branch**, a tag, a name they typed -- comes
---back unchanged, because the one revision they *can* read must not be abbreviated into one
---they cannot. `:0` is git's name for the index and a name nobody reads as one; that rule
---lives here rather than at the winbar, so one function answers the whole question and a
---second surface naming a revision cannot come to answer it differently.
---
---**Decided from the shape of the name, never by asking git.** The bar is assembled on
---every paint and a paint runs on every resize, so a `rev-parse --short` here is a process
---per resize.
---
---**And git is what makes deciding by shape safe, rather than luck.** A run of hexadecimal
---exactly as long as an object name cannot mean anything else, because git will not let it:
---`git branch <40 hex>` succeeds, and `rev-parse` on that same string then answers the
---*object* and says why -- "Git normally never creates a ref that ends with 40 hex characters
---because it will be ignored when you just specify 40-hex". Measured. So a name of this shape
---reaching here has already been read as an object by the git that resolved the **scope**,
---and reading it as one here cannot disagree with that.
---
---Length alone was rejected as the test: a 40-character name that is *not* hexadecimal is a
---name somebody chose, and its first seven characters name nothing.
---@param rev string The **scope**'s before-revision
---@return string
function M.rev_label(rev)
  if rev == ":0" then
    return "index"
  end
  if OBJECT_NAME[#rev] and rev:match("^%x+$") then
    return rev:sub(1, ABBREV)
  end
  return rev
end

---Build the view.
---
---Returns the after-pane render first because the after-image is the primary one
---throughout: context lines are attributed to it, line keys prefer it, an entry's line
---numbers prefer it, and opening a file resolves through it. In the unified layout the
---second return value is nil, which is what every existing caller already ignores.
---`notes` is the queue projected onto anchors; `archived` is the archive projected onto the
---same ones, and is optional -- absent, nil and empty are one case, and the render is then
---exactly what it was before an archive existed. `touched` is what the reconciliation made
---of those archived entries, keyed by entry id, and is optional for the same reason: an id
---it says nothing about is an entry nothing has judged.
---
---`solo` is the file to draw -- **the render is told which file to draw, and is never
---handed a shorter list**. It is an index into `files`, or nil for all of them. The walk
---below is the same walk over the same list; only which files emit rows changes, so the
---file index in every **anchor**, in `file_rows` and in the header row it points at stays
---the *true* index into the review's file list.
---
---The obvious alternative is for the caller to filter its own file list to one entry and
---call this as it always did. That collapses the index space: every anchor would say file
---1 while the **file tree**, the file picker and the reviewed marks still speak the real
---index, and the two would silently disagree about which file is which. One index space is
---the decision (ADR-0009), and this option is what buys it.
---@param files CRFile[]
---@param opts { width: integer, before_width: integer|nil, layout: string|nil, icons: table, file_icon: (fun(path: string): string|nil, string|nil)|nil, expanded: table<string, boolean>, reviewed: table<string, string>, notes: table<string, table[]>, archived: table<string, table[]>|nil, touched: table<integer, boolean>|nil, solo: integer|nil, types: CRType[] }
---@return CRRender after, CRRender|nil before
function M.build(files, opts)
  local icons = opts.icons
  local split = opts.layout == "split"
  local solo = opts.solo
  local width = math.max(40, opts.width or 80)
  local before_width = math.max(40, opts.before_width or width)
  local digits = gutter_digits(files)
  local gutter = gutter_width(icons, digits)

  local after = new_pane(gutter)
  local before = split and new_pane(gutter) or nil

  ---@param pane table
  ---@param row integer 1-indexed
  ---@param col integer 0-indexed byte
  ---@param opts_ table
  local function mark(pane, row, col, opts_)
    if opts_.priority == nil and not opts_.virt_lines then
      opts_.priority = opts_.line_hl_group and M.PRIORITY.diff or M.PRIORITY.gutter
    end
    pane.marks[#pane.marks + 1] = { row = row - 1, col = col, opts = opts_ }
  end

  ---Color one path where it was drawn: its directories quiet, the file's own name bright.
  ---
  ---**In byte offsets, because that is what an extmark column is.** The icon and the chevron
  ---in front of a path are multibyte, so a mark placed at the *display* column lands four
  ---bytes early and colors the chevron instead of the first directory. Same arithmetic the
  ---change bar already does, arriving one row above the code.
  ---
  ---`limit` is where the row stops being the path -- the end of the fitted left-hand side on
  ---the after pane, the end of the whole row on the before pane. A header cut to fit its pane
  ---therefore takes its coloring with it: a segment wholly past the cut is never emitted, and
  ---the one the cut fell inside ends where the row does. An `end_col` past the end of a line
  ---is a hard error, so this is a rule and not a tidiness. The `…` truncate leaves behind
  ---takes the color of the segment it cut into, exactly as the sticky header's leading one
  ---does.
  ---@param pane table
  ---@param row integer 1-indexed
  ---@param col integer 0-indexed byte where the path starts on that row
  ---@param limit integer One past the last byte of that row the path may color
  ---@param segments CRBarSegment[]
  local function paint_path(pane, row, col, limit, segments)
    for _, seg in ipairs(segments) do
      local stop = math.min(col + #seg.text, limit)
      if seg.hl and col < stop then
        mark(pane, row, col, { end_col = stop, hl_group = seg.hl })
      end
      col = col + #seg.text
    end
  end

  ---@param pane table
  ---@param text string
  ---@param anchor CRAnchor
  ---@return integer row
  local function push(pane, text, anchor)
    pane.lines[#pane.lines + 1] = text
    pane.anchors[#pane.lines] = anchor
    return #pane.lines
  end

  ---One logical row, drawn in both panes.
  ---
  ---Every chrome row goes through here, which is what makes parity structural rather than
  ---something to remember: a row cannot be added to one pane without the other.
  ---@param atext string
  ---@param aanchor CRAnchor
  ---@param btext string|nil
  ---@param banchor CRAnchor|nil
  ---@return integer row
  local function row2(atext, aanchor, btext, banchor)
    local r = push(after, atext, aanchor)
    if before then
      push(before, btext or "", banchor or { kind = "fill", file = aanchor.file, hunk = aanchor.hunk })
    end
    return r
  end

  ---Append one annotation's virtual lines to `virt`.
  ---
  ---A sibling of `note_virt` rather than a loop inside it, deliberately. `note_virt` runs
  ---once per annotatable row -- ninety thousand times on a large review, almost always to
  ---answer "nothing here" -- and a nested closure inside it costs that answer measurably
  ---more: it took `render.build` on 60 files from 17 ms to 23 ms, on the operation every
  ---resize, expansion, reviewed toggle and scope change pays for.
  ---@param virt table[]
  ---@param item table
  ---@param wrap_to integer|nil
  ---@param archived boolean Drawn out of the archive rather than out of the queue
  local function entry_virt(virt, item, wrap_to, archived)
    local type_def = require("codereview.types").get(opts.types, item.type)
    local icon = type_def and type_def.icon or "•"
    -- An archived entry keeps its type's icon, because what kind of finding it was is still
    -- worth knowing, and gives up that type's color: severity is an instruction to act,
    -- and this one has already been acted on.
    local group = archived and "CodeReviewArchived" or (type_def and type_def.hl or "CodeReviewNote")
    local text_group = archived and "CodeReviewArchivedNote" or "CodeReviewNote"
    local prefix = ("   %s "):format(icon)
    -- In columns, never in bytes, and measured once so the budget a note wraps to and the
    -- indent its continuation rows carry cannot disagree. They did: `#prefix` and
    -- `strdisplaywidth(prefix)` are the same number for the four spaces an empty glyph left
    -- behind, and two apart for `   ✗ ` -- which put every continuation row two columns
    -- right of the prose it continues and pushed a wrapped note two columns past the pane.
    local indent = vim.fn.strdisplaywidth(prefix)

    -- One slot before the prose, and the two things that can occupy it never share an
    -- entry -- which is the rule, not an economy. A queued entry carries staleness: its
    -- file moved since it was *captured*, so its line anchor may be wrong and that is worth
    -- fixing before it goes. An archived entry carries touchedness: its file has or has not
    -- moved since its batch was *dispatched*, which says where the agent has been. An
    -- archived entry's `stale` flag is persisted with it and is deliberately not drawn --
    -- it is a fact about a queue that no longer exists, and against the code now it would
    -- read as a claim about the code now that nothing has checked.
    local flag, flag_group
    if archived then
      local moved = opts.touched and item.id and opts.touched[item.id]
      if moved ~= nil then
        -- Said of the file, never of the note. The plugin knows the bytes moved; it does
        -- not know that anyone read the remark, agreed with it or acted on it.
        flag = moved and "file changed  " or "file unchanged  "
        flag_group = moved and "CodeReviewTouched" or "CodeReviewUntouched"
      end
    elseif item.stale then
      flag, flag_group = "⚠ stale  ", "CodeReviewStale"
    end

    local body
    if wrap_to then
      -- The marker only prefixes the first line, but wrapping the whole note to the
      -- narrower budget is what makes "nothing is clipped" true by construction rather
      -- than true of every line except one.
      local avail = wrap_to - indent - (flag and vim.fn.strdisplaywidth(flag) or 0)
      body = wrap(item.note, math.max(8, avail))
    else
      body = vim.split(item.note, "\n", { plain = true })
    end

    -- A multi-line note becomes multiple virtual lines; the continuation lines are
    -- indented to the icon so the block reads as one comment.
    for n, text in ipairs(body) do
      if n == 1 then
        local chunks = { { prefix, group } }
        if flag then
          chunks[#chunks + 1] = { flag, flag_group }
        end
        chunks[#chunks + 1] = { text, text_group }
        virt[#virt + 1] = chunks
      else
        virt[#virt + 1] = { { (" "):rep(indent), text_group }, { text, text_group } }
      end
    end
  end

  ---The virtual lines an annotated row draws, or nil when nothing is attached to it.
  ---
  ---Queued entries first, archived ones beneath them: what is still to send outranks what
  ---has already gone. Both go into one list and therefore one extmark, so the split
  ---layout's mirroring -- which holds the opposite pane's place by counting virtual lines --
  ---keeps working on a count it did not have to learn anything new about.
  ---
  ---An anchor carrying nothing at all is the overwhelmingly common case and costs two
  ---lookups, which is what makes a file the archive says nothing about cost nothing extra to
  ---render however long that archive is.
  ---@param key string
  ---@param wrap_to integer|nil Pane width to wrap the note to; nil leaves it unwrapped
  ---@return table[]|nil
  local function note_virt(key, wrap_to)
    local live = opts.notes and opts.notes[key]
    local gone = opts.archived and opts.archived[key]
    if (not live or #live == 0) and (not gone or #gone == 0) then
      return nil
    end
    local virt = {}
    for _, item in ipairs(live or {}) do
      entry_virt(virt, item, wrap_to, false)
    end
    for _, item in ipairs(gone or {}) do
      entry_virt(virt, item, wrap_to, true)
    end
    return virt
  end

  ---@param n integer
  ---@return table[]
  local function blank_virt(n)
    local out = {}
    for i = 1, n do
      out[i] = { { "", "CodeReviewNote" } }
    end
    return out
  end

  ---Draw the notes on a row, and hold the opposite pane's place while they are drawn.
  ---
  ---A note costs the same vertical space in both panes because a virtual line occupies
  ---exactly one display line whatever its width, so mirroring the *count* is enough to
  ---keep the two panes' display heights identical.
  ---@param row integer
  ---@param before_key string|nil Pre-image key owning this row in the before pane
  ---@param after_key string|nil Post-image (or whole-file) key owning it in the after pane
  local function attach_notes(row, before_key, after_key)
    if not split then
      local virt = after_key and note_virt(after_key, nil)
      if virt then
        mark(after, row, 0, { virt_lines = virt })
      end
      return
    end

    local bvirt = before_key and note_virt(before_key, before_width) or nil
    local avirt = after_key and note_virt(after_key, width) or nil
    if not bvirt and not avirt then
      return
    end
    -- The before pane's own notes come first in both panes, so the blocks line up row for
    -- row and not merely in total height.
    local bcount, acount = bvirt and #bvirt or 0, avirt and #avirt or 0
    local bside = vim.list_extend(bvirt or {}, blank_virt(acount))
    local aside = vim.list_extend(blank_virt(bcount), avirt or {})
    mark(before, row, 0, { virt_lines = bside })
    mark(after, row, 0, { virt_lines = aside })
  end

  ---The **frame**'s bottom edge, on the blank **pad** row that closes a file's body.
  ---
  ---Both panes, and the same row in each, so the two images stay comparable row for row.
  ---
  ---Nothing is emitted for it. A line-wide group is painted across the full window width
  ---past the end of the text and carries its underline out there with it -- measured on 0.12
  ---rather than assumed -- so on a blank row it is a rule from the first column to the last.
  ---That is what makes the frame highlight groups instead of a row of its own, which would
  ---need an **anchor** and would put a cursor position on a thing that is not the diff.
  ---@param row integer
  ---@param group string
  local function close_frame(row, group)
    mark(after, row, 0, { line_hl_group = group })
    if before then
      mark(before, row, 0, { line_hl_group = group })
    end
  end

  ---The rendered text of one diff line in one pane, and where its code starts.
  ---@param ln CRLine
  ---@param number integer
  ---@param sign string
  ---@return string text, integer code_col, integer bar_len
  local function line_text(ln, number, sign)
    local bar = ln.side ~= "ctx" and icons.change_bar or " "
    -- The prefix `gutter_width` above measures. Change one and the other is wrong.
    local prefix = bar .. rpad_num(number, digits) .. SEP .. sign
    -- Byte offset, not display width: extmark columns are byte offsets, and both the
    -- change bar and the separator are multibyte.
    return prefix .. ln.text, #prefix, #bar
  end

  ---@param pane table
  ---@param row integer
  ---@param ln CRLine
  ---@param bar_len integer
  ---@param code_col integer Byte offset where the line's own text starts in the row
  local function paint_line(pane, row, ln, bar_len, code_col)
    if ln.side == "add" then
      mark(pane, row, 0, { line_hl_group = "CodeReviewAdd" })
      mark(pane, row, 0, { end_col = bar_len, hl_group = "CodeReviewAddBar" })
    elseif ln.side == "del" then
      mark(pane, row, 0, { line_hl_group = "CodeReviewDel" })
      mark(pane, row, 0, { end_col = bar_len, hl_group = "CodeReviewDelBar" })
    end
    mark(pane, row, bar_len, { end_col = bar_len + digits + #SEP, hl_group = "CodeReviewLineNr" })

    -- What differs inside the line, if it has a counterpart. The offsets were computed
    -- against the line's own text when the diff was parsed; all that happens here is
    -- shifting them past a gutter that is itself multibyte.
    if ln.spans then
      local group = ln.side == "add" and "CodeReviewAddSpan" or "CodeReviewDelSpan"
      for _, span in ipairs(ln.spans) do
        mark(pane, row, code_col + span.col, {
          end_col = code_col + span.end_col,
          hl_group = group,
          priority = M.PRIORITY.span,
        })
      end
    end
  end

  for fi, file in ipairs(files) do
    -- **Solo**: every file but the one being read emits nothing. A branch inside the walk
    -- that is already here, so a review with solo off pays one comparison per file and
    -- allocates nothing -- and the gutter above is still measured across every file, so a
    -- soloed file is drawn exactly as it is drawn among the others rather than shifting
    -- sideways when its neighbours stop being drawn.
    if solo and fi ~= solo then
      goto next_file
    end

    --- File header -----------------------------------------------------------
    -- Asked rather than assembled here: the winbar's sticky header names the same file by
    -- the same rules, and this is the surface those rules are named after.
    local label = M.file_label(file, opts)
    local reviewed, expanded, note_count = label.reviewed, label.expanded, label.notes

    local left = label.prefix .. M.segment_text(label.name)
    local stat, right = label.stat, label.right

    left = truncate(left, math.max(10, width - #right - 2))
    local pad = math.max(1, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right))
    local header = left .. (" "):rep(pad) .. right

    -- The before pane draws the half that concerns it: the path the pre-image had, indented
    -- to sit under the after pane's name. A file that exists only on the after side has no
    -- pre-image path at all, so its header row is filler like the rest of it.
    local bheader, bindent = nil, 0
    if before and label.before then
      local indent = (" "):rep(vim.fn.strdisplaywidth(label.prefix))
      -- Spaces, so the indent's byte count and its column count are the same number -- which
      -- is exactly what the after pane's prefix is not, and why that one is measured in
      -- bytes below. Measured off that prefix rather than counted from its parts, so a file
      -- carrying a host's glyph keeps the two panes' paths under one another: a count would
      -- have to learn about every glyph the prefix grows.
      bindent = #indent
      bheader = truncate(indent .. M.segment_text(label.before), before_width)
    end

    -- The before pane's header row is chrome even when it is empty: it is where this file
    -- begins on that side, and it is where `file_rows` points in both panes.
    local row = row2(header, { kind = "file", file = fi }, bheader, { kind = "file", file = fi })
    after.file_rows[fi] = row
    if before then
      before.file_rows[fi] = row
    end
    -- The **frame**'s band, and the header row's own colour beside it.
    --
    -- **The colour is a column mark and not the line-wide group it used to be.** A line-wide
    -- group replaces every attribute it sets on every inline highlight the row carries, at
    -- any priority and in either direction, so a line group with a foreground flattens the
    -- whole row to one colour -- which is what the header row's `CodeReviewFileHeader` had
    -- always done to the `+N -M` stat and the note count emitted below. The frame's group
    -- carries a background and no foreground at all, and what the row is coloured in now
    -- composes with the marks under it by priority, which is what priority does arbitrate.
    -- `docs/design-notes.md` has the measurement; the two shapes are not interchangeable.
    --
    -- Below the priority band the marks under it use, so a surface that colours a run of this
    -- row -- the stat here, a **path**'s own styling -- wins on the columns it owns.
    local frame = FRAME[reviewed]
    local base = reviewed and "CodeReviewFileReviewed" or "CodeReviewFileHeader"
    mark(after, row, 0, { line_hl_group = frame.top })
    mark(after, row, 0, { end_col = #header, hl_group = base, priority = M.PRIORITY.diff })
    if before then
      mark(before, row, 0, { line_hl_group = frame.top })
      if bheader and #bheader > 0 then
        mark(before, row, 0, { end_col = #bheader, hl_group = base, priority = M.PRIORITY.diff })
      end
    end
    -- Color only the +N/-M inside the stat, not the note count that may follow it.
    local stat_col = #header - #right
    local plus_len = file.binary and 0 or #(("+%d"):format(file.added))
    if not file.binary then
      mark(after, row, stat_col, { end_col = stat_col + plus_len, hl_group = "CodeReviewStatAdd" })
      mark(after, row, stat_col + plus_len + 1, { end_col = stat_col + #stat, hl_group = "CodeReviewStatDel" })
    end
    if note_count > 0 then
      mark(after, row, stat_col + #stat, { end_col = #header, hl_group = "CodeReviewNoteCount" })
    end
    -- The path, in the two groups the **sticky header** draws it in: one function answers
    -- what a file is called and one pair of groups therefore says it, so the two surfaces
    -- cannot drift apart on a file only one of them had in mind. `#label.prefix` is bytes and
    -- not columns, which is the whole trap -- the state mark and the chevron are multibyte,
    -- and a host's glyph is multibyte too.
    paint_path(after, row, #label.prefix, #left, label.name)
    if before and bheader then
      paint_path(before, row, bindent, #bheader, label.before)
    end
    -- Whole-file annotations hang off the header, so they stay visible even when the
    -- file is collapsed -- which is exactly when a file-level note matters most. Their key
    -- carries no side, and the stat and the note count already sit here, so they belong to
    -- the after pane.
    attach_notes(row, nil, M.file_key(file.path))

    -- A collapsed file's pad row is emitted here and not by the hunk walk below, and it
    -- gets no bottom edge: the file has no body to bound.
    if not expanded then
      row2("", { kind = "pad", file = fi }, "", { kind = "pad", file = fi })
      goto next_file
    end

    if file.note then
      -- Why there are no hunks -- binary, a rename with no content change, a mode-only
      -- change. Drawn on the after pane, so the before pane holds its place with filler.
      local r = row2("   " .. file.note, { kind = "pad", file = fi })
      mark(after, r, 0, { line_hl_group = "CodeReviewNote" })
      -- That note *is* the body, so the pad row after it closes one.
      close_frame(row2("", { kind = "pad", file = fi }, "", { kind = "pad", file = fi }), frame.bottom)
      goto next_file
    end

    --- Hunks -----------------------------------------------------------------
    for hi, hunk in ipairs(file.hunks) do
      local hanchor = { kind = "hunk", file = fi, hunk = hi }
      local hrow
      if before then
        -- Each pane says what its own image spans; git's section heading describes the
        -- post-image, so it rides with the range that does.
        local old_range, new_range = header_ranges(hunk.header, hunk)
        local rhead = hunk.heading ~= "" and ("@@ %s @@ %s"):format(new_range, hunk.heading)
          or ("@@ %s @@"):format(new_range)
        hrow = row2(
          truncate(rhead, width),
          hanchor,
          truncate(("@@ %s @@"):format(old_range), before_width),
          { kind = "hunk", file = fi, hunk = hi }
        )
        mark(before, hrow, 0, { line_hl_group = "CodeReviewHunkHeader" })
      else
        -- git's own header, drawn as git wrote it. The section heading is already the tail
        -- of that line, so appending `hunk.heading` here is the signature read twice -- and
        -- worst where it matters most, because a long one doubled is what pushes the first
        -- copy off a narrow pane. Rejected: rebuilding the line from the ranges the way the
        -- branch above does. That pane has two headers and no line of git's that says what
        -- either one spans; this layout has exactly one, and git already wrote it.
        hrow = row2(truncate(hunk.header, width), hanchor)
      end
      after.hunk_rows[#after.hunk_rows + 1] = hrow
      if before then
        before.hunk_rows[#before.hunk_rows + 1] = hrow
      end
      mark(after, hrow, 0, { line_hl_group = "CodeReviewHunkHeader" })

      if not before then
        for li, ln in ipairs(hunk.lines) do
          local text, code_col, bar_len =
            line_text(ln, ln.new or ln.old, ln.side == "add" and "+" or (ln.side == "del" and "-" or " "))
          local r = push(after, text, { kind = "line", file = fi, hunk = hi, line = li, col = code_col })
          paint_line(after, r, ln, bar_len, code_col)
          attach_notes(r, nil, M.line_key(file.path, ln))
        end
      else
        ---One logical row of the split body: a pre-image line beside a post-image line,
        ---either of which may be absent and is then filler.
        ---@param bi integer|nil Index into hunk.lines of the row's pre-image line
        ---@param ai integer|nil Index into hunk.lines of the row's post-image line
        local function pair(bi, ai)
          local bln, aln = bi and hunk.lines[bi], ai and hunk.lines[ai]
          local fill = { kind = "fill", file = fi, hunk = hi }

          local atext, acol, abar
          if aln then
            atext, acol, abar = line_text(aln, aln.new, aln.side == "add" and "+" or " ")
          end
          local btext, bcol, bbar
          if bln then
            btext, bcol, bbar = line_text(bln, bln.old, bln.side == "del" and "-" or " ")
          end

          local r =
            push(after, atext or "", aln and { kind = "line", file = fi, hunk = hi, line = ai, col = acol } or fill)
          push(before, btext or "", bln and { kind = "line", file = fi, hunk = hi, line = bi, col = bcol } or fill)

          if aln then
            paint_line(after, r, aln, abar, acol)
          end
          if bln then
            paint_line(before, r, bln, bbar, bcol)
          end
          -- A deletion and its replacement share a row, so both keys are offered: each
          -- pane draws the notes its own key owns and mirrors the other's height.
          attach_notes(
            r,
            bln and bln.side == "del" and M.line_key(file.path, bln) or nil,
            aln and M.line_key(file.path, aln) or nil
          )
        end

        -- A deleted run and the run that replaced it occupy the same rows, longest first;
        -- whichever runs out is filler for the rest. A context line ends both runs, because
        -- it exists in both images and must sit on one row.
        local dels, adds = {}, {}
        local function flush()
          for i = 1, math.max(#dels, #adds) do
            pair(dels[i], adds[i])
          end
          dels, adds = {}, {}
        end
        for li, ln in ipairs(hunk.lines) do
          if ln.side == "del" then
            dels[#dels + 1] = li
          elseif ln.side == "add" then
            adds[#adds + 1] = li
          else
            flush()
            pair(li, li)
          end
        end
        flush()
      end

      local prow = row2("", { kind = "pad", file = fi, hunk = hi }, "", { kind = "pad", file = fi, hunk = hi })
      -- Only the last hunk's pad row closes the file. The pad rows between hunks are inside
      -- the frame, and a rule on each of them would read as a file boundary per hunk.
      if hi == #file.hunks then
        close_frame(prow, frame.bottom)
      end
    end

    ::next_file::
  end

  return after, before
end

return M
