local M = {}
local function problem(message)
  return { kind = 'contract', message = message }
end

function M.post(route, body, cb, opts)
  local auth = require('docmost.auth')
  return require('docmost.http').post(route, body, auth.token(), function(err, data)
    if err and err.kind == 'auth' then
      auth.expire()
    end
    cb(err, data)
  end, opts)
end

function M.identifier(input)
  local c = require('docmost.config').get()
  if type(input) ~= 'string' then
    return nil, 'Invalid page identifier'
  end
  if input:find('://', 1, true) then
    local origin, path = input:match('^(https?://[^/]+)(/.*)$')
    if origin ~= c.base_url then
      return nil, 'Page URL must belong to configured base_url'
    end
    input = path:match('/p/([^/?#]+)')
    if not input then
      return nil, 'Expected a Docmost /p/page-slug URL'
    end
    -- Browser URLs contain title-slugId; the endpoint accepts only slugId/UUID.
    local uuid =
      input:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$')
    if not uuid then
      input = input:match('([^%-]+)$')
    end
  end
  if type(input) ~= 'string' or #input > 250 or not input:match('^[%w_-]+$') then
    return nil, 'Invalid page identifier'
  end
  return input
end

function M.metadata(page)
  local out = {}
  for _, key in ipairs({
    'id',
    'title',
    'updatedAt',
    'spaceId',
    'parentPageId',
    'deletedAt',
    'permissions',
  }) do
    out[key] = page[key]
  end
  return out
end

function M.same(a, b)
  return vim.deep_equal(a.json, b.json)
    and a.markdown == b.markdown
    and vim.deep_equal(a.meta, b.meta)
end

function M.read(id, cb, opts)
  local current, cancelled
  local handle = {
    cancel = function()
      cancelled = true
      if current then
        current.cancel()
      end
    end,
  }
  local function request(format, next_step)
    if cancelled then
      cb({ kind = 'cancelled', message = 'Read cancelled' })
      return
    end
    current = M.post(
      '/pages/info',
      { pageId = id, includeContent = true, format = format },
      function(err, page)
        if cancelled then
          cb({ kind = 'cancelled', message = 'Read cancelled' })
          return
        end
        if err then
          cb(err)
          return
        end
        if type(page) ~= 'table' or type(page.id) ~= 'string' or not page.id:match('^[%w_-]+$') then
          cb(problem('Invalid page response'))
          return
        end
        next_step(page)
      end,
      opts
    )
  end
  request('json', function(first)
    id = first.id
    request('markdown', function(md)
      request('json', function(last)
        if
          not vim.deep_equal(first.content, last.content)
          or not vim.deep_equal(M.metadata(first), M.metadata(last))
          or not vim.deep_equal(M.metadata(md), M.metadata(last))
        then
          cb({
            kind = 'conflict',
            message = 'Page changed while reading; retry when the other editor is idle',
          })
          return
        end
        local json = last.content
        if json == nil or md.content == nil then
          cb(problem('Missing page content; cannot assess fidelity'))
          return
        end
        if json == vim.NIL then
          json = { type = 'doc', content = { { type = 'paragraph' } } }
        end
        if type(json) == 'string' then
          local ok, value = pcall(vim.json.decode, json)
          if not ok then
            cb(problem('Malformed page JSON content'))
            return
          end
          json = value
        end
        local markdown = md.content
        if (markdown == nil or markdown == vim.NIL) and require('docmost.fidelity').empty(json) then
          markdown = ''
        end
        if type(markdown) ~= 'string' then
          cb(problem('Missing Markdown content'))
          return
        end
        local editable, reason = require('docmost.fidelity').check(json)
        if type(last.permissions) == 'table' and last.permissions.canEdit == false then
          editable, reason = false, 'Server reports read-only permission'
        end
        cb(nil, {
          id = last.id,
          json = json,
          markdown = require('docmost.fidelity').normalize(markdown),
          meta = M.metadata(last),
          raw = last,
          editable = editable,
          reason = reason,
        })
      end)
    end)
  end)
  return handle
end

function M.update(id, markdown, cb, prepared_json)
  local body = { pageId = id, content = markdown, format = 'markdown', operation = 'replace' }
  if prepared_json then
    body.content, body.format = prepared_json, 'json'
  elseif markdown == '' then
    body.content, body.format = { type = 'doc', content = { { type = 'paragraph' } } }, 'json'
  end
  return M.post('/pages/update', body, cb)
end

function M.list(route, params, cb)
  local c = require('docmost.config').get()
  params = vim.deepcopy(params or {})
  params.limit = c.page_size
  return M.post(route, params, function(err, data)
    if err then
      cb(err)
      return
    end
    if type(data) ~= 'table' or type(data.items) ~= 'table' or not vim.islist(data.items) then
      cb(problem('Invalid list response'))
      return
    end
    local next_cursor
    if route == '/search' then
      -- Search has no total/cursor contract. Offer the next offset even after a
      -- short nonempty batch: permission filtering can shorten a server batch.
      if #data.items > 0 then
        next_cursor = (params.offset or 0) + params.limit
      end
    else
      if type(data.meta) ~= 'table' then
        cb(problem('Missing cursor metadata'))
        return
      end
      next_cursor = data.meta.nextCursor
      if next_cursor == vim.NIL then
        next_cursor = nil
      end
      if next_cursor ~= nil and type(next_cursor) ~= 'string' then
        cb(problem('Invalid pagination cursor'))
        return
      end
      if data.meta.hasNextPage and not next_cursor then
        cb(problem('Missing next page cursor'))
        return
      end
    end
    cb(nil, data.items, next_cursor)
  end)
end
return M
