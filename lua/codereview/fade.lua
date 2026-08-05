---Every file except the one the cursor is in is **faded**.
---
---What lives here is the rule: which rows one file's fade covers, and which group a row of a
---faded file carries in place of the one it would carry anyway. The marks themselves are
---emitted by `view.lua`, which owns them, and which file the cursor is in is asked there too
----- that is a fact about the diff and its anchor map, and this module is one caller of it.
---
---**The fade changes which group a mark carries. It does not change the priority order.** A
---faded file's rows are emitted in the blended variants of the groups they would carry
---anyway. The alternative is one grey foreground laid over the file above the syntax replay,
---and this project already refused that shape for the intra-line **span** emphasis: a
---foreground above the replay wins where a parser painted and loses where none did, so the
---result changes with the parsers a reader has installed. Leaving the bands alone is also
---what keeps the composition rules in the design notes true.
---
---**It is marks, and not a highlight namespace.** A namespace colours a whole window, so it
---cannot fade one file inside a **pane**. The **muted** window rule is a namespace because
---its unit *is* the window. The two mechanisms answer two different questions, and they
---share nothing but the blends in `hl.lua` -- which is what stops them drifting apart in
---colour while each keeps a strength of its own.
local config = require("codereview.config")
local hl = require("codereview.hl")

local M = {}

---Whether anything fades at all.
---
---Off means no mark is renamed and no colour is computed, so the diff is drawn exactly as it
---was before this existed.
---@return boolean
function M.enabled()
  return config.get().faded.enabled
end

---The group a faded row carries in place of `group`.
---
---**A group the active theme gives no colour of its own is emitted as itself.** `hl.lua`
---hands back nothing for it, and the row is then drawn in the group it would have carried
---anyway -- a file merely not faded rather than one drawn in a colour nobody chose.
---@param group string
---@return string
function M.group(group)
  return hl.blended("faded", group) or group
end

---One mark's options, with the groups that colour its own row faded.
---
---`hl_group` and `line_hl_group` are what a mark puts on the row it sits on, and they are
---what the fade renames. The virtual lines hanging under a row are left as they are: they
---are the **queue**'s entries and the **archive**'s, drawn beneath the code rather than on
---it, and what a faded file does to those is #112's question.
---
---A copy, never the render's own table: the same mark is emitted again whenever the fade
---moves, and it has to start from the group it was built with.
---@param opts table
---@return table
function M.opts(opts)
  if not (opts.hl_group or opts.line_hl_group) then
    return opts
  end
  local out = vim.tbl_extend("force", {}, opts)
  out.hl_group = opts.hl_group and M.group(opts.hl_group) or nil
  out.line_hl_group = opts.line_hl_group and M.group(opts.line_hl_group) or nil
  return out
end

---The rows one file's fade covers: its body, and never its header row.
---
---**Taken from the render, which records the header row of every file.** A file runs from
---its own header to the row before the next file's, and its fade starts one row after that
---header. Its hunk headers are inside the body and fade with it.
---
---What keeps a header row bright is `M.rows` below, which exempts every one of them. Leaving
---the header out here is the economy beside that rule rather than the rule: a crossing
---re-emits the two bodies whose fade changed, and a header carries the same group either
---way, so there is nothing there to write again. Deleting the `+ 1` reds no case.
---
---The row map the syntax replay builds holds a span per file as well, and it must not be
---used here. That map is built only when highlighting is on, so a fade reading it would do
---nothing at all for a reviewer with `syntax = false`.
---@param rendered CRRender
---@param fi integer
---@return integer first, integer last 1-indexed and inclusive; `first > last` when there is no body
function M.body(rendered, fi)
  local header = rendered.file_rows[fi]
  if not header then
    return 1, 0
  end
  local next_header = rendered.file_rows[fi + 1]
  return header + 1, (next_header and next_header - 1) or #rendered.lines
end

---Which rows of a render are faded, as one question a caller asks per row.
---
---Built once per emission and asked per mark, so the rule is decided against the file the
---cursor is in *now* rather than against whatever it was when a band was last painted. That
---is what makes rows scrolled into after a crossing arrive faded.
---
---Nothing is faded when the switch is off, and nothing is faded when the cursor is in no
---file: an empty review shows every file at full strength rather than every file faded.
---
---Both **panes** are answered by one of these. They hold the same rows and the same header
---rows, so the two images stay comparable row for row.
---
---**Every file's header row is exempt, not only the current file's.** The header is the one
---row that names the file, and the fade exists to help a reviewer find a place rather than to
---hide the map. This is the line that says so.
---@param rendered CRRender
---@param current integer|nil File index the cursor is in
---@return (fun(row: integer): boolean)|nil faded nil when nothing fades
function M.rows(rendered, current)
  if not M.enabled() or not current then
    return nil
  end
  local first, last = M.body(rendered, current)
  local headers = {}
  for _, row in pairs(rendered.file_rows) do
    headers[row] = true
  end
  return function(row)
    return not headers[row] and (row < first or row > last)
  end
end

return M
