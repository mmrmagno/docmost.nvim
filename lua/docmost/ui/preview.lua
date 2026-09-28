local M = {}
local tree = require('docmost.ui.tree')
local render = require('docmost.ui.render')
local ns = vim.api.nvim_create_namespace('DocmostPreview')
local limit = 30
local body_lines = 400

local function wrap(text, width)
  local out, line = {}, ''
  for word in tostring(text):gmatch('%S+') do
    if line == '' then
      line = word
    elseif vim.fn.strdisplaywidth(line .. ' ' .. word) <= width then
      line = line .. ' ' .. word
    else
      out[#out + 1] = line
      line = word
    end
  end
  if line ~= '' then
    out[#out + 1] = line
  end
  return out
end

local topics = {
  login = {
    'Sign in',
    'Enter your Docmost email, then your password in the secret prompt.',
    'The password never reaches this window, logs or process arguments. The session stays in memory unless persist_session is enabled.',
  },
  open = {
    'Open by URL or ID',
    'Paste a page link from the configured Docmost origin or a page ID. Links from other hosts are refused.',
  },
}

function M.crumbs(row)
  local g = render.icons()
  local parts = {}
  local node = row and row.node
  if not node and row and row.item then
    node = require('docmost.ui').session.nodes['page:' .. row.item.id]
  end
  if node then
    for _, ancestor in ipairs(tree.ancestors(node)) do
      parts[#parts + 1] = render.safe(tree.label(ancestor))
    end
    parts[#parts + 1] = render.safe(tree.label(node))
  elseif row and row.item then
    local space = type(row.item.space) == 'table' and row.item.space.name
    if space then
      parts[#parts + 1] = render.safe(space)
    end
    parts[#parts + 1] = render.safe(row.item.title or row.item.id)
  end
  return table.concat(parts, ' ' .. g.crumb .. ' ')
end

function M.remember(session, id, page)
  if not session.previews[id] then
    session.preview_order[#session.preview_order + 1] = id
  end
  session.previews[id] = page
  session.preview_errors[id] = nil
  while #session.preview_order > limit do
    session.previews[table.remove(session.preview_order, 1)] = nil
  end
end

function M.id(row)
  if row and (row.kind == 'page' or row.kind == 'result' or row.kind == 'open') then
    return row.item and row.item.id or (row.node and row.node.item.id)
  end
end

function M.build(session, row, width, ctx)
  local lines, marks = {}, {}
  local g = render.icons()
  width = width - 2
  local function add(text, group)
    lines[#lines + 1] = text == '' and '' or (' ' .. render.safe(text))
    if group then
      marks[#marks + 1] = { #lines - 1, group }
    end
  end
  local function para(text, group)
    for _, line in ipairs(wrap(text, math.max(10, width))) do
      add(line, group)
    end
  end
  local id = M.id(row)
  if id then
    local page = require('docmost.buffer').states[id]
    local cached = session.previews[id]
    local info = page and page.baseline or cached
    local title = (info and info.meta.title)
      or (row.item and row.item.title)
      or tree.label(row.node)
    add(title ~= '' and title or 'Untitled', 'DocmostHeading')
    local crumbs = M.crumbs(row)
    if crumbs ~= '' and require('docmost.config').get().ui.border == 'none' then
      add(crumbs, 'DocmostDim')
    end
    local updated = info and info.meta.updatedAt or (row.item and row.item.updatedAt)
    if type(updated) == 'string' and updated ~= '' then
      add('Updated ' .. updated:gsub('T', ' '):gsub('%.%d+Z$', ' UTC'), 'DocmostDim')
    end
    add('')
    if info then
      if info.editable then
        add(g.on .. ' Editable in Neovim', 'DocmostOk')
      else
        add(g.off .. ' Read-only in Neovim', 'DocmostWarn')
        para(require('docmost.status').explain(info.reason), 'DocmostDim')
      end
    end
    if page then
      local d = require('docmost.status').describe(page)
      add('Open buffer: ' .. d.label, d.group)
      if d.hint then
        para(d.hint, 'DocmostDim')
      end
    end
    if info and info.editable then
      para('Close the browser editor for this page before saving here.', 'DocmostDim')
    end
    add(string.rep(g.rule, math.max(1, width)), 'DocmostBorder')
    local body
    if page then
      body = vim.api.nvim_buf_is_valid(page.buf)
          and vim.api.nvim_buf_is_loaded(page.buf)
          and vim.api.nvim_buf_get_lines(page.buf, 0, body_lines, false)
        or vim.split(page.snapshot or '', '\n', { plain = true })
    elseif cached then
      body = vim.split(cached.markdown, '\n', { plain = true })
    elseif session.preview_errors[id] then
      add(g.error .. ' ' .. session.preview_errors[id], 'DocmostError')
      add('r retries the preview. Enter opens the page.', 'DocmostDim')
    elseif not ctx.remote then
      add('Preview is off (ui.preview = false). Enter opens the page.', 'DocmostDim')
    else
      add(g.loading .. ' Loading preview…', 'DocmostBusy')
    end
    if body then
      local _, rest = require('docmost.dfm').read_front(table.concat(body, '\n'))
      body = vim.split(rest, '\n', { plain = true })
      local start = #lines
      if #body == 0 or (#body == 1 and body[1] == '') then
        add('(empty page)', 'DocmostDim')
      end
      for index = 1, math.min(#body, body_lines) do
        add(body[index])
      end
      if #body > body_lines then
        add(g.ellipsis .. ' preview truncated; open the page for the rest', 'DocmostDim')
      end
      return lines, marks, nil, start
    end
    return lines,
      marks,
      (not page and not cached and not session.preview_errors[id] and ctx.remote) and id or nil
  end
  if row and row.kind == 'space' then
    add(tree.label(row.node), 'DocmostHeading')
    add(
      'Space' .. (row.node.item.slug and (' ' .. g.sep .. ' ' .. row.node.item.slug) or ''),
      'DocmostDim'
    )
    add('')
    if type(row.node.item.description) == 'string' and row.node.item.description ~= '' then
      para(row.node.item.description)
      add('')
    end
    para(
      row.node.expanded and 'h collapses the space. Select a page to preview it.'
        or 'Enter or l lists its pages.',
      'DocmostDim'
    )
    return lines, marks
  end
  local topic = row and row.action and topics[row.action]
  if topic then
    add(topic[1], 'DocmostHeading')
    add('')
    for index = 2, #topic do
      para(topic[index])
      add('')
    end
    return lines, marks
  end
  local c = require('docmost.config').get()
  add('Docmost workspace', 'DocmostHeading')
  add(c.authority, 'DocmostDim')
  add('')
  add('Session: ' .. require('docmost.auth').status)
  add('Compatibility: ' .. require('docmost.buffer').compatibility)
  add('')
  para(
    'Select a page to preview it here. Previews are read-only and separate from page buffers.',
    'DocmostDim'
  )
  para('Press ? for every key, or :Docmost guide for editing tips.', 'DocmostDim')
  return lines, marks
end

function M.draw(buf, lines, marks, body_start)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], 0, {
      end_row = m[1] + 1,
      hl_group = m[2],
      hl_eol = false,
      priority = 200,
    })
  end
  vim.b[buf].docmost_body_start = body_start
  if require('docmost.config').get().ui.conceal then
    require('docmost.dfm.decorate').enable(buf)
  end
end

return M
