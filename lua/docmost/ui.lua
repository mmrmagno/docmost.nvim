local M = {}
local tree = require('docmost.ui.tree')
local render = require('docmost.ui.render')
local layout = require('docmost.ui.layout')
local preview = require('docmost.ui.preview')
local auth = require('docmost.auth')
local uv = vim.uv or vim.loop

local function config()
  return require('docmost.config').get()
end

local function win_ok(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function buf_ok(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function alive(s)
  return s and M.state == s and win_ok(s.list.win) and buf_ok(s.list.buf)
end

local function ours(s, win)
  return win == s.list.win or win == s.preview_win or win == s.prompt_win or win == s.help_win
end

function M.get_session()
  local c = config()
  if not M.session or M.session.base_url ~= c.base_url then
    M.session = tree.new(c.base_url)
  end
  return M.session
end

local function scratch(name, filetype, hidden)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden = 'nofile', hidden and 'hide' or 'wipe'
  vim.bo[buf].swapfile, vim.bo[buf].undofile = false, false
  vim.api.nvim_buf_set_name(buf, name .. buf)
  vim.bo[buf].filetype = filetype
  vim.bo[buf].modifiable = false
  return buf
end

local function stop(s, name)
  local timer = s.timers[name]
  if timer then
    s.timers[name] = nil
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
end

local function later(s, name, ms, fn)
  stop(s, name)
  local timer = uv.new_timer()
  s.timers[name] = timer
  timer:start(
    ms,
    0,
    vim.schedule_wrap(function()
      if s.timers[name] == timer then
        stop(s, name)
        if alive(s) then
          fn()
        end
      end
    end)
  )
end

local function style(win, list)
  vim.wo[win].wrap = not list
  vim.wo[win].linebreak = not list
  vim.wo[win].cursorline = list
  vim.wo[win].spell, vim.wo[win].list = false, false
  vim.wo[win].sidescrolloff, vim.wo[win].scrolloff = 0, list and 2 or 0
  vim.wo[win].conceallevel = (not list and config().ui.conceal) and 2 or 0
  vim.wo[win].concealcursor = 'nc'
  vim.wo[win].winhighlight = table.concat({
    'Normal:DocmostNormal',
    'NormalFloat:DocmostNormal',
    'FloatBorder:DocmostBorder',
    'FloatTitle:DocmostTitle',
    'FloatFooter:DocmostDim',
    'CursorLine:DocmostSelection',
  }, ',')
end

local function selected(s)
  if s.showing ~= 'list' then
    return s.preview_row
  end
  return s.rows and s.rows[vim.api.nvim_win_get_cursor(s.list.win)[1]]
end

local function screen()
  return { columns = vim.o.columns, lines = vim.o.lines, cmdheight = vim.o.cmdheight }
end

local function busy(s)
  return s.auth_busy or s.preview_request ~= nil or tree.busy(M.session)
end

local function chip(s)
  local g = render.icons()
  local status = auth.status
  if s.auth_busy then
    return { ' ' .. g.loading .. ' checking session ', 'DocmostBusy' }
  elseif status == 'authenticated' then
    return { ' ' .. g.on .. ' signed in ', 'DocmostOk' }
  elseif status:match('^expired') then
    return { ' ' .. g.error .. ' session expired ', 'DocmostWarn' }
  elseif render.signed_in() then
    return { ' ' .. g.off .. ' session unchecked ', 'DocmostDim' }
  end
  return { ' ' .. g.off .. ' signed out ', 'DocmostDim' }
end

local function hints(s, width)
  local enter = config().ui.icons == 'ascii' and 'CR' or '⏎'
  local items
  if s.showing == 'preview' then
    items = { { 'p', 'back' }, { enter, 'open' }, { 'q', 'close' } }
  elseif M.session.mode == 'search' then
    items = {
      { enter, 'open' },
      { '/', 'query' },
      { 'Esc', 'browse' },
      { '.', 'actions' },
      { '?', 'help' },
    }
  else
    items = {
      { enter, 'open' },
      { 'l/h', 'tree' },
      { '/', 'search' },
      { 'p', 'preview' },
      { '.', 'actions' },
      { '?', 'help' },
    }
  end
  local chunks = {}
  for _, item in ipairs(layout.fit(items, width - 2)) do
    chunks[#chunks + 1] = { ' ' .. item[1], 'DocmostKey' }
    chunks[#chunks + 1] = { ' ' .. item[2] .. ' ', 'DocmostDim' }
  end
  return #chunks > 0 and chunks or { { ' ? ', 'DocmostKey' } }
end

local function decorate(s)
  if config().ui.border == 'none' or not alive(s) then
    return
  end
  local g = render.icons()
  local width = vim.api.nvim_win_get_width(s.list.win)
  local title = { { ' docmost ', 'DocmostBrand' } }
  local status = chip(s)
  local host = ' ' .. config().authority .. ' '
  local spin = busy(s)
      and not s.auth_busy
      and { ' ' .. g.spinner[s.frame % #g.spinner + 1] .. ' ', 'DocmostBusy' }
    or nil
  local used = 9 + vim.fn.strdisplaywidth(status[1]) + (spin and 3 or 0)
  if s.showing == 'preview' then
    local crumbs = preview.crumbs(s.preview_row)
    title[#title + 1] = {
      ' ' .. layout.truncate(crumbs ~= '' and crumbs or 'preview', width - 12, g.ellipsis) .. ' ',
      'DocmostTitle',
    }
  else
    if used + vim.fn.strdisplaywidth(host) <= width - 2 then
      title[#title + 1] = { host, 'DocmostTitle' }
    end
    if spin then
      title[#title + 1] = spin
    end
    if used <= width - 2 then
      title[#title + 1] = status
    end
  end
  vim.api.nvim_win_set_config(s.list.win, {
    title = title,
    title_pos = 'left',
    footer = hints(s, width),
    footer_pos = 'left',
  })
  if win_ok(s.preview_win) then
    local pwidth = vim.api.nvim_win_get_width(s.preview_win)
    local crumbs = preview.crumbs(s.preview_row)
    vim.api.nvim_win_set_config(s.preview_win, {
      title = {
        {
          ' '
            .. layout.truncate(crumbs ~= '' and crumbs or 'preview', pwidth - 4, g.ellipsis)
            .. ' ',
          'DocmostTitle',
        },
      },
      title_pos = 'left',
      footer = { { ' read-only preview ', 'DocmostDim' } },
      footer_pos = 'right',
    })
  end
  if win_ok(s.prompt_win) then
    vim.api.nvim_win_set_config(s.prompt_win, {
      title = { { ' search ', 'DocmostTitle' } },
      title_pos = 'left',
    })
  end
end

local function spinner(s)
  if busy(s) and not s.timers.spin then
    local timer = uv.new_timer()
    s.timers.spin = timer
    timer:start(
      120,
      120,
      vim.schedule_wrap(function()
        if s.timers.spin ~= timer then
          return
        end
        if not alive(s) or not busy(s) then
          stop(s, 'spin')
          if alive(s) then
            decorate(s)
          end
          return
        end
        s.frame = s.frame + 1
        decorate(s)
      end)
    )
  end
end

local prefix = ' / '

local function query_text(s)
  if not buf_ok(s.prompt_buf) then
    return M.session.search.query
  end
  local line = vim.api.nvim_buf_get_lines(s.prompt_buf, 0, 1, false)[1] or ''
  if line:sub(1, #prefix) == prefix then
    line = line:sub(#prefix + 1)
  end
  return line
end

local open_prompt

local function place(s)
  local c = config().ui
  local session = M.session
  local L = layout.compute(
    screen(),
    c,
    { search = session.mode == 'search', preview = not session.preview_hidden }
  )
  s.layout = L
  local base = { border = c.border, style = 'minimal', zindex = 50 }
  if win_ok(s.list.win) then
    vim.api.nvim_win_set_config(s.list.win, vim.tbl_extend('force', L.list, { border = c.border }))
  else
    s.list.win = vim.api.nvim_open_win(s.list.buf, true, vim.tbl_extend('force', L.list, base))
    style(s.list.win, true)
  end
  if L.preview then
    if s.showing == 'preview' then
      s.showing = 'list'
      vim.api.nvim_win_set_buf(s.list.win, s.list.buf)
      style(s.list.win, true)
    end
    if win_ok(s.preview_win) then
      vim.api.nvim_win_set_config(
        s.preview_win,
        vim.tbl_extend('force', L.preview, { border = c.border })
      )
    else
      s.preview_win = vim.api.nvim_open_win(
        s.preview_buf,
        false,
        vim.tbl_extend('force', L.preview, base, { focusable = false })
      )
      style(s.preview_win, false)
    end
  elseif win_ok(s.preview_win) then
    local win = s.preview_win
    s.preview_win = nil
    vim.api.nvim_win_close(win, true)
  end
  if L.prompt then
    if win_ok(s.prompt_win) then
      vim.api.nvim_win_set_config(
        s.prompt_win,
        vim.tbl_extend('force', L.prompt, { border = c.border })
      )
    else
      open_prompt(s, vim.tbl_extend('force', L.prompt, base, { zindex = 51 }))
    end
  elseif s.prompt_win then
    local win, buf = s.prompt_win, s.prompt_buf
    s.prompt_win, s.prompt_buf = nil, nil
    if win_ok(win) then
      vim.api.nvim_win_close(win, true)
    end
    if buf_ok(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  decorate(s)
end

local function show_preview(s, fetch)
  local target = s.showing == 'preview' and s.list.win or s.preview_win
  if not win_ok(target) then
    return
  end
  local row = s.preview_row
  local remote = config().ui.preview
  local lines, marks, id, body =
    preview.build(M.session, row, vim.api.nvim_win_get_width(target), { remote = remote })
  preview.draw(s.preview_buf, lines, marks, body)
  decorate(s)
  if not id or not fetch then
    return
  end
  if s.preview_id == id and s.preview_request then
    return
  end
  if s.preview_request then
    s.preview_request.cancel()
  end
  s.preview_token = (s.preview_token or 0) + 1
  local token = s.preview_token
  s.preview_id = id
  s.preview_request = require('docmost.api').read(id, function(err, page)
    if not alive(s) or s.preview_token ~= token then
      return
    end
    s.preview_request, s.preview_id = nil, nil
    if err then
      if err.kind ~= 'cancelled' then
        M.session.preview_errors[id] = err.message
      end
    else
      preview.remember(M.session, id, page)
    end
    if preview.id(s.preview_row) == id then
      show_preview(s, false)
    end
    if err and err.kind == 'auth' then
      M.render()
    end
    decorate(s)
  end)
  spinner(s)
end

local function on_cursor(s)
  if not alive(s) or s.showing ~= 'list' then
    return
  end
  local row = selected(s)
  local session = M.session
  if row and row.key then
    session.cursor[session.mode] = row.key
  end
  s.last_line = vim.api.nvim_win_get_cursor(s.list.win)[1]
  session.topline[session.mode] = vim.api.nvim_win_call(s.list.win, function()
    return vim.fn.line('w0')
  end)
  local previous = s.preview_row
  s.preview_row = row
  if previous and row and previous.key == row.key and previous.kind == row.kind then
    return
  end
  local id = preview.id(row)
  if s.preview_request and s.preview_id ~= id then
    s.preview_token = s.preview_token + 1
    s.preview_request.cancel()
    s.preview_request, s.preview_id = nil, nil
  end
  show_preview(s, false)
  if id and not session.previews[id] and not require('docmost.buffer').states[id] then
    later(s, 'preview', config().ui.preview_debounce_ms, function()
      if preview.id(s.preview_row) == id then
        show_preview(s, true)
      end
    end)
  end
end

local function restore(s, rows)
  local session = M.session
  local want = session.cursor[session.mode]
  local index = {}
  for number, spec in ipairs(rows) do
    if spec.key then
      index[spec.key] = number
    end
  end
  local target = want and index[want]
  if not target and want then
    local node = session.nodes[want:gsub('^%a+:', '', 1)] or session.nodes[want]
    while node and not target do
      target = index[node.key]
      node = node.parent
    end
  end
  if not target then
    local from = math.min(s.last_line or 1, #rows)
    for number = from, #rows do
      if rows[number].selectable then
        target = number
        break
      end
    end
    for number = from, 1, -1 do
      if target then
        break
      end
      if rows[number].selectable then
        target = number
      end
    end
  end
  return target or 1
end

function M.render()
  local s = M.state
  if not alive(s) then
    return
  end
  local session = M.session
  local ctx = {
    origin = s.origin_page,
    notice = s.notice,
    auth_busy = s.auth_busy,
    width = vim.api.nvim_win_get_width(s.list.win),
  }
  local rows = session.mode == 'search' and render.results(session, ctx)
    or render.browse(session, ctx)
  s.rows = rows
  render.draw(s.list.buf, rows, vim.api.nvim_win_get_width(s.list.win))
  if s.showing == 'list' then
    local target = restore(s, rows)
    vim.api.nvim_win_set_cursor(s.list.win, { target, 0 })
    if s.restore_topline then
      s.restore_topline = false
      local top = session.topline[session.mode]
      if top then
        vim.api.nvim_win_call(s.list.win, function()
          vim.fn.winrestview({ topline = math.min(top, target), lnum = target, col = 0 })
        end)
      end
    end
    on_cursor(s)
  end
  if s.preview_row and s.preview_row.key then
    for _, spec in ipairs(rows) do
      if spec.key == s.preview_row.key then
        s.preview_row = spec
      end
    end
  end
  show_preview(s, false)
  spinner(s)
  decorate(s)
end

local function notice(s, text, group, glyph)
  if not s or M.state ~= s then
    return
  end
  s.notice = text and { text = text, group = group or 'DocmostInfo', glyph = glyph } or nil
end

local function fetch(node, more)
  local s = M.state
  tree.fetch(M.session, node, more, function()
    if alive(s) then
      M.render()
    end
  end)
  if alive(s) then
    M.render()
  end
end

local function resume(s)
  if not render.signed_in() then
    return
  end
  local session = M.session
  if not session.root.children and not session.root.error then
    if auth.status == 'authenticated' then
      fetch(session.root)
    end
  end
  for _, node in pairs(session.nodes) do
    if node.kind ~= 'root' and node.expanded and not node.children and not node.error then
      fetch(node)
    end
  end
  local search = session.search
  if session.mode == 'search' and search.pages == 0 and #vim.trim(search.query) >= 2 then
    tree.search(session, search.query, false, function()
      if alive(s) then
        M.render()
      end
    end)
  end
end

function M.select(key)
  local s = M.state
  if not alive(s) then
    return
  end
  M.session.cursor[M.session.mode] = key
  M.render()
end

function M.move(delta)
  local s = M.state
  if not alive(s) or s.showing ~= 'list' then
    return
  end
  local current, candidates = vim.api.nvim_win_get_cursor(s.list.win)[1], {}
  for number, spec in ipairs(s.rows) do
    if spec.selectable then
      candidates[#candidates + 1] = number
    end
  end
  local target
  if delta == math.huge then
    target = candidates[#candidates]
  elseif delta == -math.huge then
    target = candidates[1]
  elseif delta > 0 then
    for _, number in ipairs(candidates) do
      if number > current then
        target = number
        break
      end
    end
  else
    for i = #candidates, 1, -1 do
      if candidates[i] < current then
        target = candidates[i]
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(s.list.win, { target, 0 })
    on_cursor(s)
  end
end

local function first_normal_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == '' then
      return win
    end
  end
end

local function focus_origin(s)
  local target = s.origin_win
  if not win_ok(target) or vim.api.nvim_win_get_config(target).relative ~= '' then
    target = first_normal_window()
  end
  if target then
    vim.api.nvim_set_current_win(target)
  end
end

local function open_page(id, how)
  local s = M.state
  M.close({ focus = false })
  focus_origin(s)
  if how == 'vsplit' then
    vim.cmd('vsplit')
  elseif how == 'split' then
    vim.cmd('split')
  elseif how == 'tab' then
    vim.cmd('tab split')
  end
  require('docmost.buffer').open(id)
end

function M.close(opts)
  local s = M.state
  if not s then
    return
  end
  opts = opts or {}
  M.state = nil
  local session = M.session
  if win_ok(s.list.win) and s.showing == 'list' then
    session.topline[session.mode] = vim.api.nvim_win_call(s.list.win, function()
      return vim.fn.line('w0')
    end)
  end
  tree.cancel(session)
  if s.preview_request then
    s.preview_request.cancel()
  end
  if s.auth_request then
    s.auth_request.cancel()
  end
  for name in pairs(s.timers) do
    stop(s, name)
  end
  pcall(vim.api.nvim_del_augroup_by_id, s.group)
  for _, key in ipairs({ 'help_win', 'prompt_win', 'preview_win' }) do
    if win_ok(s[key]) then
      pcall(vim.api.nvim_win_close, s[key], true)
    end
  end
  if win_ok(s.list.win) then
    pcall(vim.api.nvim_win_close, s.list.win, true)
  end
  for _, key in ipairs({ 'help_buf', 'prompt_buf', 'preview_buf' }) do
    if buf_ok(s[key]) then
      pcall(vim.api.nvim_buf_delete, s[key], { force = true })
    end
  end
  if buf_ok(s.list.buf) then
    pcall(vim.api.nvim_buf_delete, s.list.buf, { force = true })
  end
  if opts.focus ~= false and win_ok(s.origin_win) then
    vim.api.nvim_set_current_win(s.origin_win)
  end
end

function M.validate()
  local s = M.state
  if not alive(s) or s.auth_busy then
    return
  end
  s.auth_busy = true
  s.auth_request = auth.validate(function(err)
    if M.state ~= s then
      return
    end
    s.auth_busy, s.auth_request = false, nil
    if err then
      if err.kind ~= 'auth' then
        notice(s, err.message .. '  r retries', 'DocmostError', render.icons().error)
      end
    else
      resume(s)
    end
    M.render()
  end)
  M.render()
end

local function run_search(s, query, more)
  tree.search(M.session, query, more, function()
    if alive(s) then
      M.render()
    end
  end)
  M.render()
end

function M.login()
  local s = M.state
  if not alive(s) or s.auth_busy then
    return
  end
  s.auth_busy = true
  M.render()
  require('docmost').login(function(err)
    if M.state == s then
      s.auth_busy = false
    end
    if err then
      if err.kind == 'cancelled' then
        notice(s, 'Sign-in cancelled', 'DocmostDim')
      else
        notice(
          s,
          require('docmost.status').explain(err.message),
          'DocmostError',
          render.icons().error
        )
      end
      M.render()
      return
    end
    local session = M.session
    for _, node in pairs(session.nodes) do
      node.error = nil
    end
    session.search.error = nil
    session.preview_errors = {}
    if not alive(s) then
      return
    end
    notice(s, 'Signed in', 'DocmostOk')
    resume(s)
    if session.mode == 'search' then
      run_search(s, session.search.query, false)
    end
    M.render()
  end)
end

function M.logout()
  local s = M.state
  if not alive(s) then
    return
  end
  tree.cancel(M.session)
  if s.preview_request then
    s.preview_request.cancel()
    s.preview_request = nil
  end
  auth.logout()
  s.auth_busy, s.auth_request = false, nil
  tree.forget(M.session)
  s.preview_row = nil
  place(s)
  notice(s, 'Signed out locally. Open pages keep their edits.', 'DocmostInfo')
  M.render()
end

function M.search()
  local s = M.state
  if not alive(s) then
    return
  end
  if s.showing == 'preview' then
    M.toggle_preview()
  end
  notice(s, nil)
  local session = M.session
  if session.mode ~= 'search' then
    session.mode = 'search'
    session.cursor.search = nil
    s.last_line = 1
    place(s)
    M.render()
  end
  if win_ok(s.prompt_win) then
    vim.api.nvim_set_current_win(s.prompt_win)
    vim.cmd('startinsert!')
  end
end

function M.focus_results()
  local s = M.state
  if not alive(s) then
    return
  end
  vim.cmd('stopinsert')
  if s.timers.search then
    stop(s, 'search')
    run_search(s, query_text(s), false)
  end
  vim.api.nvim_set_current_win(s.list.win)
  local row = selected(s)
  if not (row and row.selectable) then
    M.move(1)
  end
  on_cursor(s)
end

function M.leave_search()
  local s = M.state
  if not alive(s) or M.session.mode ~= 'search' then
    return
  end
  vim.cmd('stopinsert')
  stop(s, 'search')
  local search = M.session.search
  if search.request then
    search.token = search.token + 1
    search.request.cancel()
    search.request, search.loading = nil, false
  end
  M.session.mode = 'browse'
  vim.api.nvim_set_current_win(s.list.win)
  s.restore_topline = true
  place(s)
  M.render()
end

function M.typed(s)
  if not alive(s) then
    return
  end
  local query = query_text(s)
  if query == M.session.search.query and not s.timers.search then
    return
  end
  later(s, 'search', config().ui.search_debounce_ms, function()
    run_search(s, query_text(s), false)
  end)
end

open_prompt = function(s, geometry)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'prompt', 'hide', false
  vim.bo[buf].undofile = false
  vim.api.nvim_buf_set_name(buf, 'docmost-search://' .. buf)
  vim.bo[buf].filetype = 'docmostsearch'
  vim.b[buf].completion = false
  vim.fn.prompt_setprompt(buf, prefix)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { prefix .. M.session.search.query })
  s.prompt_buf = buf
  s.prompt_win = vim.api.nvim_open_win(buf, false, geometry)
  style(s.prompt_win, false)
  vim.wo[s.prompt_win].wrap = false
  vim.api.nvim_buf_set_extmark(
    buf,
    render.ns,
    0,
    0,
    { end_col = #prefix, hl_group = 'DocmostPromptPrefix', right_gravity = false }
  )
  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, silent = true, nowait = true })
  end
  for _, lhs in ipairs({ '<CR>', '<Down>', '<C-n>', '<C-j>', '<Tab>', '<Esc>' }) do
    map('i', lhs, M.focus_results)
  end
  for _, lhs in ipairs({ '<CR>', '<Esc>', 'j', '<Down>' }) do
    map('n', lhs, M.focus_results)
  end
  map({ 'i', 'n' }, '<C-c>', M.leave_search)
  map('n', 'q', M.close)
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = s.group,
    buffer = buf,
    callback = function()
      M.typed(s)
    end,
  })
end

function M.toggle_preview()
  local s = M.state
  if not alive(s) then
    return
  end
  local session = M.session
  local capable = layout.compute(screen(), config().ui, { preview = true }).mode == 'wide'
  if capable then
    session.preview_hidden = not session.preview_hidden
    place(s)
    M.render()
    return
  end
  if s.showing == 'list' then
    s.preview_row = selected(s)
    s.showing = 'preview'
    vim.api.nvim_win_set_buf(s.list.win, s.preview_buf)
    style(s.list.win, false)
    show_preview(s, true)
  else
    s.showing = 'list'
    vim.api.nvim_win_set_buf(s.list.win, s.list.buf)
    style(s.list.win, true)
    M.render()
  end
end

function M.expand()
  local s = M.state
  local row = alive(s) and selected(s)
  if not row or not row.node or row.kind == 'root' then
    return
  end
  local node = row.node
  if row.kind == 'more' or row.kind == 'error' then
    return
  end
  if node.leaf then
    notice(s, 'No child pages', 'DocmostDim')
    M.render()
    return
  end
  if node.expanded and node.children and #node.children > 0 then
    M.select(node.children[1].key)
    return
  end
  node.expanded = true
  if not node.children or node.error then
    fetch(node)
  else
    M.render()
  end
end

function M.collapse()
  local s = M.state
  local row = alive(s) and selected(s)
  if not row or not row.node then
    return
  end
  local node = row.node
  if (row.kind == 'space' or row.kind == 'page') and node.expanded then
    node.expanded = false
    M.render()
  elseif (row.kind == 'more' or row.kind == 'error') and node.kind ~= 'root' then
    M.select(node.key)
  elseif node.parent and node.parent.kind ~= 'root' then
    M.select(node.parent.key)
  end
end

function M.top()
  local s = M.state
  local row = alive(s) and selected(s)
  local node = row and row.node
  while node and node.kind ~= 'space' do
    node = node.parent
  end
  if node then
    node.expanded = false
    M.select(node.key)
  end
end

local function target_page(s)
  local row = selected(s)
  local buffers = require('docmost.buffer')
  if row and row.kind == 'open' then
    return row.page
  end
  local id = preview.id(row)
  return (id and buffers.states[id]) or (s.origin_page and buffers.states[s.origin_page])
end

function M.page_action(what)
  local s = M.state
  if not alive(s) then
    return
  end
  local page = target_page(s)
  if not page then
    notice(s, 'Open a page first. w, R and d act on open pages.', 'DocmostWarn')
    M.render()
    return
  end
  local buffers = require('docmost.buffer')
  local loaded = buf_ok(page.buf) and vim.api.nvim_buf_is_loaded(page.buf)
  if what == 'save' then
    if not loaded then
      notice(s, 'That page buffer is closed. Open it again to save.', 'DocmostWarn')
      M.render()
      return
    end
    buffers.save(page.buf, function(err, result)
      local text = err and require('docmost.status').explain(err.message)
        or (result == 'noop' and 'No changes to save' or 'Save verified by repeated read-back')
      if alive(s) then
        notice(s, text, err and 'DocmostError' or 'DocmostOk', err and render.icons().error or nil)
        M.render()
      else
        vim.notify('docmost: ' .. text, err and vim.log.levels.ERROR or vim.log.levels.INFO)
      end
    end)
    M.render()
    return
  end
  M.close({ focus = false })
  focus_origin(s)
  if not loaded then
    buffers.open(page.id)
    return
  end
  vim.api.nvim_set_current_buf(page.buf)
  if what == 'reload' then
    buffers.reload(false)
  else
    require('docmost.conflict').show(page)
  end
end

function M.open_by_id()
  local s = M.state
  if not alive(s) then
    return
  end
  vim.ui.input({ prompt = 'Docmost page URL or ID: ' }, function(value)
    if alive(s) and value and value ~= '' then
      local id, why = require('docmost.api').identifier(value)
      if not id then
        notice(s, why, 'DocmostError', render.icons().error)
        M.render()
        return
      end
      open_page(id)
    end
  end)
end

function M.action(name)
  local s = M.state
  if not alive(s) then
    return
  end
  if name == 'login' then
    M.login()
  elseif name == 'logout' then
    M.logout()
  elseif name == 'open' then
    M.open_by_id()
  elseif name == 'search' then
    M.search()
  elseif name == 'save' or name == 'reload' or name == 'diff' then
    M.page_action(name)
  end
end

function M.activate(how)
  local s = M.state
  local row = alive(s) and selected(s)
  if not row then
    return
  end
  local id = preview.id(row)
  if id then
    open_page(id, how)
  elseif how then
    return
  elseif row.kind == 'space' then
    if row.node.expanded then
      row.node.expanded = false
      M.render()
    else
      M.expand()
    end
  elseif row.kind == 'more' then
    if row.search then
      run_search(s, M.session.search.query, true)
    else
      fetch(row.node, true)
    end
  elseif row.kind == 'error' then
    M.refresh()
  elseif row.kind == 'action' then
    M.action(row.action)
  end
end

function M.refresh()
  local s = M.state
  if not alive(s) then
    return
  end
  notice(s, nil)
  local session = M.session
  local row = selected(s)
  local id = preview.id(row)
  if session.mode == 'search' and not id then
    run_search(s, session.search.query, false)
    return
  end
  if id then
    session.previews[id], session.preview_errors[id] = nil, nil
    if row.node and row.node.expanded then
      fetch(row.node)
    end
    s.preview_row = nil
    on_cursor(s)
    show_preview(s, true)
    return
  end
  local node = row and row.node
  if node and (node.kind ~= 'root' or render.signed_in()) then
    fetch(node)
  elseif render.signed_in() then
    if auth.status == 'authenticated' then
      fetch(session.root)
    else
      M.validate()
    end
  else
    M.render()
  end
end

function M.actions()
  local s = M.state
  if not alive(s) then
    return
  end
  local row = selected(s)
  local id = preview.id(row)
  local items = {}
  local function add(label, fn)
    items[#items + 1] = { label, fn }
  end
  if id then
    add('Open page', function()
      open_page(id)
    end)
    add('Open in vertical split', function()
      open_page(id, 'vsplit')
    end)
    add('Open in horizontal split', function()
      open_page(id, 'split')
    end)
    add('Open in new tab', function()
      open_page(id, 'tab')
    end)
    if row.kind == 'page' and not row.node.leaf then
      add('Show child pages', M.expand)
    end
    add('Refresh preview', M.refresh)
    add('Copy page ID to the unnamed register', function()
      vim.fn.setreg('"', id)
      notice(s, 'Copied page ID', 'DocmostOk')
      M.render()
    end)
    if require('docmost.buffer').states[id] then
      add('Save and verify', function()
        M.page_action('save')
      end)
      add('Reload clean page', function()
        M.page_action('reload')
      end)
      add('Diff base, local and remote', function()
        M.page_action('diff')
      end)
    end
  elseif row and row.kind == 'space' then
    add(row.node.expanded and 'Collapse space' or 'Expand space', function()
      M.activate()
    end)
    add('Refresh pages', M.refresh)
  end
  add('Search pages', M.search)
  add('Open a page by URL or ID', M.open_by_id)
  if render.signed_in() then
    add('Sign out locally', M.logout)
  else
    add('Sign in', M.login)
  end
  add('Keyboard help', function()
    M.help()
  end)
  vim.ui.select(items, {
    prompt = 'Docmost',
    format_item = function(item)
      return item[1]
    end,
  }, function(choice)
    if choice and alive(s) then
      vim.api.nvim_set_current_win(s.list.win)
      choice[2]()
    end
  end)
end

local function close_help(s)
  local win, buf = s.help_win, s.help_buf
  s.help_win, s.help_buf = nil, nil
  if win_ok(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf_ok(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

local function help_window(only_editing, zindex)
  local c = config().ui
  local width = math.max(20, math.min(80, vim.o.columns - 4))
  local help = require('docmost.ui.help')
  local lines, marks
  if only_editing == 'cheatsheet' then
    lines, marks = help.sheet(width)
  else
    lines, marks = help.build(width, only_editing)
  end
  local widest = 0
  for _, line in ipairs(lines) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width, widest + 2)
  local available = math.max(3, vim.o.lines - vim.o.cmdheight - 4)
  local height = math.min(#lines, available)
  local buf = scratch('docmost-help://', 'docmosthelp', true)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, render.ns, m[1], 0, {
      end_row = m[3] and m[1] or m[1] + 1,
      end_col = m[3],
      hl_group = m[2],
    })
  end
  local geometry = {
    relative = 'editor',
    row = math.max(0, math.floor((available - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = c.border,
    style = 'minimal',
    zindex = zindex,
  }
  if c.border ~= 'none' then
    local names = { cheatsheet = ' cheatsheet ', [true] = ' editing guide ' }
    geometry.title = { { names[only_editing] or ' help ', 'DocmostBrand' } }
    geometry.title_pos = 'left'
  end
  local win = vim.api.nvim_open_win(buf, true, geometry)
  style(win, false)
  return win, buf
end

function M.help(only_editing)
  local s = M.state
  if not alive(s) then
    return
  end
  if s.help_win then
    close_help(s)
    vim.api.nvim_set_current_win(s.list.win)
    return
  end
  s.help_win, s.help_buf = help_window(only_editing, 60)
  for _, lhs in ipairs({ 'q', '?', '<Esc>' }) do
    vim.keymap.set('n', lhs, function()
      if M.state == s then
        close_help(s)
        if alive(s) then
          vim.api.nvim_set_current_win(s.list.win)
        end
      end
    end, { buffer = s.help_buf, silent = true, nowait = true })
  end
end

function M.guide(mode)
  mode = mode or true
  if M.state and alive(M.state) then
    M.help(mode)
    return
  end
  local origin = vim.api.nvim_get_current_win()
  local win, buf = help_window(mode, 60)
  for _, lhs in ipairs({ 'q', '?', '<Esc>' }) do
    vim.keymap.set('n', lhs, function()
      if win_ok(win) then
        vim.api.nvim_win_close(win, true)
      end
      if win_ok(origin) then
        vim.api.nvim_set_current_win(origin)
      end
    end, { buffer = buf, silent = true, nowait = true })
  end
  return win, buf
end

local function keymaps(s)
  local function map(lhs, fn, buf)
    vim.keymap.set('n', lhs, fn, { buffer = buf or s.list.buf, silent = true, nowait = true })
  end
  map('q', M.close)
  map('<Esc>', function()
    if M.session.mode == 'search' then
      M.leave_search()
    else
      M.close()
    end
  end)
  map('<C-c>', M.leave_search)
  for _, lhs in ipairs({ 'j', '<Down>' }) do
    map(lhs, function()
      M.move(1)
    end)
  end
  for _, lhs in ipairs({ 'k', '<Up>' }) do
    map(lhs, function()
      M.move(-1)
    end)
  end
  map('gg', function()
    M.move(-math.huge)
  end)
  map('G', function()
    M.move(math.huge)
  end)
  for _, lhs in ipairs({ '<CR>', '<2-LeftMouse>' }) do
    map(lhs, function()
      M.activate()
    end)
  end
  for _, lhs in ipairs({ 'l', '<Right>' }) do
    map(lhs, M.expand)
  end
  for _, lhs in ipairs({ 'h', '<Left>' }) do
    map(lhs, M.collapse)
  end
  for _, lhs in ipairs({ '-', '<BS>' }) do
    map(lhs, M.top)
  end
  for lhs, how in pairs({ ['<C-v>'] = 'vsplit', ['<C-x>'] = 'split', ['<C-t>'] = 'tab' }) do
    map(lhs, function()
      M.activate(how)
    end)
  end
  map('/', M.search)
  map('o', M.open_by_id)
  map('p', M.toggle_preview)
  map('r', M.refresh)
  map('.', M.actions)
  map('a', M.login)
  map('L', M.logout)
  for lhs, what in pairs({ w = 'save', R = 'reload', d = 'diff' }) do
    map(lhs, function()
      M.page_action(what)
    end)
  end
  map('?', function()
    M.help()
  end)
  for _, lhs in ipairs({ 'p', '<Esc>', 'h', '<BS>' }) do
    map(lhs, M.toggle_preview, s.preview_buf)
  end
  map('q', M.close, s.preview_buf)
  map('<CR>', function()
    local id = preview.id(s.preview_row)
    if id then
      open_page(id)
    end
  end, s.preview_buf)
end

local function autocmds(s)
  local group = s.group
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      local win = tonumber(args.match)
      if win == s.help_win then
        s.help_win = nil
        vim.schedule(function()
          if alive(s) then
            close_help(s)
          end
        end)
      elseif win == s.list.win or win == s.preview_win or win == s.prompt_win then
        vim.schedule(function()
          if M.state == s then
            M.close()
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      vim.schedule(function()
        if not alive(s) then
          return
        end
        local win = vim.api.nvim_get_current_win()
        if win == s.preview_win then
          vim.api.nvim_set_current_win(s.list.win)
        elseif not ours(s, win) and vim.api.nvim_win_get_config(win).relative == '' then
          M.close({ focus = false })
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(args)
      if args.buf == s.list.buf or args.buf == s.preview_buf then
        vim.schedule(function()
          if M.state == s then
            M.close()
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if alive(s) then
        place(s)
        M.render()
      end
    end,
  })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = s.list.buf,
    callback = function()
      on_cursor(s)
    end,
  })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DocmostPageStatus',
    callback = function()
      if alive(s) then
        M.render()
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufModifiedSet', {
    group = group,
    callback = function(args)
      if alive(s) and require('docmost.buffer').current(args.buf) then
        M.render()
      end
    end,
  })
end

function M.open()
  if M.state and alive(M.state) then
    vim.api.nvim_set_current_win(M.state.list.win)
    M.render()
    return
  end
  if M.state then
    M.close({ focus = false })
  end
  local session = M.get_session()
  local origin_win = vim.api.nvim_get_current_win()
  local origin_buf = vim.api.nvim_get_current_buf()
  local page = require('docmost.buffer').current(origin_buf)
  local s = {
    origin_win = origin_win,
    origin_buf = origin_buf,
    origin_page = page and page.id,
    timers = {},
    showing = 'list',
    restore_topline = true,
    frame = 0,
    group = vim.api.nvim_create_augroup('DocmostWorkspace', { clear = true }),
  }
  s.list = { buf = scratch('docmost-workspace://', 'docmost', true) }
  s.preview_buf = scratch('docmost-preview://', 'markdown', true)
  M.state = s
  if page and not session.cursor.browse then
    session.cursor.browse = 'open:' .. page.id
  end
  place(s)
  keymaps(s)
  autocmds(s)
  M.render()
  if session.mode == 'search' then
    vim.api.nvim_set_current_win(s.list.win)
  end
  if render.signed_in() and auth.status ~= 'authenticated' then
    M.validate()
  else
    resume(s)
  end
end

return M
