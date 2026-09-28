local M = { status = 'not validated' }
local token, disabled = nil, false
local function session_path()
  local c = require('docmost.config').get()
  return c.state_dir .. '/session-' .. vim.fn.sha256(c.base_url):sub(1, 16) .. '.json'
end

function M.token()
  if disabled then
    return nil
  end
  if token then
    return token
  end
  local c = require('docmost.config').get()
  if c.session_token then
    local ok, value = pcall(c.session_token)
    if not ok then
      return nil
    end
    token = value
  elseif c.session_file or c.persist_session then
    local ok, raw = pcall(require('docmost.storage').read, c.session_file or session_path())
    if not ok then
      M.status = 'session file unreadable or not private'
      return nil
    end
    if raw then
      local parsed, data = pcall(vim.json.decode, raw)
      if parsed and type(data) == 'table' and data.base_url == c.base_url then
        token = data.token
      end
    end
  end
  return token
end

function M.expire()
  token, disabled, M.status = nil, true, 'expired; login required'
end

function M.validate(cb)
  return require('docmost.http').post('/users/me', {}, M.token(), function(err, data)
    local user = type(data) == 'table' and (data.user or data) or nil
    if not err and (type(user) ~= 'table' or type(user.id) ~= 'string') then
      err = { kind = 'contract', message = 'Invalid current-user response; session not validated' }
    end
    if err then
      M.status = 'not authenticated'
      if err.kind == 'auth' then
        M.expire()
      end
    else
      M.status = 'authenticated'
    end
    cb(err, user)
  end)
end

function M.login(email, password, cb)
  require('docmost.http').post(
    '/auth/login',
    { email = email, password = password },
    nil,
    function(err, _, cookie)
      if err then
        cb(err)
        return
      end
      if not cookie then
        cb({
          message = 'Login returned no session cookie (SSO/MFA may require an external session)',
        })
        return
      end
      token, disabled = cookie, false
      M.validate(function(validation_error, user)
        if not validation_error and require('docmost.config').get().persist_session then
          local storage, c = require('docmost.storage'), require('docmost.config').get()
          local ok = pcall(function()
            storage.directory(c.state_dir)
            storage.write(session_path(), vim.json.encode({ base_url = c.base_url, token = token }))
          end)
          if not ok then
            cb({ message = 'Authenticated in memory, but private session storage failed' })
            return
          end
        end
        cb(validation_error, user)
      end)
    end,
    { capture_cookie = true }
  )
end

function M.logout()
  require('docmost.http').cancel_all()
  token, disabled, M.status = nil, true, 'logged out locally'
  local uv = vim.uv or vim.loop
  uv.fs_unlink(session_path())
end

function M.reset()
  token, disabled, M.status = nil, false, 'not validated'
end
return M
