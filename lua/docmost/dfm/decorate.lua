local M = {}
local attr = require('docmost.dfm.attr')
local schema = require('docmost.dfm.schema')
M.ns = vim.api.nvim_create_namespace('DocmostDecorate')
M.labels = vim.api.nvim_create_namespace('DocmostLabels')

local function blob(line, start)
  local quoted, i = false, start + 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == '"' then
      quoted = not quoted
    elseif c == '}' and not quoted then
      return i
    end
    i = i + 1
  end
end

function M.scan(line)
  local found = {}
  local fence = line:match('^%s*(:::+)%s*')
  if fence then
    local open = line:find('{', 1, true)
    local stop = open and blob(line, open)
    found[#found + 1] = { kind = 'fence', col = 0, stop = #line, open = open, close = stop }
    return found
  end
  local i = 1
  while i <= #line do
    local open = line:find('[%]%)]{', i)
    if not open then
      break
    end
    if line:sub(open - 1, open - 1) == '\\' then
      i = open + 1
    else
      local close = blob(line, open + 1)
      if not close then
        break
      end
      found[#found + 1] =
        { kind = 'attrs', col = open, stop = close, spec = line:sub(open + 1, close) }
      i = close + 1
    end
  end
  return found
end

function M.parse_spec(spec)
  local classes, attrs = {}, {}
  local body = spec:match('^{(.*)}$') or ''
  for class in body:gmatch('%.([%w_-]+)') do
    classes[#classes + 1] = class
  end
  for key, value in body:gmatch('([%w_:.-]+)="([^"]*)"') do
    if key == 'dfm-attrs' then
      local decoded = attr.decode(value)
      if type(decoded) == 'table' then
        for k, v in pairs(decoded) do
          attrs[k] = v
        end
      end
    elseif not key:match('^dfm%-') then
      attrs[attr.unkey(key)] = attr.decode(value)
    end
  end
  return classes, attrs
end

function M.specs(line)
  local c = require('docmost.config').get()
  local cchar = c.ui.icons == 'ascii' and '~' or '…'
  local out = {}
  for _, hit in ipairs(M.scan(line)) do
    if hit.kind == 'fence' then
      out[#out + 1] =
        { col = 0, opts = { end_col = #line, hl_group = 'DocmostFence', priority = 90 } }
    else
      out[#out + 1] = {
        col = hit.col,
        opts = { end_col = hit.stop, conceal = cchar, hl_group = 'DocmostAttrs', priority = 110 },
      }
    end
  end
  return out
end

local attached = {}

function M.media(line)
  local media = line:match('^%s*!?%[.-%]%(.-%){%.([%w_-]+)')
  return media and schema.media[media] and media or nil
end

local function labels(buf, rows)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.labels, 0, -1)
  for _, entry in ipairs(rows) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.labels, entry[1], entry[2], {
      virt_text = { { entry[3] .. ' ', 'DocmostKey' } },
      virt_text_pos = 'inline',
    })
  end
end

local function code_rows(buf)
  local rows, fence, media = {}, nil, {}
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local code = line:match('^%s*(```+)') or line:match('^%s*(~~~+)')
    if code then
      rows[row - 1] = true
      if not fence then
        fence = code
      elseif code:sub(1, 1) == fence:sub(1, 1) and #code >= #fence then
        fence = nil
      end
    elseif fence then
      rows[row - 1] = true
    else
      local kind = M.media(line)
      if kind then
        media[#media + 1] = { row - 1, #line:match('^%s*'), kind }
      end
    end
  end
  return rows, media
end

local provider = false

local function install()
  if provider then
    return
  end
  provider = true
  vim.api.nvim_set_decoration_provider(M.ns, {
    on_win = function(_, _, buf)
      local state = attached[buf]
      if not state or not vim.api.nvim_buf_is_valid(buf) then
        return false
      end
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      if state.tick ~= tick then
        local media
        state.tick, state.code, media = tick, code_rows(buf)
        vim.schedule(function()
          labels(buf, media)
        end)
      end
    end,
    on_line = function(_, _, buf, row)
      local state = attached[buf]
      if not state or state.code[row] then
        return
      end
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
      for _, spec in ipairs(M.specs(line)) do
        local opts = vim.tbl_extend('force', spec.opts, { ephemeral = true, end_row = row })
        pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row, spec.col, opts)
      end
    end,
  })
end

function M.enable(buf)
  install()
  if not attached[buf] then
    attached[buf] = { tick = -1, code = {} }
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = buf,
      once = true,
      callback = function()
        attached[buf] = nil
      end,
    })
  end
end

local function conceal_on()
  if not require('docmost.config').get().ui.conceal then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if vim.w[win].docmost_conceal == nil then
    vim.w[win].docmost_conceal = { vim.wo[win].conceallevel, vim.wo[win].concealcursor }
  end
  vim.wo[win].conceallevel, vim.wo[win].concealcursor = 2, ''
end

local function conceal_off()
  local win = vim.api.nvim_get_current_win()
  local saved = vim.w[win].docmost_conceal
  if saved then
    vim.wo[win].conceallevel, vim.wo[win].concealcursor = saved[1], saved[2]
    vim.w[win].docmost_conceal = nil
  end
end

function M.attach(buf)
  local group = vim.api.nvim_create_augroup('DocmostDecorate' .. buf, { clear = true })
  M.enable(buf)
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = buf,
    callback = conceal_on,
  })
  vim.api.nvim_create_autocmd('BufWinLeave', {
    group = group,
    buffer = buf,
    callback = conceal_off,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  vim.bo[buf].omnifunc = "v:lua.require'docmost.dfm.decorate'.omni"
  vim.api.nvim_create_autocmd('InsertEnter', {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      require('docmost.snippets').register()
    end,
  })
end

function M.at_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  for _, hit in ipairs(M.scan(line)) do
    if hit.kind == 'fence' and hit.open and hit.close then
      return M.parse_spec(line:sub(hit.open, hit.close))
    elseif hit.kind == 'attrs' then
      local start = line:sub(1, hit.col):match('.*()%[') or 1
      if col + 1 >= start and col < hit.stop then
        return M.parse_spec(hit.spec)
      end
    end
  end
  if line:match('^%s*:::+%s*[%w_-]+%s*$') then
    return { line:match('^%s*:::+%s*([%w_-]+)') }, {}
  end
  return nil, nil, row
end

function M.inspect()
  local classes, attrs = M.at_cursor()
  if not classes then
    vim.notify('docmost: no Docmost construct under the cursor')
    return
  end
  local lines = { classes[1] or 'attributes' }
  local keys = vim.tbl_keys(attrs)
  table.sort(keys)
  for _, key in ipairs(keys) do
    lines[#lines + 1] = '  '
      .. key
      .. ' = '
      .. vim.inspect(attrs[key] == vim.NIL and 'null' or attrs[key])
  end
  if #keys == 0 then
    lines[#lines + 1] = '  (no attributes)'
  end
  vim.lsp.util.open_floating_preview(
    lines,
    'lua',
    { border = 'rounded', focus_id = 'docmost-inspect' }
  )
end

local function known_attrs(buf)
  local page = require('docmost.buffer').current(buf)
  local out = {}
  local function walk(node)
    out[node.type] = out[node.type] or {}
    for key in pairs(node.attrs or {}) do
      out[node.type][key] = true
    end
    for _, m in ipairs(node.marks or {}) do
      out[m.type] = out[m.type] or {}
      for key in pairs(m.attrs or {}) do
        out[m.type][key] = true
      end
    end
    for _, child in ipairs(node.content or {}) do
      walk(child)
    end
  end
  if page then
    walk(page.baseline.json)
  end
  return out
end

function M.omni(findstart, base)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col)
  if findstart == 1 then
    local start = before:match('.*()[%.%s{]')
    return start and start or -3
  end
  local items = {}
  local open = before:match('.*{([^}]*)$')
  if not open then
    return items
  end
  local class = open:match('%.([%w_-]+)')
  if not class or before:match('{%.[%w_-]*$') then
    local names = vim.tbl_keys(vim.tbl_extend('force', {}, schema.known, schema.marks))
    table.sort(names)
    for _, name in ipairs(names) do
      if name:find(base, 1, true) == 1 and name ~= 'doc' and name ~= 'text' then
        items[#items + 1] = { word = name, menu = schema.marks[name] and '[style]' or '[block]' }
      end
    end
    return items
  end
  local keys = vim.tbl_keys(known_attrs(0)[class] or {})
  table.sort(keys)
  for _, key in ipairs(keys) do
    local word = attr.key(key)
    if word:find(base, 1, true) == 1 then
      items[#items + 1] = { word = word .. '=""', abbr = word, menu = '[' .. class .. ']' }
    end
  end
  return items
end

return M
