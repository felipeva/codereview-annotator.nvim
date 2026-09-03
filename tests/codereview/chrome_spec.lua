-- Three details of the **review view**'s chrome, each provable on its own.
--
-- They share no code, so they share no act here either: what a hunk header says is data out
-- of `render.build`, what a base revision is called is a pure export with nothing behind it,
-- and what the review buffer is called needs a live review because a buffer name is
-- Neovim's. A correction to one must not be able to quietly change another, which is why
-- each act asserts at the narrowest seam that can see it.
local h = require("tests.helpers")

h.ui(110, 40)
h.cd_fixture("mkfixture")

require("codereview").setup({ syntax = false })

local config = require("codereview.config")
local diff = require("codereview.diff")
local render = require("codereview.render")
local view = require("codereview.view")

--- The unified hunk header ------------------------------------------------------

-- git writes the enclosing declaration after the second `@@`, so the line it hands over
-- already names the section. This diff is git's own output, measured in a repository built
-- for it -- two files, one changed inside a function and one with no declaration above the
-- change:
--
--   git diff --no-color --no-ext-diff -M -U2
--
-- Parsed rather than typed out as a `CRHunk`, because `header` and `heading` have to agree
-- the way git's output makes them agree: a pair written by hand can be made to agree with a
-- render that is wrong. No fixture repository can supply one -- every file in `mkfixture`
-- changes at its first line or has no declaration above the change -- and giving one a
-- function would move hunk counts and row assertions in nine specs to say what these
-- eighteen lines say here.
local DIFF = [[
diff --git a/auth.lua b/auth.lua
index 60aabba..9fe3592 100644
--- a/auth.lua
+++ b/auth.lua
@@ -2,5 +2,5 @@ function M.login(user, password)
   local a = 1
   local b = 2
-  local c = 3
+  local c = 99
   local d = 4
   local e = 5
diff --git a/plain.lua b/plain.lua
index 59c319c..5a0747a 100644
--- a/plain.lua
+++ b/plain.lua
@@ -1,3 +1,3 @@
 local a = 1
-local b = 2
+local b = 22
 local c = 3
]]

local HEADING = "function M.login(user, password)"
local WITH_HEADING, PLAIN = 1, 2

local files = diff.parse(DIFF)

-- Wide enough that the doubled header fits whole, and that is the case working rather than
-- a number picked for comfort. The two copies are 81 columns together, so an 80-column
-- render cuts the second one off -- and a count of how often the heading appears then reads
-- *one* on a row that says it twice, which is the case gone quiet rather than the case
-- passing. Same trap as "a filter test needs a fixture only that filter can reject".
---@param opts table|nil Overrides on top of a plain 120-column unified render
---@return CRRender after, CRRender|nil before
local function build(opts)
  local cfg = config.get()
  return render.build(
    files,
    vim.tbl_extend("force", {
      width = 120,
      before_width = 120,
      layout = "unified",
      icons = cfg.icons,
      expanded = {},
      reviewed = {},
      notes = {},
      types = cfg.types,
    }, opts or {})
  )
end

---The row a file's first hunk header is drawn on.
---@param rendered CRRender
---@param fi integer
---@return integer
local function hunk_row(rendered, fi)
  for row = 1, #rendered.lines do
    local a = rendered.anchors[row]
    if a.kind == "hunk" and a.file == fi then
      return row
    end
  end
  error(("file %d drew no hunk header"):format(fi))
end

-- The guard, and it is what lets everything below fail at all: over a diff whose hunks carry
-- no heading, a render that says the heading twice and a render that says it once draw the
-- same row. Same trap as "a filter test needs a fixture only that filter can reject".
describe("the diff this act reads", function()
  it("carries a hunk whose header names its section", function()
    assert.same(HEADING, files[WITH_HEADING].hunks[1].heading)
    assert.same("@@ -2,5 +2,5 @@ " .. HEADING, files[WITH_HEADING].hunks[1].header)
  end)

  it("carries a hunk whose header names none", function()
    assert.same("", files[PLAIN].hunks[1].heading)
    assert.same("@@ -1,3 +1,3 @@", files[PLAIN].hunks[1].header)
  end)
end)

describe("a unified hunk header", function()
  local after = build()

  -- What a reviewer reads in the review and what they read in `git diff` is one line.
  it("draws git's own header and nothing else", function()
    local hunk = files[WITH_HEADING].hunks[1]
    local row = after.lines[hunk_row(after, WITH_HEADING)]
    assert.same("@@ -2,5 +2,5 @@ " .. HEADING, row)
    assert.same(hunk.header, row)
  end)

  -- The statement the fault was: a long signature drawn twice is what pushes the first copy
  -- off a narrow pane. Counted rather than compared, so the case says which half is wrong.
  it("names its section once", function()
    local row = after.lines[hunk_row(after, WITH_HEADING)]
    assert.same(1, select(2, row:gsub(vim.pesc(HEADING), "")), row)
  end)

  it("draws the ranges alone where git appended nothing", function()
    assert.same("@@ -1,3 +1,3 @@", after.lines[hunk_row(after, PLAIN)])
  end)
end)

