local M = {}
local tree = require('docmost.ui.tree')
local layout = require('docmost.ui.layout')
local ns = vim.api.nvim_create_namespace('DocmostUI')
M.ns = ns

M.glyphs = {
  unicode = {
    expanded = '▾',
    collapsed = '▸',
    leaf = '·',
    loading = '◌',
    more = '+',
    modified = '●',
    clean = '○',
    error = '!',
    on = '●',
    off = '○',
    sep = '·',
    crumb = '›',
    action = '›',
    ellipsis = '…',
    rule = '─',
    spinner = { '◐', '◓', '◑', '◒' },
  },
  ascii = {
    expanded = 'v',
    collapsed = '>',
    leaf = '-',
    loading = '~',
    more = '+',
    modified = '*',
    clean = ' ',
    error = '!',
    on = '*',
    off = 'o',
    sep = '|',
    crumb = '>',
    action = '>',
    ellipsis = '~',
    rule = '-',
    spinner = { '-', '\\', '|', '/' },
  },
}

function M.icons()
  return M.glyphs[require('docmost.config').get().ui.icons]
end

function M.safe(value)
  return (tostring(value or ''):gsub('[%c]', ' '))
end

local function row(rows, spec)
  rows[#rows + 1] = spec
  return spec
end

local function message(rows, depth, glyph, text, group, extra)
  local spec = vim.tbl_extend('force', {
    kind = 'message',
    chunks = {
      { string.rep('  ', depth) .. ' ' },
      { glyph .. ' ', group },
      { text, group },
    },
  }, extra or {})
  return row(rows, spec)
end

local function split(text, width)
  local out, line = {}, ''
  for word in text:gmatch('%S+') do
    if line == '' then
      line = word
    elseif vim.fn.strdisplaywidth(line .. ' ' .. word) <= width then
      line = line .. ' ' .. word
    else
      out[#out + 1] = line
      line = word
    end
  end
  out[#out + 1] = line
  return out
end

local function wrapped(rows, glyph, text, group, width, extra)
  for index, line in ipairs(split(text, math.max(10, (width or 80) - 6))) do
    if index == 1 then
      message(rows, 0, glyph, line, group, extra)
    else
      message(rows, 0, ' ', line, group)
    end
  end
end

local function section(rows, title, badge)
  if #rows > 0 then
    row(rows, { kind = 'blank', chunks = {} })
  end
  row(rows, { kind = 'section', chunks = { { ' ' .. title, 'DocmostSection' } }, badge = badge })
end

local function page_badge(id)
  local page = require('docmost.buffer').states[id]
  if page then
    local d = require('docmost.status').describe(page)
    return { d.label, d.group }
  end
end

local function nodes(rows, node, g, ctx)
  for _, child in ipairs(node.children or {}) do
    local indent = string.rep('  ', child.depth)
    local glyph, glyph_group = g.collapsed, 'DocmostDim'
    if child.loading then
      glyph, glyph_group = g.loading, 'DocmostBusy'
    elseif child.leaf then
      glyph = g.leaf
    elseif child.expanded then
      glyph, glyph_group = g.expanded, 'DocmostKey'
    end
    local label_group = child.kind == 'space' and 'DocmostSpace' or 'DocmostPage'
    if child.kind == 'page' and child.item.id == ctx.origin then
      label_group = 'DocmostHeading'
    end
    row(rows, {
      key = child.key,
      kind = child.kind,
      node = child,
      selectable = true,
      chunks = {
        { indent .. ' ' },
        { glyph .. ' ', glyph_group },
        { M.safe(tree.label(child)), label_group },
      },
      badge = child.kind == 'page' and page_badge(child.item.id) or nil,
    })
    if child.expanded then
      local depth = child.depth + 1
      if child.error then
        message(rows, depth, g.error, M.safe(child.error.message) .. '  r retry', 'DocmostError', {
          key = 'error:' .. child.key,
          kind = 'error',
          node = child,
          selectable = true,
        })
      end
      if child.loading and not child.children then
        message(rows, depth, g.loading, 'Loading…', 'DocmostBusy')
      elseif child.children and #child.children == 0 and child.kind == 'space' then
        message(rows, depth, g.off, 'No pages in this space yet', 'DocmostDim')
      end
      nodes(rows, child, g, ctx)
      if child.next_cursor then
        message(rows, depth, g.more, 'Load more', 'DocmostKey', {
          key = 'more:' .. child.key,
          kind = 'more',
          node = child,
          selectable = true,
        })
      end
    end
  end
end

function M.signed_in()
  local auth = require('docmost.auth')
  if auth.status == 'authenticated' then
    return true
  end
  if auth.status:match('^expired') or auth.status == 'logged out locally' then
    return false
  end
  return auth.token() ~= nil
end

local function action(rows, key, text, hint)
  local g = M.icons()
  row(rows, {
    key = 'action:' .. key,
    kind = 'action',
    action = key,
    selectable = true,
    chunks = { { ' ' }, { g.action .. ' ', 'DocmostKey' }, { text } },
    badge = { hint, 'DocmostKey' },
  })
end

local function open_pages(rows, g, ctx)
  local pages = {}
  for _, page in pairs(require('docmost.buffer').states) do
    pages[#pages + 1] = page
  end
  if #pages == 0 then
    return
  end
  table.sort(pages, function(a, b)
    return M.safe(a.baseline.meta.title or a.id) < M.safe(b.baseline.meta.title or b.id)
  end)
  section(rows, 'OPEN PAGES')
  for _, page in ipairs(pages) do
    local modified = require('docmost.status').modified(page)
    local badge = page_badge(page.id)
    row(rows, {
      key = 'open:' .. page.id,
      kind = 'open',
      page = page,
      item = {
        id = page.id,
        title = page.baseline.meta.title,
        spaceId = page.baseline.meta.spaceId,
      },
      selectable = true,
      chunks = {
        { ' ' },
        { (modified and g.modified or g.clean) .. ' ', modified and 'DocmostWarn' or 'DocmostDim' },
        {
          M.safe(page.baseline.meta.title or page.id),
          page.id == ctx.origin and 'DocmostHeading' or 'DocmostPage',
        },
      },
      badge = badge,
    })
  end
end

function M.browse(session, ctx)
  local rows, g = {}, M.icons()
  local auth = require('docmost.auth')
  if ctx.notice then
    wrapped(rows, ctx.notice.glyph or g.on, M.safe(ctx.notice.text), ctx.notice.group, ctx.width)
  end
  local expired = auth.status:match('^expired') ~= nil
  if expired then
    wrapped(
      rows,
      g.error,
      'Session expired. Press a to sign in again; open pages keep their edits.',
      'DocmostWarn',
      ctx.width,
      { key = 'action:login', kind = 'action', action = 'login', selectable = true }
    )
  end
  open_pages(rows, g, ctx)
  local root = session.root
  section(rows, 'SPACES')
  if not M.signed_in() and not (expired and root.children) then
    message(rows, 0, g.off, 'Sign in to browse your workspace.', 'DocmostDim')
    if not expired then
      action(rows, 'login', 'Sign in', 'a')
    end
    action(rows, 'open', 'Open a page by URL or ID', 'o')
    wrapped(
      rows,
      ' ',
      "Passwords go to Neovim's secret prompt, never this window.",
      'DocmostDim',
      ctx.width
    )
  elseif root.error and not root.children then
    message(rows, 0, g.error, M.safe(root.error.message) .. '  r retry', 'DocmostError', {
      key = 'error:root',
      kind = 'error',
      node = root,
      selectable = true,
    })
  elseif not root.children then
    message(
      rows,
      0,
      g.loading,
      ctx.auth_busy and 'Checking session…' or 'Loading spaces…',
      'DocmostBusy'
    )
  elseif #root.children == 0 then
    message(rows, 0, g.off, 'No spaces are visible to this account.', 'DocmostDim')
  else
    if root.error then
      message(rows, 0, g.error, M.safe(root.error.message) .. '  r retry', 'DocmostError', {
        key = 'error:root',
        kind = 'error',
        node = root,
        selectable = true,
      })
    end
    nodes(rows, root, g, ctx)
    if root.next_cursor then
      message(rows, 0, g.more, 'Load more spaces', 'DocmostKey', {
        key = 'more:root',
        kind = 'more',
        node = root,
        selectable = true,
      })
    end
  end
  return rows
end

function M.results(session, ctx)
  local rows, g, s = {}, M.icons(), session.search
  if ctx.notice then
    wrapped(rows, ctx.notice.glyph or g.on, M.safe(ctx.notice.text), ctx.notice.group, ctx.width)
  end
  local query = vim.trim(s.query)
  local count = #s.items > 0 and (#s.items .. (s.next_offset and '+' or '') .. ' found') or nil
  section(rows, 'SEARCH', count and { count, 'DocmostDim' } or nil)
  if #query < 2 then
    message(rows, 0, g.off, 'Type at least two characters to search.', 'DocmostDim')
    return rows
  end
  if s.error then
    message(rows, 0, g.error, M.safe(s.error.message) .. '  r retry', 'DocmostError', {
      key = 'error:search',
      kind = 'error',
      search = true,
      selectable = true,
    })
  end
  if s.loading and #s.items == 0 then
    message(rows, 0, g.loading, 'Searching for "' .. M.safe(query) .. '"…', 'DocmostBusy')
  elseif not s.loading and not s.error and s.pages > 0 and #s.items == 0 then
    message(rows, 0, g.off, 'No pages match "' .. M.safe(query) .. '".', 'DocmostDim')
    message(rows, 0, ' ', 'Edit the query with /, or press Esc to browse.', 'DocmostDim')
  end
  for _, entry in ipairs(s.items) do
    local space = type(entry.item.space) == 'table' and entry.item.space.name or nil
    row(rows, {
      key = entry.key,
      kind = 'result',
      item = entry.item,
      selectable = true,
      chunks = {
        { ' ' },
        { g.leaf .. ' ', 'DocmostDim' },
        { M.safe(entry.item.title ~= '' and entry.item.title or 'Untitled'), 'DocmostPage' },
      },
      badge = page_badge(entry.item.id) or (space and { M.safe(space), 'DocmostDim' }),
    })
  end
  if s.next_offset and not s.loading then
    message(rows, 0, g.more, 'Load more results', 'DocmostKey', {
      key = 'more:search',
      kind = 'more',
      search = true,
      selectable = true,
    })
  end
  return rows
end

function M.draw(buf, rows, width)
  local g = M.icons()
  local lines, marks = {}, {}
  for index, spec in ipairs(rows) do
    local badge_width = spec.badge and (vim.fn.strdisplaywidth(spec.badge[1]) + 2) or 0
    local room = math.max(1, width - badge_width - 1)
    local text, col = {}, 0
    for _, chunk in ipairs(spec.chunks) do
      local used = vim.fn.strdisplaywidth(table.concat(text))
      local piece = layout.truncate(chunk[1], room - used, g.ellipsis)
      if piece ~= '' then
        text[#text + 1] = piece
        if chunk[2] then
          marks[#marks + 1] = { index - 1, col, col + #piece, chunk[2] }
        end
        col = col + #piece
      end
    end
    lines[index] = table.concat(text)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  for index, spec in ipairs(rows) do
    if spec.badge then
      vim.api.nvim_buf_set_extmark(buf, ns, index - 1, 0, {
        virt_text = { { M.safe(spec.badge[1]) .. ' ', spec.badge[2] or 'DocmostDim' } },
        virt_text_pos = 'right_align',
      })
    end
  end
  return lines
end

return M
