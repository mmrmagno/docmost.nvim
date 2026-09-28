local M = { active = {} }

local function error_result(kind, message, status)
  return { kind = kind, message = message, status = status }
end

local function quote(s)
  return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\r', '\\r'):gsub('\n', '\\n') .. '"'
end

function M.post(route, body, token, callback, opts)
  local c = require('docmost.config').get()
  opts = opts or {}
  assert(route:match('^/[a-z/-]+$'), 'invalid internal route')
  local config = {
    'url = ' .. quote(c.base_url .. '/api' .. route),
    'header = "Content-Type: application/json"',
    'header = "Accept: application/json"',
    'header = ' .. quote('Origin: ' .. c.base_url),
    'data-binary = ' .. quote(vim.json.encode(next(body) == nil and vim.empty_dict() or body)),
  }
  if token then
    if type(token) ~= 'string' or not token:match('^[%w._~+/%-=]+$') then
      vim.schedule(function()
        callback(error_result('auth', 'Invalid session token'))
      end)
      return { cancel = function() end }
    end
    config[#config + 1] = 'header = ' .. quote('Cookie: authToken=' .. token)
  end
  local chunks, bytes, too_large, cancelled, process = {}, 0, false, false, nil
  local handle = {}
  function handle.cancel()
    cancelled = true
    if process then
      process:kill(15)
    end
  end
  M.active[handle] = true
  local function finish(result)
    M.active[handle] = nil
    local err, data, cookie
    if cancelled then
      err = error_result('cancelled', 'Request cancelled')
    elseif too_large then
      err = error_result('size', 'Response exceeded configured size limit')
    elseif result.code ~= 0 then
      err = error_result(
        result.code == 28 and 'timeout' or 'network',
        result.code == 28 and 'Request timed out' or 'Network/TLS request failed'
      )
    else
      local raw = table.concat(chunks)
      local status, headers, response
      -- curl -i can include proxy CONNECT and informational response headers.
      while raw:match('^HTTP/') do
        local stop = raw:find('\r\n\r\n', 1, true)
        if not stop then
          break
        end
        headers, response = raw:sub(1, stop - 1), raw:sub(stop + 4)
        status = tonumber(headers:match('^HTTP/%S+ (%d+)'))
        raw = response
      end
      if not status then
        err = error_result('protocol', 'Missing HTTP response status')
      elseif status == 401 then
        err = error_result('auth', 'Session expired or login rejected; use :Docmost login', status)
      elseif status == 403 then
        err = error_result('permission', 'Permission denied', status)
      elseif status == 429 then
        err = error_result('rate_limit', 'Rate limited; wait before retrying', status)
      elseif status >= 300 and status < 400 then
        err = error_result('redirect', 'Redirect refused; check base_url and session', status)
      elseif status < 200 or status >= 300 then
        err = error_result('http', 'HTTP request failed (' .. status .. ')', status)
      elseif not headers:lower():match('content%-type:%s*application/[%w.+-]*json') then
        err =
          error_result('content_type', 'Expected JSON; received a proxy/login or non-JSON response')
      else
        local ok, decoded = pcall(vim.json.decode, response)
        if not ok or type(decoded) ~= 'table' then
          err = error_result('json', 'Malformed JSON response')
        elseif
          decoded.success == false or (type(decoded.status) == 'number' and decoded.status >= 400)
        then
          err = error_result('application', 'Application rejected request')
        else
          data = decoded.data ~= nil and decoded.data or decoded
          for line in headers:gmatch('[^\r\n]+') do
            if line:lower():match('^set%-cookie:') then
              cookie = line:match('^.-:%s*authToken=([^;%s]+)') or cookie
            end
          end
        end
      end
    end
    callback(err, data, opts.capture_cookie and cookie or nil)
  end
  local ok, proc = pcall(vim.system, {
    'curl',
    '--disable',
    '--silent',
    '--show-error',
    '--include',
    '--no-location',
    '--proto',
    '=http,https',
    '--max-time',
    tostring((opts.timeout_ms or c.timeout_ms) / 1000),
    '--connect-timeout',
    tostring(math.min(c.timeout_ms, 10000) / 1000),
    '--config',
    '-',
  }, {
    stdin = table.concat(config, '\n'),
    stdout = function(_, chunk)
      if chunk then
        bytes = bytes + #chunk
        if bytes > c.max_response_bytes then
          too_large = true
          if process then
            process:kill(15)
          end
        else
          chunks[#chunks + 1] = chunk
        end
      end
    end,
    stderr = function() end,
  }, function(result)
    vim.schedule(function()
      finish(result)
    end)
  end)
  config = nil
  if not ok then
    M.active[handle] = nil
    vim.schedule(function()
      callback(error_result('process', 'Could not start curl'))
    end)
  else
    process = proc
  end
  return handle
end

function M.cancel_all()
  for handle in pairs(M.active) do
    handle.cancel()
  end
end
return M