-- The split layout never carried the fault: it has no line of git's to draw, because each
-- pane says what its own image spans, so it rebuilds both headers from the ranges and keeps
-- the heading with the post-image. Asserted here because nothing else in the suite can --
-- `split_spec`'s heading case is conditional on the fixture carrying one, and no fixture
-- does.
describe("a split hunk header", function()
  local after, before = build({ layout = "split" })

  it("keeps git's section heading with the post-image range", function()
    local row = hunk_row(after, WITH_HEADING)
    assert.same("@@ +2,5 @@ " .. HEADING, after.lines[row])
    assert.same("@@ -2,5 @@", before.lines[row])
  end)

  it("draws the ranges alone where git appended nothing", function()
    local row = hunk_row(after, PLAIN)
    assert.same("@@ +1,3 @@", after.lines[row])
    assert.same("@@ -1,3 @@", before.lines[row])
  end)
end)

--- What a base revision is called ------------------------------------------------

-- No review, no fixture and no repository behind it: a rule about what a revision is called
-- needs none of the three to be true. The same division `file_label` is tested under, and
-- for the same reason -- the data answer here, and one live case in `split_spec` proving the
-- before pane really draws it.
describe("the name a base revision is drawn under", function()
  local OBJECT = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  it("abbreviates a 40-character object name to seven", function()
    assert.same("4b825dc", render.rev_label(OBJECT))
  end)

  it("answers index for the staged pre-image", function()
    assert.same("index", render.rev_label(":0"))
  end)

  it("leaves a branch name whole", function()
    assert.same("feature", render.rev_label("feature"))
  end)

  it("leaves a tag whole", function()
    assert.same("v1.2.0", render.rev_label("v1.2.0"))
  end)

  it("leaves a short name a reviewer typed whole", function()
    assert.same("HEAD~3", render.rev_label("HEAD~3"))
    assert.same("4b825dc", render.rev_label("4b825dc"))
  end)

  -- Length alone is not the rule. A 40-character branch name is a name a reviewer chose and
  -- cannot be read from its first seven characters, so it stays whole.
  it("leaves a 40-character name that is not hexadecimal whole", function()
    local name = "release/the-fortieth-character-is-here-x"
    assert.same(40, #name)
    assert.same(name, render.rev_label(name))
  end)

  -- The bar is assembled on every paint and a paint runs on every resize, so `rev-parse
  -- --short` per paint is a process this must never spawn. `vim.system` is what every git
  -- read in this plugin goes through, so a stub on it is the whole answer.
  it("spawns no process to decide", function()
    local system = vim.system
    vim.system = function()
      error("rev_label spawned a process")
    end
    local ok, err = pcall(render.rev_label, OBJECT)
    vim.system = system
    assert.is_true(ok, tostring(err))
  end)
end)

--- What the review buffer is called ----------------------------------------------

-- A tabline, a bufferline and `:ls` all read this name, and a buffer number says nothing
-- about what the review covers. Live, because the name is Neovim's and the collision is
-- Neovim's too.
describe("the review buffer's name", function()
  view.open("branch")
  local V = view.current()

  it("carries the scope rather than the buffer number", function()
    assert.same("codereview://branch", vim.api.nvim_buf_get_name(V.buf))
  end)

  -- Only the diff is the review, so only the diff claims the scope's name. Two buffers
  -- cannot share one, and the tree and the before pane are opened beside the diff of the
  -- same scope -- so a name for the scope on either of them is the collision, every time.
  it("leaves the file tree's buffer the numbered form", function()
    assert.same("codereviewpanel://" .. V.panel_buf, vim.api.nvim_buf_get_name(V.panel_buf))
  end)

  it("leaves a before pane's buffer the numbered form", function()
    view.toggle_layout()
    V = view.current()
    assert.is_truthy(V.before_buf)
    assert.same("codereview://" .. V.before_buf, vim.api.nvim_buf_get_name(V.before_buf))
  end)

  -- Through the key, because the name has to follow wherever the scope is set from.
  it("follows the scope when gs changes it", function()
    vim.api.nvim_set_current_win(V.win)
    h.feed("gs")
    V = view.current()
    assert.same("staged", V.scope.name)
    assert.same("codereview://staged", vim.api.nvim_buf_get_name(V.buf))
  end)
end)

-- Reached by a reviewer who put the review buffer in a tab of its own: closing the review's
-- own tab then leaves the buffer alive, holding the name, and the next review of that scope
-- has nowhere to put it. `nvim_buf_set_name` raises E95 rather than renaming, measured
-- directly, so the fallback is a rule and not a nicety -- without it that reviewer loses the
-- review rather than the name.
describe("a second review of one scope", function()
  local first = view.current().buf
  vim.cmd("tab sbuffer " .. first)
  view.open("staged")
  local V = view.current()

  it("leaves the first buffer holding the plain name", function()
    assert.is_true(vim.api.nvim_buf_is_valid(first))
    assert.same("codereview://staged", vim.api.nvim_buf_get_name(first))
  end)

  it("opens, under the numbered form", function()
    assert.is_true(V.buf ~= first)
    assert.same(("codereview://staged#%d"):format(V.buf), vim.api.nvim_buf_get_name(V.buf))
  end)
end)
