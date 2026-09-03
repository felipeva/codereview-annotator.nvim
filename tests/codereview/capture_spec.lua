-- Capturing an annotation from an ordinary buffer, with no review view involved.
--
-- The tracer bullet for "the plugin owns capture": one public entry point cuts through
-- type resolution, blob hashing, the composer, the queue, the float, payload rendering
-- and submit -- for the simplest capture shape there is, a whole file.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local codereview = require("codereview")
local queue = require("codereview.queue")

-- Resolved before setup: the target's `cwd` is what `@ref`s are rendered against, and a
-- /var path that has not been through realpath does not contain its own /private/var
-- files as far as the renderer is concerned.
local root = assert(vim.uv.fs_realpath(fixture))

local composed = {}
local sent = {}
-- What the adapters were asked for, in order. An immediate send has to choose a target
-- before a word is typed, which is a claim about ordering and nothing else.
local steps = {}
local BATCH_TARGET = { short = "agent", pane_id = "wV:p3", cwd = root }
-- Reassigned by the cases below; read at call time, the way a real picker's answer is.
local target_answer = BATCH_TARGET
-- Runs while the composer is open, before it answers. How a case makes the world change
-- under a composer the way a language server does.
local compose_hook

codereview.setup({
  syntax = false,
  compose = function(ctx, on_accept, label)
    -- The mode the composer is entered in is part of its contract: a composer opened with
    -- a selection still active gets a buffer it cannot type into cleanly.
    steps[#steps + 1] = "compose"
    composed[#composed + 1] = { ctx = ctx, label = label, mode = vim.fn.mode() }
    if compose_hook then
      compose_hook()
    end
    on_accept(nil, "the note")
  end,
  pick_target = function(cb)
    steps[#steps + 1] = "target"
    cb(target_answer)
  end,
  send = function(text, target)
    sent[#sent + 1] = { text = text, target = target }
  end,
})

---Open a real file from the fixture, the way a user browsing code would.
---@param rel string
---@return integer buf
local function edit(rel)
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, rel)))
  return vim.api.nvim_get_current_buf()
end

describe("annotating the current file", function()
  queue.clear()
  edit("src/main.lua")
  codereview.annotate("bug")

  it("queues one annotation", function()
    assert.same(1, queue.count())
  end)

  it("records it as a whole-file annotation for that buffer", function()
    local entry = queue.all()[1]
    assert.same("file", entry.kind)
    assert.same("src/main.lua", entry.path)
    assert.same(vim.fs.joinpath(root, "src/main.lua"), entry.abs_path)
  end)

  it("carries the type it was given", function()
    assert.same("bug", queue.all()[1].type)
  end)

  it("carries the note the composer collected", function()
    assert.same("the note", queue.all()[1].note)
  end)

  -- The staleness key. Derived from git rather than hardcoded, so it cannot drift when
  -- the fixture changes.
  it("records the blob of the file as captured", function()
    local expected = h.git_lines(root, { "hash-object", "src/main.lua" })[1]
    assert.same(expected, queue.all()[1].blob)
  end)
end)

describe("the buffer it was captured from", function()
  local buf = edit("src/main.lua")
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  queue.clear()
  codereview.annotate("bug")

  it("is left with its contents untouched", function()
    assert.same(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("is not left modified", function()
    assert.is_false(vim.bo[buf].modified)
  end)
end)

describe("with no type given", function()
  local offered, prompt
  local orig = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    offered, prompt = items, opts.prompt
    cb(items[2], 2)
  end

  queue.clear()
  edit("src/main.lua")
  codereview.annotate()
  vim.ui.select = orig

  it("offers the type picker", function()
    assert.is_truthy(prompt, "no picker was offered")
    assert.same(#require("codereview.config").get().types + 1, #offered)
  end)

  -- The picker is the one place a reviewer meets the whole vocabulary at once, so it has to
  -- offer the same glyphs the diff draws -- choosing and reading are then one vocabulary.
  -- What a label *carries* and not how it is laid out: the format is free to grow.
  it("offers every type with its own glyph, and declining with the untyped mark", function()
    for i, t in ipairs(require("codereview.config").get().types) do
      assert.is_true(t.icon ~= "", ("%s carries no glyph to offer"):format(t.name))
      assert.is_truthy(offered[i]:find(t.icon, 1, true), ("%s: %q"):format(t.name, offered[i]))
    end
    local untyped = require("codereview.types").UNTYPED.icon
    assert.is_truthy(offered[#offered]:find(untyped, 1, true), offered[#offered])
  end)

  it("queues with the type that was picked", function()
    assert.same(1, queue.count())
    assert.same("fix", queue.all()[1].type)
  end)
end)

-- A reviewer with no instruction to attach should not have to invent one. Declining is an
-- answer, so it is an entry in the picker rather than a way of dismissing it.
describe("declining a type", function()
  local offered
  local orig = vim.ui.select
  vim.ui.select = function(items, _, cb)
    offered = items
    cb(items[#items], #items)
  end

  queue.clear()
  edit("src/main.lua")
  codereview.annotate()
  vim.ui.select = orig

  it("offers declining after every type, never before one", function()
    assert.is_truthy(offered[#offered]:find("no type", 1, true), vim.inspect(offered))
    for i = 1, #offered - 1 do
      assert.is_nil(offered[i]:find("no type", 1, true), vim.inspect(offered))
    end
  end)

  it("queues the annotation carrying no type", function()
    assert.same(1, queue.count())
    assert.is_nil(queue.all()[1].type)
  end)

  it("costs the type and nothing else", function()
    assert.same("the note", queue.all()[1].note)
    assert.same("src/main.lua", queue.all()[1].path)
  end)
end)

-- Dismissing the picker still abandons the annotation entirely. The two were the same
-- outcome while canceling was the only way out of the picker without choosing.
describe("canceling the picker", function()
  local orig = vim.ui.select
  vim.ui.select = function(_, _, cb)
    cb(nil, nil)
  end

  queue.clear()
  local before = #composed
  edit("src/main.lua")
  codereview.annotate()
  vim.ui.select = orig

  it("queues nothing", function()
    assert.same(0, queue.count())
  end)

  it("never opens the composer", function()
    assert.same(before, #composed)
  end)
end)

describe("an unrecognized type", function()
  queue.clear()
  edit("src/main.lua")
  local msgs, restore = h.capture_notify()
  codereview.annotate("nonsense")
  restore()

  it("queues nothing", function()
    assert.same(0, queue.count())
  end)

  it("names the type it did not recognize", function()
    assert.is_true(h.notified(msgs, "unknown annotation type: nonsense"))
  end)
end)

-- An *unnamed* buffer is a bare thought, and queues one -- see `norepo_spec`. A buffer
-- whose name is not a file on disk is a different thing: it claims to be something, and
-- the review view's own buffer is one of them. Turning `aa` inside a review into a bare
-- note would be a worse answer than saying so.
describe("a buffer whose name is not a file on disk", function()
  queue.clear()
  vim.cmd("enew")
  vim.api.nvim_buf_set_name(0, "codereview://not-a-real-file")
  local msgs, restore = h.capture_notify()
  codereview.annotate("bug")
  restore()

  it("queues nothing", function()
    assert.same(0, queue.count())
  end)

  it("says so rather than inventing a note", function()
    assert.is_true(h.notified(msgs, "is not a file on disk"), vim.inspect(msgs))
  end)
end)

describe("the user command", function()
  queue.clear()
  edit("src/routes.lua")
  vim.cmd("CodeReviewAnnotate suggestion")

  it("queues an annotation for the current file", function()
    assert.same(1, queue.count())
    assert.same("src/routes.lua", queue.all()[1].path)
  end)

  it("takes the annotation type as its argument", function()
    assert.same("suggestion", queue.all()[1].type)
  end)

  it("completes the configured type names", function()
    local command = vim.api.nvim_get_commands({})["CodeReviewAnnotate"]
    assert.is_truthy(command, "the command is not defined")
    local completions = vim.fn.getcompletion("CodeReviewAnnotate ni", "cmdline")
    assert.same({ "nitpick" }, completions)
  end)
end)

---One capture, in a process of its own.
---@param file string
---@param type_name string|nil nil declines a type, for an untyped annotation
---@param note string
local function session(file, type_name, note)
  return vim
    .system({
      vim.v.progpath,
      "--clean",
      "-l",
      vim.fs.joinpath(h.root, "tests", "codereview", "capture_child.lua"),
    }, {
      cwd = fixture,
      text = true,
      env = {
        XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
        FIXTURE = fixture,
        CAPTURE_FILE = file,
        CAPTURE_TYPE = type_name,
        CAPTURE_NOTE = note,
      },
    })
    :wait(60000)
end

-- `nvim -l` sends `print` to stderr, so the child's report is read from both streams
-- rather than from stdout alone.
---@param child table
---@return string
local function output(child)
  return (child.stdout or "") .. (child.stderr or "")
end

describe("capturing across a restart", function()
  local state = require("codereview.state")

  -- A clean slate on both sides, so what the two sessions write is all that is on disk.
  queue.clear()
  state.clear(root)

  local first = session("src/main.lua", "bug", "from an earlier session")
  local second = session("src/routes.lua", "nitpick", "from a later session")

  it("both sessions exit cleanly", function()
    assert.same(0, first.code, (first.stderr or "") .. (first.stdout or ""))
    assert.same(0, second.code, (second.stderr or "") .. (second.stdout or ""))
  end)

  it("the first session persisted its annotation", function()
    assert.is_true(output(first):find("queued: 1", 1, true) ~= nil, output(first))
  end)

  -- The restore half. The second session captured one annotation and ended up holding
  -- two, which is only possible if it read the first session's queue off disk first.
  it("the second session restored the first one's annotation before adding its own", function()
    assert.is_true(output(second):find("queued: 2", 1, true) ~= nil, output(second))
  end)

  -- The trap this case exists for. `persist_queue` writes whatever is in memory over the
  -- document's queue, so capturing as the first action of a session -- before anything has
  -- read the queue back -- would silently drop everything the last session left.
  it("kept both annotations on disk, in the order they were captured", function()
    local saved = state.load(root).queue
    assert.same({ "from an earlier session", "from a later session" }, {
      saved[1] and saved[1].note,
      saved[2] and saved[2].note,
    })
    assert.same({ "src/main.lua", "src/routes.lua" }, {
      saved[1] and saved[1].path,
      saved[2] and saved[2].path,
    })
  end)

  it("persisted each one's type and blob", function()
    local saved = state.load(root).queue
    assert.same({ "bug", "nitpick" }, { saved[1].type, saved[2].type })
    assert.same(h.git_lines(root, { "hash-object", "src/main.lua" })[1], saved[1].blob)
    assert.same(h.git_lines(root, { "hash-object", "src/routes.lua" })[1], saved[2].blob)
  end)
end)

-- An entry with no type has to survive a restart like any other. Two processes for the
-- reason the case above needs two: the queue is restored once per session, so a session
-- that already restored cannot observe what restoring does to what the last one left.
describe("an untyped annotation across a restart", function()
  local state = require("codereview.state")

  queue.clear()
  state.clear(root)

  local declined = session("src/main.lua", nil, "no instruction attached")
  local later = session("src/routes.lua", "bug", "from a later session")

  it("both sessions exit cleanly", function()
    assert.same(0, declined.code, output(declined))
    assert.same(0, later.code, output(later))
  end)

  it("queued the declined annotation rather than abandoning it", function()
    assert.is_true(output(declined):find("queued: 1", 1, true) ~= nil, output(declined))
  end)

  -- Written with the field absent, not with a placeholder standing in for one: an entry
  -- restored into a session whose host renamed its types must still read as untyped.
  it("wrote it to disk carrying no type at all", function()
    local saved = state.load(root).queue
    assert.same("no instruction attached", saved[1].note)
    assert.is_nil(saved[1].type)
  end)

  it("kept everything else an annotation carries", function()
    local saved = state.load(root).queue
    assert.same("src/main.lua", saved[1].path)
    assert.same(h.git_lines(root, { "hash-object", "src/main.lua" })[1], saved[1].blob)
  end)

  -- The restore half: the later session captured one and ended up holding two, which is
  -- only possible if the untyped entry came back off disk instead of being dropped.
  it("is restored by the next session, not discarded on the way back", function()
    assert.is_true(output(later):find("queued: 2", 1, true) ~= nil, output(later))
  end)

  it("still groups as untyped once restored", function()
    local saved = state.load(root).queue
    local groups = require("codereview.types").group(saved, require("codereview.config").get().types)
    local labels = vim.tbl_map(function(g)
      return g.type.label
    end, groups)
    assert.same({ "Bugs", "Untyped" }, labels)
  end)
end)

-- The whole point of the feature: once queued, a buffer annotation is indistinguishable
-- from one captured during a review. One queue, one float, one payload, one batch.
describe("alongside a review annotation", function()
  local view = require("codereview.view")
  local annotate = require("codereview.annotate")

  queue.clear()
  require("codereview.state").clear(root)

  -- A review annotation, captured the way the review view captures one.
  view.open("branch")
  local V = assert(view.current(), "the review view did not open")
  local row = assert(h.line_row(V, "src/main.lua"), "no diff line for src/main.lua")
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
  annotate.annotate("bug")

  -- ...and a buffer annotation captured with that review still open, in its own tab so
  -- the review view keeps its window.
  vim.cmd("tabedit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/fresh.lua")))
  codereview.annotate("nitpick")

  it("captures from a buffer while a review view is open", function()
    assert.same(2, queue.count())
    assert.is_not_nil(view.current(), "capturing closed the review view")
  end)

  it("is counted by the public API", function()
    assert.same(2, codereview.count())
  end)

  local float
  view.review_queue()
  do
    local win = assert(V.queue_win, "the queue float did not open")
    float = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
    vim.api.nvim_win_close(win, true)
    V.queue_win = nil
  end

  it("appears in the queue float alongside the review annotation", function()
    assert.is_truthy(float:find("src/main.lua", 1, true), float)
    assert.is_truthy(float:find("src/fresh.lua", 1, true), float)
  end)

  it("is listed under its own type's heading in the float", function()
    assert.is_truthy(float:find("## Bugs", 1, true), float)
    assert.is_truthy(float:find("## Nitpicks", 1, true), float)
  end)

  view.pick_target()
  view.submit()

  it("submits as one batch, through one adapter call, to the chosen target", function()
    assert.same(1, #sent)
    assert.same("wV:p3", sent[1].target.pane_id)
    assert.same(0, queue.count())
  end)

  it("groups under its type in the payload, in the configured type order", function()
    local text = sent[1].text
    local bugs = assert(text:find("## Bugs", 1, true), text)
    local nitpicks = assert(text:find("## Nitpicks", 1, true), text)
    assert.is_true(bugs < nitpicks, "nitpicks came before bugs")
  end)

  it("travels in that payload as a reference to its own file", function()
    assert.is_truthy(sent[1].text:find("@src/fresh.lua", 1, true), sent[1].text)
  end)

  view.close()
end)

-- The composer seam is what a host config wires. It has to receive the same shape here as
-- it does from the review path, or a host composer works in one place and not the other.
describe("what the composer is handed", function()
  queue.clear()
  edit("src/routes.lua")
  local win = vim.api.nvim_get_current_win()
  local before = #composed
  local msgs, restore = h.capture_notify()
  codereview.annotate("suggestion")
  restore()

  local call = composed[#composed]

  it("calls the composer once", function()
    assert.same(before + 1, #composed)
  end)

  it("names the file both ways the review path does", function()
    assert.same("src/routes.lua", call.ctx.rel_path)
    assert.same(vim.fs.joinpath(root, "src/routes.lua"), call.ctx.file_path)
  end)

  it("titles it from the type and the target", function()
    assert.same("none", call.ctx.scope)
    assert.is_truthy(call.ctx.label:find("Suggestion", 1, true), call.ctx.label)
    assert.is_truthy(call.ctx.label:find("src/routes.lua", 1, true), call.ctx.label)
  end)

  it("passes the same `queue` label the review path passes", function()
    assert.same("queue", call.label)
  end)

  -- Here that is the buffer's own window, not the review view's -- which is the whole
  -- reason the composer is told rather than left to assume.
  it("names the window the annotation was started from", function()
    assert.same(win, call.ctx.origin_win)
  end)

  it("reports what was queued and how many are now in the batch", function()
    assert.is_true(h.notified(msgs, "Queued suggestion"), vim.inspect(msgs))
    assert.is_true(h.notified(msgs, "src/routes.lua"), vim.inspect(msgs))
    assert.is_true(h.notified(msgs, "(1 in queue)"), vim.inspect(msgs))
  end)
end)

-- Fired from a mapping rather than called directly, because the selection has to still be
-- live when capture reads it -- which is only true from inside a visual-mode mapping.
vim.keymap.set({ "n", "x" }, "<F5>", function()
  codereview.annotate("bug")
end, { desc = "capture_spec: annotate as bug" })

describe("annotating a visual selection", function()
  queue.clear()
  edit("src/main.lua")
  h.feed("1GVj<F5>")
  local e = queue.all()[1]

  it("queues one annotation", function()
    assert.same(1, queue.count())
  end)

  it("records it as a range", function()
    assert.same("range", e.kind)
  end)

  it("spans exactly the selected lines", function()
    assert.same(1, e.first)
    assert.same(2, e.last)
  end)

  it("carries the selected lines themselves", function()
    local source = vim.fn.readfile(vim.fs.joinpath(root, "src/main.lua"))
    assert.same({ " " .. source[1], " " .. source[2] }, e.lines)
  end)

  -- The review path escapes visual mode before opening the composer. Capture has to do
  -- the same, or the composer is entered with a selection still live.
  it("leaves visual mode before the composer opens", function()
    assert.same("n", composed[#composed].mode)
  end)

  it("travels as a reference the target can resolve", function()
    local text = require("codereview.payload").render(queue.all(), root, {
      types = require("codereview.config").get().types,
    })
    assert.is_truthy(text:find("@src/main.lua#L1-2", 1, true), text)
  end)

  -- An agent whose cwd does not contain the file cannot follow a ref at all, so the code
  -- has to travel with the note instead.
  it("inlines its code when the file is outside the target's tree", function()
    local text = require("codereview.payload").render(queue.all(), "/nowhere/else", {
      types = require("codereview.config").get().types,
    })
    assert.is_nil(text:find("@src/main.lua", 1, true), text)
    assert.is_truthy(text:find("```diff", 1, true), text)
    local source = vim.fn.readfile(vim.fs.joinpath(root, "src/main.lua"))
    assert.is_truthy(text:find(source[1], 1, true), text)
  end)
end)

-- The command line drops visual mode before running the command, so `:'<,'>` has to come
-- through as a range or the selection is silently lost and the whole file captured.
describe("the user command given a range", function()
  queue.clear()
  edit("src/main.lua")
  vim.cmd("1,2CodeReviewAnnotate nitpick")
  local e = queue.all()[1]

  it("captures exactly those lines", function()
    assert.same("range", e.kind)
    assert.same(1, e.first)
    assert.same(2, e.last)
  end)

  it("captures a single-line range as a line, as the review path does", function()
    queue.clear()
    vim.cmd("2CodeReviewAnnotate nitpick")
    local one = queue.all()[1]
    assert.same("line", one.kind)
    assert.same(2, one.first)
    assert.same(2, one.last)
  end)

  it("still captures the whole file when given no range", function()
    queue.clear()
    vim.cmd("CodeReviewAnnotate nitpick")
    assert.same("file", queue.all()[1].kind)
  end)
end)

describe("diagnostics riding along", function()
  local ns = vim.api.nvim_create_namespace("capture_spec_diagnostics")
  local buf = edit("src/main.lua")
  local S = vim.diagnostic.severity

  ---@param lnum integer 0-based, as `vim.diagnostic` reports them
  local function diag(lnum, severity, message)
    return { lnum = lnum, col = 0, severity = severity, message = message, source = "lua_ls" }
  end

  vim.diagnostic.set(ns, buf, {
    diag(0, S.ERROR, "undefined global `app`"),
    diag(1, S.WARN, "unused local `cfg`"),
    diag(2, S.ERROR, "past the selection"),
    -- Inside the selection on purpose, so the severity filter is what excludes these and
    -- not the line range. Parked on line 3 they passed either way, measuring nothing.
    diag(0, S.HINT, "a hint nobody asked for"),
    diag(1, S.INFO, "merely informational"),
  })

  queue.clear()
  h.feed("1GVj<F5>")
  local ranged = queue.all()[1].note

  it("keeps the note the composer collected first", function()
    assert.is_truthy(ranged:find("^the note"), ranged)
  end)

  it("appends the errors and warnings overlapping the selection", function()
    assert.is_truthy(ranged:find("Diagnostics:", 1, true), ranged)
    assert.is_truthy(ranged:find("ERROR", 1, true), ranged)
    assert.is_truthy(ranged:find("undefined global `app`", 1, true), ranged)
    assert.is_truthy(ranged:find("WARN", 1, true), ranged)
    assert.is_truthy(ranged:find("unused local `cfg`", 1, true), ranged)
  end)

  it("names the line and the source of each", function()
    assert.is_truthy(ranged:find("L1", 1, true), ranged)
    assert.is_truthy(ranged:find("L2", 1, true), ranged)
    assert.is_truthy(ranged:find("(lua_ls)", 1, true), ranged)
  end)

  it("leaves out one that does not overlap the selection", function()
    assert.is_nil(ranged:find("past the selection", 1, true), ranged)
  end)

  it("leaves out hints and info", function()
    assert.is_nil(ranged:find("a hint nobody asked for", 1, true), ranged)
    assert.is_nil(ranged:find("merely informational", 1, true), ranged)
  end)

  queue.clear()
  codereview.annotate("bug")
  local whole = queue.all()[1].note

  it("rides along with a whole-file capture too", function()
    assert.is_truthy(whole:find("undefined global `app`", 1, true), whole)
    assert.is_truthy(whole:find("unused local `cfg`", 1, true), whole)
    assert.is_truthy(whole:find("past the selection", 1, true), whole)
  end)

  it("still leaves out hints and info for a whole file", function()
    assert.is_nil(whole:find("a hint nobody asked for", 1, true), whole)
    assert.is_nil(whole:find("merely informational", 1, true), whole)
  end)

  -- A clean buffer must not grow an empty heading.
  it("adds nothing when there is nothing to add", function()
    vim.diagnostic.reset(ns, buf)
    queue.clear()
    codereview.annotate("bug")
    assert.same("the note", queue.all()[1].note)
  end)
end)

describe("a range and a whole file together", function()
  local view = require("codereview.view")
  queue.clear()
  local before_sent = #sent

  local buf = edit("src/main.lua")
  local before_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  h.feed("1GVj<F5>")
  vim.cmd("CodeReviewAnnotate nitpick")

  it("queues both shapes", function()
    assert.same(2, queue.count())
    assert.same({ "range", "file" }, { queue.all()[1].kind, queue.all()[2].kind })
  end)

  -- Capturing a selection escapes visual mode, which is the one thing in either path that
  -- touches the buffer's state at all.
  it("leaves the source buffer untouched", function()
    assert.same(before_lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_false(vim.bo[buf].modified)
  end)

  view.submit()

  it("submits them in a single batch", function()
    assert.same(before_sent + 1, #sent)
    assert.same(0, queue.count())
  end)

  it("carries both in that one payload, each under its own type", function()
    local text = sent[#sent].text
    assert.is_truthy(text:find("@src/main.lua#L1%-2"), text)
    assert.is_truthy(text:find("## Bugs", 1, true), text)
    assert.is_truthy(text:find("## Nitpicks", 1, true), text)
    assert.is_truthy(text:find("2 annotations", 1, true), text)
  end)
end)

-- An untyped annotation is a first-class entry: it appears wherever an entry appears. Both
-- surfaces used to drop it, each through its own copy of the same grouping loop.
describe("an untyped annotation in the queue and in the batch", function()
  local view = require("codereview.view")
  queue.clear()
  local before_sent = #sent

  local orig = vim.ui.select
  vim.ui.select = function(items, _, cb)
    cb(items[#items], #items)
  end
  edit("src/main.lua")
  codereview.annotate()
  vim.ui.select = orig

  edit("src/routes.lua")
  codereview.annotate("bug")

  local float
  view.review_queue()
  do
    local win = vim.api.nvim_get_current_win()
    float = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
    vim.api.nvim_win_close(win, true)
  end

  it("is listed in the queue float", function()
    assert.is_truthy(float:find("## Untyped", 1, true), float)
    assert.is_truthy(float:find("src/main.lua", 1, true), float)
  end)

  it("is listed after every typed group there", function()
    assert.is_true(float:find("## Bugs", 1, true) < float:find("## Untyped", 1, true), float)
  end)

  it("carries no directive on its heading", function()
    assert.is_truthy(float:find("## Untyped\n", 1, true), float)
  end)

  view.submit()

  it("reaches the delivered payload, grouped and last", function()
    assert.same(before_sent + 1, #sent)
    local text = sent[#sent].text
    assert.is_truthy(text:find("## Untyped (1)\n", 1, true), text)
    assert.is_true(text:find("## Bugs", 1, true) < text:find("## Untyped", 1, true), text)
  end)

  it("travels with everything a typed annotation would have carried", function()
    local text = sent[#sent].text
    assert.is_truthy(text:find("@src/main.lua", 1, true), text)
    assert.is_truthy(text:find("2 annotations", 1, true), text)
  end)
end)

-- An immediate send: the same capture, delivered on its own instead of joining the queue.
describe("sending one annotation immediately", function()
  queue.clear()
  local before = #sent
  edit("src/main.lua")
  codereview.annotate("bug", nil, { immediate = true })

  it("hands a payload to the send adapter", function()
    assert.same(before + 1, #sent)
  end)

  it("leaves the queue empty", function()
    assert.same(0, queue.count())
  end)
end)

-- The plugin owns this choice now, and it makes it before a word is typed: a target
-- declined after the note is written costs the note.
describe("where an immediate send goes", function()
  queue.clear()
  steps = {}
  target_answer = { short = "solo", pane_id = "wV:p9", cwd = root }
  edit("src/main.lua")
  codereview.annotate("bug", nil, { immediate = true })
  local order = table.concat(steps, " ")
  target_answer = BATCH_TARGET

  it("asks for a target before the composer opens", function()
    assert.same("target compose", order)
  end)

  it("delivers to the target that was chosen for it", function()
    assert.same("wV:p9", sent[#sent].target.pane_id)
  end)

  -- Batch routing and immediate-send routing are different things pointing at the same
  -- kind of destination. An errand must not redirect the batch you are assembling.
  it("leaves the batch's own target where it was", function()
    assert.same("agent", require("codereview.delivery").target_label())
  end)
end)

-- Distinct from having no picker at all, which sends to whatever the adapter defaults to.
-- A picker that ran and came back empty is a reviewer who changed their mind.
describe("declining to choose a target", function()
  queue.clear()
  steps = {}
  local before = #sent
  target_answer = nil
  edit("src/main.lua")
  local msgs, restore = h.capture_notify()
  codereview.annotate("bug", nil, { immediate = true })
  restore()
  local order = table.concat(steps, " ")
  target_answer = BATCH_TARGET

  it("never opens the composer, so no note is written for nothing", function()
    assert.same("target", order)
  end)

  it("delivers nothing", function()
    assert.same(before, #sent)
  end)

  it("queues nothing instead", function()
    assert.same(0, queue.count())
  end)

  it("says so rather than failing silently", function()
    assert.is_true(h.notified(msgs, "No target chosen"), vim.inspect(msgs))
  end)
end)

-- Why a type became optional at all (ADR-0004): a batch of one would otherwise force one
-- onto the fastest interaction there is, and a remark with no instruction behind it would
-- have to invent a directive to be sendable.
describe("sending one annotation with no type", function()
  queue.clear()
  steps = {}
  local before = #sent
  local orig = vim.ui.select
  vim.ui.select = function(items, _, cb)
    steps[#steps + 1] = "type"
    -- One past the configured types is the decline entry, which is not a dismissal.
    cb(items[#items], #items)
  end
  edit("src/main.lua")
  codereview.annotate(nil, nil, { immediate = true })
  vim.ui.select = orig
  local order = table.concat(steps, " ")
  local text = sent[#sent].text

  it("delivers it rather than making a type the price of sending", function()
    assert.same(before + 1, #sent)
  end)

  -- Both pickers are answered before a word is written; neither hides inside the
  -- composer's callback, where the answer would arrive too late to matter.
  it("asks for the type, then the target, then opens the composer", function()
    assert.same("type target compose", order)
  end)

  it("lands its one annotation in the untyped group", function()
    assert.is_truthy(text:find("Code review — 1 annotation", 1, true), text)
    assert.is_truthy(text:find("## Untyped (1)", 1, true), text)
    assert.is_truthy(text:find("@src/main.lua", 1, true), text)
    assert.is_truthy(text:find("the note", 1, true), text)
  end)

  -- A group with nothing to instruct should not pretend otherwise.
  it("gives that group no directive", function()
    assert.is_truthy(text:find("## Untyped (1)\n", 1, true), text)
  end)

  it("still leaves the queue alone", function()
    assert.same(0, queue.count())
  end)
end)

-- Declining and dismissing were the same gesture until the picker grew a way to say "no
-- type", and the send path must not quietly put them back together: one delivers an
-- untyped annotation, the other abandons the send entirely.
describe("dismissing the type picker on an immediate send", function()
  queue.clear()
  steps = {}
  local before, composed_before = #sent, #composed
  local orig = vim.ui.select
  vim.ui.select = function(_, _, cb)
    steps[#steps + 1] = "type"
    cb(nil, nil)
  end
  edit("src/main.lua")
  codereview.annotate(nil, nil, { immediate = true })
  vim.ui.select = orig
  local order = table.concat(steps, " ")

  it("delivers nothing", function()
    assert.same(before, #sent)
  end)

  it("queues nothing either", function()
    assert.same(0, queue.count())
  end)

  -- Neither the composer nor the target picker: abandoning before a type is chosen costs
  -- nothing at all, not even the question of where it would have gone.
  it("asks nothing further", function()
    assert.same("type", order)
    assert.same(composed_before, #composed)
  end)
end)

-- The promise the queue makes to a batch half assembled: an errand does not disturb it.
describe("an immediate send beside a queue with something in it", function()
  queue.clear()
  edit("src/main.lua")
  codereview.annotate("bug")
  local queued_before = vim.deepcopy(queue.all())

  local before = #sent
  edit("src/routes.lua")
  codereview.annotate("nitpick", nil, { immediate = true })
  local text = sent[#sent].text

  it("leaves what was queued exactly as it was", function()
    assert.same(1, queue.count())
    assert.same(queued_before[1].path, queue.all()[1].path)
    assert.same(queued_before[1].note, queue.all()[1].note)
  end)

  it("renders one annotation, not the queue", function()
    assert.same(before + 1, #sent)
    assert.is_truthy(text:find("Code review — 1 annotation", 1, true), text)
    assert.is_truthy(text:find("src/routes.lua", 1, true), text)
    assert.is_nil(text:find("src/main.lua", 1, true), text)
  end)

  -- The same renderer a batch goes through, which is what keeps one payload format:
  -- grouped under its type's heading, with that type's directive.
  it("groups it under its type, as a batch of one", function()
    assert.is_truthy(text:find("## Nitpicks (1)", 1, true), text)
    assert.is_truthy(text:find("the note", 1, true), text)
  end)
end)

-- Fired from a mapping for the reason `<F5>` is: the selection has to still be live when
-- capture reads it, which is only true from inside a visual-mode mapping.
vim.keymap.set({ "n", "x" }, "<F6>", function()
  codereview.annotate("bug", nil, { immediate = true })
end, { desc = "capture_spec: send as bug, immediately" })

describe("sending a visual selection immediately", function()
  queue.clear()
  local before = #sent
  edit("src/main.lua")
  h.feed("1GVj<F6>")
  local text = sent[#sent].text

  it("delivers it without queueing it", function()
    assert.same(before + 1, #sent)
    assert.same(0, queue.count())
  end)

  it("names exactly the lines that were selected", function()
    assert.is_truthy(text:find("@src/main.lua#L1-2", 1, true), text)
  end)

  -- The queued path escapes visual mode before the composer opens; so must this one, or
  -- the composer is entered with a selection still live.
  it("leaves visual mode before the composer opens", function()
    assert.same("n", composed[#composed].mode)
  end)
end)

-- A thought with no file behind it is still worth sending on its own.
describe("sending a bare note immediately", function()
  queue.clear()
  local before = #sent
  vim.cmd("enew")
  codereview.annotate("bug", nil, { immediate = true })
  local text = sent[#sent].text

  it("delivers it with nothing to anchor to", function()
    assert.same(before + 1, #sent)
    assert.is_truthy(text:find("(no file)", 1, true), text)
  end)

  it("still leaves the queue alone", function()
    assert.same(0, queue.count())
  end)
end)

-- An `@ref` only resolves relative to whoever reads it, so it is rendered against the
-- directory this note is going to -- not against this Neovim's.
describe("sending to a target whose working directory is elsewhere", function()
  queue.clear()
  target_answer = { short = "far", pane_id = "wV:p4", cwd = "/nowhere/else" }
  edit("src/main.lua")
  h.feed("1GVj<F6>")
  target_answer = BATCH_TARGET
  local text = sent[#sent].text

  it("carries the code instead of a reference the target could not follow", function()
    assert.is_nil(text:find("@src/main.lua", 1, true), text)
    assert.is_truthy(text:find("```diff", 1, true), text)
    local source = vim.fn.readfile(vim.fs.joinpath(root, "src/main.lua"))
    assert.is_truthy(text:find(source[1], 1, true), text)
  end)
end)

-- A language server is free to republish while a composer is open. What rides along has to
-- be what was on screen when the note was started, which is only true if diagnostics are
-- read before the composer opens rather than inside its callback.
describe("diagnostics on an immediate send", function()
  local ns = vim.api.nvim_create_namespace("capture_spec_immediate_diagnostics")
  local buf = edit("src/main.lua")
  local S = vim.diagnostic.severity

  ---@param message string
  local function publish(message)
    vim.diagnostic.set(ns, buf, {
      { lnum = 0, col = 0, severity = S.ERROR, message = message, source = "lua_ls" },
    })
  end

  publish("on screen when the note was started")
  local republished = false
  compose_hook = function()
    publish("republished while the composer was open")
    republished = true
  end

  queue.clear()
  codereview.annotate("bug", nil, { immediate = true })
  compose_hook = nil
  vim.diagnostic.reset(ns, buf)
  local text = sent[#sent].text

  -- Without this the case below passes whether or not anything republished, which is the
  -- fixture trap: an assertion that cannot fail is measuring nothing.
  it("ran a language server that republished under the composer", function()
    assert.is_true(republished)
  end)

  it("carries what the language server had when the note was started", function()
    assert.is_truthy(text:find("on screen when the note was started", 1, true), text)
  end)

  it("does not carry what it republished while the composer was open", function()
    assert.is_nil(text:find("republished while the composer was open", 1, true), text)
  end)
end)

-- The cases below reconfigure the plugin, so they come last.

-- What a host that wires nothing gets is the plugin's own composer -- from capture exactly
-- as from the review view, since both arrive through the same tail. `vim.ui.input` is not
-- the fallback any more.
describe("with no composer wired", function()
  codereview.setup({ syntax = false })
  queue.clear()
  edit("src/main.lua")
  local origin = vim.api.nvim_get_current_win()

  -- Stubbed rather than left alone: the prompt blocks headless Neovim, so a regression to
  -- it would hang the suite rather than fail it.
  local prompted = false
  local orig = vim.ui.input
  vim.ui.input = function()
    prompted = true
  end
  codereview.annotate("bug")
  vim.ui.input = orig

  local composer
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      composer = win
    end
  end

  it("opens the plugin's composer, not a prompt", function()
    assert.is_false(prompted)
    assert.is_truthy(composer, "no composer window was opened")
  end)

  it("titles it with what is being annotated", function()
    local cfg_win = vim.api.nvim_win_get_config(composer)
    local title = cfg_win.title and tostring(cfg_win.title[1][1]) or ""
    assert.is_truthy(title:find("src/main.lua", 1, true), title)
  end)

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "captured through the composer" })
  h.feed("<C-s>")

  it("queues the note it collected", function()
    assert.same(1, queue.count())
    assert.same("captured through the composer", queue.all()[1].note)
  end)

  it("leaves focus in the buffer it was captured from", function()
    vim.wait(200, function()
      return vim.api.nvim_get_current_win() == origin
    end)
    assert.same(origin, vim.api.nvim_get_current_win())
  end)
end)

-- Nothing in capture may assume the built-in five exist: the vocabulary is the host's.
describe("with a custom type vocabulary", function()
  codereview.setup({
    syntax = false,
    types = {
      { name = "blocker", key = "b" },
      { name = "praise", key = "p" },
    },
    compose = function(_, on_accept)
      on_accept(nil, "a custom note")
    end,
  })
  queue.clear()
  edit("src/main.lua")
  codereview.annotate("blocker")

  it("resolves a type only the host defines", function()
    assert.same(1, queue.count())
    assert.same("blocker", queue.all()[1].type)
  end)

  it("refuses a built-in type the host replaced", function()
    local msgs, restore = h.capture_notify()
    codereview.annotate("bug")
    restore()
    assert.same(1, queue.count())
    assert.is_true(h.notified(msgs, "unknown annotation type: bug"))
  end)

  it("completes the host's names rather than the built-ins", function()
    assert.same({ "blocker" }, vim.fn.getcompletion("CodeReviewAnnotate bl", "cmdline"))
    assert.same({}, vim.fn.getcompletion("CodeReviewAnnotate nit", "cmdline"))
  end)

  it("groups it under the label derived from the host's name", function()
    local text = require("codereview.payload").render(queue.all(), root, {
      types = require("codereview.config").get().types,
    })
    assert.is_truthy(text:find("## Blockers", 1, true), text)
  end)

  it("offers the host's types to the picker", function()
    local offered
    local orig = vim.ui.select
    vim.ui.select = function(items, _, cb)
      offered = items
      cb(nil, nil)
    end
    codereview.annotate()
    vim.ui.select = orig

    -- The host's two, then declining. Nothing the host did not configure is offered as a
    -- type, and the way out of the menu without one does not depend on the vocabulary.
    assert.same(3, #offered)
    assert.is_truthy(offered[1]:find("blocker", 1, true), vim.inspect(offered))
    assert.is_truthy(offered[3]:find("no type", 1, true), vim.inspect(offered))
  end)
end)

-- Nothing to choose between, and no way to decline. The plugin carries no opinion about
-- where a payload goes, so it delivers with no target and lets the adapter decide what
-- that means -- refusing here would be an opinion about transport.
describe("an immediate send with no target picker wired", function()
  local delivered = {}
  codereview.setup({
    syntax = false,
    compose = function(_, on_accept)
      on_accept(nil, "no picker here")
    end,
    send = function(text, to)
      delivered[#delivered + 1] = { text = text, target = to }
    end,
  })
  queue.clear()
  edit("src/main.lua")
  local msgs, restore = h.capture_notify()
  codereview.annotate("bug", nil, { immediate = true })
  restore()

  it("delivers it anyway, with no target", function()
    assert.same(1, #delivered)
    assert.is_nil(delivered[1].target)
    assert.is_truthy(delivered[1].text:find("no picker here", 1, true), delivered[1].text)
  end)

  it("says there was nothing to choose from", function()
    assert.is_true(h.notified(msgs, "No pick_target adapter configured"), vim.inspect(msgs))
  end)
end)

-- The fallback a batch already has, for the same reason: a note is never dropped in
-- silence because the host wired no delivery.
describe("an immediate send with no send adapter wired", function()
  codereview.setup({
    syntax = false,
    compose = function(_, on_accept)
      on_accept(nil, "nowhere to send this")
    end,
  })
  queue.clear()
  edit("src/main.lua")
  vim.fn.setreg("+", "")
  local msgs, restore = h.capture_notify()
  codereview.annotate("bug", nil, { immediate = true })
  restore()

  it("falls back to the clipboard", function()
    assert.is_truthy(vim.fn.getreg("+"):find("nowhere to send this", 1, true), vim.fn.getreg("+"))
  end)

  it("does not claim to have sent it", function()
    assert.is_true(h.notified(msgs, "No send adapter configured"), vim.inspect(msgs))
    assert.is_false(h.notified(msgs, "Sent bug"), vim.inspect(msgs))
  end)

  it("still leaves the queue alone", function()
    assert.same(0, queue.count())
  end)
end)
