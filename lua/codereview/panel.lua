---The file tree panel.
---
---The main buffer answers "what changed here"; this answers "where am I and how much is
---left", which a single scrolling document cannot show. A flat list of basenames could not
---either: in any real repository half the entries are called `index.ts`.
---
---Pure, and one edge: `render` decides what a **host**'s icon adapters answer with, for the
---tree as for the two surfaces the diff draws. The rule is one `pcall` and a type test on
---each half of the answer -- the glyph, and the highlight group that colours it -- and a
---second copy of it here is two places for the tree and the diff to come to disagree about
---the same file, which is the whole of *one file, one icon*. It lives in `render` because
---`render` already owns what a file is called wherever it is named.
---
---This surface asks it twice, with two adapters: `file_icon` for a file row and `dir_icon`
---for a directory one. Two adapters and one rule -- a host wires one function per kind of
---thing so that neither has to guess what it was handed, and both answers are then checked
---in the one place.
local M = {}

local render = require("codereview.render")

---@class CRPanelNode
---@field kind "dir"|"file"
---@field name string          Display segment (a dir may hold several, e.g. "apps/api")
---@field path string          Full path from the repository root
---@field children CRPanelNode[]|nil
---@field index integer|nil    Index into the file list, for a file node
---@field total integer        Files in this subtree
---@field reviewed integer     Reviewed files in this subtree
---@field notes integer        Annotations in this subtree
---@field lead string|nil      Highlight group of a file's **leading type**. A file node only:
---                            a directory answers how much of it has been read, not what kind
---                            of thing is waiting inside it.

