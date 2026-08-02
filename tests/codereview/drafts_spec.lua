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
