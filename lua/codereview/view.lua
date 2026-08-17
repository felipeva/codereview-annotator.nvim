---The review surface: buffers, windows, navigation.
---
---One view exists at a time, in its own tab page. Everything it draws comes from
---`render.lua`; everything it knows about position comes from that render's anchor map;
---and the keys that drive the actions exported here are declared in `keymaps.lua`, which
---is handed this module rather than requiring it. The **queue** float is `queue_float.lua`,
---handed this module the same way; what stays here is the jump from a queued **entry** into
---the diff, and the window a float is open in. Where the review's windows *are* is
---`view_layout.lua`, handed this module the same way again: the **panes**, the before pane,
---and the toggle between the two layouts. The **file tree**'s window and the actions its
---keys run are `view_panel.lua`, handed this module the same way once more; its pure half
---is `panel.lua`, which this module no longer reaches at all. The single `V` below is what
---all three mutate, and the names they took out from under `keymaps.lua` and `annotate.lua`
---are re-exported here.
---
---In the split layout the view keeps its existing buffer and window as the **after** pane
---and gains a before pane beside it. The after-image is the primary one everywhere else --
---context lines are attributed to it, line keys prefer it, an entry's line numbers prefer
---it, and opening a file resolves through it -- so naming it primary here is consistent
---rather than arbitrary, and it is what keeps the unified layout untouched.
local config = require("codereview.config")
local git = require("codereview.git")
local render = require("codereview.render")
local hl = require("codereview.hl")
local fade = require("codereview.fade")
local delivery = require("codereview.delivery")
local queue_float = require("codereview.queue_float")
local trim_float = require("codereview.trim_float")
local view_layout = require("codereview.view_layout")
local view_panel = require("codereview.view_panel")

local M = {}

local NS = vim.api.nvim_create_namespace("codereview")

---@class CRView
---@field root string
---@field scope CRScope
---@field files CRFile[]
---@field per_scope table<string, { reviewed: table<string,string>, expanded: table<string,boolean> }>
---@field reviewed table<string, string>   Path -> blob at the time it was marked
---@field expanded table<string, boolean>
---@field collapsed table<string, boolean> Directory path -> folded shut in the file tree
---@field notes table<string, table[]>     Line key -> queued annotations
---@field archived table<string, table[]>  Line key -> archived entries; empty when off
---@field touched table<integer, boolean>  Archived entry id -> whether its file has moved
---@field untouched integer|nil            How many of those have not; nil when none were judged
---@field judged integer|nil               `state.archive_writes` the two above were judged at
---@field buf integer                     The after pane
---@field win integer                     The after pane
---@field before_buf integer|nil          nil in the unified layout
---@field before_win integer|nil          nil in the unified layout
---@field layout "unified"|"split"
---@field panel_buf integer|nil
---@field panel_win integer|nil
---@field queue_win integer|nil           The window a queue float is open in
---@field focus_win integer|nil           The review window focus last landed in: the bright one
---@field tab integer
---@field augroup integer                 Autocommands belonging to this review
---@field render CRRender|nil             The after pane's render
---@field before_render CRRender|nil      nil in the unified layout
---@field current_file integer|nil        File index the diff cursor is in; the crossing latch
---@field panel_render CRPanelRender|nil
---@field painted_bands table<integer, boolean>|nil  Row bands whose marks have been emitted
---@field painted_file integer|nil        File index those bands were emitted bright; the fade's latch
---@field syntax_cache table<string, CRCapture[]|false>  `path|side` -> captures; false to skip it
---@field syntax_painted table<string, boolean>|nil      Path -> already replayed onto this render
---@field syntax_rows table<integer, CRFileRows>|nil     File index -> where its lines are drawn
---@field dims string|nil                 The size of every review window the last paint was made at

---@type CRView|nil
local V = nil

---@param msg string
local function warn(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = "Code review" })
end

---@param msg string
local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Code review" })
end

---@return CRView|nil
function M.current()
  if V and vim.api.nvim_win_is_valid(V.win) then
    return V
  end
  return nil
end

---Reviewed/expanded state is tracked per scope: marking a file done in `staged` says
---nothing about whether you have reviewed the whole branch's changes to it.
---
---Which scope that is comes from the scope's own identity, and is not worked out here. The
---identity holds still while the pre-image ref moves, so a scope that draws a smaller diff
---than it did yesterday reads yesterday's reviewed marks back.
---@param scope CRScope
---@return string
local function scope_key(scope)
  return scope.name .. ":" .. scope.identity
end

--- Panes ----------------------------------------------------------------------

-- The panes are `view_layout.lua`, which is handed this module and the view it mutates.
-- What is left here is the one name that was exported from this module before the split:
-- `annotate.lua` reads the focused pane to resolve a target, and it should not have to
-- learn that the body moved.

---@return integer win, CRRender|nil render
function M.focused_pane()
  return view_layout.focused_pane(V)
end

--- Painting --------------------------------------------------------------------

-- The file tree is painted by `view_panel.lua`, which is handed the view it mutates. What
-- is left here is the diff's own paint, and the two moments the tree comes due with it: a
-- repaint of everything, and a cursor that crossed into a different file. Which file that
-- is stays here -- see `current_file` below -- because it is a fact about the diff, and the
-- tree is only the first thing to ask for it.

--- The winbar ------------------------------------------------------------------

-- Each pane's winbar carries two halves: the **sticky header** naming the file the cursor
-- is in, and the review summary beside it. The file is what survives scrolling past its own
-- header row, so it takes the left -- and it is written where the summary already was
-- rather than over it, because a bar that answered *which file* by dropping *which review*
-- would have moved the problem rather than solved it.
--
-- What a bar is *made of* is `render.lua`'s: an ordered list of segments, each saying
-- whether the plugin wrote it or whether it is a name the plugin did not choose, and
-- `render.bar` is what turns that list into the string a winbar is set to. Everything here
-- decides *which* segments there are, what each one says and which group it carries.
-- `render.bar_width` is the ruler for all of it, and the only one: it measures what a bar
-- draws, which is neither its byte length nor its character count -- and a highlight marker
-- is several characters of it and no columns at all.
--
-- The groups are `hl.lua`'s, linked by default into whatever colorscheme is active, so a
-- theme change is the theme's problem and a **muted** pane's bar recedes with the pane
-- through the twins that set already has. The path carries none of them: the bar's own group
-- is the brightest thing on a winbar, and leaving the path in it is what makes it the
-- brightest thing on the left.

local SEP = " · "
-- One blank column at each edge, and at least two between the halves, so the two never
-- read as one sentence.
local MARGIN, GAP = 1, 2

---Columns of one bare string: the path, which is the only part of a bar that is cut rather
---than assembled. Anything already in segments is measured with `render.bar_width`, which
---is the same count plus what a segment can hold that a string cannot say.
---@param text string
---@return integer
local function cols(text)
  return vim.fn.strdisplaywidth(text)
end