---@class CRPanelRender
---@field lines string[]
---@field marks table[]
---@field row_file table<integer, integer>   Buffer row -> file index
---@field row_dir table<integer, string>     Buffer row -> directory path
---@field row_depth table<integer, integer>  Buffer row -> tree depth
---@field file_row table<integer, integer>   File index -> buffer row
---@field file_rows integer[]                Every file row, ascending, for ]f / [f

---@param text string
---@param width integer
---@return string
local function truncate_left(text, width)
  if width <= 1 or vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  -- Truncate from the LEFT: the tail of a name identifies it, the head is usually shared
  -- boilerplate with its siblings.
  local chars = vim.fn.strcharlen(text)
  return "…" .. vim.fn.strcharpart(text, chars - width + 1)
end

--- Tree construction -----------------------------------------------------------

---@param files CRFile[]
---@return table root
local function build(files)
  local root = { kind = "dir", name = "", path = "", dirs = {}, files = {} }
  for index, file in ipairs(files) do
    local parts = vim.split(file.path, "/", { plain = true })
    local leaf = table.remove(parts)
    local node, acc = root, {}
    for _, part in ipairs(parts) do
      acc[#acc + 1] = part
      if not node.dirs[part] then
        node.dirs[part] = { kind = "dir", name = part, path = table.concat(acc, "/"), dirs = {}, files = {} }
      end
      node = node.dirs[part]
    end
    node.files[#node.files + 1] = { kind = "file", name = leaf, path = file.path, index = index, file = file }
  end
  return root
end

---Compact, sort and total a subtree.
---
---Compaction merges a directory that holds exactly one directory and no files into its
---child, so a monorepo shows `apps/api/src` on one row instead of burning three rows and
---six columns of indent on path segments that carry no information.
---@param node table
---@param stat fun(file: CRFile, path: string): boolean reviewed, integer notes, string|nil lead
---@return CRPanelNode
local function finish(node, stat)
  -- The root is virtual and has no row of its own, so it must not absorb its only child;
  -- that child compacts on its own and renders at depth zero anyway.
  while node.path ~= "" and vim.tbl_count(node.dirs) == 1 and #node.files == 0 do
    local _, only = next(node.dirs)
    node.name = node.name .. "/" .. only.name
    node.path = only.path
    node.dirs, node.files = only.dirs, only.files
  end

  local children = {}
  local dir_names = vim.tbl_keys(node.dirs)
  table.sort(dir_names, function(a, b)
    return a:lower() < b:lower()
  end)
  -- Directories first, then files: the ordering every file explorer uses.
  for _, name in ipairs(dir_names) do
    children[#children + 1] = finish(node.dirs[name], stat)
  end
  table.sort(node.files, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  for _, file in ipairs(node.files) do
    local reviewed, notes, lead = stat(file.file, file.path)
    file.reviewed = reviewed and 1 or 0
    file.total = 1
    file.notes = notes
    -- Not totalled onto the parent below, unlike the three above it. A directory's row says
    -- how much of it has been read, and a **leading type** of a whole subtree would be a
    -- second question that row was never asked -- and a fourth field on a directory node that
    -- nothing reads is a field someone later has to prove is dead.
    file.lead = lead
    children[#children + 1] = file
  end

  node.children = children
  node.total, node.reviewed, node.notes = 0, 0, 0
  for _, child in ipairs(children) do
    node.total = node.total + child.total
    node.reviewed = node.reviewed + child.reviewed
    node.notes = node.notes + child.notes
  end
  node.dirs, node.files = nil, nil
  return node
end

---A file's **leading type** is the first **annotation type** in the *configured* order with an
---**entry** in that file, and it is what colours the file's state mark.
---
---**The configured order arrives as an argument**, the way the glyph table and the icon
---adapters already do, so this stays a pure function of what it is handed and the
---configuration module stays out of its requires. Declaration order is the order the type
---picker lists and the **payload** groups, so the tree agrees with both rather than holding a
---private ordering a host would have to learn a second time.
---
---**Ranked by position rather than matched by name at the mark.** A rank turns "first in the
---configured order" into one integer comparison per **entry**; comparing names would be a
---search of the list per entry instead.
---@param files CRFile[]
---@param opts { reviewed: table<string, string>, notes: table<string, table[]>, types: CRType[]|nil }
---@return CRPanelNode
function M.tree(files, opts)
  local rank, group = {}, {}
  for i, t in ipairs(opts.types or {}) do
    rank[t.name] = rank[t.name] or i
    group[i] = t.hl
  end

  -- Note counts are bucketed once rather than rescanned per file: the naive form is
  -- O(files x annotations), which is the whole panel's cost on a large review.
  --
  -- **The leading type rides in this walk, and it is not free.** The walk is over anchor
  -- *keys* and `#items` is O(1), so an entry's own type is something this loop did not read
  -- before. What it adds is one comparison per **entry**, inside the pass that is already
  -- here, and no second pass over anything. The tree is rebuilt on every file crossing as
  -- well as on every paint, so what the cost is counted in matters: entries queued, not files
  -- reviewed. A three-hundred-file review holding ten annotations walks ten more items.
  local per_path, lead = {}, {}
  for key, items in pairs(opts.notes or {}) do
    local path = key:match("^(.*):[nof]:%d+$")
    if path then
      per_path[path] = (per_path[path] or 0) + #items
      for _, item in ipairs(items) do
        -- An entry whose type is not in the configured list is counted above and leads
        -- nothing. A queue restored under a configuration that has since dropped a type still
        -- says how much is waiting in a file and stops saying what kind of thing it is, which
        -- is the same answer `types.group` gives it in the payload.
        local r = rank[item.type]
        if r and r < (lead[path] or math.huge) then
          lead[path] = r
        end
      end
    end
  end

  return finish(build(files), function(_, path)
    local first = lead[path]
    return (opts.reviewed or {})[path] ~= nil, per_path[path] or 0, first and group[first] or nil
  end)
end

--- Rendering -------------------------------------------------------------------

---What a host's answer costs one row: the glyph, the group that colours it, the glyph and
---its separator as one string, and that string's width in display columns.
---
---**One copy, because it is one rule.** A file row and a directory row reach two different
---adapters, but what an answer *costs a row* is the same thing on both: the separator rides
---with the glyph, so a row with no glyph contributes nothing rather than a space -- which
---would move every name in every tree by one column and look right while doing it -- and the
---width is measured only when there is something to measure. `strdisplaywidth` is a call
---across the vimscript bridge, once a row, on every paint *and* on every **file crossing**;
---#217 measured the unguarded form at 0.14 us a row. Two copies of that is one place for the
---guard to be dropped without anyone noticing.
---
---**The name's budget is not in here, and that is deliberate.** Both branches subtract the
---same expression today and the two are equal by coincidence rather than by rule: on a
---directory row the fixed 2 is the chevron and its separator, on a file row it is the state
---mark and its separator. Shared, the expression would assert an equality nothing guarantees,
---and a chevron two columns wide would silently mis-budget the other branch.
---
---**The guard stays outside**, at each caller, which is why this takes an adapter that is
---never nil. A nil adapter answered in here is a call a row makes for a review that wired
---nothing, and that guarantee is structural rather than remembered (ADR-0001).
---@param adapter fun(path: string): string|nil, string|nil
---@param path string
---@return string|nil glyph, string|nil group, string lead, integer lead_width
local function row_icon(adapter, path)
  local glyph, group = render.file_icon(adapter, path)
  if not glyph then
    return nil, nil, "", 0
  end
  local lead = glyph .. " "
  return glyph, group, lead, vim.fn.strdisplaywidth(lead)
end

---How wide each of a file row's two counts has to be drawn: the widest each one reaches
---anywhere in the review, and no wider.
---
---**The same question `trim_float.size_widths` answers for the commit list**, one surface
---over, and the same answer -- "the widest figure any row carries, and no wider". A stat is a
---column only while every row spends the same width on it, and a reviewer comparing two
---changes is then comparing two columns rather than doing arithmetic. A width fixed in
---advance would either cut a large count or charge every name in every review for digits no
---file in it has.
---
---**A binary file is skipped rather than counted as zero.** It has no line counts to give,
---so it widens nothing, and its row draws the field blank -- see `M.build`.
---@param files CRFile[]
---@return { added: integer, removed: integer }
local function stat_widths(files)
  local at = { added = 0, removed = 0 }
  for _, file in ipairs(files) do
    if not file.binary then
      at.added = math.max(at.added, #("+%d"):format(file.added))
      at.removed = math.max(at.removed, #("-%d"):format(file.removed))
    end
  end
  return at
end

---The footer row: the reviewed tally, and a progress bar filled from the same two numbers.
---
---**The bar carries no highlight range of its own, and that is a measurement rather than a
---saving.** The row draws in one line-wide `CodeReviewTitle`, and a line-wide group with a
---foreground replaces the foreground of every mark beneath it. Read on a painted cell: a
---range asking for `ee0000` on this row comes back `00ee00`, which is the row's own colour. So
---a bar emitted as two ranges -- one for its filled cells, one for its empty ones -- draws in
---one colour, and no assertion over mark tables can see that it did. Narrowing the line-wide
---group to the text would free those cells, and would take the row's fill off every
---colorscheme that gives `Title` a background, which is a fill this plugin cannot see. So the
---two kinds of cell are told apart by their glyph and the bar takes the tally's own colour.
---
---**The bar is measured against the widest tally the review can print, not against the one it
---prints now.** `N/M reviewed` grows a column the moment the reviewed count grows a digit, so
---a bar taking whatever is left over shrinks as it fills -- and at a hundred files it stops
---moving: 9 reviewed leaves 18 cells and fills one of them, 10 leaves 17 and fills one of
---them, so a file was read and the bar says nothing happened. The tally is padded out to
---`M/M reviewed` instead. That is the rule the commit list's size column already follows: a
---column only while every row spends the same width on it.
---
---**A started review draws at least one cell.** The count is a floor, which is what makes a
---full bar mean a finished review and nothing else -- 299 of 300 is 15 cells of 16, and only
---`reviewed == total` can reach the last one. The floor costs the other end: at 300 files it
---reaches its first cell at 19 reviewed, so a reviewer finishes eighteen files and the bar
---still says they have not begun, on the review size the bar is most use on. The clamp
---answers that end and cannot reach the other.
---
---**The row spends the columns every other row of the tree spends**, which is `width - 1`, so
---the bar ends where a directory's tally ends. With no columns left for a bar the row is the
---tally alone, byte for byte what it was before this existed.
---
---**A scope with no files in it draws no bar either.** A full row of empty cells over `0/0
---reviewed` says there is everything left to read, which is the opposite of true, and it is
---the same lie the clamp above exists to stop telling from the other end. It is also what
---`file_icon_spec` already asserts of an empty scope: an empty tree, and a footer.
---@param reviewed integer
---@param total integer
---@param width integer
---@param icons table
---@return string
local function footer(reviewed, total, width, icons)
  local tally = ("%d/%d reviewed"):format(reviewed, total)
  local widest = ("%d/%d reviewed"):format(total, total)
  local cells = width - 1 - #widest - 1
  if cells < 1 or total == 0 then
    return tally
  end
  -- `reviewed * cells` first and the division after it. `reviewed / total * cells` is two
  -- roundings, and the second is not free: 15 of 22 files over a 22-cell bar -- a panel 38
  -- columns wide -- lands on 14.999999999999998 and floors to 14, one cell short of the 15
  -- the exact form gives. The shipped width cannot show it, because 18 cells over a two-digit
  -- total agrees either way, so the case that pins this spells the width out.
  local filled = reviewed > 0 and math.max(1, math.floor(reviewed * cells / total)) or 0
  local bar = icons.progress_full:rep(filled) .. icons.progress_empty:rep(cells - filled)
  -- The tally is padded to the widest, so the bar starts in the same column all review long.
  return tally .. (" "):rep(#widest - #tally + 1) .. bar
end

---@param files CRFile[]
---@param opts { width: integer, icons: table, types: CRType[]|nil, file_icon: (fun(path: string): string|nil, string|nil)|nil, dir_icon: (fun(path: string): string|nil, string|nil)|nil, reviewed: table<string, string>, notes: table<string, table[]>, collapsed: table<string, boolean>, current: integer|nil }
---@return CRPanelRender
function M.build(files, opts)
  local icons = opts.icons
  local width = math.max(14, opts.width)
  local collapsed = opts.collapsed or {}
  local tree = M.tree(files, opts)

  -- The columns every file row spends on its `+N -M`, decided once for the whole review.
  -- Zero when no file in it has line counts to give -- a review of nothing but binary files
  -- leaves the columns off the rows rather than blank on them, which is what the commit list
  -- does with a commit git answered nothing for.
  local size_at = stat_widths(files)
  local stat_width = size_at.added > 0 and (size_at.added + 1 + size_at.removed) or 0
  -- Each count right-aligned in a sub-column of its own, so the digits line up down the page
  -- and the `+` and the `-` are free to move. `trim_float` spells its size columns the same
  -- way and for the same reason.
  local stat_format = ("%%%ds %%%ds"):format(size_at.added, size_at.removed)

  local lines, marks = {}, {}
  local row_file, row_dir, row_depth, file_row, file_rows = {}, {}, {}, {}, {}

  ---@param row integer
  ---@param col integer
  ---@param o table
  local function mark(row, col, o)
    marks[#marks + 1] = { row = row - 1, col = col, opts = o }
  end

  ---@param node CRPanelNode
  ---@param depth integer
  local function draw(node, depth)
    local indent = ("  "):rep(depth)

    if node.kind == "dir" then
      -- **A directory row carries a glyph through an adapter of its own, and never through
      -- the file one.** A directory names no file, so there is nothing to ask `file_icon`
      -- about it and asking about an invented path would be the plugin having the opinion
      -- the adapter exists to avoid (ADR-0001). That reasoning stood while there was one
      -- adapter and it stands now: the answer is a second adapter rather than a wider first
      -- one, and neither is ever handed the other's kind of thing. `file_icon` is reached
      -- from the file branch below and from nowhere else.
      --
      -- The rule that reads the answer is the file one, handed this adapter. One rule and
      -- not two: a second copy is a second place for a glyph and a group to be checked
      -- differently, and a reviewer would meet the difference as a colour their icon plugin
      -- chose surviving on one row of one tree and not on the next.
      --
      -- Nothing wired is the common case and costs the test in front of the call, for the
      -- reason the file branch spells out below: there is no glyph shipped behind this key,
      -- so with none of it there is nothing to call.
      local shut = collapsed[node.path]
      local chevron = shut and icons.collapsed or icons.expanded
      local right = ("%d/%d"):format(node.reviewed, node.total)
      -- `node.path` is the directory this row **names**, which for a compacted chain is the
      -- deepest of the directories the row spells: `apps/api/src` and never `apps`. The
      -- glyph and the name are then about the same directory, which is the whole of what a
      -- compacted row promises.
      local glyph, group, lead, lead_width = nil, nil, "", 0
      if opts.dir_icon then
        glyph, group, lead, lead_width = row_icon(opts.dir_icon, node.path)
      end
      -- The name's budget pays for the glyph, and the name goes on being cut from the left.
      -- The fixed 2 here is the chevron and its separator, which is why this expression is
      -- spelled again on the file row rather than shared with it -- see `row_icon`.
      local name = truncate_left(node.name, width - #indent - 2 - #right - 2 - lead_width)
      -- **What the glyph starts after, spelled once**, so the string the row is built from
      -- and the offset the glyph's own mark lands at are one expression and neither can be
      -- updated without the other. A chevron and its separator are four bytes and two
      -- columns, so a range placed at the display column lands two bytes early and colours
      -- the chevron -- which is the trap the header row sprang first.
      local before_glyph = ("%s%s "):format(indent, chevron)
      local head = before_glyph .. lead .. name
      local pad = math.max(1, width - vim.fn.strdisplaywidth(head) - #right - 1)
      local text = head .. (" "):rep(pad) .. right

      lines[#lines + 1] = text
      local row = #lines
      row_dir[row] = node.path
      row_depth[row] = depth
      -- **The row's own colour is laid around the host's and never under it.** A directory
      -- row colours its whole head, so a glyph's group would be a second range over bytes
      -- the first already covers, and which of the two drew would rest on which extmark was
      -- emitted last -- true today, and findable nowhere in this file by anyone wondering
      -- later why a colour changed. So the head is split at the glyph when there is a group
      -- to put there, and stays the single range it has always been when there is not: an
      -- adapter that answered with a glyph alone draws it in the row's own colour, which is
      -- what a broken group costs as well. The group is the host's own and is never
      -- translated into one of this plugin's (ADR-0001).
      --
      -- **Three ranges that abut, and not three that nearly do.** The third begins where the
      -- *glyph* ends and not where `lead` does -- `lead` is the glyph and its separator, so
      -- starting there would leave that one byte covered by no range at all. It is a space,
      -- so today the row looks identical either way and nothing on screen could report it;
      -- the day the row's group grows a background it is a one-column hole, and the comment
      -- above would be false without ever having been edited. So the head is covered, and
      -- the spec asserts the cover rather than the three offsets.
      if group then
        mark(row, 0, { end_col = #before_glyph, hl_group = "CodeReviewPanelDir" })
        mark(row, #before_glyph, { end_col = #before_glyph + #glyph, hl_group = group })
        mark(row, #before_glyph + #glyph, { end_col = #head, hl_group = "CodeReviewPanelDir" })
      else
        mark(row, 0, { end_col = #head, hl_group = "CodeReviewPanelDir" })
      end
      mark(row, #text - #right, {
        end_col = #text,
        -- A fully-reviewed directory reads as done at a glance, without counting.
        hl_group = node.reviewed == node.total and "CodeReviewStatAdd" or "CodeReviewNoteCount",
      })

      if not shut then
        for _, child in ipairs(node.children) do
          draw(child, depth + 1)
        end
      end
      return
    end

    local reviewed = node.reviewed == 1
    local icon = reviewed and icons.reviewed or (node.notes > 0 and icons.annotated or icons.unreviewed)

    -- **The row's `+N -M`, from the counts the file record already carries.** The same two
    -- numbers the file's header row draws in the **review view**, in the same two groups:
    -- one file, one set of facts, wherever the file is named. Read off the record through
    -- `node.index` rather than off a field copied onto the node -- the index is what a file
    -- row already is, and a fourth number totalled up the tree is one a directory row was
    -- never asked for.
    --
    -- **What left to pay for it is the note count number.** The count is still produced and
    -- still totalled onto the directory nodes; only the printing of it is gone. What mattered
    -- about it -- which **annotation type** is waiting -- is the state mark's colour since
    -- #244, and the mark above still says *something* is waiting. A file holding one entry
    -- and a file holding nine now draw the same row, which the parent spec chose knowingly:
    -- the colour answers *how bad*, and *how many* is the queue's own question.
    --
    -- **A binary file draws the field blank.** It has no line counts, so `+0 -0` would be a
    -- size it never had. The file's header row spells the word `binary` there and this row
    -- does not, on purpose: the word is six columns, so one binary file anywhere in a review
    -- would take a column off every name in it, and a word in a column of numbers does not
    -- answer how big a change is. Clear columns are what the commit list leaves for a commit
    -- git answered nothing for, rather than pulling every row under it out of line.
    local file = files[node.index]
    local right, plus, minus = "", nil, nil
    if stat_width > 0 then
      if file.binary then
        right = (" "):rep(stat_width)
      else
        plus, minus = ("+%d"):format(file.added), ("-%d"):format(file.removed)
        right = stat_format:format(plus, minus)
      end
    end
    -- The **state** mark above stays the leftmost thing after the indent: a reviewer reads
    -- that column down the page for what they have already done, and a glyph of a width the
    -- plugin does not control put in front of it would break the one thing it is for. So the
    -- glyph is a second thing about the file, between the mark and the name.
    --
    -- Nothing wired is the common case and costs the test in front of the call: the adapter
    -- is the only implementation there is, so with none of it there is nothing to call. The
    -- tree is rebuilt on every file crossing as well as on every paint, so that matters more
    -- here than it does on the diff.
    --
    -- **The group comes back beside the glyph**, because both icon plugins a host would wire
    -- answer with the pair, and reading only the first is what drew every wired glyph in
    -- this panel's own foreground. Two statements rather than the `and`/`or` one the glyph
    -- alone was reached by: that idiom is an expression, so it truncates a second return
    -- value away silently -- the colour would be dropped here, and nowhere a reader could
    -- see it happen.
    local glyph, group, lead, lead_width = nil, nil, "", 0
    if opts.file_icon then
      glyph, group, lead, lead_width = row_icon(opts.file_icon, node.path)
    end
    -- **The name's budget pays for the glyph**, and the name goes on being cut from the
    -- left, so what survives a narrow panel is the end of the name -- which is where the
    -- extension is, and the extension is what the glyph is about. In display columns,
    -- because that is what a panel is 34 of: a host's glyph is multibyte, and the ones it is
    -- likeliest to answer with are one column wide while some are two.
    --
    -- The fixed 2 here is the state mark and its separator, which is a different two from
    -- the directory row's chevron -- see `row_icon` for why the expression is not shared.
    --
    -- **And the budget is a number with conditions, never a number.** It moves with the
    -- indent, with what the stat costs this review, and with whether a host wired a glyph:
    -- twenty-five columns at the top of the tree against a five-column stat with nothing
    -- wired, nineteen two levels down with a glyph beside it, seventeen if that review's
    -- widest counts make the stat seven. `panel_spec` asserts all three with their conditions
    -- named, because a figure quoted without them reads as a property of the panel width and
    -- is wrong on every row but the one it was measured on.
    local name = truncate_left(node.name, width - #indent - 2 - #right - 2 - lead_width)
    -- **What the glyph starts after, spelled once**, so the string the row is built from and
    -- the offset the glyph's own mark lands at are one expression and neither can be updated
    -- without the other. That is `file_label`'s discipline with its `prefix`, one surface
    -- over, and it is here for the reason it is there: a range placed at a display column
    -- lands four bytes early on a top-level row, where the indent, the state mark and the
    -- separator are six bytes and four columns.
    local before_glyph = ("%s%s "):format(indent, icon)
    local head = before_glyph .. lead .. name
    local pad = math.max(1, width - vim.fn.strdisplaywidth(head) - #right - 1)
    local text = head .. (" "):rep(pad) .. right

    lines[#lines + 1] = text
    local row = #lines
    row_file[row] = node.index
    row_depth[row] = depth
    file_row[node.index] = row
    file_rows[#file_rows + 1] = row

    -- **The state mark carries the file's leading type**, so a file holding a bug stops
    -- looking like a file holding a nitpick -- and it says so in the column a reviewer already
    -- runs their eye down for review state, rather than in a second column of its own. The
    -- group is the type's own, so a host that replaced the vocabulary outright gets its own
    -- groups here and the tree agrees with the picker and the queue float about one colour per
    -- kind of finding.
    --
    -- **A reviewed file is not given one, and not only because the two facts have to be
    -- ordered.** A line-wide group replaces every attribute it sets on the marks beneath it,
    -- at every priority -- measured, and recorded in `docs/design-notes.md` -- and a reviewed
    -- row carries `CodeReviewFileReviewed` over the whole of it. A group put here would be
    -- named by an extmark on every paint and would reach no cell on any screen, which is a
    -- dead mark a later reader has no way of discovering is dead. A reviewed row is
    -- deliberately recessive anyway: the tree answers what to read next, and a file already
    -- read is not a candidate.
    mark(row, #indent, {
      end_col = #indent + #icon,
      hl_group = reviewed and "CodeReviewStatAdd" or node.lead or "CodeReviewNoteCount",
    })
    -- The colour the host's icon plugin chose for this file, over the glyph's own bytes.
    --
    -- **A second thing about the file, laid beside the state mark and never over it.** The
    -- range above keeps every byte it had, because the glyph starts where the mark ends --
    -- which is the same rule that put the glyph after the mark in the first place, now
    -- answered in colour as well as in columns.
    --
    -- Emitted only when the adapter gave a group. A range in no group is an extmark that
    -- costs a paint and draws nothing, and an adapter answering with a glyph alone has to go
    -- on carrying the marks it has always carried.
    --
    -- The group is the host's own -- `MiniIconsAzure`, `DevIconLua` -- and is never
    -- translated into one of this plugin's, which would be this plugin having the opinion
    -- about colour that the adapter exists to avoid (ADR-0001). A group the active theme
    -- gives no colour draws nothing extra, so a group nobody defined costs the glyph its
    -- colour rather than costing the row its glyph.
    if group then
      mark(row, #before_glyph, { end_col = #before_glyph + #glyph, hl_group = group })
    end
    if reviewed then
      mark(row, 0, { line_hl_group = "CodeReviewFileReviewed" })
    end
    -- **Each count over its own bytes, and neither its padding nor the space between them.**
    -- That is the rule the file's header row follows, and here it keeps a background either
    -- group may carry off the columns that hold nothing. Measured back from the end of the
    -- row in bytes, the way the commit list places every column right of its subject: the
    -- name between here and the indent is any number of bytes wide at a given number of
    -- columns, and adding up what is drawn puts every mark on this side of it out by one
    -- the first time a host's glyph or an accented name arrives.
    --
    -- **A reviewed row is given neither range.** `CodeReviewFileReviewed` covers the whole of
    -- it and resolves to `Comment`, which carries a foreground, and a line-wide group replaces
    -- every attribute it sets on the marks beneath it at every priority -- measured, and
    -- recorded in `docs/design-notes.md`. Read again on a painted cell by `panel_spec`: a
    -- range asking for `00ee00` on that row comes back `ee0000`, which is the row's own. So a
    -- range here would be named by an extmark on every paint and would reach no cell on any
    -- screen, which is a dead mark a later reader has no way of discovering is dead. The two
    -- numbers still draw; they draw recessive, which is the statement that row is for.
    if plus and not reviewed then
      local at = #text - #right
      mark(row, at + size_at.added - #plus, { end_col = at + size_at.added, hl_group = "CodeReviewStatAdd" })
      local from = at + size_at.added + 1
      mark(row, from + size_at.removed - #minus, { end_col = from + size_at.removed, hl_group = "CodeReviewStatDel" })
    end
    -- Where the diff cursor currently is. Painted last so it wins over the reviewed dim.
    if opts.current and node.index == opts.current then
      mark(row, 0, { line_hl_group = "CodeReviewPanelSel", priority = 200 })
    end
  end

  for _, child in ipairs(tree.children) do
    draw(child, 0)
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = footer(tree.reviewed, tree.total, width, icons)
  mark(#lines, 0, { line_hl_group = "CodeReviewTitle" })

  return {
    lines = lines,
    marks = marks,
    row_file = row_file,
    row_dir = row_dir,
    row_depth = row_depth,
    file_row = file_row,
    file_rows = file_rows,
  }
end

---Every file index beneath a directory path.
---@param files CRFile[]
---@param dir string
---@return integer[]
function M.files_under(files, dir)
  local out = {}
  local prefix = dir .. "/"
  for index, file in ipairs(files) do
    if file.path:sub(1, #prefix) == prefix then
      out[#out + 1] = index
    end
  end
  return out
end

---Directory paths in the tree, for collapse-all.
---@param tree CRPanelNode
---@return string[]
function M.dir_paths(tree)
  local out = {}
  local function walk(node)
    for _, child in ipairs(node.children or {}) do
      if child.kind == "dir" then
        out[#out + 1] = child.path
        walk(child)
      end
    end
  end
  walk(tree)
  return out
end

return M
