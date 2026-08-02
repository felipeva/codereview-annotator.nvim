---Capturing an annotation about the buffer you are in, with no review view involved.
---
---The review path resolves its target from a rendered diff and its anchor map. There is
---no diff here, so the target is resolved from the buffer itself -- but the entry it
---produces is the same shape, goes into the same queue and is rendered by the same code.
---A queued annotation must not remember which way it was captured.
local config = require("codereview.config")
local git = require("codereview.git")
local payload = require("codereview.payload")
local render = require("codereview.render")
local types = require("codereview.types")

local M = {}

---@param msg string
local function warn(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = "Code review" })
end

---Resolve a buffer into an annotation entry, minus its type and note.
---
---@param buf integer|nil Defaults to the current buffer
---@return CRAnnotation|nil entry, string|nil err
function M.target(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf

  local name = vim.api.nvim_buf_get_name(buf)
  -- A scratch buffer, the review view's own buffer, or anything else with no file behind
  -- it. A bare thought with no path is a real capture shape, but it is its own slice.
  if name == "" then
    return nil, "no file in this buffer"
  end

  -- Realpath rather than the buffer's name: `git rev-parse --show-toplevel` answers in
  -- resolved form, and on macOS a path under /var is a symlink into /private/var. Compare
  -- the two unresolved and the file looks like it lives outside its own repository.
  local abs = vim.uv.fs_realpath(name)
  if not abs then
    return nil, ("%s is not a file on disk"):format(vim.fn.fnamemodify(name, ":t"))
  end

  local root = git.root(vim.fs.dirname(abs))
  local rel = root and payload.relative_to(abs, root)
  if not rel then
    return nil, "not inside a git repository"
  end

  return {
    kind = "file",
    path = rel,
    abs_path = abs,
    -- Hashed at capture time, exactly as the review path hashes a diffed file. This is
    -- what buys staleness detection later; an entry without it can go quietly wrong.
    blob = git.blob(rel, nil, root),
    key = render.file_key(rel),
    tag = "whole file",
    inline = false,
  }
end

---Annotate the whole of the current buffer's file.
---@param type_name string|nil Falls back to the same picker the review view offers
function M.annotate(type_name)
  local cfg = config.get()

  local type_def = type_name and types.get(cfg.types, type_name)
  if type_name and not type_def then
    warn(("unknown annotation type: %s"):format(type_name))
    return
  end

  -- Resolved before the picker opens, not inside its callback: `vim.ui.select` is
  -- asynchronous, and the annotation is about the buffer the user was in when they asked
  -- -- not about wherever the cursor happens to be once a menu has come and gone.
  local entry, err = M.target(0)
  if not entry then
    warn(err)
    return
  end

  local annotate = require("codereview.annotate")
  if type_def then
    annotate.queue_entry(entry, type_def)
    return
  end

  local labels = vim.tbl_map(function(t)
    return ("%s  %s"):format(t.icon, t.name)
  end, cfg.types)
  vim.ui.select(labels, { prompt = "Annotation type:" }, function(_, index)
    if not index then
      return
    end
    annotate.queue_entry(entry, cfg.types[index])
  end)
end

return M
