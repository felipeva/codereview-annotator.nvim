---Every key the review view binds, in one place: the diff's, and the file tree's.
---
---Nothing here reads the view. The buffer to bind onto is handed in, and so are the actions
---the keys run, which leaves this module a function of its arguments and the configured
---annotation types. Taking the actions as an argument rather than requiring `view` for them
---is also what keeps this module out of the cycle that module already sits in.
---
---The buffer has to be a parameter rather than something looked up. Both a before pane's
---buffer and the tree's are `bufhidden = "wipe"`, so toggling the layout back to unified and
---dismissing the tree each destroy every mapping bound to them, and what comes back is a
---*new* buffer that has to be given the whole set again.
local config = require("codereview.config")

local M = {}

---@param buf integer
---@param maps table<string, function|table>
local function bind(buf, maps)
  for lhs, rhs in pairs(maps) do
    local fn, desc, mode = rhs, "", "n"
    if type(rhs) == "table" then
      fn, desc, mode = rhs[1], rhs[2] or "", rhs[3] or "n"
    end
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
end

---Bind the diff's keys. Every pane gets the same set: which pane a reviewer happens to be
---in decides what a key acts on, never whether it works.
---@param buf integer
---@param view table The review view, whose exported actions these keys run.
function M.diff(buf, view)
  -- Annotation keys are prefixed rather than bound bare, and `types.PREFIX` is where the
  -- prefix and the reasoning for it live -- the type picker prints the same keystroke, so
  -- binding it from a literal here would let the two drift apart silently.
  --
  -- Required here rather than at file scope: `annotate` requires `view`, and `view`
  -- requires this module, so a require up there would route their cycle through it.
  local annotate = require("codereview.annotate")
  local types = require("codereview.types")
  for _, t in ipairs(config.get().types) do
    vim.keymap.set({ "n", "x" }, types.PREFIX .. t.key, function()
      annotate.annotate(t.name)
    end, { buffer = buf, nowait = true, silent = true, desc = "Annotate: " .. t.name })
  end
  vim.keymap.set({ "n", "x" }, types.PREFIX .. types.PREFIX, annotate.annotate_pick, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Annotate: pick type",
  })

  bind(buf, {
    ["x"] = { annotate.drop, "Drop the annotation here" },
    ["]f"] = {
      function()
        view.jump("file", true)
      end,
      "Next file",
    },
    ["[f"] = {
      function()
        view.jump("file", false)
      end,
      "Previous file",
    },
    ["]h"] = {
      function()
        view.jump("hunk", true)
      end,
      "Next hunk",
    },
    ["[h"] = {
      function()
        view.jump("hunk", false)
      end,
      "Previous hunk",
    },
    ["]F"] = {
      function()
        view.jump_unreviewed(true)
      end,
      "Next unreviewed file",
    },
    ["[F"] = {
      function()
        view.jump_unreviewed(false)
      end,
      "Previous unreviewed file",
    },
    ["]a"] = {
      function()
        view.jump_annotation(true)
      end,
      "Next annotation",
    },
    ["[a"] = {
      function()
        view.jump_annotation(false)
      end,
      "Previous annotation",
    },
    ["<C-p>"] = { view.pick_file, "Jump to a file" },
    ["<Tab>"] = { view.toggle_focus, "Focus the file tree" },
    ["R"] = { view.toggle_reviewed, "Toggle reviewed" },
    ["za"] = { view.toggle_expand, "Toggle expansion" },
    ["gs"] = {
      function()
        view.set_scope(nil)
      end,
      "Cycle scope",
    },
    ["gr"] = { view.refresh, "Reload the diff" },
    ["gp"] = { view.toggle_panel, "Show or hide the file tree" },
    -- From the `g` family the other view-level commands come from, and clear of `gt`/`gT`,
    -- which are how `<CR>`'s new tab is returned from.
    ["gl"] = { view.toggle_layout, "Toggle the unified and split layouts" },
    -- `gb` for the **batch**, from the same `g` family. It opens the surface the command
    -- opens, so a reviewer reads one fact off one surface however they asked for it.
    ["gb"] = { view.last_batch, "Read the last batch back" },
    -- `gc` for the **commits**, from the same `g` family. It takes the comment operator,
    -- which is dead in a nomodifiable buffer for the reason `a` became the annotation
    -- prefix: nothing here can be commented out, so the key costs a keystroke and no motion.
    ["gc"] = { view.commit_list, "List the commits on the branch, and trim the review" },
    -- `gA` for **archived** entries, and uppercase because `ga` is `:ascii`. It overrides
    -- the configured switch for the session rather than editing it.
    ["gA"] = { view.toggle_archived, "Show or hide archived entries" },
    -- `gS` for the **switch**, from the same `g` family, and it reads as the reserved word.
    -- `gC` and `gB` were rejected because they are confusable with the commit list and the
    -- last batch, and `gw` because it would teach "worktree", which the glossary avoids --
    -- it now says **wrap** below, which the glossary does keep. It is free in a nomodifiable
    -- buffer for the reason `a` became the annotation prefix.
    ["gS"] = { view.switch, "Switch the review to another checkout" },
    -- `gw` for **wrap**, from the same `g` family. Lowercase, unlike `gA`, because nothing
    -- shadows it: `gw` is the format operator, which is dead in a nomodifiable buffer for
    -- the reason `a` became the annotation prefix. It overrides the configured switch for
    -- the session rather than editing it.
    ["gw"] = { view.toggle_wrap, "Fold long lines, or stop folding them" },
    -- `go` for **solo**, from the same `g` family. Not `gs` or `gS`, which are the scope
    -- and the switch, so solo's own initial is taken twice over -- `go` is the letter of
    -- *one file*. It shadows the byte-offset motion, which in a rendered diff counts the
    -- bytes of the rendering rather than of any file and so names no position a reviewer
    -- could ask for. It overrides the configured switch for the session rather than
    -- editing it.
    ["go"] = { view.toggle_solo, "Draw one file at a time, or every file" },
    ["<CR>"] = { view.open_file, "Open the real file here" },
    ["Q"] = { view.review_queue, "Review the queue" },
    -- `gy`, not `Y`: yank is not dead in this buffer the way append is, and pulling a code
    -- line out of the diff is something reviewers do. From the same `g` family as the
    -- commands above, where it shadows nothing.
    ["gy"] = { view.copy, "Copy the batch to the clipboard" },
    ["<C-t>"] = { view.pick_target, "Choose the delivery target" },
    ["<C-s>"] = { view.submit, "Submit the batch" },
    -- `<C-a>` for the reason `a` became the annotation prefix: increment is dead in a
    -- nomodifiable buffer, so it costs a keystroke and no motion.
    ["<C-a>"] = { view.submit_with_preamble, "Submit the batch under a preamble" },
    ["q"] = { view.close, "Close the review" },
  })

  -- Only once the adapter is injected. Every adapter is nil by default, and a key that
  -- silently does nothing is worse than no key at all -- it also keeps `gd` free for
  -- whatever a host that wired no diff tool would rather have there. From the same `g`
  -- family as the commands above, and clear of `gt`/`gT`.
  if config.get().open_diff then
    bind(buf, { ["gd"] = { view.open_diff, "Read this file in the host's diff tool" } })
  end
