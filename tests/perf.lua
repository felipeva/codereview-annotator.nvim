-- Open-time and per-keystroke report on a large review. Deliberately NOT part of `make test`.
--
-- Wall-clock numbers are machine-dependent, so this is a report you read rather than an
-- assertion you trust. The one ceiling here is loose on purpose: it catches a regression
-- that changes the shape of the work (parsing every file up front, hashing blobs one at a
-- time), not the ordinary spread between a laptop and a CI runner.
--
-- Run with:  make perf
--
-- Two tiers of one shape and a third of another, because neither size nor shape alone shows
-- everything. 60 files is the size the budget has always watched and the only tier that can
-- fail this command; at 300 files the same operations are large enough to read a change
-- from. The larger tiers report and never assert: a second budget would be a second number
-- to tune per machine, on a file that is read rather than gated.
--
-- The third tier is the same 300 files with two changed lines each instead of half a file
-- each. That is not a smaller review, it is a *wide* one: a file is twenty rows rather than
-- three hundred, so a screenful holds a dozen files instead of one, and everything that
-- costs a review per file in view -- which is the whole of the `file content` line -- can
-- only be read there. On the deep tiers one file is near the window at a time, so that line
-- reads the same whether content is fetched per file or for all of them at once.
--
-- The line to read first is `cursor move`. It is the body of the autocommand that fires on
-- every CursorMoved, which a reviewer pays per row while holding `j` -- unlike open, scroll
-- and repaint, which are paid at moments a reviewer expects to wait.
--
-- Three things keep opening a review fast: syntax harvesting bounded by the viewport,
-- batched blob hashing, and whole-file content fetched for everything one pass brings into
-- view together rather than one process per file. If open regresses, suspect one of those
-- three, and read the `file content` line for the third: it reports git *calls* beside the
-- milliseconds, so work moved back to a process per file shows up as a count that has
-- multiplied rather than as a number that is merely large. The last cost is the
-- character-level spans, reported at the foot of each tier because they are paid once per
-- git read and must never appear in the repaint line.
--
-- The 300-file tier ends with a block on **solo**, which draws one file and none of the
-- others. Solo moves the two halves of a paint in opposite directions and neither is visible
-- anywhere else: it emits one file's rows instead of three hundred files', and it turns every
-- file move into a paint on a key that used to be a cursor motion inside one buffer. Both
-- arms are timed here, next to each other, so the trade is read rather than reasoned about.
--
-- That block is at the *foot* of the tier because the `file content` line above it is a total
-- for open and the two scrolls, and a soloed file move fetches content for every file it
-- draws. Run higher up it would move that line and take the invariant with it, so it runs
-- after the line is printed and reports its own git cost on a line of its own.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

vim.o.columns = 140
vim.o.lines = 50

-- A five-fold regression fails; ordinary machine variance does not. The 60-file tier only:
-- see the header for why the larger one carries no ceiling.
local BUDGET_MS = tonumber(vim.env.CODEREVIEW_PERF_BUDGET_MS) or 2000

-- Held down rather than tapped: one move is too short to time against a millisecond clock,
-- and fifty rows is roughly what leaning on `j` through a hunk costs a reviewer.
local MOVES = 50

-- Rounds of the solo block's two duels. Each round times both arms, so these are samples
-- per arm rather than timings in total, and every figure the block prints is a median of
-- them.
--
-- **Even, and that is not a detail.** A round reverses the order the two arms run in, so an
-- odd count leaves one arm leading one round more often than the other. With solo switched
-- off in the view -- two arms doing exactly the same work, which is the null this block was
-- checked against -- five rounds read 97.9 ms against 128.5 ms, and six rounds read 98.0
-- against 96.2. Whatever going second costs, both arms must pay it the same number of times.
local SOLO_ROUNDS = 6
local SOLO_MOVE_ROUNDS = 4
-- Presses per round, and the stride from one arm-round's range of files to the next. The
-- ranges must not overlap: a file drawn once replays from a cache that survives a repaint,
-- so a second walk of it flatters whichever arm makes that walk. They start past everything
-- open and the two scrolls have touched.
local SOLO_MOVES = 10
local SOLO_MOVE_STRIDE = 20
local SOLO_MOVE_FROM = 100

