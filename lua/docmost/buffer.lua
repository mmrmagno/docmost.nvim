local M = { states = {}, opening = {}, compatibility = 'unverified' }
local api = require('docmost.api')
local dfm = require('docmost.dfm')
local identity = require('docmost.dfm.identity')
local diagnostics = vim.api.nvim_create_namespace('DocmostValidation')
local function valid(s)
  return s.buf and vim.api.nvim_buf_is_valid(s.buf) and vim.api.nvim_buf_is_loaded(s.buf)
end
local function content(s)
  return valid(s) and table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), '\n')
    or s.snapshot
end
local function notify(message, level)
  vim.notify('docmost: ' .. message, level or vim.log.levels.INFO)
end
local function fail(message, kind)
  return { message = message, kind = kind or 'state' }
end
local function set(s, status)
  s.status = status
  if status == 'verified' then
    s.verified_at = os.time()
  end
  if valid(s) then
    vim.b[s.buf].docmost_status = status
  end
  vim.api.nvim_exec_autocmds(
    'User',
    { pattern = 'DocmostPageStatus', modeline = false, data = { id = s.id } }
  )
  if #vim.api.nvim_list_uis() > 0 then
    vim.cmd('redrawstatus!')
  end
end
M.set_status = set

function M.current(buf)
  buf = (not buf or buf == 0) and vim.api.nvim_get_current_buf() or buf
  for _, s in pairs(M.states) do
    if s.buf == buf then
      return s
    end
  end
end

local function backup(s, snapshot)
  local ok, path = pcall(require('docmost.storage').backup, s, snapshot)
  if ok then
    s.backup_path = path
    return true
  end
  return false
end

local function attach(s, markdown, modified, target_win)
  local c = require('docmost.config').get()
  if s.buf and vim.api.nvim_buf_is_valid(s.buf) and not vim.api.nvim_buf_is_loaded(s.buf) then
    vim.api.nvim_buf_delete(s.buf, { force = true })
  end
  local buf = vim.api.nvim_create_buf(true, false)
  s.buf, s.snapshot = buf, markdown
  vim.api.nvim_buf_set_name(buf, 'docmost://' .. c.authority .. '/' .. s.id)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden = 'acwrite', 'hide'
  vim.bo[buf].swapfile, vim.bo[buf].undofile = false, false
  vim.bo[buf].filetype, vim.bo[buf].endofline, vim.bo[buf].fixendofline = 'markdown', false, false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(markdown, '\n', { plain = true }))
  vim.bo[buf].modified = modified or false
  vim.bo[buf].readonly = not s.baseline.editable
  vim.bo[buf].modifiable = s.baseline.editable or modified or false
  vim.b[buf].docmost_title = s.baseline.meta.title
  require('docmost.dfm.decorate').attach(buf)
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function(args)
      if args.match ~= vim.api.nvim_buf_get_name(buf) then
        notify(
          'Use :Docmost save to save this page; export via a separate local buffer',
          vim.log.levels.ERROR
        )
        return
      end
      M.save(buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufUnload', {
    buffer = buf,
    callback = function()
      s.snapshot = content(s)
      s.detached_entries = identity.collect(s)
      s.detached_modified = vim.bo[buf].modified
      if s.detached_modified or s.pending or s.busy then
        if not backup(s, s.snapshot) then
          notify('Could not back up closing page buffer', vim.log.levels.ERROR)
        end
      end
    end,
  })
  if vim.api.nvim_win_is_valid(target_win) then
    vim.api.nvim_win_set_buf(target_win, buf)
  end
end

local function prepare(page, cb)
  return dfm.load(page, function(err, loaded)
    if err then
      if err.kind == 'dependency' then
        page.editable, page.reason = false, err.message
        page.anchors, page.tail = {}, select(2, dfm.split_tail(page.json))
        cb(nil, page)
        return
      end
      cb(err)
      return
    end
    page.markdown, page.anchors, page.tail = loaded.text, loaded.anchors, loaded.tail
    if not loaded.editable then
      page.editable, page.reason = false, page.reason or loaded.reason
    end
    cb(nil, page)
  end)
