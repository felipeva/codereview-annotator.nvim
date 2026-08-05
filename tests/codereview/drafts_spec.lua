-- A draft outliving the session it was written in.
--
-- Two processes, because one cannot answer the question. Reopening the composer twice in a
-- single Neovim restores from a table that never left memory, and would pass whether or not
-- anything reached the disk.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mktree")

local drafts = require("codereview.drafts")

describe("the writing session", function()
  -- The child shares this process's throwaway XDG_STATE_HOME and nothing else. `--clean`
  -- so no user config, and no minimal_init, can hand it a different one.
  local proc = vim.system({
    vim.v.progpath,
    "--clean",
    "-l",
    vim.fs.joinpath(h.root, "tests", "codereview", "drafts_child.lua"),
  }, {
    cwd = fixture,
    text = true,
    env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = fixture },
  })
  local child = proc:wait(60000)

  it("exits cleanly", function()
    assert.same(0, child.code, (child.stderr or "") .. (child.stdout or ""))
  end)

  it("leaves a draft store behind", function()
    assert.same(1, vim.fn.filereadable(drafts.path()), "no drafts at " .. drafts.path())
  end)

  describe("the session that follows", function()
    require("codereview").setup({ syntax = false })
    local view = require("codereview.view")
    local queue = require("codereview.queue")
    local annotate = require("codereview.annotate")

    view.open("branch")
    local V = assert(view.current(), "the review view did not open")
    queue.clear()

    -- The same first annotatable line the child took. Same fixture, same scope, same
    -- dimensions, so the render is the same and both sessions mean the same file.
    local row
    for r = 1, vim.api.nvim_buf_line_count(V.buf) do
      local a = V.render.anchors[r]
      if a and a.kind == "line" then
        row = r
        break
      end
    end

    it("finds the file the earlier session annotated", function()
      assert.is_truthy(row, "no annotatable line in the render")
    end)

    vim.api.nvim_set_current_win(V.win)
    vim.api.nvim_win_set_cursor(V.win, { assert(row), 0 })
    annotate.annotate("bug")
    local reopened = vim.api.nvim_buf_get_lines(0, 0, -1, false)

    it("opens the composer holding what the earlier one abandoned", function()
      assert.same({ "written in an earlier session" }, reopened)
    end)
  end)
end)

--- The preamble's draft, which is keyed by a repository rather than by a file ---------

-- Abandon a **preamble** and the text is kept exactly as a note's is. What differs is the
-- key: a preamble is written about a **batch** and not about a file, so it is filed against
-- the repository the batch would go out of, and one written outside a checkout shares the
-- single slot there is -- the same split the **queue**'s two stores already make.
--
-- Driven through the view's action rather than `<C-a>` itself, as the cases above are driven
-- through `annotate`: which key reaches it is `delivery_spec`'s claim, and a draft is not
-- about a keystroke.
local codereview = require("codereview")
local view = require("codereview.view")
local queue = require("codereview.queue")
local git = require("codereview.git")

describe("a preamble abandoned in the composer", function()
  -- The composer the block above left open. Abandoned rather than left floating over
  -- everything below it, and the store wiped afterwards so nothing here is restored by
  -- accident.
  h.feed("q")
  view.close()
  drafts.clear()

  -- Something to cover. A preamble is only ever asked for when there is a batch to write it
  -- above, and the guard that says so runs before any composer opens.
  queue.clear()
  queue.add({ type = "bug", kind = "note", note = "something worth covering" })

  view.submit_with_preamble()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "read the third one first" })
  h.feed("q")

  it("leaves the queue whole, because abandoning is not submitting", function()
    assert.same(1, queue.count())
  end)

  view.submit_with_preamble()
  local reopened = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  h.feed("q")

  it("offers it back to the next preamble asked for in that repository", function()
    assert.same({ "read the third one first" }, reopened)
  end)
end)

describe("a preamble asked for in another repository", function()
  -- A second checkout, built rather than borrowed: "keyed by the repository" is a claim
  -- about two of them, and one repository cannot make it.
  local other = h.fixture("mktree")
  vim.cmd("cd " .. vim.fn.fnameescape(other))

  it("is a different repository from the first", function()
    assert.are_not.same(vim.uv.fs_realpath(fixture), vim.uv.fs_realpath(other))
    assert.is_truthy(git.root(other))
  end)

  view.submit_with_preamble()
  local opened = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "written in the other checkout" })
  h.feed("q")

  it("opens on an empty composer", function()
    assert.same({ "" }, opened)
  end)

  vim.cmd("cd " .. vim.fn.fnameescape(fixture))
  view.submit_with_preamble()
  local first = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  h.feed("q")

  it("leaves the first repository's preamble where it was", function()
    assert.same({ "read the third one first" }, first)
  end)
end)

-- The other half of the split: what has no repository behind it has to share one slot,
-- because there is nothing to key it by. Two directories outside a checkout are the same
-- reviewer with the same batch in front of them.
describe("a preamble with no repository behind it", function()
  local outside = vim.fn.tempname() .. "-outside"
  local elsewhere = vim.fn.tempname() .. "-elsewhere"
  vim.fn.mkdir(outside, "p")
  vim.fn.mkdir(elsewhere, "p")

  -- Asserted rather than assumed: if the temp directory ever sits inside a repository, both
  -- cases below silently become a test of the ordinary in-repository path.
  it("has two directories genuinely outside any checkout", function()
    assert.is_nil(git.root(outside), outside .. " is inside a checkout")
    assert.is_nil(git.root(elsewhere), elsewhere .. " is inside a checkout")
  end)

  vim.cmd("cd " .. vim.fn.fnameescape(outside))
  view.submit_with_preamble()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "loose prose about a loose batch" })
  h.feed("q")

  vim.cmd("cd " .. vim.fn.fnameescape(elsewhere))
  view.submit_with_preamble()
  local reopened = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  h.feed("q")

  it("meets the same draft from any directory outside one", function()
    assert.same({ "loose prose about a loose batch" }, reopened)
  end)
end)

-- A **bare note** has no file either, and every bare note shares the one slot there is. A
-- preamble is not a bare note: filing one where the other lives would hand a reviewer their
-- covering prose when they annotate a thought, and their thought when they cover a batch.
describe("a preamble beside a bare note's draft", function()
  vim.cmd("cd " .. vim.fn.fnameescape(fixture))
  vim.cmd("enew")
  codereview.annotate("issue")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a thought with no file behind it" })
  h.feed("q")

  view.submit_with_preamble()
  local preamble = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  h.feed("q")

  it("opens holding the repository's preamble, not the bare note", function()
    assert.same({ "read the third one first" }, preamble)
  end)

  vim.cmd("enew")
  codereview.annotate("issue")
  local note = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  h.feed("q")

  it("leaves the bare note's draft where it was", function()
    assert.same({ "a thought with no file behind it" }, note)
  end)
end)
