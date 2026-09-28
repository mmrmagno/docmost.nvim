local root = vim.env.DOCMOST_TEST_DIR
require('docmost').setup({
  base_url = vim.env.DOCMOST_TEST_URL,
  allow_insecure_localhost = true,
  state_dir = root .. '/state',
  timeout_ms = 500,
  max_response_bytes = 20000,
  verify_timeout_ms = 550,
  verify_interval_ms = 25,
  page_size = 2,
  backup_retention = 3,
})
local api, auth, buffers =
  require('docmost.api'), require('docmost.auth'), require('docmost.buffer')
local http, fidelity = require('docmost.http'), require('docmost.fidelity')
local checks = 0
local function eq(a, b, message)
  assert(
    vim.deep_equal(a, b),
    (message or 'Mismatch') .. '\nexpected: ' .. vim.inspect(b) .. '\nactual: ' .. vim.inspect(a)
  )
  checks = checks + 1
end
local function wait(start)
  local result
  start(function(...)
    result = { n = select('#', ...), ... }
  end)
  assert(
    vim.wait(4000, function()
      return result ~= nil
    end, 5),
    'Callback timed out'
  )
  return unpack(result, 1, result.n)
end
local function control(opts)
  local err = wait(function(cb)
    http.post('/control', opts, nil, cb)
  end)
  assert(not err, vim.inspect(err))
end
local function stats()
  local err, data = wait(function(cb)
    http.post('/stats', {}, nil, cb)
  end)
  assert(not err)
  return data
end
local function reset(mode)
  for _, s in pairs(buffers.states) do
    if vim.api.nvim_buf_is_valid(s.buf) then
      vim.api.nvim_buf_delete(s.buf, { force = true })
    end
  end
  buffers.states, buffers.compatibility = {}, 'unverified'
  control({ reset = true, mode = mode or 'normal' })
end
local function open()
  local err, s = wait(function(cb)
    buffers.open('page-1', cb)
  end)
  assert(not err, vim.inspect(err))
  return s
end
local function edit(s, text)
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
end
local function save(s)
  return wait(function(cb)
    buffers.save(s.buf, cb)
  end)
end
local function test(name, fn)
  fn()
  print('PASS ' .. name)
end

