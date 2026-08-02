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
codereview.setup({
  syntax = false,
  compose = function(ctx, on_accept, label)
    -- The mode the composer is entered in is part of its contract: a composer opened with
    -- a selection still active gets a buffer it cannot type into cleanly.
    composed[#composed + 1] = { ctx = ctx, label = label, mode = vim.fn.mode() }
    on_accept(nil, "the note")
  end,
  pick_target = function(cb)
    cb({ short = "agent", pane_id = "wV:p3", cwd = root })
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
    assert.same(#require("codereview.config").get().types, #offered)
  end)

  it("queues with the type that was picked", function()
    assert.same(1, queue.count())
    assert.same("fix", queue.all()[1].type)
  end)
end)

describe("an unrecognised type", function()
  queue.clear()
  edit("src/main.lua")
  local msgs, restore = h.capture_notify()
  codereview.annotate("nonsense")
  restore()

  it("queues nothing", function()
    assert.same(0, queue.count())
  end)

  it("names the type it did not recognise", function()
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

describe("capturing across a restart", function()
  local state = require("codereview.state")

  ---One capture, in a process of its own.
  ---@param file string
  ---@param type_name string
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

  -- A clean slate on both sides, so what the two sessions write is all that is on disk.
  queue.clear()
  state.clear(root)

  local first = session("src/main.lua", "bug", "from an earlier session")
  local second = session("src/routes.lua", "nitpick", "from a later session")

  it("both sessions exit cleanly", function()
    assert.same(0, first.code, (first.stderr or "") .. (first.stdout or ""))
    assert.same(0, second.code, (second.stderr or "") .. (second.stdout or ""))
  end)

  -- `nvim -l` sends `print` to stderr, so the child's report is read from both streams
  -- rather than from stdout alone.
  ---@param child table
  ---@return string
  local function output(child)
    return (child.stdout or "") .. (child.stderr or "")
  end

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

-- The two cases below reconfigure the plugin, so they come last.

describe("with no composer wired", function()
  codereview.setup({ syntax = false })
  queue.clear()
  edit("src/main.lua")

  local prompt
  local orig = vim.ui.input
  vim.ui.input = function(opts, cb)
    prompt = opts.prompt
    cb("typed into the fallback")
  end
  codereview.annotate("bug")
  vim.ui.input = orig

  it("falls back to the built-in prompt", function()
    assert.is_truthy(prompt, "vim.ui.input was never called")
    assert.is_truthy(prompt:find("src/main.lua", 1, true), prompt)
  end)

  it("queues the note that prompt collected", function()
    assert.same(1, queue.count())
    assert.same("typed into the fallback", queue.all()[1].note)
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

    assert.same(2, #offered)
    assert.is_truthy(offered[1]:find("blocker", 1, true), vim.inspect(offered))
  end)
end)
