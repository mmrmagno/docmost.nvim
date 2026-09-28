local M = {}

local function child_kind(node)
  return node.kind == 'root' and 'space' or 'page'
end

function M.new(base_url)
  local session = {
    base_url = base_url,
    nodes = {},
    mode = 'browse',
    cursor = {},
    topline = {},
    previews = {},
    preview_order = {},
    preview_errors = {},
    search = { query = '', items = {}, seen = {}, pages = 0, token = 0 },
  }
  session.root = { key = 'root', kind = 'root', depth = -1, expanded = true, seen = {}, pages = 0 }
  session.nodes.root = session.root
  return session
end

function M.node(session, kind, item, parent)
  local key = kind .. ':' .. item.id
  local node = session.nodes[key]
  if not node then
    node = { key = key, kind = kind, seen = {}, pages = 0 }
    session.nodes[key] = node
  end
  node.item, node.parent, node.depth = item, parent, parent.depth + 1
  if kind == 'space' then
    node.space_id = item.id
  else
    node.space_id = type(item.spaceId) == 'string' and item.spaceId or parent.space_id
  end
  if item.hasChildren == false then
    node.leaf = true
  elseif item.hasChildren == true then
    node.leaf = false
  end
  return node
end

function M.label(node)
  local item = node.item or {}
  local value = node.kind == 'space' and (item.name or item.slug) or item.title
  if type(value) ~= 'string' or value == '' then
    return node.kind == 'space' and 'Unnamed space' or 'Untitled'
  end
  return value
end

function M.ancestors(node)
  local out = {}
  local current = node and node.parent
  while current and current.kind ~= 'root' do
    table.insert(out, 1, current)
    current = current.parent
  end
  return out
end

local function request(node)
  if node.kind == 'root' then
    return '/spaces', {}
  end
  local params = { spaceId = node.space_id }
  if node.kind == 'page' then
    params.pageId = node.item.id
  end
  return '/pages/sidebar-pages', params
end

function M.fetch(session, node, more, done)
  if node.loading then
    return
  end
  if node.kind == 'page' and not node.space_id then
    node.error = { message = 'Space unknown; browse this page from its space' }
    done(node.error)
    return
  end
  local cursor = more and node.next_cursor or nil
  if more and (not cursor or node.seen[cursor]) then
    return
  end
  if more and node.pages >= require('docmost.config').get().max_pages then
    node.error = { message = 'Pagination limit reached' }
    done(node.error)
    return
  end
  if not more then
    node.seen, node.pages, node.next_cursor = {}, 0, nil
  end
  local route, params = request(node)
  params.cursor = cursor
  node.loading, node.error = true, nil
  node.token = (node.token or 0) + 1
  local token = node.token
  node.request = require('docmost.api').list(route, params, function(err, items, next_cursor)
    if node.token ~= token then
      return
    end
    node.loading, node.request = false, nil
    if err then
      node.error = err
      done(err)
      return
    end
    if cursor then
      node.seen[cursor] = true
    end
    local list, existing = more and node.children or {}, {}
    for _, child in ipairs(list) do
      existing[child.item.id] = true
    end
    for _, item in ipairs(items) do
      if type(item) == 'table' and type(item.id) == 'string' and not existing[item.id] then
        list[#list + 1] = M.node(session, child_kind(node), item, node)
        existing[item.id] = true
      end
    end
    node.children = list
    node.pages = node.pages + 1
    node.next_cursor = next_cursor and not node.seen[next_cursor] and next_cursor or nil
    if node.kind == 'page' then
      node.leaf = #list == 0
    end
    done()
  end)
end

function M.search(session, query, more, done)
  local s = session.search
  if s.request then
    s.request.cancel()
    s.request = nil
  end
  s.token = s.token + 1
  local token = s.token
  if not more then
    s.query, s.items, s.seen, s.pages, s.next_offset, s.error = query, {}, {}, 0, nil, nil
  end
  s.loading = false
  if #vim.trim(s.query) < 2 then
    done()
    return
  end
  local offset = more and s.next_offset or 0
  if more and (not offset or s.seen[offset]) then
    return
  end
  if more and s.pages >= require('docmost.config').get().max_pages then
    s.error = { message = 'Pagination limit reached' }
    done(s.error)
    return
  end
  s.loading, s.error = true, nil
  s.request = require('docmost.api').list(
    '/search',
    { query = s.query, offset = offset },
    function(err, items, next_offset)
      if s.token ~= token then
        return
      end
      s.loading, s.request = false, nil
      if err then
        s.error = err
        done(err)
        return
      end
      s.seen[offset] = true
      local existing = {}
      for _, entry in ipairs(s.items) do
        existing[entry.item.id] = true
      end
      for _, item in ipairs(items) do
        if type(item) == 'table' and type(item.id) == 'string' and not existing[item.id] then
          s.items[#s.items + 1] = { key = 'result:' .. item.id, kind = 'result', item = item }
          existing[item.id] = true
        end
      end
      s.pages = s.pages + 1
      s.next_offset = #items > 0 and next_offset and not s.seen[next_offset] and next_offset or nil
      done()
    end
  )
end

function M.cancel(session)
  for _, node in pairs(session.nodes) do
    if node.request then
      node.token = (node.token or 0) + 1
      node.request.cancel()
      node.request, node.loading = nil, false
    end
  end
  local s = session.search
  if s.request then
    s.token = s.token + 1
    s.request.cancel()
    s.request, s.loading = nil, false
  end
end

function M.forget(session)
  M.cancel(session)
  local fresh = M.new(session.base_url)
  for key, value in pairs(fresh) do
    session[key] = value
  end
end

function M.busy(session)
  if session.search.loading then
    return true
  end
  for _, node in pairs(session.nodes) do
    if node.loading then
      return true
    end
  end
  return false
end

return M