end

---Bind the file tree's keys.
---@param buf integer
---@param view table The review view, whose exported actions these keys run.
function M.panel(buf, view)
  bind(buf, {
    ["<CR>"] = { view.panel_select, "Open the file / fold the directory" },
    ["o"] = { view.panel_select, "Open the file / fold the directory" },
    ["za"] = {
      function()
        view.panel_fold(nil)
      end,
      "Toggle the directory",
    },
    ["l"] = {
      function()
        view.panel_fold(false)
      end,
      "Expand the directory",
    },
    ["zo"] = {
      function()
        view.panel_fold(false)
      end,
      "Expand the directory",
    },
    ["h"] = {
      function()
        view.panel_fold(true)
      end,
      "Collapse the directory / go to the parent",
    },
    ["zc"] = {
      function()
        view.panel_fold(true)
      end,
      "Collapse the directory",
    },
    ["zM"] = {
      function()
        view.panel_fold_all(true)
      end,
      "Collapse every directory",
    },
    ["zR"] = {
      function()
        view.panel_fold_all(false)
      end,
      "Expand every directory",
    },
    ["]f"] = {
      function()
        view.panel_jump_file(true)
      end,
      "Next file in the tree",
    },
    ["[f"] = {
      function()
        view.panel_jump_file(false)
      end,
      "Previous file in the tree",
    },
    ["<C-p>"] = { view.pick_file, "Jump to a file" },
    ["<Tab>"] = { view.toggle_focus, "Focus the diff" },
    ["gp"] = { view.toggle_panel, "Hide the file tree" },
    ["gl"] = { view.toggle_layout, "Toggle the unified and split layouts" },
    ["gb"] = { view.last_batch, "Read the last batch back" },
    ["gc"] = { view.commit_list, "List the commits on the branch, and trim the review" },
    ["gA"] = { view.toggle_archived, "Show or hide archived entries" },
    ["gS"] = { view.switch, "Switch the review to another checkout" },
    -- Bound in the tree as well as in the diff, as every view-wide key is: a reviewer
    -- standing here who wants the diff folded should not have to move first.
    ["gw"] = { view.toggle_wrap, "Fold long lines, or stop folding them" },
    -- And the same for solo, which narrows the diff around the file being read there. The
    -- tree goes on listing every file either way, so the key changes nothing under the
    -- cursor it is pressed with.
    ["go"] = { view.toggle_solo, "Draw one file at a time, or every file" },
    ["R"] = { view.panel_toggle_reviewed, "Toggle reviewed (whole subtree on a directory)" },
    ["q"] = { view.close, "Close the review" },
  })

  if config.get().open_diff then
    bind(buf, { ["gd"] = { view.panel_open_diff, "Read this file in the host's diff tool" } })
  end
end

return M
