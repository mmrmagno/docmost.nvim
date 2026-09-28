local M = { states = {}, opening = {}, compatibility = 'unverified' }
local api = require('docmost.api')
local fidelity = require('docmost.fidelity')
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
    M.opening[id] = nil
    if err then
      cb(err)
      return
    end
    if M.states[page.id] and reuse(M.states[page.id]) then
      return
    end
    local s = { id = page.id, baseline = page }
    M.states[s.id] = s
    attach(s, page.markdown, false, target_win)
    set(s, 'opened')
    if not page.editable then
      notify('Read-only: ' .. require('docmost.status').explain(page.reason), vim.log.levels.WARN)
    end
    cb(nil, s)
  end)
end

local function verified(s, remote, snapshot, tick)
  s.baseline, s.pending, s.remote = remote, nil, nil
  s.saved_snapshot = snapshot
  M.compatibility = 'HTTP body persistence observed'
  if valid(s) then
    local unchanged = vim.api.nvim_buf_get_changedtick(s.buf) == tick and content(s) == snapshot
    -- Never replace the buffer here, including on server canonicalization.
    vim.bo[s.buf].modified = not unchanged
    vim.bo[s.buf].readonly = not remote.editable
    vim.bo[s.buf].modifiable = remote.editable or vim.bo[s.buf].modified
  else
    s.detached_modified = s.snapshot ~= snapshot
  end
  set(s, 'verified')
  if not remote.editable then
    notify('Saved page is now read-only: ' .. remote.reason, vim.log.levels.WARN)
  end
end

local function verify(s, done)
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
      if s.remote and s.remote.markdown == pending.before.markdown then
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
        local body_matches = remote.markdown == pending.markdown
        if pending.json then
          body_matches = require('docmost.markdown').matches(pending.json, remote.json)
        end
        if pending.markdown == '' then
          body_matches = body_matches and fidelity.empty(remote.json)
        end
        -- A title/parent/space change during the write is a conflict, even if
        -- Markdown happens to match. updatedAt is expected to change.
        for _, key in ipairs({ 'id', 'title', 'spaceId', 'parentPageId', 'deletedAt' }) do
          if not vim.deep_equal(remote.meta[key], pending.before.meta[key]) then
            body_matches = false
          end
        end
        if body_matches then
          matches = previous and api.same(previous, remote) and (matches + 1) or 1
          previous = remote
          if matches >= c.verify_reads then
            verified(s, remote, pending.markdown, pending.tick)
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
  local supported, reason = fidelity.local_check(snapshot)
  if not supported then
    cb(fail(reason))
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(s.buf)
  if not backup(s, snapshot) then
    cb(fail('Private backup failed; save was not sent'))
    return
  end
  s.busy, s.snapshot = true, snapshot
  set(s, 'checking remote')
  local function done(err, result)
    s.busy, s.request = false, nil
    cb(err, result)
  end
  local function preflight(prepared)
    set(s, 'checking remote')
    s.request = api.read(s.id, function(err, remote)
      if s.cancelled then
        set(s, 'preflight cancelled')
        done(fail('Save cancelled before update', 'cancelled'))
        return
      end
      if err then
        set(s, 'preflight failed')
        done(err)
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
      s.pending = { markdown = snapshot, tick = tick, before = s.baseline, json = prepared }
      set(s, 'saving')
      if not backup(s, content(s)) then
        s.pending = nil
        done(fail('Could not record pending write; save was not sent'))
        return
      end
      s.request = api.update(s.id, snapshot, function(update_error)
        -- Definitive rejection cannot have persisted. Network errors and 5xx can.
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
      end, prepared)
    end)
  end
  local markdown = require('docmost.markdown')
  if markdown.needed(s.baseline.json) then
    set(s, 'parsing Markdown')
    s.request = markdown.parse(s.baseline.markdown, function(base_error, parsed_base)
      if base_error or s.cancelled or not valid(s) then
        done(base_error or fail('Save cancelled before update', 'cancelled'))
        return
      end
      s.request = markdown.parse(snapshot, function(edit_error, parsed_edit)
        if edit_error or s.cancelled or not valid(s) then
          done(edit_error or fail('Save cancelled before update', 'cancelled'))
          return
        end
        local prepared, reason = markdown.prepare(s.baseline, parsed_base, parsed_edit)
        if not prepared then
          set(s, 'conversion blocked')
          done(fail(reason, 'fidelity'))
          return
        end
        preflight(prepared)
      end)
    end)
  else
    preflight()
  end
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
  s.request = api.read(s.id, function(err, remote)
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
    s.saved_snapshot, s.last_error = nil, nil
    vim.b[s.buf].docmost_title = remote.meta.title
    set(s, 'reloaded')
    cb(nil, remote)
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