end

local function problems(s, errors)
  if not valid(s) then
    return
  end
  local items = {}
  for _, e in ipairs(errors or {}) do
    items[#items + 1] = {
      lnum = math.min(e.row, vim.api.nvim_buf_line_count(s.buf) - 1),
      col = 0,
      severity = vim.diagnostic.severity.ERROR,
      message = e.message,
      source = 'docmost',
    }
  end
  if #items == 0 and not s.problems then
    return
  end
  s.problems = #items > 0
  vim.diagnostic.set(diagnostics, s.buf, items)
end

function M.open(input, cb)
  local target_win = vim.api.nvim_get_current_win()
  cb = cb
    or function(err)
      if err then
        notify(err.message, vim.log.levels.ERROR)
      end
    end
  local id, why = api.identifier(input)
  if not id then
    cb(fail(why))
    return
  end
  local function reuse(s)
    if valid(s) then
      if vim.api.nvim_win_is_valid(target_win) then
        vim.api.nvim_win_set_buf(target_win, s.buf)
      end
    elseif s.busy then
      cb(fail('Page operation still running; reopen after it completes'))
      return true
    elseif s.detached_modified or s.pending then
      attach(s, s.snapshot, true, target_win)
      identity.attach(s, s.detached_entries)
    else
      if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
        vim.api.nvim_buf_delete(s.buf, { force = true })
      end
      return false
    end
    cb(nil, s)
    return true
  end
  if M.states[id] and reuse(M.states[id]) then
    return
  end
  if M.opening[id] then
    cb(fail('Page is already opening'))
    return
  end
  M.opening[id] = true
  api.read(id, function(err, page)
    if err then
      M.opening[id] = nil
      cb(err)
      return
    end
    prepare(page, function(load_error)
      M.opening[id] = nil
      if load_error then
        cb(load_error)
        return
      end
      if M.states[page.id] and reuse(M.states[page.id]) then
        return
      end
      local s = { id = page.id, baseline = page, tail = page.tail }
      M.states[s.id] = s
      attach(s, page.markdown, false, target_win)
      identity.attach(s, page.anchors)
      set(s, 'opened')
      if not page.editable then
        notify('Read-only: ' .. require('docmost.status').explain(page.reason), vim.log.levels.WARN)
      end
      cb(nil, s)
    end)
  end)
end

local function regate(s, remote)
  prepare(vim.deepcopy(remote), function(err, page)
    if err or s.baseline ~= remote then
      return
    end
    remote.markdown, remote.tail = page.markdown, page.tail
    if not page.editable then
      remote.editable, remote.reason = false, page.reason
      if valid(s) then
        vim.bo[s.buf].readonly = true
        vim.bo[s.buf].modifiable = vim.bo[s.buf].modified
      end
      notify('Saved page is now read-only: ' .. remote.reason, vim.log.levels.WARN)
    end
  end)
end

local function verified(s, remote, snapshot, tick, pending, partial)
  s.baseline, s.pending, s.remote = remote, nil, nil
  s.saved_snapshot = not partial and snapshot or nil
  s.tail = select(2, dfm.split_tail(remote.json))
  M.compatibility = 'HTTP body persistence observed'
  regate(s, remote)
  if valid(s) then
    local unchanged = vim.api.nvim_buf_get_changedtick(s.buf) == tick and content(s) == snapshot
    vim.bo[s.buf].modified = partial or not unchanged
    vim.bo[s.buf].readonly = not remote.editable
    vim.bo[s.buf].modifiable = remote.editable or vim.bo[s.buf].modified
    vim.b[s.buf].docmost_title = remote.meta.title
    if unchanged and pending and pending.json and pending.positions then
      identity.reanchor(s, pending.json, pending.positions, remote.json)
    end
  else
    s.detached_modified = partial or s.snapshot ~= snapshot
  end
  set(s, 'verified')
  if not remote.editable then
    notify('Saved page is now read-only: ' .. remote.reason, vim.log.levels.WARN)
  end
