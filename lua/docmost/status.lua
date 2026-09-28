local M = {}

local things = {
  table = 'a table',
  tableRow = 'a table',
  tableCell = 'a table',
  tableHeader = 'a table',
  image = 'an image',
  attachment = 'an attachment',
  video = 'a video',
  audio = 'an audio clip',
  taskList = 'a task list',
  taskItem = 'a task list',
  callout = 'a callout',
  mention = 'a mention',
  embed = 'an embedded item',
  youtube = 'an embedded video',
  drawio = 'a diagram',
  excalidraw = 'a diagram',
  mathInline = 'math',
  mathBlock = 'math',
  details = 'a collapsible section',
  detailsSummary = 'a collapsible section',
  detailsContent = 'a collapsible section',
  hardBreak = 'a manual line break',
  subpages = 'a subpage list',
  link = 'a link',
  underline = 'underlined text',
  highlight = 'highlighted text',
  textStyle = 'coloured text',
  subscript = 'subscript text',
  superscript = 'superscript text',
  comment = 'an inline comment',
}

local rules = {
  {
    '^Unsupported node: (.+)$',
    function(kind)
      return 'This page contains '
        .. (things[kind] or ('a "' .. kind .. '" block'))
        .. '. That content only round-trips through the browser editor, so the page opens read-only.'
    end,
  },
  {
    '^Unsupported mark: (.+)$',
    function(kind)
      return 'This page uses '
        .. (things[kind] or ('"' .. kind .. '" formatting'))
        .. ', which Markdown cannot carry back safely, so the page opens read-only.'
    end,
  },
  {
    '^Unsupported attribute: ([^.]+)%.(.+)$',
    function(kind, key)
      if key == 'textAlign' then
        return 'Some text is centred or right aligned. Alignment would be lost, so the page opens read-only.'
      end
      if key == 'indent' then
        return 'Some blocks are indented in the browser editor. That would be lost, so the page opens read-only.'
      end
      return 'A '
        .. kind
        .. ' block carries a "'
        .. key
        .. '" setting that Markdown cannot keep, so the page opens read-only.'
    end,
  },
  {
    '^Server reports read%-only permission$',
    'Your account can view this page but not edit it.',
  },
  {
    '^Install pandoc',
    'Pandoc is needed to keep block IDs when saving this page. Install pandoc, then reopen the page.',
  },
  {
    '^New rich Markdown/HTML is outside the supported subset$',
    'The edit adds content Neovim cannot save safely (images, HTML, tables, task lists, callouts or footnotes). Add those in the browser instead.',
  },
  {
    '^Markdown is outside the supported JSON adapter subset$',
    'The edit uses Markdown that cannot be mapped back to Docmost blocks. Stick to headings, paragraphs, lists, quotes, code blocks and rules.',
  },
  {
    'save text edits and inserted/deleted blocks separately',
    'Text changes and added or removed blocks overlap, so existing block IDs cannot be matched. Save the text edits first (:w), then add or remove blocks and save again.',
  },
  {
    'Mixed block moves and edits',
    'Blocks were moved and edited in one go. Save the text edits first (:w), then move blocks in a separate save.',
  },
  {
    'Repeated blocks have ambiguous IDs',
    'Identical blocks were added or removed, so their IDs are ambiguous. Change them in smaller steps and save between steps.',
  },
  {
    'Cannot map block IDs across this structural change',
    'The page structure changed too much in one save to keep block IDs. Save text edits first, then restructure in a separate save.',
  },
  {
    'Too many blocks to map IDs safely',
    'The page is too large to match block IDs in one edit. Save smaller changes more often.',
  },
  {
    'does not represent the page JSON losslessly',
    'The Markdown view of this page is not exact, so saving could change it unexpectedly. Edit it in the browser.',
  },
  {
    '^Unsupported Markdown (%a+): (.+)$',
    function(where, kind)
      return 'The edit uses Markdown '
        .. where
        .. ' "'
        .. kind
        .. '" that Docmost blocks cannot represent. Remove it and save again.'
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