---Lay one winbar out: `left` against the left margin, `right` against the right edge.
---
---Padded with spaces rather than with the statusline's `%=`. The escape that used to rule
---`%=` out is per segment now, so chrome could carry one -- but it would replace a single
---subtraction and take the bar's own width away with it, and what the fitting rule below
---needs is how many columns the path may keep, which is this arithmetic either way.
---
---The padding is counted in display columns and never in bytes: the summary's separators,
---the file icons and a rename's arrow are all multibyte, so a bar padded by `#` drifts left
---by two columns for every one of them, and does it on the very first path with an accent.
---@param width integer Columns the winbar has
---@param left CRBarSegment[]
---@param right CRBarSegment[] Empty to leave the bar left-aligned, as it is with nothing to align
---@return CRBarSegment[]
local function lay_out(width, left, right)
  local out = { render.chrome((" "):rep(MARGIN)) }
  vim.list_extend(out, left)
  if #right == 0 then
    return out
  end
  local pad = width - 2 * MARGIN - render.bar_width(left) - render.bar_width(right)
  out[#out + 1] = render.chrome((" "):rep(math.max(GAP, pad)))
  vim.list_extend(out, right)
  out[#out + 1] = render.chrome((" "):rep(MARGIN))
  return out
end

---@param win integer
---@param segments CRBarSegment[]
local function set_winbar(win, segments)
  vim.wo[win].winbar = render.bar(segments)
end

---The `+N -M` a stat is, with its two halves colored apart.
---
---Taken as the string the stat already is rather than as two numbers, so that the file's own
---counts and the review's totals are spelled by one format and colored by one rule. A
---`binary` file has no counts in it and takes no color.
---@param stat string
---@return CRBarSegment[]
local function stat_segments(stat)
  local plus, minus = stat:match("^(%+%d+) (%-%d+)$")
  if not plus then
    return { render.chrome(stat) }
  end
  return {
    render.chrome(plus, "CodeReviewStatAdd"),
    render.chrome(" "),
    render.chrome(minus, "CodeReviewStatDel"),
  }
end

---What the review summary says, one entry per `·`.
---
---A list rather than a string because a pane too narrow for both halves is one the summary
---gives way on, and which entry goes is the only thing here that is not a format. `spare`
---marks the ones the sticky header beside them says twice: the review's line totals, against
---the file's own `+N -M` two columns to the left; the queue's note count, against the file's
---own. What is not spare is what nothing else on screen says.
---
---The review's own name is not here at all. It was the first thing a narrow pane dropped,
---and a bar inside a review does not need to say it is one -- which is about thirty columns
---handed back to the path.
---
---Each entry is already segments, because a count is colored and the `·` beside it is not,
---and because the counts carry glyphs a host chose: those are literals for the reason the
---file's icon is one. Three counts, three glyphs, so that three numbers side by side cannot
---be read as one another.
---@return { parts: CRBarSegment[], spare: boolean|nil }[]
local function summary_segments()
  local icons = config.get().icons
  local reviewed = 0
  for _ in pairs(V.reviewed) do
    reviewed = reviewed + 1
  end
  local added, removed = require("codereview.diff").totals(V.files)
  local notes = 0
  for _, items in pairs(V.notes) do
    notes = notes + #items
  end
  local out = {
    { parts = { render.literal(V.scope.label) } },
    { parts = { render.literal(("%s%d/%d"):format(icons.reviewed, reviewed, #V.files)) } },
    { parts = stat_segments(("+%d -%d"):format(added, removed)), spare = true },
  }
  if notes > 0 then
    out[#out + 1] = {
      parts = { render.literal(("%s%d"):format(icons.annotated, notes), "CodeReviewNoteCount") },
      spare = true,
    }
  end
  -- Read rather than computed: this runs on every paint, and a paint runs on every resize.
  -- The git behind the number is paid where the archive is judged, which is where the diff
  -- is read -- see `judge_archive`.
  if V.untouched then
    out[#out + 1] = {
      parts = { render.literal(("%s%d"):format(icons.untouched, V.untouched), "CodeReviewUntouched") },
    }
  end
  local to = delivery.target()
  if to and to.short then
    -- One literal, arrow and all: the arrow is the plugin's and costs nothing by being
    -- escaped, and a marker pair around each half would say the same thing twice.
    out[#out + 1] = { parts = { render.literal(("→ %s"):format(to.short), "CodeReviewBarTarget") } }
  end
  return out
end

---The summary as segments, minus whatever a narrow pane has made it drop.
---
---Names are literals, and that is where the escaping lives: the **scope**'s label, the
---**target**'s short name and every configured glyph are things the plugin did not choose.
---What the plugin formatted itself holds no `%` left by the time it has been formatted, so
---escaping one segment too many draws exactly what was asked for; escaping one too few is
---how a branch called `100%-done` stops being a branch name. The separators are the plugin's
---own, and quieter than the facts they separate.
---@param segments { parts: CRBarSegment[], spare: boolean|nil }[]
---@param dropped table<integer, boolean>|nil
---@return CRBarSegment[]
local function join(segments, dropped)
  local out = {}
  for i, seg in ipairs(segments) do
    if not (dropped and dropped[i]) then
      if #out > 0 then
        out[#out + 1] = render.chrome(SEP, "CodeReviewBarSep")
      end
      vim.list_extend(out, seg.parts)
    end
  end
  return out
end

---How the render would name the file the cursor is in, or nil when it is in none.
---
---Asked on every paint rather than read off `V.current_file`, for the reason the tree asks:
---a paint can run between two crossings -- a resize, a fold, a scope change -- and the
---latch is what decides when the *bar changes*, not what the bar says.
---@param layout string
---@return CRFileLabel|nil
local function current_label(layout)
  local index = M.current_file()
  local file = index and V.files[index]
  if not file then
    return nil
  end
  return render.file_label(file, {
    icons = config.get().icons,
    reviewed = V.reviewed,
    expanded = V.expanded,
    notes = V.notes,
    layout = layout,
  })
end

---The file under the cursor, named as its own in-buffer header names it.
---
---Split into the part that may be cut and the parts that may not: the icon, the chevron and
---the stat are a handful of columns each and say what no number of columns of path can, so
---when a pane runs out of room the path is what gives them up.
---
---Literals, the icons included: a host chooses those, so they are not text the plugin wrote.
---The path stays a bare string rather than a segment because it is the one part the fitting
---rule cuts, and `render.keep_tail` takes text.
---
---Colored as the in-buffer file header colors the same facts, and for the same reason one
---function names the file for both: the counts apart, the note count in the group the notes
---themselves carry, the icon and the chevron quiet. The path takes no group at all, which
---leaves it drawing in the bar's own -- the brightest thing on the left, and the thing the
---reviewer scrolled there to keep.
---@param label CRFileLabel
---@return { head: CRBarSegment[], path: string, tail: CRBarSegment[] }
local function file_segment(label)
  local tail = { render.chrome("  ") }
  vim.list_extend(tail, stat_segments(label.stat))
  -- Whatever the label puts after the stat, which is the note count when there is one. Taken
  -- off the label rather than spelled again here: how a file's right-hand side reads is
  -- `render.file_label`'s answer, and a second spelling of it would drift from the in-buffer
  -- header the first time either moved.
  local rest = label.right:sub(#label.stat + 1)
  if rest ~= "" then
    tail[#tail + 1] = render.chrome(rest, "CodeReviewNoteCount")
  end
  return {
    head = { render.literal(("%s %s "):format(label.icon, label.chevron), "CodeReviewBarIcon") },
    path = label.name,
    tail = tail,
  }
end

---Fit the file and the summary into `room` columns, and say what each is left holding.
---
---Four steps, in the order a reviewer can afford to lose things:
---
---1. the summary drops what the file beside it repeats, to keep the whole path;
---2. the path gives up its head, down to the file's own name;
---3. the summary drops the rest, from its head, so the target it ends on is the last to go;
---4. the path takes whatever is left, which on an absurd pane is the ellipsis alone.
---
---The path is what a reviewer scrolled here to keep, and its *tail* is the part that says
---which file this is -- the directories above it are shared with every sibling and are what
---can go. The summary's own facts outrank those directories, which is step 3 sitting where
---it does: a bar that had shed the scope to spell out two more directory names would have
---kept the least of what it was holding.
---@param room integer Columns, margins already taken off
---@param file { head: CRBarSegment[], path: string, tail: CRBarSegment[] }
---@param segments { parts: CRBarSegment[], spare: boolean|nil }[]
---@return CRBarSegment[] left, CRBarSegment[] right
local function fit(room, file, segments)
  -- The order they go in: the spares, then the rest from the head.
  local order, spares = {}, {}
  for i, seg in ipairs(segments) do
    if seg.spare then
      spares[#spares + 1] = i
    end
  end
  vim.list_extend(order, spares)
  for i, seg in ipairs(segments) do
    if not seg.spare then
      order[#order + 1] = i
    end
  end

  local dropped = {}
  local summary, path_room
  local function measure()
    summary = join(segments, dropped)
    path_room = room
      - render.bar_width(file.head)
      - render.bar_width(file.tail)
      - (#summary > 0 and GAP + render.bar_width(summary) or 0)
  end
  measure()

  -- Cut back to the file's own name, and no further, before the summary gives up anything
  -- it alone says.
  local floor = math.min(cols(file.path), cols("…" .. file.path:match("[^/]*$")))
  local next_drop = 1
  ---@param last integer Last position in `order` this step may reach
  ---@param want integer Columns the path is being kept at
  local function shed(last, want)
    while next_drop <= last and path_room < want do
      dropped[order[next_drop]] = true
      next_drop = next_drop + 1
      measure()
    end
  end
  -- Step 1 keeps the whole path; steps 3 and 4 keep only the file's own name.
  shed(#spares, cols(file.path))
  shed(#order, floor)

  local left = vim.list_extend({}, file.head)
  left[#left + 1] = render.literal(render.keep_tail(file.path, path_room))
  return vim.list_extend(left, file.tail), summary
end

---The after pane's winbar: the file under the cursor, and the review summary beside it.
local function update_winbar()
  if not vim.api.nvim_win_is_valid(V.win) then
    return
  end
  local width = vim.api.nvim_win_get_width(V.win)
  local segments = summary_segments()
  -- The layout decides how a rename is spelled, and it is the render's decision rather than
  -- a second one taken here: one header per file when unified, one side per pane when split.
  local label = current_label(view_layout.has_before(V) and "split" or "unified")
  if not label then
    -- No file under the cursor -- an empty review. The summary has the bar to itself,
    -- exactly as it did before there was anything to share it with, rather than a segment
    -- advertising a file that is not there.
    set_winbar(V.win, lay_out(width, join(segments), {}))
    return
  end
  local left, right = fit(width - 2 * MARGIN, file_segment(label), segments)
  set_winbar(V.win, lay_out(width, left, right))
end

---Name the revision the before pane is showing, and the path it is showing it at.
---
---The after pane's winbar already says what the review is; what it cannot say is which of
---the two images is the base, and a reviewer should never have to infer that from the code.
---The pre-image path rides on the right of it, so a rename reads correctly on the side that
---holds the old name -- each pane naming its own side, which is the rule the in-buffer
---header follows in this layout rather than a second one invented for the winbar.
local function update_before_winbar()
  if not view_layout.has_before(V) then
    return
  end
  local rev = V.scope.before
  -- `:0` is git's name for the index, and a name nobody reads as one. The revision itself is
  -- a name the repository chose, so it is a literal beside chrome rather than one string --
  -- and it is accented, because it is what this pane exists to name. The same separator, and
  -- the same quiet group on it, as the summary on the other pane.
  local left = {
    render.chrome("Before"),
    render.chrome(SEP, "CodeReviewBarSep"),
    render.literal(rev == ":0" and "index" or rev, "CodeReviewBarRev"),
  }
  local width = vim.api.nvim_win_get_width(V.before_win)
  -- A file that exists only on the after side has no pre-image path to name, exactly as its
  -- header row on this pane has none: the revision keeps the bar to itself and says so by
  -- naming nothing beside it.
  local label = current_label("split")
  local path = label and label.before or ""
  -- The revision is what this pane exists to name and is never cut for the path's sake: on
  -- a pane too narrow to hold both, a base revision half spelled out is worse than none of
  -- the path, which the after pane is naming anyway.
  local room = width - 2 * MARGIN - GAP - render.bar_width(left)
  path = (path ~= "" and room >= 2) and render.keep_tail(path, room) or ""
  set_winbar(V.before_win, lay_out(width, left, path ~= "" and { render.literal(path) } or {}))
end

---Write one pane's render into its buffer: the lines, and nothing else.
---
---Which of the render's marks reach the buffer is `paint_bands`' decision, taken against
---the window rather than against the diff. The namespace is cleared here, so this is also
---where everything a previous paint emitted stops existing.
---@param buf integer
---@param rendered CRRender
local function write_pane(buf, rendered)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
end

---First index in `marks` whose row is at or after `row`.
---
---`render.build` appends each mark as it draws the row it belongs to, so a pane's marks are
---in non-decreasing row order and a run of rows is a slice of that array. Found rather than
---filtered, because a filter is a walk of the whole review -- the cost this bounding exists
---to remove, and one that would then be paid again on every scroll into new rows.
---`bounded_spec` pins the ordering this relies on, for both panes.
---@param marks table[]
---@param row integer 0-indexed, as an extmark's row is
---@return integer
local function lower_bound(marks, row)
  local lo, hi = 1, #marks + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if marks[mid].row < row then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

---Emit every mark one pane's render put on rows `first`..`last`, 1-indexed and inclusive.
---
---`faded` decides which of those rows are drawn in the blended groups rather than in the
---ones the render gave them. Asked per mark and never remembered, so a row emitted long
---after a crossing carries what the fade says now.
---@param buf integer
---@param rendered CRRender
---@param first integer
---@param last integer
---@param faded (fun(row: integer): boolean)|nil
local function emit_rows(buf, rendered, first, last, faded)
  local marks = rendered.marks
  for i = lower_bound(marks, first - 1), #marks do
    local m = marks[i]
    if m.row > last - 1 then
      return
    end
    local opts = m.opts
    if faded and faded(m.row + 1) then
      opts = fade.opts(opts)
    end
    -- An end_col past the end of a line is a hard error; a mis-measured header should
    -- lose its color, not abort the whole repaint.
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, m.row, m.col, opts)
  end
end

---How the replay's groups are renamed on one file's rows, or nil when that file is bright.
---
---Handed to `syntax.apply` rather than asked for from inside it: the replay knows which file
---it is painting, and the rule for which file is faded lives out here with the cursor.
---@param fi integer
---@return (fun(group: string): string)|nil
local function faded_replay(fi)
  if not fade.enabled() then
    return nil
  end
  local current = M.current_file()
  if not current or fi == current then
    return nil
  end
  return fade.group
end

---Emit the marks for the rows near the window, in every pane there is.
---
---Bounded by the viewport, not by the diff, for the reason the harvest already is and
---against the same bounds: a 300-file review renders 271,000 marks, and writing all of them
---is a sixth of a second on every resize, expansion, reviewed toggle and scope change.
---
---Rows are tracked in bands so that scrolling back re-emits nothing, and quantising is what
---keeps that tracking a handful of lookups instead of a set the size of the review. The
---grain is the harvest's margin: one figure decides both how far ahead the view paints and
---how coarsely it remembers, and a band is either wholly emitted or wholly not.
---
---Cheap when there is nothing new -- which is what lets it hang off `CursorMoved`.
local function paint_bands()
  if not V.render then
    return
  end
  local syntax = require("codereview.syntax")
  local band = syntax.VIEWPORT_MARGIN
  local lo, hi = syntax.viewport(V)
  -- Once for the whole pass, and for both panes: they hold the same rows and the same header
  -- rows, so one answer keeps the two images comparable row for row. Asked live rather than
  -- read off `V.current_file`, for the reason the winbar asks live: a paint can run between
  -- two crossings -- a resize, a fold, a layout toggle -- and park the cursor in a third file
  -- without the latch hearing a thing.
  local current = M.current_file()
  local faded = fade.rows(V.render, current)
  -- Which file the rows on screen were emitted bright, kept beside the bands that hold them
  -- and for the same reason: what a mark means is decided by the emission it came from, and a
  -- crossing has to know what the rows already painted were painted for. Taken here only when
  -- a paint has just dropped it -- a band emitted while a crossing is pending is put right by
  -- the `refade` a tick later, and moving this would tell that `refade` there was nothing to
  -- do.
  V.painted_file = V.painted_file or current
  V.painted_bands = V.painted_bands or {}
  for b = math.floor((lo - 1) / band), math.floor((hi - 1) / band) do
    if not V.painted_bands[b] then
      V.painted_bands[b] = true
      -- Both panes draw the same rows, so one set of bands answers for both: a band is
      -- emitted into both or into neither, which is what keeps the two images comparable
      -- row for row wherever a reviewer has scrolled.
      emit_rows(V.buf, V.render, b * band + 1, (b + 1) * band, faded)
      if V.before_render then
        emit_rows(V.before_buf, V.before_render, b * band + 1, (b + 1) * band, faded)
      end
    end
  end
end

---Emit the rows of the files whose fade has just changed, and no others.
---
---Only two files change on a crossing: the one the rows on screen were emitted for, and the
---one the cursor is in now. Their bodies are dropped and written again in the groups the fade
---decides now -- the header rows are not touched at all, because a header carries the same
---group faded or bright.
---
---**The file left is the one the emission drew bright, not the one the crossing latch names.**
---The two differ wherever a paint has parked the cursor without a crossing: the latch is
---still on the file being read before it, and the rows on screen are already drawn for the
---file it landed in. Re-emitting against the latch would leave that third file bright.
---
---Bounded by the bands a paint has reached, as every emission here is: a row the reviewer
---has never been near holds nothing to replace, and it arrives faded when it is painted.
---The replay is dropped for those files and run again for the same reason -- its marks were
---cleared with the rest, and a file too far from the window to be repainted is one whose
---flag is left down for the next scroll.
---@param entered integer|nil The file the cursor is in now
local function refade(entered)
  local left = V.painted_file
  V.painted_file = entered
  if not (V.render and V.painted_bands and fade.enabled()) then
    return
  end
  local syntax = require("codereview.syntax")
  local band = syntax.VIEWPORT_MARGIN
  local faded = fade.rows(V.render, entered)
  local changed = {}
  if left then
    changed[#changed + 1] = left
  end
  if entered and entered ~= left then
    changed[#changed + 1] = entered
  end
  for _, fi in ipairs(changed) do
    local first, last = fade.body(V.render, fi)
    if first <= last then
      vim.api.nvim_buf_clear_namespace(V.buf, NS, first - 1, last)
      if V.before_render then
        vim.api.nvim_buf_clear_namespace(V.before_buf, NS, first - 1, last)
      end
      for b = math.floor((first - 1) / band), math.floor((last - 1) / band) do
        if V.painted_bands[b] then
          local from, to = math.max(first, b * band + 1), math.min(last, (b + 1) * band)
          emit_rows(V.buf, V.render, from, to, faded)
          if V.before_render then
            emit_rows(V.before_buf, V.before_render, from, to, faded)
          end
        end
      end
      local file = V.files[fi]
      if file and V.syntax_painted then
        V.syntax_painted[file.path] = nil
      end
    end
  end
  if config.get().syntax then
    syntax.apply(V, NS, faded_replay)
  end
end

---The size of every review window, as one value two moments can be compared by.
---
---The two **panes** and the **file tree**, each as its width and its height, which is
---exactly what a paint is a function of: header padding and the winbar are cut to a pane's
---width, and how far past the window marks are emitted comes from its height. A window that
---is not there contributes a placeholder rather than nothing, so a layout toggle and a tree
---that arrives or leaves are changes like any other.
---
---A string rather than a table, because the only question ever asked of it is whether it is
---the one recorded before.
---@return string
local function dimensions()
  local out = {}
  for _, win in ipairs({ V.win, V.before_win or -1, V.panel_win or -1 }) do
    if vim.api.nvim_win_is_valid(win) then
      out[#out + 1] = ("%dx%d"):format(vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win))
    else
      out[#out + 1] = "-"
    end
  end
  return table.concat(out, " ")
end

---Redraw from the files already in memory. Cheap; no git.
---@param keep_file integer|nil File index to park the cursor on afterwards
function M.paint(keep_file)
  if not M.current() then
    return
  end
  local cfg = config.get()
  -- What this paint is drawn for, recorded by the paint itself rather than by the resize
  -- callback that is the one thing reading it. Every path that changes a review window
  -- repaints for itself -- the layout toggle, the tree arriving or leaving, a pane rebuilt --
  -- so recording it here is what leaves the resize event those paths' main loop lands
  -- afterwards with nothing to do.
  V.dims = dimensions()
  -- The queue is the source of truth for annotations; the view only ever displays a
  -- projection of it, so there is no second copy to keep in sync.
  V.notes = require("codereview.queue").by_key()
  -- And the archive is the source of truth for what has already gone, projected the same
  -- way onto the same anchors. Asked for on every paint rather than cached here, because
  -- the answer changes on a dispatch this view need not have made -- an **immediate send**
  -- archives a batch of one without emptying anything -- and the read behind it is a
  -- comparison until something has written.
  V.archived = config.archived() and require("codereview.archive").by_key(V.root) or {}
  -- What was judged against an archive that has since been overtaken describes something
  -- else now: an **immediate send** archives a batch of one with no repaint of its own, so
  -- the entries below may belong to a batch nothing has judged. Dropped rather than
  -- recomputed, because judging is two git invocations and this runs on every resize --
  -- saying nothing until the next reconcile is the honest answer, and the winbar's segment
  -- goes with it.
  if V.judged ~= require("codereview.state").archive_writes() then
    V.touched, V.untouched = {}, nil
  end
  -- Both panes from one walk: their row counts and their anchors agree by construction
  -- rather than because two calls happened to be handed the same arguments.
  V.render, V.before_render = render.build(V.files, {
    width = vim.api.nvim_win_get_width(V.win),
    before_width = view_layout.has_before(V) and vim.api.nvim_win_get_width(V.before_win) or nil,
    layout = view_layout.has_before(V) and "split" or "unified",
    icons = cfg.icons,
    expanded = V.expanded,
    reviewed = V.reviewed,
    notes = V.notes,
    archived = V.archived,
    touched = V.touched,
    types = cfg.types,
  })

  write_pane(V.buf, V.render)
  if V.before_render then
    write_pane(V.before_buf, V.before_render)
  end
  -- The namespaces above were just cleared, so nothing this records still exists. Dropped
  -- here rather than in `paint_bands` for the reason `syntax_painted` is dropped by the
  -- paint: what a band means is decided by the render it was emitted from. The file those
  -- bands were emitted bright goes with them, and `paint_bands` takes it again below.
  V.painted_bands, V.painted_file = {}, nil

  view_panel.paint_panel(V, M)

  if keep_file and V.render.file_rows[keep_file] then
    view_layout.place(V, V.render.file_rows[keep_file])
  end

  -- After `place`, not before it: the winbar names the file the cursor is in, and parking
  -- the cursor on a file is what decides which file that is. Built here rather than left to
  -- the crossing latch because a paint can change what the bar says without the cursor
  -- having moved at all -- a note queued, a file marked reviewed, a pane resized.
  update_winbar()
  update_before_winbar()

  -- After `place`, not before it: parking the cursor on a file is what decides which rows
  -- are near the window, and a repaint has to leave the rows it lands on painted rather
  -- than waiting for the reviewer to move.
  paint_bands()

  -- The namespace was just cleared and the renders above are new, so nothing a previous
  -- paint derived from them still describes what is on screen -- but the parsed captures
  -- behind it are still good. Unconditional, unlike the pass below it: a row map left over
  -- from a paint made with highlighting off would be replayed onto rows it never described
  -- the moment highlighting came back.
  local syntax = require("codereview.syntax")
  syntax.repainted(V)
  if config.get().syntax then
    syntax.apply(V, NS, faded_replay)
  end
  -- A pass that parsed a file resolved capture groups nothing knew about before it, and a
  -- **muted** window needs a variant of each or the tokens it just gained come out bright.
  -- Here rather than inside the pass, so that the module that knows about windows is called
  -- by the one that owns them rather than reaching back up for them.
  view_layout.mute_extend()

  view_layout.resync(V)
end

---Write progress to disk. Called from every mutation rather than from `paint`, which
---also runs on resize and would turn a window drag into a stream of file writes.
---
---With a view, that means the reviewed marks and the queue together. Without one, only
---the queue -- there are no marks to write, and writing the document anyway would blank
---the ones a review left behind.
function M.persist()
  local state = require("codereview.state")
  if V then
    state.persist(V)
    return
  end
  -- Passed even when nil: there may still be annotations with no repository to write, and
  -- skipping would leave a submitted batch's entries on disk to come back next start.
  state.persist_queue(state.ambient_root())
end

--- Cursor queries --------------------------------------------------------------

---Row the cursor is on, in whichever pane has focus. The two agree row for row, so this
---is a question about the cursor rather than about the layout.
---@return integer
local function cursor_row()
  local win = view_layout.focused_pane(V)
  return vim.api.nvim_win_get_cursor(win)[1]
end

---@return CRAnchor|nil
local function anchor_at_cursor()
  local win, rendered = view_layout.focused_pane(V)
  if not rendered then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  -- Walk upward: a blank padding row still belongs to the file above it, so a cursor
  -- resting in whitespace resolves to something sensible rather than nothing. In the split
  -- layout there is nothing to walk -- every row carries an anchor, and a filler row says
  -- so rather than letting the cursor inherit an unrelated line above it.
  for r = row, 1, -1 do
    if rendered.anchors[r] then
      return rendered.anchors[r], r
    end
  end
  return nil
end

---@return CRFile|nil, integer|nil
local function file_at_cursor()
  local anchor = anchor_at_cursor()
  if not anchor then
    return nil
  end
  return V.files[anchor.file], anchor.file
end

---Which file the diff cursor is in, as an index into `V.files`.
---
---The one answer to that, for everything that follows the diff from one file into the
---next. It is a question about the diff and its anchor map, so it is asked here rather
---than inside whichever surface happens to want it: the file tree is an interested party,
---not the authority, and a copy kept there would put a fact about the diff behind a
---require on the tree's module.
---
---The window check is the tree's own, moved with it: this is reached from a paint, and a
---render that outlives its window by a tick must answer nil rather than raise.
---@return integer|nil
local function current_file()
  local win = view_layout.focused_pane(V)
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local anchor = anchor_at_cursor()
  return anchor and anchor.file
end

M.anchor_at_cursor = anchor_at_cursor
M.file_at_cursor = file_at_cursor
M.current_file = current_file

--- Following the diff ----------------------------------------------------------

---Everything that comes due when the cursor crosses into a different file.
---
---The latch is the view's rather than the tree's, and it is judged whether or not there is
---a tree to repaint. That is the whole of it: a latch that stopped running when the tree
---was dismissed would sit on the file being read at the moment it went away, and reading
---that same file again once the tree was back would repaint nothing. Running it always is
---also what lets a second consumer hang off it -- the crossing is a fact about the diff,
---and the tree is one caller of it.
---
---Everything that follows the diff hangs off the crossing rather than off the movement:
---this is reached from every `CursorMoved`, and rebuilding the tree on each keystroke is
---real work on a large review. The **sticky header** is the second thing hanging off it and
---costs what the tree costs -- an anchor lookup per keystroke, and two winbars only when
---the answer changed.
local function follow_file()
  local index = current_file()
  if index == V.current_file then
    return
  end
  V.current_file = index
  update_winbar()
  update_before_winbar()
  view_panel.sync_panel(V, M)
  -- The third thing hanging off the crossing, and the only one that writes to the diff: the
  -- file the rows on screen were drawn bright is faded, and the file entered is brightened.
  -- Nothing else on screen moves, so nothing else is emitted again.
  refade(index)
end

---Everything a moved cursor comes due for, in the order it comes due.
---
---Both the diff's own marks and its highlighting are bounded by the viewport, so
---scrolling into rows nothing has been emitted onto is what emits them, and scrolling
---into an un-parsed file is what triggers its parse. One trigger for the two of them:
---they share a margin, so they come due at the same moment. Cheap on every other scroll --
---a band already emitted is a lookup, an already-painted file is skipped, and an
---already-parsed one repaints from cache.
---
---Exported so that the autocommand driving it wires one name rather than reaching into
---three internals at once. It runs on every keystroke a reviewer holds, so the guards
---here are what keep it cheap rather than decoration around it.
function M.cursor_moved()
  if not M.current() then
    return
  end
  paint_bands()
  if config.get().syntax then
    require("codereview.syntax").apply(V, NS, faded_replay)
  end
  -- Whatever that pass resolved, muted in the pane that does not have focus -- which is
  -- usually not the pane the scroll happened in. Cheap when it resolved nothing new: one
  -- integer comparison and no allocation.
  --
  -- Deliberately here as well as in the paint, and *not* covered by a spec: what reaches
  -- this and not the paint is scrolling into a file whose language nothing has parsed yet,
  -- which needs a diff taller than the viewport margin holding more than one language. The
  -- tall fixture is single-language and the many-language one is short enough to parse on
  -- open, so no fixture in the suite has that shape -- see tests/README.md. Removing this
  -- line reds nothing; it is still the line that keeps a real scroll from thinning out.
  view_layout.mute_extend()
  -- Cheap: an anchor lookup, and then nothing at all unless the cursor left the file it
  -- was in.
  follow_file()
end

--- Actions ---------------------------------------------------------------------

---@param rows integer[]
---@param from integer
---@param forward boolean
---@return integer|nil
local function nearest(rows, from, forward)
  local best
  for _, r in ipairs(rows) do
    if forward and r > from then
      if not best or r < best then
        best = r
      end
    elseif not forward and r < from then
      if not best or r > best then
        best = r
      end
    end
  end
  return best
end

---Exported because the tree walks its own file rows with `]f` and `[f` exactly as the diff
---walks its, and "the nearest row in that direction" is one rule rather than two copies of
---one. It is the only thing `view_panel.lua` needs from this section.
M.nearest = nearest

---Put a file header at the top of the window rather than leaving it wherever it lands:
---jumping to a file is a request to read it, and its first hunk should be on screen.
---
---Both panes, because a jump that moved only one would leave them reading different code.
---
---Exported because the layout toggle lands a cursor the same way every jump here does, and
---it is the one arrival the two halves of this share: placing the panes is
---`view_layout.lua`'s and following the diff with the tree is `view_panel.lua`'s, so the
---pair is glued where the view that owns both is.
---
---A jump moves the cursor itself rather than waiting for `CursorMoved`, so the crossing is
---judged here too -- and by the same latch, so a jump that lands in the file already being
---read costs what standing still costs.
---@param row integer
---@param cmd string|nil `zt`, `zz`, or nil to leave the window where it is
local function goto_row(row, cmd)
  view_layout.place(V, row, cmd)
  follow_file()
end

M.goto_row = goto_row

---@param what "file"|"hunk"
---@param forward boolean
function M.jump(what, forward)
  if not M.current() or not V.render then
    return
  end
  local rows = what == "file" and V.render.file_rows or V.render.hunk_rows
  local row = nearest(rows, cursor_row(), forward)
  if not row then
    info(("No %s %s here"):format(forward and "next" or "previous", what))
    return
  end
  goto_row(row, what == "file" and "zt" or nil)
end

---Jump to the next or previous file that is still unreviewed.
---
---The point of marking files reviewed is to stop looking at them, so the common motion is
---"take me to the next thing I have not done" -- not "the next file", which walks back
---through everything already finished.
---@param forward boolean
function M.jump_unreviewed(forward)
  if not M.current() or not V.render then
    return
  end
  local rows = {}
  for index, row in ipairs(V.render.file_rows) do
    if not V.reviewed[V.files[index].path] then
      rows[#rows + 1] = row
    end
  end
  if #rows == 0 then
    info("Everything in this scope is reviewed")
    return
  end

  local row = nearest(rows, cursor_row(), forward)
  if not row then
    -- Wrap: with the reviewed files skipped there are few targets left, and stopping dead
    -- at the last one means scrolling back by hand.
    row = forward and rows[1] or rows[#rows]
    info(forward and "Wrapped to the first unreviewed file" or "Wrapped to the last unreviewed file")
  end
  goto_row(row, "zt")
end

---Jump to the next or previous annotated line.
---@param forward boolean
function M.jump_annotation(forward)
  if not M.current() or not V.render then
    return
  end
  ---Rows carrying a note, and whether the before pane is the one carrying it there. Both
  ---anchor maps are read: a note on a deleted line exists only in the before pane's, and
  ---skipping it would make half a reviewer's remarks unreachable by `]a`.
  local owner = {}
  ---@param rendered CRRender|nil
  ---@param is_before boolean
  local function collect(rendered, is_before)
    for row, a in pairs(rendered and rendered.anchors or {}) do
      local file = V.files[a.file]
      local key
      if a.kind == "line" then
        key = render.line_key(file.path, file.hunks[a.hunk].lines[a.line])
      elseif a.kind == "file" and not is_before then
        -- A whole-file note carries no side, and it hangs off the after pane's header.
        key = render.file_key(file.path)
      end
      -- The after pane is collected first, so a row annotated on both sides is recorded as
      -- its own rather than being claimed by the before pane.
      if key and V.notes[key] and owner[row] == nil then
        owner[row] = is_before
      end
    end
  end
  collect(V.render, false)
  collect(V.before_render, true)

  local rows = vim.tbl_keys(owner)
  if #rows == 0 then
    info("No annotations yet")
    return
  end
  table.sort(rows)

  local row = nearest(rows, cursor_row(), forward) or (forward and rows[1] or rows[#rows])
  -- Land in the pane the note is drawn in, so the jump arrives at the code and not beside
  -- it. A row annotated on both sides keeps whichever pane the reviewer is already in.
  if view_layout.has_before(V) and owner[row] and vim.api.nvim_get_current_win() ~= V.before_win then
    vim.api.nvim_set_current_win(V.before_win)
  end
  goto_row(row, "zz")
end

---Jump straight to a file, chosen from a list.
---
---`]f` is fine for the next file; it is useless for "the one three hundred rows down that
---I know the name of".
function M.pick_file()
  if not M.current() then
    return
  end
  local cfg = config.get()
  local items, labels = {}, {}
  for index, file in ipairs(V.files) do
    local reviewed = V.reviewed[file.path] ~= nil
    local notes = 0
    for key, list in pairs(V.notes) do
      if key:sub(1, #file.path + 1) == file.path .. ":" then
        notes = notes + #list
      end
    end
    items[#items + 1] = index
    labels[#labels + 1] = ("%s %-50s %s%s"):format(
      reviewed and cfg.icons.reviewed or (notes > 0 and cfg.icons.annotated or cfg.icons.unreviewed),
      file.path,
      file.binary and "binary" or ("+%d -%d"):format(file.added, file.removed),
      notes > 0 and ("  [%d]"):format(notes) or ""
    )
  end

  vim.ui.select(labels, { prompt = "Jump to file:" }, function(_, choice)
    if not choice then
      return
    end
    local index = items[choice]
    -- A file collapsed because it is reviewed must open when you deliberately jump to it,
    -- otherwise the jump lands on a header with nothing beneath it.
    if V.expanded[V.files[index].path] == false then
      V.expanded[V.files[index].path] = true
      M.paint()
    end
    if V.render.file_rows[index] then
      goto_row(V.render.file_rows[index], "zt")
    end
  end)
end

--- Focus -----------------------------------------------------------------------

-- Moving between the tree and the diff is a question about the tree's existence rather than
-- about the diff, so its body is `view_panel.lua`'s. What is left here is the name
-- `keymaps.lua` binds to `<Tab>` in both.

function M.toggle_focus()
  view_panel.toggle_focus(V, M)
end

function M.toggle_reviewed()
  local file, index = file_at_cursor()
  if not file then
    return
  end
  if V.reviewed[file.path] then
    V.reviewed[file.path] = nil
    V.expanded[file.path] = true
  else
    -- The blob is what makes the mark verifiable later: on reload, a file whose content
    -- no longer hashes to this is a file you have not actually reviewed.
    V.reviewed[file.path] = file.blob or ""
    V.expanded[file.path] = false
  end
  M.paint(index)
  M.persist()
end

function M.toggle_expand()
  local file, index = file_at_cursor()
  if not file then
    return
  end
  local current = V.expanded[file.path]
  if current == nil then
    current = V.reviewed[file.path] == nil
  end
  V.expanded[file.path] = not current
  M.paint(index)
end

---Re-read the diff from git, preserving reviewed marks and annotations.
function M.refresh()
  if not M.current() then
    return
  end
  local cfg = config.get()
  local files, err =
    git.collect(V.scope, V.root, { context = cfg.context, untracked = cfg.untracked, spans = cfg.spans })
  if not files then
    warn("git: " .. (err or "diff failed"))
    return
  end
  V.files = files
  require("codereview.syntax").invalidate(V)
  M.reconcile()
  M.paint()
  M.persist()
end

---Ask which of the last batch's files the agent has been in since it went.
---
---Kept apart from the reconciliation below, and reported through the winbar rather than a
---sentence, because it says nothing a reviewer has to act on: *stale* means a note may now
---be wrong, *untouched* only means a file has not moved. The computation is `state`'s,
---beside the staleness rule it parallels rather than joins.
---
---Called where the diff is read -- opening, refreshing, changing scope, and this view's own
---submit -- and never from a paint, which also runs on every resize.
local function judge_archive()
  -- Submitting reaches here with nothing open: a batch is not a window, and it can go out
  -- of a session that never opened a review at all.
  if not V then
    return
  end
  if not config.archived() then
    -- One switch turns the archive off in the review view outright: nothing drawn, nothing
    -- tallied, and no git spent deciding either.
    V.touched, V.untouched, V.judged = {}, nil, nil
    return
  end
  local state = require("codereview.state")
  V.touched, V.untouched = state.reconcile_archive(V.root, V.files)
  V.judged = state.archive_writes()
end

---Re-check reviewed marks and annotations against the diff now on screen, reporting what
---the blob comparison invalidated.
function M.reconcile()
  if not V then
    return
  end
  judge_archive()
  local unmarked, staled = require("codereview.state").reconcile(V)
  local parts = {}
  if unmarked > 0 then
    parts[#parts + 1] = ("%d file%s changed since review"):format(unmarked, unmarked == 1 and "" or "s")
  end
  if staled > 0 then
    parts[#parts + 1] = require("codereview.queue").stale_phrase(staled)
  end
  if #parts > 0 then
    info(table.concat(parts, ", "))
  end
end

---@param spec string|nil nil cycles to the next scope this repository offers
function M.set_scope(spec)
  if not M.current() then
    return
  end
  if not spec then
    -- Asked per repository rather than read off a constant: which scopes are safe to walk
    -- blind depends on whether anything has ever been dispatched from this one.
    local cycle = git.cycle(V.root)
    local at = 1
    for i, name in ipairs(cycle) do
      if name == V.scope.name then
        at = i
        break
      end
    end
    spec = cycle[(at % #cycle) + 1]
  end

  local scope, err = git.resolve_scope(spec, V.root)
  if not scope then
    warn(err or ("cannot resolve scope: " .. spec))
    return
  end

  local cfg = config.get()
  local files, derr =
    git.collect(scope, V.root, { context = cfg.context, untracked = cfg.untracked, spans = cfg.spans })
  if not files then
    warn("git: " .. (derr or "diff failed"))
    return
  end

  V.scope = scope
  V.files = files
  -- Cached captures are keyed by path and side only, so they are meaningless once the
  -- refs behind those sides change.
  require("codereview.syntax").invalidate(V)
  local key = scope_key(scope)
  V.per_scope[key] = V.per_scope[key] or { reviewed = {}, expanded = {} }
  V.reviewed = V.per_scope[key].reviewed
  V.expanded = V.per_scope[key].expanded
  require("codereview.state").restore(V, key)
  M.reconcile()

  if #files == 0 then
    info(("No changes in scope '%s'"):format(scope.label))
  end
  M.paint()
  view_layout.place(V, 1)
end

---Line in the current file that this row corresponds to.
---
---A deleted line does not exist in the working tree, so we fall back to the nearest
---preceding line that does -- landing on the code that replaced it rather than on an
---unrelated line that happens to share the number.
---@param file CRFile
---@param anchor CRAnchor
---@return integer
local function worktree_line(file, anchor)
  local hunk = file.hunks[anchor.hunk]
  if not hunk then
    return 1
  end
  local ln = hunk.lines[anchor.line]
  if ln and ln.new then
    return ln.new
  end
  for i = (anchor.line or 1) - 1, 1, -1 do
    if hunk.lines[i].new then
      return hunk.lines[i].new
    end
  end
  return math.max(1, hunk.new_start)
end

function M.open_file()
  local anchor = anchor_at_cursor()
  if not anchor then
    return
  end
  local file = V.files[anchor.file]
  local abs = vim.fs.joinpath(V.root, file.path)
  if vim.fn.filereadable(abs) == 0 then
    warn(("%s does not exist in the working tree"):format(file.path))
    return
  end
  local line = anchor.kind == "line" and worktree_line(file, anchor) or 1
  -- A new tab keeps the review intact: `gT` returns to exactly where you were.
  vim.cmd("tabedit " .. vim.fn.fnameescape(abs))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  vim.cmd("normal! zz")
end

---Hand a file and the refs its scope is between to the host's diff tool, and stop caring.
---
---The plugin ships no diff tool and keeps no opinion about which one this is, the same way
---it keeps none about delivery (ADR-0001): everything the host needs to fetch either image
---is in the spec, and what it does with them is its own. Nothing it opens has an anchor
---map, so this is a read-only detour -- there is nowhere in there to annotate from.
---
---Exported because the tree's `gd` hands a file over too, knowing no line in it. What a host
---is handed is one rule about the scope a review is of, not one rule per surface that can
---ask for it.
---@param file CRFile
---@param line integer|nil nil when the caller knows a file but no position in it
local function hand_to_diff(file, line)
  local adapter = config.get().open_diff
  if not adapter then
    -- Reachable only when a host bound this itself: the view binds no key without an
    -- adapter, precisely so that pressing one can never do nothing quietly.
    warn("No open_diff adapter configured")
    return
  end
  adapter({
    -- Absolute, because the spec carries no root to read a relative path against. From
    -- this the host can reach both the file and the repository it is in.
    path = vim.fs.joinpath(V.root, file.path),
    before = V.scope.before,
    -- nil when the post-image is the working tree, which is most scopes. Not an error and
    -- not worth a sentinel: nil says "the file on disk", which is what a diff tool would
    -- have opened anyway.
    after = V.scope.after,
    line = line,
  })
end

M.hand_to_diff = hand_to_diff

---`gd`: read the file under the cursor in the host's diff tool.
---
---At the line `<CR>` opens, deleted-line fallback and all -- one rule about where a diff
---row lands in the post-image, not two. A row that names no line hands over none rather
---than inventing line 1: a file header knows which file and nothing about where in it.
function M.open_diff()
  if not M.current() then
    return
  end
  local anchor = anchor_at_cursor()
  if not anchor then
    return
  end
  local file = V.files[anchor.file]
  hand_to_diff(file, anchor.kind == "line" and worktree_line(file, anchor) or nil)
end

--- Panel actions ---------------------------------------------------------------

-- The tree's actions are `view_panel.lua`'s, which is handed this module and the view it
-- mutates. What is left here are the six names `keymaps.lua` binds onto the tree's buffer,
-- so that the key table does not learn where the bodies moved to.

function M.panel_select()
  view_panel.panel_select(V, M)
end

function M.panel_open_diff()
  view_panel.panel_open_diff(V, M)
end

---@param shut boolean|nil nil toggles
function M.panel_fold(shut)
  view_panel.panel_fold(V, M, shut)
end

---@param shut boolean
function M.panel_fold_all(shut)
  view_panel.panel_fold_all(V, M, shut)
end

function M.panel_toggle_reviewed()
  view_panel.panel_toggle_reviewed(V, M)
end

---@param forward boolean
function M.panel_jump_file(forward)
  view_panel.panel_jump_file(V, M, forward)
end

--- Delivery -------------------------------------------------------------------

---Choose where the batch goes, from a surface this module owns.
---
---The choice is delivery's; what is left here is windows. Delivery puts focus back in the
---window that asked, so all this adds is the case delivery cannot know about: that window
---being gone by the time the picker answers -- the queue float closed under it, say -- in
---which case the diff is where a reviewer belongs.
---@param on_done fun()|nil Runs after a target is chosen, once the picker has closed
function M.pick_target(on_done)
  local asked_from = vim.api.nvim_get_current_win()
  delivery.pick_target(function()
    if not vim.api.nvim_win_is_valid(asked_from) and M.current() then
      vim.api.nvim_set_current_win(V.win)
    end
    -- The winbar names the target, and the picker is asynchronous: repainting after
    -- `pick_target` returns paints before there is anything new to say.
    if V then
      update_winbar()
    end
    if on_done then
      on_done()
    end
  end)
end

---What the review a batch is going out of can say about itself, or nothing when there is
---no review at all.
---
---Handed over rather than read back: delivery knows nothing about views, and a batch that
---leaves with none open is answered from the working directory instead. Shared by submit
---and copy because the payload names this in its first line -- a copy assembled from a
---different context would differ from the send it stands in for by exactly that line.
---@return { root?: string, scope_label?: string, files?: integer, reviewed?: integer }
local function review_ctx()
  local V_ = M.current()
  if not V_ then
    return {}
  end

  local reviewed = 0
  for _ in pairs(V_.reviewed) do
    reviewed = reviewed + 1
  end
  return { root = V_.root, scope_label = V_.scope.label, files = #V_.files, reviewed = reviewed }
end

---Close a float that is listing the batch about to be handed over.
---
---Shared by both submit keys: a submitted batch must never leave a dialog listing it on
---screen, and a composer opening over that dialog is no better.
local function close_queue_float()
  if V and V.queue_win and vim.api.nvim_win_is_valid(V.queue_win) then
    vim.api.nvim_win_close(V.queue_win, true)
    V.queue_win = nil
  end
end

---Submit the batch, and put the windows back the way a sent batch leaves them.
---
---The rule -- restore, deliver, empty only on a dispatch -- is delivery's, because none of
---it is about a window and all of it happens with nothing open. What is left here is the
---float that was listing the batch, the diff behind it, and telling delivery what this
---review can say about itself.
function M.submit()
  -- Submitting empties the queue, so any open queue float is now describing nothing.
  close_queue_float()

  local dispatched = delivery.submit(review_ctx())
  -- A batch that did not go is still queued and still drawn on the diff, so there is
  -- nothing to repaint -- and the reviewer has already been told why.
  if dispatched then
    -- The batch that just went was snapshotted a moment ago, so every one of its entries is
    -- untouched and the winbar should say so immediately. Judged here rather than left to
    -- the next reconcile because a submit is the one moment a reviewer looks for that
    -- number, and because the archive underneath it has certainly moved.
    judge_archive()
    M.paint()
  end
end

---Submit the batch under a **preamble**, written in the composer first.
---
---`<C-s>` with a composer in front of it and the same submit behind it, so the fast path
---costs nothing: `<C-s>` still asks no questions. The flow itself is delivery's, for the
---reason the plain submit's is -- none of it is about a window, and it works with nothing
---open.
---
---What is left here is what submitting already left here, a composer later: the float that
---was listing the batch, and the diff behind it once something has actually gone. Handed
---over rather than run in order, because a composer answers on a later tick and an abandoned
---one never answers at all -- and an abandoned composer is not a submit, so there is nothing
---to repaint.
function M.submit_with_preamble()
  close_queue_float()

  delivery.submit_with_preamble(review_ctx(), function(dispatched)
    if dispatched then
      -- Exactly what the plain submit does with a dispatch, and for the same reasons: the
      -- batch that just went was snapshotted a moment ago, so every entry in it is
      -- untouched and the winbar should say so now rather than at the next reconcile.
      judge_archive()
      M.paint()
    end
  end)
end

---Copy the batch to the clipboard, exactly as submitting would have rendered it.
---
---Nothing here does what submit does with the windows, because nothing was consumed: the
---queue still holds every entry, the diff still draws them, and a float listing them is
---still telling the truth. That is the whole difference between the two keys, and it is
---why this one leaves the surface alone.
function M.copy()
  delivery.copy(review_ctx())
end

--- The queue float --------------------------------------------------------------

-- The float itself is `queue_float.lua`, which is handed this module. What is left here is
-- what is about the view rather than about the queue: the jump into the diff, and the
-- window a float is open in.

---Put the cursor on the place a queued annotation is about.
---
---Says why not rather than doing nothing when it cannot, and says it differently each
---time: a **bare note** will never have a destination, a missing review view means open
---one, and a file the scope does not cover means change scope. One shared "cannot jump
---there" would name none of the three remedies.
---@param entry CRAnnotation
---@return boolean jumped Whether the cursor actually moved; false has already reported why
function M.jump_to_entry(entry)
  -- One queue holds both paths' entries, and the capture path can produce an annotation
  -- with no file behind it at all. Checked before the view, because opening a review would
  -- not give this one anywhere to go either.
  if entry.kind == "note" then
    info("A bare note is about no file — there is nowhere to jump to")
    return false
  end
  if not M.current() then
    info("No review view open — open one to jump to an annotation")
    return false
  end

  local index
  for i, file in ipairs(V.files) do
    if file.path == entry.path then
      index = i
      break
    end
  end
  -- An entry captured outside a checkout has no repository-relative path, so it names the
  -- only path it has and falls in here too: no scope of this review covers it.
  if not index then
    info(
      ("%s is not in the %s scope — change scope to jump to it"):format(entry.path or entry.abs_path, V.scope.label)
    )
    return false
  end

  -- A file collapsed because it is reviewed must open when you deliberately jump into it,
  -- otherwise the jump lands on a header with nothing beneath it -- the same courtesy the
  -- file picker extends. Reviewed with nothing recorded reads as collapsed too, which is
  -- how the render decides it.
  local expanded = V.expanded[entry.path]
  if expanded == nil then
    expanded = V.reviewed[entry.path] == nil
  end
  if not expanded then
    V.expanded[entry.path] = true
    M.paint()
  end

  -- The entry's key is already sided, so it also says which pane the annotation belongs to,
  -- and that pane's anchor map is the only one carrying it. No new rule: the same key that
  -- decides where the note is drawn decides where the jump lands.
  local to_before = view_layout.has_before(V) and render.is_before_key(entry.key)
  local rendered = to_before and V.before_render or V.render

  -- The scan `]a` already makes: the anchor map is the only thing that knows which row a
  -- key is on now, which is what lets a stale annotation still land wherever its anchor
  -- points. A whole-file entry's key matches no line, and neither does a line that this
  -- diff no longer renders; both mean the file, so both land on its header.
  local row = rendered.file_rows[index]
  local file = V.files[index]
  for r, a in pairs(rendered.anchors) do
    if
      a.file == index
      and a.kind == "line"
      and render.line_key(file.path, file.hunks[a.hunk].lines[a.line]) == entry.key
    then
      row = r
      break
    end
  end

  vim.api.nvim_set_current_win(to_before and V.before_win or V.win)
  goto_row(row, "zz")
  return true
end

---Record the window a queue float has opened in.
---
---Kept here rather than on the float because closing it on a submit is a rule about this
---module's windows: `submit` runs from either pane as readily as from the float, and a
---batch that has gone must never leave a dialog listing it on screen.
---
---Against whatever view there is rather than `M.current()`, which answers nil once the
---review's own window has gone: the float outlives that, and is still a window to close.
---@param win integer
function M.hold_queue_float(win)
  if V then
    V.queue_win = win
  end
end

---Forget that window, if it is still the one recorded.
---
---Guarded rather than cleared outright: a float that closes after a later one opened would
---otherwise leave the view holding nothing while a float is still on screen.
---@param win integer
function M.release_queue_float(win)
  if V and V.queue_win == win then
    V.queue_win = nil
  end
end

---List the queued annotations, drop any of them, then submit the batch.
---
---The surface is `queue_float`'s; what stays here is the name a host's command and the `Q`
---key already bind, and this module handing itself in for the actions the float drives.
function M.review_queue()
  queue_float.open(M)
end

---List the commits on the branch, from inside a review, and trim it to the one picked.
---
---The surface is `trim_float`'s, and both the repository and the commit the branch starts at
---are handed to it rather than looked up: the review already knows both, and a second answer
---to either question is a second chance to answer it differently -- a `git fetch` in another
---window moves the default branch, and a list derived a second time would then be drawn
---against a base this review is not reading. The **identity** is what is handed over and
---never the pre-image, because the pre-image is exactly what a trim narrows.
---
---What stays here is the one refusal only the view can make. Which **scope** is on screen
---is this module's own state, and a commit list is about a branch: on `staged`, `unstaged`,
---`worktree` or a revspec there is no branch behind the review to list. Said rather than
---ignored, so a reviewer learns where the key applies instead of watching nothing happen.
function M.commit_list()
  local v = M.current()
  if not v then
    return
  end
  if v.scope.name ~= "branch" then
    info(("Commits are listed for a branch review — this review is %s"):format(v.scope.label))
    return
  end
  trim_float.open(M, v.root, v.scope.identity)
end

---Read the branch review with `skipped` taken out of it, or the whole branch with nothing
---passed.
---
---Set and then applied through `set_scope`, which is the same entry point a **scope** change
---goes through, because that path already re-reads the diff, invalidates the syntax caches
---and seeds the per-scope progress table. A path of its own would eventually forget one of
---the three, and which one it forgot would be invisible until a reviewer met it.
---
---Nothing here re-reads the trim to draw anything: resolution does that, so the label and
---the diff are answering out of the same store on the same pass.
---
---**The build is attempted before anything is stored.** A set with a hole in it needs a tree
---that never existed, and taking one commit out can need a commit that is staying -- the
---formatter case is the likeliest of all, because a formatter touches the same lines every
---other commit touched. Such a set is refused rather than approximated, and refused *here*,
---so the store still holds what it held, the review on screen is the review that was there,
---and the reviewer is a keystroke away from a selection that works. A refusal is an ordinary
---answer to a reviewer asking for a tree that never existed, not a failure.
---
---The base handed to the check is the review's own **identity**, for the reason the commit
---list is drawn from it: a second derivation of where this branch starts is a second chance
---to answer it differently.
---@param skipped string[]|nil The commits to take out; nil removes the trim
function M.trim_to(skipped)
  local v = M.current()
  if not v then
    return
  end
  local refused = require("codereview.git").trim_refusal(v.root, v.scope.identity, skipped)
  if refused then
    info(refused)
    return
  end
  require("codereview.state").set_trim(v.root, skipped)
  M.set_scope("branch")
end

---Read the last dispatched **batch** back, from inside a review.
---
---The surface is `archive`'s, and it consults no view: a batch has already gone, so nothing
---about which window is current could change which one went last. What stays here is the
---name `keymaps.lua` binds to `gb` in both the diff and the file tree, so the key table does
---not learn where the body lives -- exactly as `gp` and `gl` are named here.
function M.last_batch()
  require("codereview.archive").open()
end

function M.close()
  if V and vim.api.nvim_tabpage_is_valid(V.tab) then
    -- Closing the tab takes both windows and both scratch buffers with it.
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(V.tab))
  end
  V = nil
end

--- The panel window ------------------------------------------------------------

-- The tree's window is `view_panel.lua`'s, built and dismissed there as the before pane is
-- built and dismissed in `view_layout.lua`. What is left here is the name `keymaps.lua`
-- binds to `gp` in both the diff and the tree.

function M.toggle_panel()
  view_panel.toggle_panel(V, M)
end

--- The layout ------------------------------------------------------------------

-- The layouts, and everything the switch between them carries across, are
-- `view_layout.lua`. What is left here is the name `keymaps.lua` binds to `gl` in both the
-- diff and the tree, so that the key table does not learn where the body moved to.

function M.toggle_layout()
  view_layout.toggle_layout(V, M)
end

--- Archived entries -------------------------------------------------------------

-- The switch and the override in front of it are `config`'s, because the choice outlives
-- this view: every review opened afterwards has to agree with it. What is left here is the
-- name `keymaps.lua` binds to `gA` in the diff and in the tree, and the repaint that makes
-- the answer immediate.

---Turn **archived** entries on or off for the rest of the Neovim session.
---
---Off is off entirely, which is the switch's own coarseness rather than a middle state
---invented here: nothing drawn, nothing tallied and no git spent judging, so the
---`untouched` segment leaves the sticky header with the entries.
---
---Judged here rather than left to the paint, which also runs on every resize -- and
---repainted rather than left to the next reason to repaint, because a reviewer who presses
---a key is asking about the diff in front of them. Both calls do nothing with no review
---open, which is a state this key cannot be pressed in but the exported action can be
---called in: the override is still taken, and the next review opened agrees with it.
function M.toggle_archived()
  config.toggle_archived()
  judge_archive()
  M.paint()
end

--- Opening --------------------------------------------------------------------

---@param spec string|nil
function M.open(spec)
  hl.setup()
  local cfg = config.get()

  local root = git.root(vim.fn.getcwd())
  if not root then
    warn("not inside a git repository")
    return
  end

  local scope, err = git.resolve_scope(spec or "branch", root)
  if not scope then
    warn(err or "could not resolve the review scope")
    return
  end

  local files, derr = git.collect(scope, root, { context = cfg.context, untracked = cfg.untracked, spans = cfg.spans })
  if not files then
    warn("git: " .. (derr or "diff failed"))
    return
  end
  if #files == 0 then
    info(("No changes in scope '%s'"):format(scope.label))
    return
  end

  if M.current() then
    M.close()
  end

  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local main_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(main_win, buf)
  view_layout.scratch(buf, "codereview")
  view_layout.window_opts(main_win)

  local key = scope_key(scope)
  -- Configuration decides this only until a reviewer has said otherwise; from then on their
  -- choice does, for the rest of the session.
  local layout = view_layout.opening_layout()
  V = {
    root = root,
    scope = scope,
    files = files,
    per_scope = { [key] = { reviewed = {}, expanded = {} } },
    reviewed = {},
    expanded = {},
    notes = {},
    archived = {},
    touched = {},
    syntax_cache = {},
    collapsed = {},
    buf = buf,
    win = main_win,
    layout = layout,
    tab = tab,
    augroup = vim.api.nvim_create_augroup("CodeReviewView", { clear = true }),
  }
  V.reviewed = V.per_scope[key].reviewed
  V.expanded = V.per_scope[key].expanded
  require("codereview.state").restore(V, key)
  M.reconcile()

  -- Before the windows below it: every one of them takes focus while it is being built, and
  -- this is what is watching when they hand it back.
  view_layout.watch_focus(V)

  -- Before the panel, so the panel's `topleft`/`botright` split lands outside both panes
  -- rather than between them.
  if layout == "split" then
    view_layout.show_before_pane(V, M)
  end
  if cfg.panel.enabled then
    view_panel.show_panel(V, M)
  end
  view_layout.balance_panes(V)

  -- The before pane, if there is one, was given its own by `show_before_pane` -- which is
  -- also what gives it back to a pane the layout toggle rebuilt.
  view_layout.attach_pane(V, M, V.buf)

  -- Header padding is width-dependent, so a resize needs a full repaint -- but only a resize
  -- that moved a review window.
  --
  -- One terminal resize fires `VimResized` *and* `WinResized`, so this callback runs twice
  -- for one resize, and each run repainted both panes and rebuilt the whole file tree. It
  -- carries no pattern and no buffer either, so a window resized in another tab page ran it
  -- as well. Both are answered by the same comparison: the paint records the dimensions it
  -- drew at, and a callback that finds them unchanged returns. `docs/design-notes.md` holds
  -- the measurements, and `repaint_spec` owns the rule.
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = V.augroup,
    callback = function()
      if M.current() and dimensions() ~= V.dims then
        M.paint()
      end
    end,
  })

  -- A **muted** window's colors are blends of the theme's, so they cannot outlive it.
  -- `hl.lua` writes those blends again from its own `ColorScheme` autocommand; what this
  -- adds is the pass that links a group the new theme gives a color to at last. Declared
  -- after `hl.setup()`, which is the first thing this function does: the two fire in the
  -- order they were declared, so every blend this links to exists by the time it links.
  -- Watched from here rather than from `hl.lua`, which would have to reach back up into the
  -- module that owns the windows to say it.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = V.augroup,
    callback = function()
      view_layout.recolor()
    end,
  })

  M.paint()
  view_layout.place(V, 1)
end

return M