end

local watched = { 'id', 'title', 'icon', 'spaceId', 'parentPageId', 'deletedAt' }

function M.field(value)
  if type(value) ~= 'string' then
    return ''
  end
  return vim.trim(value)
end

local function persisted(pending, remote)
  if pending.kind == 'title' then
    if not vim.deep_equal(remote.json, pending.before.json) then
      return false
    end
    for key, value in pairs(pending.fields) do
      if M.field(remote.meta[key]) ~= M.field(value) then
        return false
      end
    end
    for _, key in ipairs({ 'id', 'spaceId', 'parentPageId', 'deletedAt' }) do
      if not vim.deep_equal(remote.meta[key], pending.before.meta[key]) then
        return false
      end
    end
    return true
  end
  if not dfm.matches(pending.json, remote.json) then
    return false
  end
  for _, key in ipairs(watched) do
    if not vim.deep_equal(remote.meta[key], pending.before.meta[key]) then
      return false
    end
  end
  return true
end

local verify

local function rename(s, fields, snapshot, tick, done)
  s.pending =
    { kind = 'title', fields = fields, before = s.baseline, markdown = snapshot, tick = tick }
  if not backup(s, content(s)) then
    s.pending = nil
    done(fail('Could not record pending rename; nothing was sent'))
    return
  end
  set(s, 'saving')
  s.request = api.rename(s.id, fields, function(update_error)
    if
      update_error
      and (
        update_error.status == 400
        or update_error.status == 401
        or update_error.status == 403
        or update_error.status == 404
        or update_error.status == 429
      )
    then
      s.pending = nil
      set(s, 'save rejected')
      done(update_error)
      return
    end
    set(s, 'verifying')
    verify(s, done)
  end)
end

verify = function(s, done)
  local c, uv = require('docmost.config').get(), vim.uv or vim.loop
  local deadline = uv.hrtime() / 1e6 + c.verify_timeout_ms
  local matches, previous = 0, nil
  local pending = s.pending
  local function uncertain(err)
    set(s, 'save outcome uncertain')
    if valid(s) then
      vim.bo[s.buf].modified = true
    end
    backup(s, content(s))
    if err then
      err = fail(
        'Save outcome uncertain: '
          .. err.message
          .. '. Edits retained; next save reconciles without replay.',
        err.kind
      )
    end
    done(
      err
        or fail(
          'Save outcome uncertain: read-back did not match. Edits retained; :Docmost diff or :Docmost save to reconcile. No write will be replayed.',
          'uncertain'
        )
    )
  end
  local function poll()
    if s.cancelled then
      uncertain(fail('Verification cancelled', 'cancelled'))
      return
    end
    local remaining = deadline - uv.hrtime() / 1e6
    if remaining <= 0 then
      if
        s.remote
        and vim.deep_equal(s.remote.json, pending.before.json)
        and pending.kind ~= 'title'
      then
        M.compatibility = 'read-only: HTTP body update not observed'
      end
      uncertain()
      return
    end
    s.request = api.read(s.id, function(err, remote)
      if s.cancelled then
        uncertain(fail('Verification cancelled', 'cancelled'))
        return
      end
      if err then
        if err.kind == 'auth' or err.kind == 'permission' or err.kind == 'cancelled' then
          uncertain(err)
          return
        end
        matches = 0
      else
        s.remote = remote
        if persisted(pending, remote) then
          matches = previous and api.same(previous, remote) and (matches + 1) or 1
          previous = remote
          if matches >= c.verify_reads then
            local follow = pending.kind ~= 'title' and pending.rename
            verified(
              s,
              remote,
              pending.markdown,
              pending.tick,
              pending,
              follow ~= nil and follow ~= false
            )
            if follow then
              rename(s, follow, pending.markdown, pending.tick, done)
              return
            end
            done(nil, remote)
            return
          end
        else
          matches, previous = 0, nil
        end
      end
      vim.defer_fn(poll, math.min(c.verify_interval_ms, math.max(1, deadline - uv.hrtime() / 1e6)))
    end, { timeout_ms = math.max(1, math.min(c.timeout_ms, math.floor(remaining / 3))) })
  end
  poll()