local MKBIG = vim.fs.joinpath(root, "tests", "fixtures", "mkbig.sh")

---Build one tier's fixture repository and answer with its path.
---
---Built per run rather than taken from the environment: `mkbig.sh` already takes the file
---and line counts, so each tier asks it for its own size, and a single pre-built path could
---only ever be one of the two. It costs about half a second per tier.
---@param files integer
---@param lines integer
---@param changed integer|nil Lines rewritten per file; nil rewrites half of each
---@return string path
local function build(files, lines, changed)
  local path = ("%s-big-%dx%dx%s"):format(vim.fn.tempname(), files, lines, changed or "half")
  local argv = { "bash", MKBIG, path, tostring(files), tostring(lines) }
  if changed then
    argv[#argv + 1] = tostring(changed)
  end
  local res = vim.system(argv, { text = true }):wait(120000)
  assert(res.code == 0, res.stderr)
  -- Through `print`, which `nvim -l` sends to stderr, rather than writing the script's own
  -- stdout: the whole report then arrives on one stream and stays in order however it is
  -- redirected.
  print(vim.trim(res.stdout))
  return path
end

local function ms(fn)
  local t0 = vim.uv.hrtime()
  fn()
  return (vim.uv.hrtime() - t0) / 1e6
end

---The middle sample of a set, which is what every figure in the solo block is.
---
---A median and not a mean: one timing that landed on a collection is an outlier rather than
---a contribution, and what the block reports is what a paint or a press usually costs.
---@param xs number[]
---@return number
local function median(xs)
  table.sort(xs)
  local n = #xs
  if n % 2 == 1 then
    return xs[(n + 1) / 2]
  end
  return (xs[n / 2] + xs[n / 2 + 1]) / 2
end

---Time one call from a collected heap.
---
---**This is what makes two arms comparable, and it is not optional here.** Timed A then B in
---a fixed order with nothing collected between them, a soloed render walk measured 33 percent
---faster than an unsoloed one. It was the allocator: collect before every timing and alternate
---the two, and the same measurement read 53.3 ms against 54.6 ms, which is the same number
---twice. A branch inside a walk cannot make the walk faster, so a figure that flatters solo is
---the first one to distrust.
---@param fn fun()
---@return number ms
local function timed(fn)
  collectgarbage("collect")
  return ms(fn)
end

require("codereview").setup({})
local view = require("codereview.view")
local config = require("codereview.config")
local syntax = require("codereview.syntax")
local git = require("codereview.git")
local diff = require("codereview.diff")
local NS = vim.api.nvim_create_namespace("codereview")
local PRIORITY = require("codereview.render").PRIORITY.syntax

---What this tier spent inside git fetching whole-file content for the syntax pass.
---
---Wrapped here rather than counted in `git.lua`, which has no business carrying a counter
---only this file reads. `blobs` is how many sides were asked for and `calls` is how many
---invocations answered them: the two are equal when every file is fetched on its own, and
---the gap between them is the whole point of the batch.
local fetch = { ms = 0, blobs = 0, calls = 0 }
do
  local one, many = git.file_content, git.file_contents
  ---@param items { path: string, ref: string|nil }[]
  git.file_contents = function(items, ...)
    fetch.calls, fetch.blobs = fetch.calls + 1, fetch.blobs + #items
    local t0 = vim.uv.hrtime()
    local res = many(items, ...)
    fetch.ms = fetch.ms + (vim.uv.hrtime() - t0) / 1e6
    return res
  end
  ---A nil ref is a working-tree read: no process, and nothing a batch was ever going to
  ---take, so it is left out of both counts rather than flattering them.
  ---@param path string
  ---@param ref string|nil
  git.file_content = function(path, ref, ...)
    if ref == nil then
      return one(path, ref, ...)
    end
    fetch.calls, fetch.blobs = fetch.calls + 1, fetch.blobs + 1
    local t0 = vim.uv.hrtime()
    local res = one(path, ref, ...)
    fetch.ms = fetch.ms + (vim.uv.hrtime() - t0) / 1e6
    return res
  end
end

local function syntax_marks(buf)
  return #vim.tbl_filter(function(m)
    return m[4].priority == PRIORITY
  end, vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true }))
end

