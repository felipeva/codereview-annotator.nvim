-- The one test that cannot run headless.
--
-- `startinsert` needs the interactive input loop, so in headless Neovim `mode()` always
-- reports "n" and the composer's insert-mode leak is unreachable: a headless version of
-- this test passes whether or not the fix exists. The first attempt at it did exactly
-- that and was worthless.
--
-- So this spec drives a *real* Neovim over a pty, talking to it through `--listen` /
-- `--remote-send` / `--remote-expr` the way a user's terminal would.
--
-- To confirm it still has teeth: remove the BufEnter/WinEnter/InsertEnter autocmd in
-- view.lua and the `stopinsert` in annotate.lua's `collect`, and it must fail with
-- mode='i'. If it still passes, it is not reproducing the bug.
local h = require("tests.helpers")

local fixture = h.fixture("mkfixture")
local init = vim.fs.joinpath(h.root, "tests", "codereview", "interactive_init.lua")
local sock = vim.fn.tempname() .. ".sock"

-- Everything the child persists goes to a throwaway directory. Without this the run
-- writes review progress into the user's real state directory and restores it next time,
-- silently making the queue assertions non-idempotent.
local state_home = vim.fn.tempname() .. "-pty-state"

local job = vim.fn.jobstart({
  vim.v.progpath,
  "--listen",
  sock,
  "-u",
  init,
  "--noplugin",
  "-i",
  "NONE",
}, {
  pty = true,
  width = 120,
  height = 40,
  cwd = fixture,
  env = { XDG_STATE_HOME = state_home, TERM = "xterm-256color" },
})

---Poll until `fn` returns something truthy, or give up.
---@generic T
---@param fn fun(): T
---@param timeout? integer
---@return T|nil
local function poll(fn, timeout)
  local deadline = vim.uv.hrtime() + (timeout or 20000) * 1e6
  repeat
    local value = fn()
    if value then
      return value
    end
    vim.wait(100)
  until vim.uv.hrtime() > deadline
  return nil
end

local function server(...)
  local res = vim.system({ vim.v.progpath, "--server", sock, ... }, { text = true }):wait(15000)
  return vim.trim(res.stdout or "")
end

local function expr(e)
  return server("--remote-expr", e)
end

---Send keys, then wait for the state they were supposed to produce. Polling rather than
---sleeping: `--remote-send` returns long before the editor has finished reacting.
local function send(keys, settled)
  server("--remote-send", keys)
  if settled then
    poll(settled)
  else
    vim.wait(300)
  end
end

local function cleanup()
  pcall(server, "--remote-send", "<Esc>:qa!<CR>")
  vim.wait(300)
  pcall(vim.fn.jobstop, job)
  pcall(vim.fn.delete, sock)
end

describe("a real terminal", function()
  it("starts and answers", function()
    assert.is_true(job > 0, "jobstart failed")
    assert.is_truthy(
      poll(function()
        return vim.uv.fs_stat(sock) ~= nil
      end),
      "nvim never created its socket"
    )
    assert.is_truthy(
      poll(function()
        return expr("1") == "1"
      end),
      "nvim never answered on its socket"
    )
  end)

  -- The premise of the whole file. If this reports something other than "n" the editor is
  -- in a state the rest of the assertions cannot be read against.
  it("reaches the interactive input loop", function()
    assert.same("n", expr("mode()"))
  end)
end)

describe("annotating from insert mode", function()
  it("opens the review view", function()
    send(":CodeReview<CR>", function()
      return expr("&filetype") == "codereview"
    end)
    assert.same("codereview", expr("&filetype"))
  end)

  it("opens the composer in INSERT", function()
    send("]h")
    send("j")
    send("ab", function()
      return expr("mode()"):sub(1, 1) == "i"
    end)
    -- Unreachable headless: this is the assertion that makes the pty worth the trouble.
    assert.same("i", expr("mode()"):sub(1, 1))
  end)

  it("returns to the review buffer when submitted", function()
    send("why the rename")
    send("<C-s>", function()
      return expr("&filetype") == "codereview"
    end)
    assert.same("codereview", expr("&filetype"))
  end)

  -- The bug: closing the composer's window does not end insert mode, so focus lands back
  -- in a nomodifiable buffer still in INSERT.
  it("does not leave the review buffer in insert mode", function()
    assert.same("n", expr("mode()"):sub(1, 1))
  end)

  it("queued the annotation", function()
    assert.same("1", expr("luaeval(\"require('codereview').count()\")"))
  end)

  -- Only meaningful now that the composer is genuinely entered in insert mode. Typed in
  -- normal mode those keystrokes would have been motions, and the note would have been
  -- something else entirely -- which is what this asserted nothing about before.
  it("queued what was actually typed", function()
    assert.same("why the rename", expr("luaeval(\"require('codereview.queue').all()[1].note\")"))
  end)
end)

-- `@` is bound in insert mode, so this is the only place it can be pressed the way a user
-- presses it. Headless the mapping is reachable only by feeding an `i` first, which is not
-- what a composer opened in insert mode does.
describe("referencing a file while typing", function()
  it("opens the composer again", function()
    send("ab", function()
      return expr("mode()"):sub(1, 1) == "i"
    end)
    assert.same("i", expr("mode()"):sub(1, 1))
  end)

  it("splices the reference as the @ is typed", function()
    send("compare with @", function()
      return expr("getline('.')"):find("routes", 1, true) ~= nil
    end)
    -- Without its trailing space: `expr` trims what comes back over the socket, so the
    -- space the splice leaves for you to keep typing is not observable from here. That it
    -- is there at all is a headless assertion.
    assert.same("compare with @src/routes.lua#L2-4", expr("getline('.')"))
  end)

  it("queues the note with its reference", function()
    send("<C-s>", function()
      return expr("&filetype") == "codereview"
    end)
    assert.same("compare with @src/routes.lua#L2-4", expr("luaeval(\"require('codereview.queue').all()[2].note\")"))
  end)
end)

describe("the review buffer after submitting", function()
  -- The reported symptom: navigation keys typed text instead of moving.
  it("treats ]h as a motion, not as input", function()
    local before = expr('line(".")')
    send("]h", function()
      return expr('line(".")') ~= before
    end)
    assert.is_true(expr('line(".")') ~= before)
  end)

  it("is still nomodifiable", function()
    assert.same("0", expr("&modifiable"))
  end)

  cleanup()
end)