end

local function renamed(s, fields)
  if not fields then
    return nil
  end
  local out, changed = {}, false
  for _, key in ipairs({ 'title', 'icon' }) do
    local value = fields[key]
    local current = s.baseline.meta[key]
    if key == 'icon' and value == nil then
      value = type(current) == 'string' and '' or nil
    end
    if value ~= nil and M.field(value) ~= M.field(current) then
      out[key] = value
      changed = true
    end
  end
  return changed and out or nil
end

function M.save(buf, cb)
  cb = cb
    or function(err, result)
      if err then
        notify(require('docmost.status').explain(err.message), vim.log.levels.ERROR)
      elseif result == 'noop' then
        notify('No changes to save')
      else
        notify('Save verified by repeated read-back')
      end
    end
  local s = M.current(buf)
  if not s then
    cb(fail('Not a Docmost buffer'))
    return
  end
  local reply = cb
  cb = function(err, result)
    if not (err and err.message == 'A page operation is already pending') then
      s.last_error = err and err.message or nil
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'DocmostPageStatus', modeline = false, data = { id = s.id } }
      )
    end
    reply(err, result)
  end
  if s.busy then
    cb(fail('A page operation is already pending'))
    return
  end
  s.cancelled = false
  if s.pending then
    s.busy = true
    verify(s, function(err, result)
      s.busy, s.request = false, nil
      cb(err, result)
    end)
    return
  end
  local snapshot = content(s)
  if snapshot == s.baseline.markdown or snapshot == s.saved_snapshot then
    vim.bo[s.buf].modified = false
    problems(s, {})
    cb(nil, 'noop')
    return
  end
  if not s.baseline.editable then
    cb(fail('Read-only: ' .. s.baseline.reason))
    return
  end
  if M.compatibility:match('^read%-only') then
    cb(fail(M.compatibility .. '; validate server compatibility before reopening Neovim'))
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(s.buf)
  if not backup(s, snapshot) then
    cb(fail('Private backup failed; save was not sent'))
    return
  end
  s.busy, s.snapshot = true, snapshot
  local function done(err, result)
    s.busy, s.request = false, nil
    cb(err, result)
  end
  local entries = identity.collect(s)
  local previous_status = s.status
  set(s, 'parsing Markdown')
  s.request = dfm.build(
    snapshot,
    entries,
    s.baseline.json,
    s.tail,
    function(err, doc, fields, positions)
      if s.cancelled then
        done(fail('Save cancelled before update', 'cancelled'))
        return
      end
      if err then
        if err.kind == 'validation' then
          problems(s, err.errors)
          set(s, 'conversion blocked')
        else
          set(s, 'preflight failed')
        end
        done(err)
        return
      end
      problems(s, {})
      if not valid(s) then
        done(fail('Buffer closed before update; nothing was written'))
        return
      end
      local title = renamed(s, fields)
      local body = not dfm.equal(doc, s.baseline.json)
      if not body and not title then
        s.saved_snapshot = snapshot
        if vim.api.nvim_buf_get_changedtick(s.buf) == tick then
          vim.bo[s.buf].modified = false
        end
        set(s, previous_status)
        done(nil, 'noop')
        return
      end
      set(s, 'checking remote')
      s.request = api.read(s.id, function(read_error, remote)
        if s.cancelled then
          set(s, 'preflight cancelled')
          done(fail('Save cancelled before update', 'cancelled'))
          return
        end
        if read_error then
          set(s, 'preflight failed')
          done(read_error)
          return
        end
        if not api.same(s.baseline, remote) then
          s.remote = remote
          set(s, 'conflict')
          done(
            fail(
              'Remote page changed; save blocked. Use :Docmost diff for base/local/remote, then explicitly reload and merge.',
              'conflict'
            )
          )
          return
        end
        if not valid(s) then
          done(fail('Buffer closed before update; nothing was written'))
          return
        end
        if not body then
          rename(s, title, snapshot, tick, done)
          return
        end
        s.pending = {
          kind = 'body',
          markdown = snapshot,
          tick = tick,
          before = s.baseline,
          json = doc,
          positions = positions,
          rename = title,
        }
        set(s, 'saving')
        if not backup(s, content(s)) then
          s.pending = nil
          done(fail('Could not record pending write; save was not sent'))
          return
        end
        s.request = api.update(s.id, doc, function(update_error)
          if
            update_error
            and (
              update_error.status == 400
              or update_error.status == 401
              or update_error.status == 403
              or update_error.status == 404
              or update_error.status == 429
            )
          then
            s.pending = nil
            set(s, 'save rejected')
            done(update_error)
            return
          end
          set(s, 'verifying')
          verify(s, done)
        end)
      end)
    end
  )
