local M = {}
local schema = require('docmost.dfm.schema')
M.ns = vim.api.nvim_create_namespace('DocmostIdentity')

function M.attach(s, anchors)
  s.entries = {}
  if not (s.buf and vim.api.nvim_buf_is_valid(s.buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(s.buf, M.ns, 0, -1)
  local count = vim.api.nvim_buf_line_count(s.buf)
  for _, a in ipairs(anchors or {}) do
    if a.row < count then
      local line = vim.api.nvim_buf_get_lines(s.buf, a.row, a.row + 1, false)[1] or ''
      if a.col <= #line then
        local last = a.row + 1 >= count
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, s.buf, M.ns, a.row, a.col, {
          end_row = last and a.row or (a.row + 1),
          end_col = last and #line or 0,
          invalidate = true,
        })
        if ok then
          s.entries[id] = {
            type = a.node and a.node.type or a.type,
            hidden = a.node and (schema.split(a.node)) or a.hidden,
          }
        end
      end
    end
  end
end

function M.collect(s)
  local out = {}
  if not (s.buf and vim.api.nvim_buf_is_valid(s.buf) and s.entries) then
    return out
  end
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.buf, M.ns, 0, -1, { details = true })) do
    local id, row, col, details = m[1], m[2], m[3], m[4]
    local entry = s.entries[id]
    if entry and not details.invalid then
      out[#out + 1] = { row = row, col = col, type = entry.type, hidden = entry.hidden }
    end
  end
  return out
end

local function prose(list, out)
  for _, node in ipairs(list or {}) do
    if node.type == 'paragraph' or node.type == 'heading' then
      out[#out + 1] = node
    end
    prose(node.content, out)
  end
  return out
end

function M.reanchor(s, submitted, positions, remote)
  local dfm = require('docmost.dfm')
  local mine = prose(select(1, dfm.split_tail(submitted)).content, {})
  local theirs = prose(select(1, dfm.split_tail(remote)).content, {})
  if #mine ~= #theirs then
    return false
  end
  local anchors = {}
  for i, node in ipairs(mine) do
    local pos = positions[node]
    if pos then
      anchors[#anchors + 1] = { row = pos.row, col = pos.col, node = theirs[i] }
    end
  end
  M.attach(s, anchors)
  return true
end

return M