local function run()
  test('cookie login; no secrets in argv; private persisted session', function()
    local system = vim.system
    vim.system = function(argv, opts, cb)
      assert(not table.concat(argv, ' '):find(vim.env.DOCMOST_TEST_PASSWORD, 1, true))
      assert(not table.concat(argv, ' '):find(vim.env.DOCMOST_TEST_TOKEN, 1, true))
      return system(argv, opts, cb)
    end
    require('docmost.config').get().persist_session = true
    local err = wait(function(cb)
      auth.login('mock@example.test', vim.env.DOCMOST_TEST_PASSWORD, cb)
    end)
    eq(err, nil)
    eq(auth.status, 'authenticated')
    eq(auth.token(), vim.env.DOCMOST_TEST_TOKEN)
    local path = vim.fn.glob(root .. '/state/session-*.json')
    eq((vim.uv.fs_stat(path).mode % 512), 384)
    eq((vim.uv.fs_stat(root .. '/state').mode % 512), 448)
    auth.reset()
    eq(auth.token(), vim.env.DOCMOST_TEST_TOKEN)
  end)
  test('HTML, malformed JSON, redirects, size, rate, and redacted errors', function()
    for mode, kind in pairs({
      html = 'content_type',
      malformed = 'json',
      redirect = 'redirect',
      oversize = 'size',
      rate = 'rate_limit',
      application = 'application',
    }) do
      control({ mode = mode })
      local err = wait(function(cb)
        api.post('/users/me', {}, cb)
      end)
      eq(err.kind, kind)
      eq(err.message:find(vim.env.DOCMOST_TEST_TOKEN, 1, true), nil)
    end
    control({ mode = 'normal' })
  end)
  test('production requires HTTPS and TLS validates certificates', function()
    local c = require('docmost.config').get()
    eq(pcall(require('docmost.config').setup, { base_url = 'http://docs.example.com' }), false)
    eq(
      pcall(require('docmost.config').setup, { base_url = 'https://token@docs.example.com' }),
      false
    )
    eq(pcall(require('docmost.config').setup, { base_url = 'http://127.0.0.1:80' }), false)
    local original_url = c.base_url
    c.base_url = vim.env.DOCMOST_TEST_TLS_URL
    local err = wait(function(cb)
      api.post('/users/me', {}, cb)
    end)
    eq(err.kind, 'network') -- Untrusted self-signed certificate is rejected.
    local system = vim.system
    vim.system = function(argv, opts, cb)
      opts.env = { CURL_CA_BUNDLE = vim.env.DOCMOST_TEST_CERT }
      return system(argv, opts, cb)
    end
    err = wait(function(cb)
      api.post('/users/me', {}, cb)
    end)
    eq(err, nil) -- Trust only the temporary test CA; no insecure flag.
    vim.system, c.base_url = system, original_url
  end)
  test('cursor and offset pagination and on-demand child requests', function()
    local err, items, cursor = wait(function(cb)
      api.list('/spaces', {}, cb)
    end)
    eq(err, nil)
    eq(#items, 1)
    eq(cursor, 'next')
    err, items, cursor = wait(function(cb)
      api.list('/spaces', { cursor = cursor }, cb)
    end)
    eq(err, nil)
    eq(items[1].id, 'root-2')
    eq(cursor, nil)
    err, items = wait(function(cb)
      api.list('/pages/sidebar-pages', { spaceId = 'space-1', pageId = 'parent' }, cb)
    end)
    eq(err, nil)
    eq(items[1].title, 'Child')
    err, items, cursor = wait(function(cb)
      api.list('/search', { query = 'foo', offset = 0 }, cb)
    end)
    eq(err, nil)
    eq(cursor, 2)
    err, items, cursor = wait(function(cb)
      api.list('/search', { query = 'foo', offset = cursor }, cb)
    end)
    eq(items[1].id, 'search-2')
    eq(cursor, 4)
    err, items, cursor = wait(function(cb)
      api.list('/search', { query = 'foo', offset = cursor }, cb)
    end)
    eq(#items, 0)
    eq(cursor, nil)
    eq(stats().trace[3][2].pageId, 'parent')
  end)
  test('picker follows spaces pagination and loads children only on selection', function()
    reset()
    local original, calls, finished = vim.ui.select, 0, false
    vim.ui.select = function(items, opts, cb)
      calls = calls + 1
      if calls == 1 then
        cb(items[#items]) -- more spaces
      elseif calls == 2 then
        cb(items[1]) -- space
      elseif calls == 3 then
        cb(items[1]) -- page
      elseif calls == 4 then
        cb(items[2]) -- children
      else
        finished = true
        cb(nil)
      end
    end
    require('docmost.picker').spaces()
    assert(vim.wait(3000, function()
      return finished
    end, 5))
    vim.ui.select = original
    local trace = stats().trace
    eq(trace[2][2].cursor, 'next')
    eq(trace[3][2].pageId, nil)
    eq(trace[4][2].pageId, 'root-1')
  end)
  test('URL validation, one buffer per identity, raw/canonical baselines and no-op', function()
    reset()
    eq(api.identifier('https://wrong.example/s/p/foo'), nil)
    eq(
      api.identifier(vim.env.DOCMOST_TEST_URL .. '/s/space/p/title-slugAbC1234#anchor'),
      'slugAbC1234'
    )
    eq(
      api.identifier(vim.env.DOCMOST_TEST_URL .. '/s/space/p/12345678-1234-1234-1234-123456789abc'),
      '12345678-1234-1234-1234-123456789abc'
    )
    local s = open()
    eq(vim.bo[s.buf].buftype, 'acwrite')
    eq(vim.bo[s.buf].filetype, 'markdown')
    eq(vim.bo[s.buf].swapfile, false)
    eq(s.baseline.editable, true)
    eq(s.baseline.json.content[4].type, 'codeBlock')
    local err, other = wait(function(cb)
      buffers.open('other-slug', cb)
    end)
    eq(err, nil)
    eq(other.buf, s.buf)
    eq(save(s), nil)
    eq(#stats().writes, 0)
  end)
  test(':write performs verified in-place save and preserves title', function()
    reset()
    local s = open()
    local md = s.baseline.markdown .. '\n\nA new Unicode note: ä 🦊'
    edit(s, md)
    vim.cmd('write')
    assert(vim.wait(3500, function()
      return not s.busy
    end, 5))
    eq(s.status, 'verified')
    eq(vim.bo[s.buf].modified, false)
    eq(s.baseline.markdown, md)
    local writes = stats().writes
    eq(#writes, 1)
    eq(writes[1].pageId, 'page-1')
    eq(writes[1].title, nil)
    eq(writes[1].format, 'json')
    eq(writes[1].operation, 'replace')
    eq(vim.uv.fs_stat(s.backup_path).mode % 512, 384)
    local err, reopened = wait(function(cb)
      api.read(s.id, cb)
    end)
    eq(err, nil)
    eq(reopened.markdown, md)
  end)
  test('delayed persistence, duplicate save and edits while pending', function()
    reset('delayed')
    local s = open()
    edit(s, 'submitted')
    local finished, save_error
    buffers.save(s.buf, function(err)
      finished, save_error = true, err
    end)
    eq(save(s).message, 'A page operation is already pending')
    edit(s, 'typed during save')
    assert(vim.wait(3000, function()
      return finished
    end, 5))
    eq(save_error, nil)
    eq(s.baseline.json.content[1].content[1].text, 'submitted')
    eq(vim.bo[s.buf].modified, true)
    eq(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), { 'typed during save' })
    eq(#stats().writes, 1)
    eq(save(s), nil)
    eq(vim.bo[s.buf].modified, false)
  end)
  test('false success locks writes and reconciles without replay', function()
    reset('ignored')
    local s = open()
    edit(s, 'must survive')
    eq(save(s).kind, 'uncertain')
    eq(vim.bo[s.buf].modified, true)
    eq(s.status, 'save outcome uncertain')
    assert(buffers.compatibility:match('read%-only'))
    eq(save(s).kind, 'uncertain')
    eq(#stats().writes, 1)
    control({ mode = 'normal', document = s.pending.json, generation = 1 })
    eq(save(s), nil)
    eq(s.status, 'verified')
    eq(#stats().writes, 1)
    eq(vim.bo[s.buf].modified, false)
  end)
  test('remote raw JSON or metadata conflicts block overwrite and offer three-way diff', function()
    reset()
    local s = open()
    edit(s, 'local edit')
    control({ generation = 8 })
    eq(save(s).kind, 'conflict')
    eq(#stats().writes, 0)
    eq(vim.bo[s.buf].modified, true)
    require('docmost.conflict').show(s)
    eq(#vim.api.nvim_tabpage_list_wins(0), 3)
    vim.cmd('tabclose')
    vim.api.nvim_set_current_buf(s.buf)
    local err = wait(function(cb)
      buffers.reload(false, cb)
    end)
    assert(err)
    eq(
      wait(function(cb)
        buffers.reload(true, cb)
      end),
      nil
    )
    eq(vim.bo[s.buf].modified, false)
    control({ mode = 'rich' })
    edit(s, 'another edit')
    eq(save(s).kind, 'conflict')
    eq(#stats().writes, 0)
  end)
  test('rich pages are editable and untouched rich nodes are written back exactly', function()
    reset()
    local rich = {
      type = 'doc',
      content = {
        {
          type = 'paragraph',
          attrs = { id = 'p1', textAlign = 'left' },
          content = {
            { type = 'text', text = 'Intro ' },
            {
              type = 'text',
              text = 'anchored',
              marks = { { type = 'comment', attrs = { commentId = 'c1', resolved = false } } },
            },
            { type = 'mention', attrs = { id = 'u1', label = 'Marcos', entityType = 'user' } },
          },
        },
        {
          type = 'attachment',
          attrs = { url = '/files/r.pdf', name = 'report.pdf', attachmentId = 'keep-me', size = 9 },
        },
        {
          type = 'table',
          content = {
            {
              type = 'tableRow',
              content = {
                {
                  type = 'tableCell',
                  attrs = { colspan = 2, rowspan = 1, colwidth = { 100, 50 } },
                  content = {
                    {
                      type = 'paragraph',
                      attrs = { id = 'p2' },
                      content = { { type = 'text', text = 'cell' } },
                    },
                  },
                },
              },
            },
          },
        },
        {
          type = 'callout',
          attrs = { type = 'info' },
          content = {
            {
              type = 'paragraph',
              attrs = { id = 'p3' },
              content = { { type = 'text', text = 'Note' } },
            },
          },
        },
        {
          type = 'paragraph',
          attrs = { id = 'p4', textAlign = 'center' },
          content = { { type = 'text', text = 'keep  two  spaces' } },
        },
        { type = 'futureWidget', attrs = { config = { a = 1 } } },
      },
    }
    control({ document = rich })
    local s = open()
    eq(s.baseline.editable, true)
    eq(vim.bo[s.buf].modifiable, true)
    local text = table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), '\n')
    assert(text:find('[report.pdf](/files/r.pdf){.attachment', 1, true), text)
    assert(text:find('[@Marcos]{.mention', 1, true), text)
    assert(text:find('::: {.callout type="info"}', 1, true), text)
    local row
    for i, line in ipairs(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)) do
      if line == 'Note' then
        row = i - 1
      end
    end
    vim.api.nvim_buf_set_text(s.buf, row, 4, row, 4, { ' edited in Neovim' })
    eq(save(s), nil)
    local write = stats().writes[1]
    eq(write.format, 'json')
    local expected = vim.deepcopy(rich)
    expected.content[4].content[1].content[1].text = 'Note edited in Neovim'
    eq(write.content, expected)
    eq(s.status, 'verified')
    eq(vim.bo[s.buf].modified, false)
    reset('readonly')
    s = open()
    eq(s.baseline.editable, false)
    eq(vim.bo[s.buf].modifiable, false)
    vim.bo[s.buf].modifiable = true
    edit(s, 'force local edit')
    assert(save(s))
    eq(#stats().writes, 0)
  end)
  test('front matter renames the page separately and after the body', function()
    reset()
    local s = open()
    local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    eq(lines[1], '---')
    eq(lines[2], 'title: Title stays separate')
    lines[2] = 'title: Renamed from Neovim'
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
    eq(save(s), nil)
    local writes = stats().writes
    eq(#writes, 1)
    eq(writes[1], { pageId = 'page-1', title = 'Renamed from Neovim' })
    eq(s.baseline.meta.title, 'Renamed from Neovim')
    eq(vim.bo[s.buf].modified, false)
    lines[2] = 'title: Both at once'
    lines[#lines] = lines[#lines] .. ' and more'
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
    eq(save(s), nil)
    writes = stats().writes
    eq(#writes, 3)
    eq(writes[2].format, 'json')
    eq(writes[3].title, 'Both at once')
    eq(s.baseline.meta.title, 'Both at once')
    lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    edit(s, table.concat(vim.list_slice(lines, 5), '\n'))
    eq(save(s), nil)
    eq(#stats().writes, 3)
  end)
  test('empty body sends a schema-valid document and verifies structural emptiness', function()
    reset()
    local s = open()
    edit(s, '')
    eq(save(s), nil)
    local write = stats().writes[1]
    eq(write.format, 'json')
    eq(write.content, { type = 'doc', content = { { type = 'paragraph' } } })
    eq(fidelity.empty(s.baseline.json), true)
    reset('ignored')
    s = open()
    edit(s, '')
    eq(save(s).kind, 'uncertain')
    eq(vim.bo[s.buf].modified, true)
    reset('wrongempty')
    s = open()
    edit(s, '')
    eq(save(s).kind, 'uncertain')
    eq(vim.bo[s.buf].modified, true)
    reset('nullbody')
    s = open()
    eq(s.baseline.markdown:match('\n\n(.*)$'), '')
    eq(fidelity.empty(s.baseline.json), true)
    reset('missingbody')
    local err = wait(function(cb)
      api.read('page-1', cb)
    end)
    eq(err.kind, 'contract')
  end)
  test('a rejected rename after a verified body keeps the title change pending', function()
    reset()
    control({ icon = '📄' })
    local s = open()
    local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    eq(lines[3], 'icon: 📄')
    table.remove(lines, 3)
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
    eq(save(s), nil)
    eq(stats().writes[1], { pageId = 'page-1', icon = '' })
    eq(vim.bo[s.buf].modified, false)
    control({ mode = 'renamefail' })
    lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    lines[2] = 'title: After the body'
    lines[#lines] = lines[#lines] .. ' changed'
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
    eq(save(s).kind, 'rate_limit')
    local writes = stats().writes
    eq(#writes, 3)
    eq(writes[2].format, 'json')
    eq(vim.bo[s.buf].modified, true)
    control({ mode = 'normal' })
    eq(save(s), nil)
    writes = stats().writes
    eq(#writes, 4)
    eq(writes[4], { pageId = 'page-1', title = 'After the body' })
    eq(vim.bo[s.buf].modified, false)
  end)
  test('meaningful whitespace in stored text is kept across unrelated edits', function()
    eq(fidelity.normalize('a  \r\n\r\n  code\n'), 'a  \n\n  code\n')
    reset()
    control({
      document = {
        type = 'doc',
        content = {
          {
            type = 'paragraph',
            content = { { type = 'text', text = '  leading, two  spaces, trailing ' } },
          },
          { type = 'codeBlock', content = { { type = 'text', text = '\tindented\n  code\n' } } },
          { type = 'paragraph', content = { { type = 'text', text = 'edit me' } } },
        },
      },
    })
    local s = open()
    local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    lines[#lines] = 'edited'
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
    eq(save(s), nil)
    local write = stats().writes[1].content
    eq(write.content[1].content[1].text, '  leading, two  spaces, trailing ')
    eq(write.content[2].content[1].text, '\tindented\n  code\n')
    eq(write.content[3].content[1].text, 'edited')
  end)
  test('HTTP 403 preserves changes without pending ambiguous state', function()
    reset('forbidden')
    local s = open()
    edit(s, 'local')
    eq(save(s).kind, 'permission')
    eq(s.pending, nil)
    eq(vim.bo[s.buf].modified, true)
  end)
  test('network timeout before update preserves edits; ambiguous update reconciles', function()
    reset()
    local s = open()
    edit(s, 'local')
    control({ mode = 'slow' })
    require('docmost.config').get().timeout_ms = 70
    eq(save(s).kind, 'timeout')
    eq(#stats().writes, 0)
    eq(vim.bo[s.buf].modified, true)
    control({ mode = 'ambiguous' })
    eq(save(s), nil)
    eq(#stats().writes, 1)
    eq(vim.bo[s.buf].modified, false)
    require('docmost.config').get().timeout_ms = 500
  end)
  test('unstable paired reads are rejected', function()
    reset('changing')
    local err = wait(function(cb)
      api.read('page-1', cb)
    end)
    eq(err.kind, 'conflict')
  end)
  test('reload does not discard edits entered during the request', function()
    reset()
    local s = open()
    local finished, error
    buffers.reload(false, function(err)
      finished, error = true, err
    end)
    edit(s, 'new during reload')
    assert(vim.wait(3000, function()
      return finished
    end, 5))
    assert(error)
    eq(vim.bo[s.buf].modified, true)
    eq(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), { 'new during reload' })
  end)
  test('buffers wiped during save retain latest edits and do not crash callbacks', function()
    reset('delayed')
    local s = open()
    edit(s, 'submitted')
    local done
    buffers.save(s.buf, function()
      done = true
    end)
    assert(vim.wait(2000, function()
      return s.pending ~= nil
    end, 5))
    edit(s, 'recover after wipe')
    vim.api.nvim_buf_delete(s.buf, { force = true })
    local attempts = 0
    buffers.open('page-1', function(err)
      assert(err)
      attempts = attempts + 1
    end)
    assert(vim.wait(3000, function()
      return done
    end, 5))
    eq(attempts, 1)
    eq(s.snapshot, 'recover after wipe')
    eq(s.detached_modified, true)
    local reopened = open()
    eq(vim.api.nvim_buf_get_lines(reopened.buf, 0, -1, false), { 'recover after wipe' })
    eq(vim.bo[reopened.buf].modified, true)
  end)
  test('unloaded modified buffers reopen with their edits', function()
    reset()
    local s = open()
    edit(s, 'recover unloaded buffer')
    vim.api.nvim_buf_delete(s.buf, { force = true, unload = true })
    eq(vim.api.nvim_buf_is_loaded(s.buf), false)
    local reopened = open()
    eq(vim.api.nvim_buf_get_lines(reopened.buf, 0, -1, false), { 'recover unloaded buffer' })
    eq(vim.bo[reopened.buf].modified, true)
    reset()
    s = open()
    vim.api.nvim_buf_delete(s.buf, { force = true, unload = true })
    reopened = open()
    eq(vim.bo[reopened.buf].modified, false)
    eq(reopened.baseline.markdown, s.baseline.markdown)
  end)
  test('backup failure prevents writes and retention stays bounded', function()
    reset()
    local s = open()
    edit(s, 'private edit')
    local c = require('docmost.config').get()
    local original = c.state_dir
    vim.fn.writefile({ 'file blocks directory creation' }, root .. '/not-a-directory')
    c.state_dir = root .. '/not-a-directory'
    assert(save(s))
    eq(#stats().writes, 0)
    eq(vim.bo[s.buf].modified, true)
    c.state_dir = original
    for i = 1, 5 do
      edit(s, 'retention ' .. i)
      eq(save(s), nil)
    end
    local files = vim.fn.glob(vim.fn.fnamemodify(s.backup_path, ':h') .. '/*.json', false, true)
    eq(#files, c.backup_retention)
    local data = vim.json.decode(table.concat(vim.fn.readfile(s.backup_path), '\n'))
    eq(data.local_markdown, 'retention 5')
    eq(data.baseline.json.content[1].content[1].text, 'retention 4')
  end)
  test('server-added block IDs remain editable and survive a second save', function()
    reset('newanchor')
    local s = open()
    edit(s, 'saved once')
    eq(save(s), nil)
    eq(vim.bo[s.buf].readonly, false)
    eq(vim.bo[s.buf].modifiable, true)
    edit(s, 'saved twice')
    eq(save(s), nil)
    eq(stats().writes[2].format, 'json')
    eq(s.baseline.json.content[1].attrs.id, 'generated-id')
  end)
  test('block IDs and default alignment survive repeated Markdown edits and clearing', function()
    reset('anchored')
    local s = open()
    eq(vim.bo[s.buf].modifiable, true)
    local original = vim.deepcopy(s.baseline.json)
    local body = s.baseline.markdown:gsub('# Notes', '# Edited notes')
    edit(s, body)
    eq(save(s), nil)
    eq(stats().writes[1].format, 'json')
    eq(s.baseline.json.content[1].attrs.id, original.content[1].attrs.id)
    eq(s.baseline.json.content[1].attrs.textAlign, 'left')
    eq(vim.bo[s.buf].modifiable, true)
    body = body:gsub('Grüezi', 'Bonjour')
    edit(s, body)
    eq(save(s), nil)
    eq(s.baseline.json.content[2].attrs.id, original.content[2].attrs.id)
    eq(save(s), nil)
    eq(#stats().writes, 2)
    edit(s, '')
    eq(save(s), nil)
    eq(fidelity.empty(s.baseline.json), true)
  end)
  test('text edits and new blocks in one save keep every existing block ID', function()
    reset('anchored')
    local s = open()
    local original = vim.deepcopy(s.baseline.json)
    local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    local heading, para
    for i, line in ipairs(lines) do
      if line == '# Notes' then
        heading = i - 1
      elseif line:find('Grüezi', 1, true) then
        para = i - 1
      end
    end
    vim.api.nvim_buf_set_text(s.buf, heading, 7, heading, 7, { ' and more' })
    vim.api.nvim_buf_set_lines(s.buf, para, para, false, { 'A brand new paragraph', '' })
    vim.api.nvim_buf_set_text(s.buf, para + 2, 0, para + 2, #'Grüezi', { 'Hello' })
    eq(save(s), nil)
    local written = stats().writes[1].content.content
    eq(written[1].attrs.id, original.content[1].attrs.id)
    eq(written[1].content[1].text, 'Notes and more')
    eq(written[2].attrs, nil)
    eq(written[3].attrs.id, original.content[2].attrs.id)
    assert(written[3].content[1].text:find('^Hello'))
    eq(
      written[4].content[1].content[1].attrs.id,
      original.content[3].content[1].content[1].attrs.id
    )
  end)
  test('check reports problems as diagnostics without writing; attributes are concealed', function()
    reset()
    local s = open()
    vim.api.nvim_set_current_buf(s.buf)
    vim.api.nvim_buf_set_lines(s.buf, -1, -1, false, { '', '[odd]{.glitter}' })
    local err = wait(function(cb)
      buffers.check(cb)
    end)
    eq(err.kind, 'validation')
    local diagnostics = vim.diagnostic.get(s.buf)
    eq(#diagnostics, 1)
    eq(diagnostics[1].lnum, vim.api.nvim_buf_line_count(s.buf) - 1)
    assert(diagnostics[1].message:find('glitter', 1, true))
    eq(save(s).kind, 'validation')
    eq(#stats().writes, 0)
    vim.api.nvim_buf_set_lines(s.buf, -2, -1, false, { '[odd]{.underline}' })
    local e, count = wait(function(cb)
      buffers.check(cb)
    end)
    eq(e, nil)
    assert(count > 0)
    eq(#vim.diagnostic.get(s.buf), 0)
    local decorate = require('docmost.dfm.decorate')
    local specs = decorate.specs('[odd]{.underline} and [x](https://e.x){target="_blank"}')
    eq(#specs, 2)
    eq(specs[1].opts.conceal ~= nil, true)
    eq(#decorate.specs('![c](/a.png){.image width="1"}'), 1)
    eq(decorate.media('![c](/a.png){.image width="1"}'), 'image')
    eq(decorate.media('[f.pdf](/f.pdf){.attachment}'), 'attachment')
    eq(#decorate.specs('plain text'), 0)
    local win = vim.api.nvim_get_current_win()
    vim.wo[win].conceallevel = 0
    vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = s.buf })
    eq(vim.wo[win].conceallevel, 2)
    vim.api.nvim_exec_autocmds('BufWinLeave', { buffer = s.buf })
    eq(vim.wo[win].conceallevel, 0)
    eq(#stats().writes, 0)
  end)
  test('same visible Markdown without submitted IDs is never a verified save', function()
    reset('anchored')
    local s = open()
    control({ mode = 'dropids' })
    edit(s, s.baseline.markdown:gsub('# Notes', '# Edited'))
    eq(save(s).kind, 'uncertain')
    eq(vim.bo[s.buf].modified, true)
    eq(#stats().writes, 1)
  end)
  test('edits and cancellation during local Markdown parsing stay safe', function()
    reset('anchored')
    local s = open()
    local original = s.baseline.markdown
    edit(s, original:gsub('# Notes', '# Submitted'))
    local finished, failure
    buffers.save(s.buf, function(err)
      finished, failure = true, err
    end)
    eq(s.status, 'parsing Markdown')
    edit(s, original:gsub('# Notes', '# Newer edit'))
    assert(vim.wait(4000, function()
      return finished
    end, 5))
    eq(failure, nil)
    eq(vim.bo[s.buf].modified, true)
    assert(s.baseline.markdown:find('# Submitted', 1, true))
    eq(save(s), nil)
    edit(s, original:gsub('# Notes', '# Cancelled'))
    finished, failure = false, nil
    buffers.save(s.buf, function(err)
      finished, failure = true, err
    end)
    buffers.cancel()
    assert(vim.wait(4000, function()
      return finished
    end, 5))
    eq(failure.kind, 'cancelled')
    eq(vim.bo[s.buf].modified, true)
    eq(#stats().writes, 2)
  end)
  test('alternative Markdown spelling saves once and never replaces the buffer', function()
    reset('anchored')
    local s = open()
    edit(s, s.baseline.markdown:gsub('%*italic%*', '_changed italic_'))
    eq(save(s), nil)
    assert(s.baseline.markdown:find('*changed italic*', 1, true))
    assert(
      table
        .concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), '\n')
        :find('_changed italic_', 1, true)
    )
    eq(vim.bo[s.buf].modified, false)
    eq(save(s), nil)
    eq(#stats().writes, 1)
  end)
  test('cancellation between verification polls retains uncertain snapshot', function()
    reset('delayed')
    local s = open()
    edit(s, 'cancel me')
    local finished, failure
    buffers.save(s.buf, function(err)
      finished, failure = true, err
    end)
    assert(vim.wait(2000, function()
      return s.status == 'verifying' and next(http.active) == nil
    end, 1))
    buffers.cancel()
    assert(vim.wait(2000, function()
      return finished
    end, 5))
    eq(failure.kind, 'cancelled')
    assert(s.pending)
    eq(vim.bo[s.buf].modified, true)
    eq(save(s), nil)
    eq(#stats().writes, 1)
  end)
  test('cancel transport and session expiry are explicit', function()
    control({ mode = 'slow' })
    local err = wait(function(cb)
      local request = api.post('/users/me', {}, cb)
      request.cancel()
    end)
    eq(err.kind, 'cancelled')
    control({ mode = 'expired' })
    err = wait(function(cb)
      auth.validate(cb)
    end)
    eq(err.kind, 'auth')
    eq(auth.token(), nil)
    auth.logout()
    eq(vim.fn.glob(root .. '/state/session-*.json'), '')
  end)
  print(string.format('SUCCESS: %d assertions', checks))
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
