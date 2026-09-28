local M = {}

local rules = {
  {
    '^Server reports read%-only permission$',
    'Your account can view this page but not edit it.',
  },
  {
    'pandoc',
    'Pandoc is needed to turn your Markdown back into Docmost blocks. Install pandoc, then reopen the page.',
  },
  {
    '^Round trip failed for content%[(%d+)%] %((.-)%)$',
    function(index, kind)
      return 'Neovim could not reproduce block '
        .. index
        .. ' ('
        .. kind
        .. ') exactly, so the page opens read-only and nothing can be lost. Please report this block type.'
    end,
  },
  {
    '^Line (%d+): (.+)$',
    function(line, message)
      return 'Line ' .. line .. ': ' .. message .. '. Nothing was sent; fix it and :w again.'
    end,
  },
}

function M.explain(reason)
  if type(reason) ~= 'string' then
    return ''
  end
  for _, rule in ipairs(rules) do
    local found = { reason:match(rule[1]) }
    if found[1] then
      return type(rule[2]) == 'function' and rule[2](unpack(found)) or rule[2]
    end
  end
  return reason
end

local busy = {
  ['checking remote'] = { 'checking', 'Comparing with the server before writing' },
  ['parsing Markdown'] = { 'preparing', 'Converting Markdown to blocks locally' },
  saving = { 'saving', 'Update sent; waiting to verify it' },
  verifying = { 'verifying', 'Reading back until two fresh reads match' },
}

local outcomes = {
  conflict = {
    'conflict',
    'DocmostError',
    'The page changed on the server. :Docmost diff compares base, local and remote.',
  },
  ['save outcome uncertain'] = {
    'uncertain',
    'DocmostWarn',
    'The server did not confirm the save. :w checks again by reading; it never resends.',
  },
  ['save rejected'] = {
    'rejected',
    'DocmostError',
    'The server refused the update. Your edits are kept.',
  },
  ['preflight failed'] = {
    'not saved',
    'DocmostError',
    'Could not check the server before writing. Nothing was sent; edits are kept.',
  },
  ['preflight cancelled'] = {
    'cancelled',
    'DocmostWarn',
    'Save cancelled before anything was sent.',
  },
  ['conversion blocked'] = { 'blocked', 'DocmostWarn', nil },
}

function M.modified(s)
  if s.buf and vim.api.nvim_buf_is_valid(s.buf) and vim.api.nvim_buf_is_loaded(s.buf) then
    return vim.bo[s.buf].modified
  end
  return s.detached_modified or false
end

function M.describe(s)
  local modified = M.modified(s)
  local explained = s.last_error and M.explain(s.last_error) or nil
  local b = busy[s.status]
  if s.busy and b then
    return { label = b[1], group = 'DocmostBusy', hint = b[2], busy = true, modified = modified }
  end
  local o = outcomes[s.status]
  if o then
    return { label = o[1], group = o[2], hint = o[3] or explained, modified = modified }
  end
  if not s.baseline.editable then
    return {
      label = 'read-only',
      group = 'DocmostDim',
      hint = M.explain(s.baseline.reason),
      modified = modified,
    }
  end
  if modified then
    return {
      label = 'unsaved',
      group = 'DocmostWarn',
      hint = explained or ':w saves and verifies with fresh reads',
      modified = true,
    }
  end
  if s.status == 'verified' then
    return {
      label = 'verified ' .. os.date('%H:%M', s.verified_at or os.time()),
      group = 'DocmostOk',
      hint = 'Two fresh reads matched what you wrote',
      modified = false,
    }
  end
  return { label = 'clean', group = 'DocmostDim', hint = nil, modified = false }
end

local expr = "%{%v:lua.require'docmost.status'.winbar()%}"
M.expr = expr

local function escape(text)
  return (tostring(text or ''):gsub('[%c]', ' '):gsub('%%', '%%%%'))
end

function M.winbar()
  local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  local s = ok and require('docmost.buffer').current(buf)
  if not s then
    return ''
  end
  local d = M.describe(s)
  local short = s.baseline.reason and s.baseline.reason:match(': ([^:]+)$')
  local access = s.baseline.editable and '%#DocmostOk#editable'
    or ('%#DocmostWarn#read-only' .. (short and '%#DocmostDim# (' .. escape(short) .. ')' or ''))
  local parts = {
    '%#DocmostBrand# docmost %#DocmostWinbar# ',
    escape(s.baseline.meta.title or s.id),
    '%#DocmostDim#  ·  ',
    access,
  }
  if d.label ~= 'clean' and d.label ~= 'read-only' then
    parts[#parts + 1] = '%#DocmostDim#  ·  %#' .. d.group .. '#' .. escape(d.label)
  end
  parts[#parts + 1] = '%#DocmostWinbar#%<%='
  if d.hint then
    parts[#parts + 1] = '%#DocmostDim#' .. escape(d.hint) .. ' '
  end
  return table.concat(parts)
end

function M.sweep()
  if not require('docmost.config').values or not require('docmost.config').get().ui.winbar then
    return
  end
  local buffers = require('docmost.buffer')
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative == '' then
      local page = buffers.current(vim.api.nvim_win_get_buf(win))
      local current = vim.wo[win].winbar
      if (page and current == '') or (not page and current == expr) then
        vim.api.nvim_set_option_value('winbar', page and expr or '', { scope = 'local', win = win })
      end
    end
  end
end

return M
