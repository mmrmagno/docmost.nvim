require('docmost').setup({
  base_url = vim.env.DOCMOST_TEST_URL,
  allow_insecure_localhost = true,
  state_dir = vim.env.DOCMOST_TEST_DIR .. '/ui-state',
  timeout_ms = 700,
  verify_timeout_ms = 600,
  verify_interval_ms = 20,
  page_size = 2,
  ui = { search_debounce_ms = 60, preview_debounce_ms = 30 },
})
local ui, auth, http = require('docmost.ui'), require('docmost.auth'), require('docmost.http')
local buffers, status = require('docmost.buffer'), require('docmost.status')
local checks = 0
local function eq(a, b)
  assert(vim.deep_equal(a, b), 'expected ' .. vim.inspect(b) .. ', got ' .. vim.inspect(a))
  checks = checks + 1
end
local function ok(value, message)
  assert(value, message or 'assertion failed')
  checks = checks + 1
end
local function await(predicate, message)
  assert(vim.wait(4000, predicate, 5), message or 'UI operation timed out')
end
local function post(route, payload)
  local done, error, result
  http.post(route, payload, nil, function(e, d)
    done, error, result = true, e, d
  end)
  await(function()
    return done
  end)
  assert(not error, vim.inspect(error))
  return result
end
local function text(buf)
  buf = buf or ui.state.list.buf
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end
local function key(lhs, buf)
  for _, binding in ipairs(vim.api.nvim_buf_get_keymap(buf or ui.state.list.buf, 'n')) do
    if vim.keycode(binding.lhs) == vim.keycode(lhs) then
      binding.callback()
      return
    end
  end
  error('Missing key: ' .. lhs)
end
local function row(wanted)
  ui.select(wanted)
  local current = ui.state.rows[vim.api.nvim_win_get_cursor(ui.state.list.win)[1]]
  assert(current and current.key == wanted, 'Missing workspace row ' .. wanted)
  return current
end
local function has(wanted)
  for _, spec in ipairs(ui.state.rows) do
    if spec.key == wanted then
      return spec
    end
  end
end
local function idle()
  await(function()
    return ui.state and next(http.active) == nil and not ui.state.auth_busy
  end)
end
local function floats()
  local count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then
      count = count + 1
    end
  end
  return count
end
local function searches()
  local n = 0
  for _, entry in ipairs(post('/stats', {}).trace) do
    if entry[1] == '/search' then
      n = n + 1
    end
  end
  return n
end
local function type_query(query)
  vim.api.nvim_buf_set_lines(ui.state.prompt_buf, 0, -1, false, { ' / ' .. query })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = ui.state.prompt_buf })
end
local function sign_in()
  local input, secret = vim.ui.input, vim.fn.inputsecret
  vim.ui.input = function(_, cb)
    cb('ui-test@example.test')
  end
  vim.fn.inputsecret = function()
    return vim.env.DOCMOST_TEST_PASSWORD
  end
  key('a')
  vim.ui.input, vim.fn.inputsecret = input, secret
  idle()
end
local function test(name, fn)
  fn()
  print('PASS UI ' .. name)
end