end

function M.reload(force, cb)
  cb = cb
    or function(err)
      if err then
        notify(err.message, vim.log.levels.ERROR)
      else
        notify('Reloaded')
      end
    end
  local s = M.current()
  if not s then
    cb(fail('Not a Docmost buffer'))
    return
  end
  if s.busy then
    cb(fail('A page operation is pending'))
    return
  end
  if (vim.bo[s.buf].modified or s.pending) and not force then
    cb(
      fail(
        'Local edits or uncertain save retained. :Docmost! reload explicitly discards them after a private backup.'
      )
    )
    return
  end
  if not backup(s, content(s)) then
    cb(fail('Private backup failed; reload cancelled'))
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(s.buf)
  s.busy = true
  s.cancelled = false
  local function finish(err, remote)
    s.busy, s.request = false, nil
    if s.cancelled then
      cb(fail('Reload cancelled', 'cancelled'))
      return
    end
    if err then
      cb(err)
      return
    end
    if not valid(s) or vim.api.nvim_buf_get_changedtick(s.buf) ~= tick then
      cb(fail('Buffer changed during reload; local edits retained'))
      return
    end
    vim.bo[s.buf].modifiable = true
    vim.api.nvim_buf_set_lines(
      s.buf,
      0,
      -1,
      false,
      vim.split(remote.markdown, '\n', { plain = true })
    )
    vim.bo[s.buf].modified, vim.bo[s.buf].readonly, vim.bo[s.buf].modifiable =
      false, not remote.editable, remote.editable
    s.baseline, s.pending, s.remote, s.snapshot = remote, nil, nil, remote.markdown
    s.saved_snapshot, s.last_error, s.tail = nil, nil, remote.tail
    identity.attach(s, remote.anchors)
    problems(s, {})
    vim.b[s.buf].docmost_title = remote.meta.title
    set(s, 'reloaded')
    cb(nil, remote)
  end
  s.request = api.read(s.id, function(err, remote)
    if err or s.cancelled then
      finish(err)
      return
    end
    s.request = prepare(remote, finish)
  end)
end

function M.check(cb)
  cb = cb
    or function(err, count)
      if err then
        notify(require('docmost.status').explain(err.message), vim.log.levels.ERROR)
      else
        notify('No problems found in ' .. count .. ' blocks; nothing was sent')
      end
    end
  local s = M.current()
  if not s then
    cb(fail('Not a Docmost buffer'))
    return
  end
  dfm.build(content(s), identity.collect(s), s.baseline.json, s.tail, function(err, doc)
    if err then
      if err.kind == 'validation' then
        problems(s, err.errors)
      end
      cb(err)
      return
    end
    problems(s, {})
    cb(nil, #doc.content)
  end)
end

function M.cancel()
  local s = M.current()
  if s and s.busy then
    s.cancelled = true
    if s.request then
      s.request.cancel()
    end
  end
end

function M.backup_all()
  for _, s in pairs(M.states) do
    if valid(s) and (vim.bo[s.buf].modified or s.pending) then
      if not backup(s, content(s)) then
        notify('Private exit backup failed', vim.log.levels.ERROR)
      end
    end
  end
end
return M