---Time the work one `CursorMoved` does, averaged over a held-down key.
---
---The event is dispatched rather than provoked: neither `nvim_win_set_cursor` nor a
---`normal! j` raises `CursorMoved` in a headless `nvim -l` -- measured, not assumed -- so a
---report that only moved the cursor would time the move and none of the work. Dispatching
---runs the review buffer's own autocommand, so this is the whole body a reviewer pays for
---(the syntax pass and the tree sync together), not a stand-in for it.
---
---Warmed first, because the file under the cursor is parsed by the first pass after a
---paint, and that one-off parse is not what a keystroke costs. The moves stay inside that
---file for the same reason.
---@param V CRView
---@return number total_ms
local function cursor_moves(V)
  vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
  return ms(function()
    for i = 1, MOVES do
      vim.api.nvim_win_set_cursor(V.win, { 1 + i, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
    end
  end)
end

---One arm of the paint duel: a repaint of one rendering over itself.
---
---Settled first and untimed, because a paint that replaces ninety thousand rows with three
---hundred is the transition between the two arms and not what either of them costs. A
---reviewer repaints a soloed review over a soloed one -- a resize, an expansion, a reviewed
---toggle -- so that is what is timed. The cursor goes to the top for the same reason: the
---emission is bounded by the viewport, so two arms looking at different rows would be
---emitting different amounts of the review.
---@param V CRView
---@param on boolean Whether this arm draws one file
---@return number ms
local function solo_paint(V, on)
  config.get().solo = on
  view.paint()
  vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
  return timed(function()
    view.paint()
  end)
end

---One arm of the file-move duel, over files nothing has drawn yet.
---
---**Each arm walks a range of its own.** The parsed captures are cached on the view and
---survive a repaint, so an arm sent through files the other arm has already drawn replays
---them from memory while its rival paid to parse and to fetch them -- which flatters
---whichever arm goes second by the whole cost of a parse and a git read. The ranges here
---never overlap.
---
---The landing is outside the timing: the first press has to cost what the presses after it
---cost, and the file a press arrives *from* is not what it is timing.
---@param V CRView
---@param on boolean Whether this arm draws one file
---@param from integer File the arm starts on
---@param count integer Presses to time
---@return number[] samples
local function solo_moves(V, on, from, count)
  config.get().solo = on
  view.paint()
  view.goto_file(from)
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
  local out = {}
  for _ = 1, count do
    out[#out + 1] = timed(function()
      -- `]f`, exactly as `keymaps.lua` binds it, and then the event a real keystroke raises:
      -- a script that moves the cursor raises none under `nvim -l`. In solo the file arrived
      -- at is parsed inside the paint and unsoloed it is parsed inside this event, so both
      -- arms pay that parse and what is left between them is the paint.
      view.jump("file", true)
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
    end)
  end
  return out
end

---What **solo** saves and what it costs, at this tier and on this tier's own review.
---
---Two duels, each alternating its arms and each reporting medians. The arms are reversed on
---alternate rounds so that neither is always the one that follows the other: with the heap
---collected before every timing that should not matter, and "should not matter" is what the
---first measurement of solo also said before the allocator answered it.
---
---Reports and asserts nothing, like every line at this tier. No budget is added: the report's
---rule is that only the sixty-file open is judged, because a second ceiling is a second figure
---to tune per machine rather than a second thing known.
---@param V CRView
local function solo_block(V)
  local base = { ms = fetch.ms, blobs = fetch.blobs, calls = fetch.calls }
  local paints = { [true] = {}, [false] = {} }
  local size = { [true] = {}, [false] = {} }
  for round = 1, SOLO_ROUNDS do
    for _, on in ipairs(round % 2 == 1 and { true, false } or { false, true }) do
      paints[on][#paints[on] + 1] = solo_paint(V, on)
      -- The render this arm just built. Counted rather than argued: the claim solo is made
      -- on is that it stops the render building marks for files nobody is reading, and a
      -- count says whether it does where a millisecond only says how long something took.
      size[on] = { rows = #V.render.lines, marks = #V.render.marks }
    end
  end

  local moves = { [true] = {}, [false] = {} }
  for round = 1, SOLO_MOVE_ROUNDS do
    for _, on in ipairs(round % 2 == 1 and { true, false } or { false, true }) do
      -- Keyed on the arm and the round rather than on the order they ran in, so reversing
      -- the arms above leaves every range exactly where it was.
      local from = SOLO_MOVE_FROM + ((round - 1) * 2 + (on and 0 or 1)) * SOLO_MOVE_STRIDE + 1
      for _, sample in ipairs(solo_moves(V, on, from, SOLO_MOVES)) do
        moves[on][#moves[on] + 1] = sample
      end
    end
  end
  -- As it was found. The tiers after this one are not soloed reviews.
  config.get().solo = false

  local one, all = size[true], size[false]
  print(
    ("\nsolo:                          (%d paints and %d presses per arm, alternated; medians)"):format(
      SOLO_ROUNDS,
      SOLO_MOVES * SOLO_MOVE_ROUNDS
    )
  )
  print(("  paint          %6.1f ms   (%d rows, %d marks built)"):format(median(paints[true]), one.rows, one.marks))
  print(("  paint unsoloed %6.1f ms   (%d rows, %d marks built)"):format(median(paints[false]), all.rows, all.marks))
  print(
    ("  ]f             %6.1f ms   (per press: a paint; the file it lands on is parsed inside it)"):format(
      median(moves[true])
    )
  )
  print(
    ("  ]f unsoloed    %6.1f ms   (per press: a cursor move and the CursorMoved after it)"):format(median(moves[false]))
  )
  -- This block's own, and not part of the `file content` line above: that line is a total for
  -- open and the two scrolls, and every file drawn here is content fetched for a file the
  -- reviewer moved to.
  local blobs, calls = fetch.blobs - base.blobs, fetch.calls - base.calls
  print(("  file content   %6.0f ms   (%d blobs in %d git calls)"):format(fetch.ms - base.ms, blobs, calls))
end

---Report one tier, and answer with the figures the tiers are compared on.
---@param files integer
---@param lines integer
---@param budget_ms integer|nil the ceiling this tier is judged against; nil means it only reports
---@param changed integer|nil Lines rewritten per file; nil rewrites half of each
---@param solo boolean|nil Whether this tier ends with the solo block. The deep 300-file tier
---                        only: it is the one big enough to read the ratio from, and running
---                        it twice would double a report that is read rather than gated.
---@return { open: number, move: number, repaint: number, fetch: number }
local function tier(files, lines, budget_ms, changed, solo)
  print(
    ("\n=== %d files x %d lines, %s ==="):format(
      files,
      lines,
      changed and ("%d changed"):format(changed) or "half rewritten"
    )
  )
  vim.cmd("cd " .. vim.fn.fnameescape(build(files, lines, changed)))
  fetch.ms, fetch.blobs, fetch.calls = 0, 0, 0

  local open_ms = ms(function()
    view.open("branch")
  end)
  local V = view.current()

  local verdict = budget_ms and ("(budget %d ms)"):format(budget_ms) or "(reported, never fails this command)"
  print(("open:            %6.0f ms   %s"):format(open_ms, verdict))
  print(("  rows           %6d"):format(#V.render.lines))
  print(("  files parsed   %6d / %d"):format(vim.tbl_count(V.syntax_painted), #V.files))
  print(("  syntax marks   %6d"):format(syntax_marks(V.buf)))

  -- Scroll to the bottom: files there must get parsed on demand, not up front.
  print(("scroll to end:   %6.0f ms"):format(ms(function()
    vim.api.nvim_win_set_cursor(V.win, { #V.render.lines, 0 })
    vim.api.nvim_win_call(V.win, function()
      vim.cmd("normal! zz")
    end)
    syntax.apply(V, NS)
  end)))
  print(("  files parsed   %6d / %d"):format(vim.tbl_count(V.syntax_painted), #V.files))

  print(("scroll back:     %6.0f ms   (cached)"):format(ms(function()
    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    vim.api.nvim_win_call(V.win, function()
      vim.cmd("normal! zz")
    end)
    syntax.apply(V, NS)
  end)))

  -- The interactive path, and the only line here that is paid per keystroke.
  local moves_ms = cursor_moves(V)
  print(("cursor move:     %6.1f ms   (per keystroke: one CursorMoved, autocommand and all)"):format(moves_ms / MOVES))
  print(("  %2d moves       %6.0f ms   (holding `j`)"):format(MOVES, moves_ms))

  local repaint_ms = ms(function()
    view.paint()
  end)
  print(("repaint:         %6.0f ms   (every resize, expansion, reviewed toggle, scope change)"):format(repaint_ms))

  -- Spans are computed once per git read and never during a repaint, which is the whole
  -- reason they live in the parser. Both parses are timed so the cost has a home of its own:
  -- if it ever stops showing up here and starts showing up in the repaint line above, the
  -- work has moved back into the render and every resize is paying for it.
  local cwd = vim.fn.getcwd()
  local scope = assert(git.resolve_scope("branch", cwd))
  local diff_text = assert(git.diff(scope, cwd, 3))
  local plain_ms = ms(function()
    diff.parse(diff_text)
  end)
  local spans_ms = ms(function()
    diff.parse(diff_text, { spans = true })
  end)
  local spanned = 0
  for _, file in ipairs(diff.parse(diff_text, { spans = true })) do
    for _, hunk in ipairs(file.hunks) do
      for _, ln in ipairs(hunk.lines) do
        spanned = spanned + (ln.spans and 1 or 0)
      end
    end
  end
  -- At the foot of the tier because it is a total for everything above it, and because
  -- only open and the two scrolls can add to it: a repaint drops what it painted but keeps
  -- the captures, and a cursor move stays inside a file already parsed. Either of those
  -- moving this line means content is being re-fetched for files nothing needs re-read.
  -- Taken here rather than read again at the end, because the solo block below fetches
  -- content for every file it draws: the figure the side-by-side table compares tiers on has
  -- to be the figure this line printed, or the table reports one tier's reading habits.
  local content_ms = fetch.ms
  print(("file content:    %6.0f ms   (%d blobs in %d git calls)"):format(content_ms, fetch.blobs, fetch.calls))
  print(("parse:           %6.0f ms   (once per git read, not per repaint)"):format(plain_ms))
  print(("  spans          %6.0f ms   (+%.0f ms)"):format(spans_ms, spans_ms - plain_ms))
  print(("  lines spanned  %6d"):format(spanned))

  -- Last, and after the `file content` line above it: this draws files of its own and fetches
  -- their content, which that line is not a total for.
  if solo then
    solo_block(V)
  end

  -- Each tier gets its own review, on its own repository: whatever the next one measures, it
  -- must not be measuring what this one left open.
  view.close()
  return { open = open_ms, move = moves_ms / MOVES, repaint = repaint_ms, fetch = content_ms }
end

local small = tier(60, 200, BUDGET_MS)
local large = tier(300, 200, nil, nil, true)
-- Not kept: the side-by-side below is a comparison of two sizes at one shape, and this tier
-- is the other shape. What it is here to report it reports on its own `file content` line.
tier(300, 200, nil, 2)

-- Side by side, because the point of the larger tier is the ratio: every one of these costs
-- is linear in the size of the review, so five times the files should be about five times
-- the milliseconds, and a change that flattens one of these lines is what the two slices
-- after this one are for.
-- The blank line is a prefix rather than a `print("")`: an empty message is dropped, not
-- echoed, so a line of its own would leave the table welded to the tier above it.
print(("\n%-16s %12s %12s"):format("side by side", "60 files", "300 files"))
print(("%-16s %9.0f ms %9.0f ms"):format("  open", small.open, large.open))
print(("%-16s %9.1f ms %9.1f ms"):format("  cursor move", small.move, large.move))
print(("%-16s %9.0f ms %9.0f ms"):format("  repaint", small.repaint, large.repaint))
-- The one row here that must *not* scale with the review, and the deep tiers are where that
-- is worth watching: content is fetched only for the files a pass brings near the window, so
-- five times the files is the same handful of blobs. A figure that starts tracking the file
-- count is content being fetched for files nothing is about to draw.
print(("%-16s %9.0f ms %9.0f ms"):format("  file content", small.fetch, large.fetch))

if small.open > BUDGET_MS then
  print(("\nFAIL: open took %.0f ms, over the %d ms budget"):format(small.open, BUDGET_MS))
  vim.cmd("cq")
end
print("\nOK")
vim.cmd("qa!")