local function run()
  vim.o.columns, vim.o.lines = 140, 40
  post('/control', { reset = true })
  test('command opens a safe workspace that owns its windows', function()
    local origin_win, origin = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    vim.cmd('Docmost')
    local s = ui.state
    eq(vim.api.nvim_get_current_win(), s.list.win)
    eq(vim.bo[s.list.buf].buftype, 'nofile')
    eq(vim.bo[s.list.buf].filetype, 'docmost')
    eq(vim.bo[s.list.buf].modifiable, false)
    eq(vim.bo[s.list.buf].swapfile, false)
    eq(vim.api.nvim_win_get_config(s.preview_win).focusable, false)
    eq(vim.bo[s.preview_buf].buftype, 'nofile')
    eq(vim.bo[s.preview_buf].modifiable, false)
    ok(not vim.api.nvim_buf_get_name(s.preview_buf):find('^docmost://'))
    ok(has('action:login'), 'signed-out card offers sign in')
    ok(text():find('secret prompt', 1, true))
    local title = vim.api.nvim_win_get_config(s.list.win).title
    eq(title[1][1], ' docmost ')
    vim.cmd('Docmost ui')
    eq(ui.state, s)
    key('?')
    ok(vim.api.nvim_win_is_valid(s.help_win))
    ok(text(s.help_buf):find('Adding blocks', 1, true))
    key('q', s.help_buf)
    eq(s.help_win, nil)
    eq(vim.api.nvim_get_current_win(), s.list.win)
    key('q')
    eq(ui.state, nil)
    eq(floats(), 0)
    eq(vim.api.nvim_get_current_win(), origin_win)
    eq(vim.api.nvim_get_current_buf(), origin)
  end)

  test('sign in stays in the secret prompt and spaces load automatically', function()
    ui.open()
    sign_in()
    eq(auth.status, 'authenticated')
    ok(has('space:root-1'), 'spaces listed after sign in')
    eq(ui.state.notice.text, 'Signed in')
    ui.help()
    for _, buf in ipairs({ ui.state.list.buf, ui.state.preview_buf, ui.state.help_buf }) do
      local shown = text(buf)
      eq(shown:find(vim.env.DOCMOST_TEST_PASSWORD, 1, true), nil)
      eq(shown:find(vim.env.DOCMOST_TEST_TOKEN, 1, true), nil)
      eq(shown:find('ui-test@example.test', 1, true), nil)
    end
    local messages = vim.fn.execute('messages')
    eq(messages:find(vim.env.DOCMOST_TEST_PASSWORD, 1, true), nil)
    eq(messages:find(vim.env.DOCMOST_TEST_TOKEN, 1, true), nil)
    ui.help()
  end)

  test('tree expands on demand, paginates per node and walks back to parents', function()
    post('/control', { reset = true })
    row('more:root')
    key('<CR>')
    idle()
    ok(has('space:root-2'), 'second space page')
    row('space:root-1')
    key('l')
    idle()
    ok(has('page:root-1'), 'root pages of the space')
    row('page:root-1')
    key('l')
    idle()
    ok(has('page:child-1'), 'children loaded on demand')
    row('more:page:root-1')
    key('<CR>')
    idle()
    ok(has('page:child-2'), 'child pagination')
    row('page:child-2')
    local crumbs = vim.api.nvim_win_get_config(ui.state.preview_win).title[1][1]
    ok(crumbs:find('Root › Root › Child', 1, true), crumbs)
    key('h')
    eq(ui.state.rows[vim.api.nvim_win_get_cursor(ui.state.list.win)[1]].key, 'page:root-1')
    key('h')
    eq(has('page:child-1'), nil)
    key('l')
    ok(has('page:child-1'), 'expanding again reuses loaded children')
    key('-')
    eq(ui.state.rows[vim.api.nvim_win_get_cursor(ui.state.list.win)[1]].key, 'space:root-1')
    eq(has('page:root-1'), nil)
    local trace = post('/stats', {}).trace
    local lists = vim.tbl_filter(function(entry)
      return entry[1] ~= '/search'
    end, trace)
    eq(#lists, 4)
    eq(lists[1][1], '/spaces')
    eq(lists[1][2].cursor, 'next')
    eq(lists[2][2].spaceId, 'root-1')
    eq(lists[2][2].pageId, nil)
    eq(lists[3][2].pageId, 'root-1')
    eq(lists[4][2].cursor, 'next')
  end)

  test('reopening restores tree expansion, selection and scroll without refetching', function()
    key('l')
    row('page:root-1')
    key('l')
    row('page:child-2')
    local before = #post('/stats', {}).trace
    key('q')
    eq(ui.state, nil)
    ui.open()
    idle()
    eq(ui.state.rows[vim.api.nvim_win_get_cursor(ui.state.list.win)[1]].key, 'page:child-2')
    eq(#post('/stats', {}).trace, before)
    local lines = vim.o.lines
    vim.o.lines = 14
    vim.api.nvim_exec_autocmds('VimResized', {})
    key('G')
    local top = vim.api.nvim_win_call(ui.state.list.win, function()
      return vim.fn.line('w0')
    end)
    ui.close()
    ui.open()
    eq(
      vim.api.nvim_win_call(ui.state.list.win, function()
        return vim.fn.line('w0')
      end),
      top
    )
    vim.o.lines = lines
    vim.api.nvim_exec_autocmds('VimResized', {})
  end)

  test('preview is a separate read-only buffer, debounced, cached and stale-safe', function()
    local reads = post('/stats', {}).reads
    row('page:child-1')
    await(function()
      return ui.session.previews['child-1'] ~= nil
    end)
    ok(text(ui.state.preview_buf):find('Grüezi', 1, true), 'preview shows Markdown')
    ok(text(ui.state.preview_buf):find('Editable in Neovim', 1, true))
    eq(vim.bo[ui.state.preview_buf].modifiable, false)
    eq(buffers.states['child-1'], nil)
    local after = post('/stats', {}).reads
    ok(after - reads >= 3)
    row('space:root-1')
    row('page:child-1')
    idle()
    eq(post('/stats', {}).reads, after)
    ui.session.previews, ui.session.preview_order = {}, {}
    post('/control', { mode = 'slow' })
    row('page:child-2')
    await(function()
      return ui.state.preview_request ~= nil
    end)
    row('space:root-1')
    eq(ui.state.preview_request, nil)
    vim.wait(400)
    eq(ui.session.previews['child-2'], nil)
    ok(
      text(ui.state.preview_buf):find('lists its pages', 1, true)
        or text(ui.state.preview_buf):find('collapses', 1, true)
    )
    post('/control', { mode = 'normal' })
  end)

  test('search debounces typing, cancels stale queries and returns to browsing', function()
    row('page:child-1')
    local base = searches()
    key('/')
    eq(ui.session.mode, 'search')
    eq(vim.api.nvim_get_current_win(), ui.state.prompt_win)
    eq(vim.bo[ui.state.prompt_buf].buftype, 'prompt')
    type_query('r')
    type_query('re')
    type_query('res')
    await(function()
      return ui.session.search.pages > 0 and not ui.session.search.loading
    end)
    eq(searches() - base, 1)
    eq(ui.session.search.query, 'res')
    ok(has('result:search-0'), 'result row')
    ui.focus_results()
    eq(vim.api.nvim_get_current_win(), ui.state.list.win)
    row('more:search')
    key('<CR>')
    idle()
    ok(has('result:search-2'), 'offset pagination')
    local trace = post('/stats', {}).trace
    eq(trace[#trace][2].offset, 2)
    post('/control', { mode = 'slowsearch' })
    key('/')
    type_query('slow one')
    await(function()
      return ui.session.search.request ~= nil
    end)
    local stale = ui.session.search.token
    type_query('nothing')
    await(function()
      return ui.session.search.token > stale and not ui.session.search.loading
    end)
    eq(ui.session.search.query, 'nothing')
    eq(#ui.session.search.items, 0)
    ok(text():find('No pages match "nothing"', 1, true))
    vim.wait(350)
    eq(#ui.session.search.items, 0)
    post('/control', { mode = 'normal' })
    ui.focus_results()
    key('<Esc>')
    eq(ui.session.mode, 'browse')
    eq(ui.state.prompt_win, nil)
    eq(ui.state.rows[vim.api.nvim_win_get_cursor(ui.state.list.win)[1]].key, 'page:child-1')
    key('/')
    type_query('x')
    vim.wait(120)
    ok(text():find('at least two characters', 1, true))
    key('<C-c>', ui.state.prompt_buf)
    eq(ui.session.mode, 'browse')
  end)

  test('resize switches between wide, narrow and tiny layouts', function()
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 140, 40
    vim.api.nvim_exec_autocmds('VimResized', {})
    eq(ui.state.layout.mode, 'wide')
    ok(vim.api.nvim_win_is_valid(ui.state.preview_win))
    key('p')
    eq(ui.state.preview_win, nil)
    key('p')
    ok(vim.api.nvim_win_is_valid(ui.state.preview_win))
    vim.o.columns = 80
    vim.api.nvim_exec_autocmds('VimResized', {})
    eq(ui.state.layout.mode, 'narrow')
    eq(ui.state.preview_win, nil)
    row('page:child-1')
    key('p')
    eq(vim.api.nvim_win_get_buf(ui.state.list.win), ui.state.preview_buf)
    await(function()
      return text(ui.state.preview_buf):find('Grüezi', 1, true)
    end)
    key('p', ui.state.preview_buf)
    eq(vim.api.nvim_win_get_buf(ui.state.list.win), ui.state.list.buf)
    eq(ui.state.rows[vim.api.nvim_win_get_cursor(ui.state.list.win)[1]].key, 'page:child-1')
    vim.o.columns, vim.o.lines = 40, 12
    vim.api.nvim_exec_autocmds('VimResized', {})
    eq(ui.state.layout.mode, 'tiny')
    ok(vim.api.nvim_win_get_width(ui.state.list.win) <= 38)
    ok(vim.api.nvim_win_get_height(ui.state.list.win) <= 9)
    vim.o.columns, vim.o.lines = columns, lines
    vim.api.nvim_exec_autocmds('VimResized', {})
  end)

  test('leaving for an editor window or closing any pane closes the workspace', function()
    local origin = ui.state.origin_win
    vim.api.nvim_set_current_win(origin)
    await(function()
      return ui.state == nil
    end)
    eq(floats(), 0)
    ui.open()
    idle()
    vim.api.nvim_win_close(ui.state.preview_win, true)
    await(function()
      return ui.state == nil
    end)
    eq(floats(), 0)
    ui.open()
    idle()
    ok(has('page:child-1'), 'state kept after external close')
    local input = vim.ui.input
    vim.ui.input = function(_, cb)
      local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
        relative = 'editor',
        row = 1,
        col = 1,
        width = 10,
        height = 1,
      })
      vim.wait(20)
      vim.api.nvim_win_close(float, true)
      cb(nil)
    end
    key('o')
    vim.ui.input = input
    vim.wait(20)
    ok(ui.state ~= nil, 'floating prompts do not close the workspace')
  end)

  test('open variants target the original window and pages become ordinary buffers', function()
    local wins = #vim.api.nvim_tabpage_list_wins(0) - floats()
    row('page:child-1')
    key('<C-v>')
    await(function()
      return buffers.current() ~= nil
    end)
    eq(ui.state, nil)
    eq(#vim.api.nvim_tabpage_list_wins(0), wins + 1)
    eq(vim.bo.buftype, 'acwrite')
    eq(vim.bo.filetype, 'markdown')
    vim.wait(20)
    eq(vim.wo.winbar, status.expr)
    ok(status.winbar():find('editable', 1, true))
    local page = buffers.current()
    eq(page.id, 'page-1')
    vim.cmd('enew')
    vim.wait(20)
    eq(vim.wo.winbar, '')
    vim.cmd('buffer ' .. page.buf)
    vim.wait(20)
    eq(vim.wo.winbar, status.expr)
    vim.cmd('only')
  end)

  test('page status flows into badges, preview and winbar through a verified save', function()
    local page = buffers.current()
    vim.api.nvim_buf_set_lines(page.buf, 0, -1, false, { 'Saved through workspace' })
    ok(status.winbar():find('unsaved', 1, true))
    vim.cmd('Docmost')
    idle()
    eq(ui.state.origin_page, 'page-1')
    local open = has('open:page-1')
    ok(open, 'open pages section')
    eq(open.badge[1], 'unsaved')
    row('open:page-1')
    ok(text(ui.state.preview_buf):find('Saved through workspace', 1, true))
    key('w')
    await(function()
      return not page.busy
    end)
    eq(page.status, 'verified')
    eq(vim.bo[page.buf].modified, false)
    ok(has('open:page-1').badge[1]:find('^verified'))
    ok(text():find('Save verified', 1, true))
    key('<CR>')
    eq(ui.state, nil)
    eq(vim.api.nvim_get_current_buf(), page.buf)
    ok(status.winbar():find('verified', 1, true))
    eq(#post('/stats', {}).writes, 1)
  end)

  test('status and restrictions are explained in plain language', function()
    local fake = { status = 'conflict', baseline = { editable = true, meta = {} } }
    eq(status.describe(fake).label, 'conflict')
    ok(status.describe(fake).hint:find(':Docmost diff', 1, true))
    fake.status = 'save outcome uncertain'
    ok(status.describe(fake).hint:find('never resends', 1, true))
    fake.status, fake.busy = 'verifying', true
    eq(status.describe(fake).label, 'verifying')
    ok(status.explain('Unsupported node: table'):find('a table', 1, true))
    ok(status.explain('Unsupported node: attachment'):find('attachment', 1, true))
    ok(
      status
        .explain('Ambiguous block IDs: save text edits and inserted/deleted blocks separately')
        :find('Save the text edits first', 1, true)
    )
    eq(status.explain('Something new'), 'Something new')
    fake.busy, fake.status = false, 'opened'
    fake.baseline = { editable = false, reason = 'Unsupported node: image', meta = {} }
    eq(status.describe(fake).label, 'read-only')
    ok(status.describe(fake).hint:find('an image', 1, true))
  end)

  test('list errors and expired sessions are recoverable in place', function()
    ui.open()
    idle()
    post('/control', { mode = 'html' })
    row('space:root-1')
    key('r')
    idle()
    ok(has('error:space:root-1'), 'error row under the node')
    ok(text():find('Expected JSON', 1, true))
    post('/control', { mode = 'normal' })
    row('error:space:root-1')
    key('r')
    idle()
    eq(has('error:space:root-1'), nil)
    ok(has('page:root-1'))
    post('/control', { mode = 'expired' })
    row('page:root-1')
    key('r')
    idle()
    ok(auth.status:match('^expired'))
    ok(has('action:login'), 'expired banner offers sign in')
    ok(has('page:root-1'), 'tree stays visible while expired')
    local chips = vim.tbl_map(function(chunk)
      return chunk[1]
    end, vim.api.nvim_win_get_config(ui.state.list.win).title)
    ok(table.concat(chips):find('session expired', 1, true))
    post('/control', { mode = 'normal' })
    sign_in()
    idle()
    eq(auth.status, 'authenticated')
    eq(has('action:login'), nil)
    ok(has('page:child-1'), 'failed node retried after sign in')
  end)

  test('navigation and closing ignore stale async responses', function()
    post('/control', { mode = 'slow' })
    row('space:root-2')
    key('l')
    ok(ui.session.nodes['space:root-2'].loading)
    key('q')
    await(function()
      return next(http.active) == nil
    end)
    eq(ui.state, nil)
    eq(ui.session.nodes['space:root-2'].loading, false)
    eq(ui.session.nodes['space:root-2'].children, nil)
    post('/control', { mode = 'normal' })
    ui.open()
    idle()
    ok(ui.session.nodes['space:root-2'].children, 'reopen refetches interrupted expansion')
    ui.close()
  end)

  test('pending page open targets its original window when the workspace reopens', function()
    local origin_win = vim.api.nvim_get_current_win()
    post('/control', { mode = 'slow' })
    local done, failure
    buffers.open('page-1', function(err)
      done, failure = true, err
    end)
    ui.open()
    local panel, win = ui.state.list.buf, ui.state.list.win
    await(function()
      return done
    end)
    assert(not failure, vim.inspect(failure))
    eq(vim.api.nvim_get_current_win(), win)
    eq(vim.api.nvim_win_get_buf(win), panel)
    eq(vim.api.nvim_win_get_buf(origin_win), buffers.states['page-1'].buf)
    ui.close()
    post('/control', { mode = 'normal' })
  end)

  test('logout and failures preserve page edits', function()
    local page = buffers.states['page-1']
    vim.api.nvim_set_current_buf(page.buf)
    vim.api.nvim_buf_set_lines(page.buf, 0, -1, false, { 'Unsaved after logout' })
    ui.open()
    idle()
    key('L')
    eq(auth.token(), nil)
    eq(vim.bo[page.buf].modified, true)
    eq(has('page:root-1'), nil)
    ok(has('open:page-1'), 'open pages survive logout')
    ok(has('action:login'))
    ok(ui.state.notice.text:find('keep their edits', 1, true))
    ok(text():find('Signed out locally', 1, true))
    key('w')
    await(function()
      return not page.busy
    end)
    eq(vim.bo[page.buf].modified, true)
    eq(ui.state.notice.group, 'DocmostError')
    ui.close()
    eq(vim.api.nvim_buf_get_lines(page.buf, 0, -1, false), { 'Unsaved after logout' })
  end)

  test('guide opens on its own and restores focus', function()
    local origin = vim.api.nvim_get_current_win()
    vim.cmd('Docmost guide')
    local win = vim.api.nvim_get_current_win()
    ok(win ~= origin)
    local buf = vim.api.nvim_win_get_buf(win)
    ok(text(buf):find('changes the body, not the page title', 1, true))
    ok(text(buf):find('disposable page', 1, true))
    eq(text(buf):find('BROWSE', 1, true), nil)
    key('q', buf)
    eq(vim.api.nvim_get_current_win(), origin)
    eq(floats(), 0)
  end)
  print('SUCCESS UI: ' .. checks .. ' assertions')
end

local ok_run, err = xpcall(run, debug.traceback)
if not ok_run then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
