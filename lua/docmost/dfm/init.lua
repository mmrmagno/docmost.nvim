local M = {}
local serialize = require('docmost.dfm.serialize')
local parse = require('docmost.dfm.parse')
local schema = require('docmost.dfm.schema')

local function null(v)
  return v == nil or v == vim.NIL
end

function M.split_tail(doc)
  local copy, tail = vim.deepcopy(doc), {}
  copy.content = copy.content or {}
  while #copy.content > 0 do
    local last = copy.content[#copy.content]
    if last.type ~= 'paragraph' or #(last.content or {}) > 0 then
      break
    end
    local _, visible = schema.split(last)
    if next(visible) then
      break
    end
    table.insert(tail, 1, table.remove(copy.content))
  end
  return copy, tail
end

local function clean_attrs(attrs)
  local out = {}
  for key, value in pairs(attrs or {}) do
    if not null(value) then
      out[key] = value
    end
  end
  return next(out) and out or nil
end

local function merge_text(list)
  local out = {}
  for _, node in ipairs(list) do
    local last = out[#out]
    if
      node.type == 'text'
      and last
      and last.type == 'text'
      and vim.deep_equal(last.marks, node.marks)
      and vim.deep_equal(last.extra, node.extra)
    then
      last.text = last.text .. node.text
    elseif not (node.type == 'text' and node.text == '') then
      out[#out + 1] = node
    end
  end
  return out
end

function M.normalize(node)
  local out = { type = node.type, text = node.text, attrs = clean_attrs(node.attrs) }
  for key, value in pairs(node) do
    if
      key ~= 'type'
      and key ~= 'text'
      and key ~= 'attrs'
      and key ~= 'content'
      and key ~= 'marks'
    then
      out.extra = out.extra or {}
      out.extra[key] = value
    end
  end
  if node.marks and #node.marks > 0 then
    local marks = {}
    for _, m in ipairs(node.marks) do
      marks[#marks + 1] = { type = m.type, attrs = clean_attrs(m.attrs) }
    end
    table.sort(marks, function(a, b)
      if a.type == b.type then
        return vim.json.encode(a.attrs or {}) < vim.json.encode(b.attrs or {})
      end
      return a.type < b.type
    end)
    out.marks = marks
  end
  if node.content then
    local content = {}
    for _, child in ipairs(node.content) do
      content[#content + 1] = M.normalize(child)
    end
    content = merge_text(content)
    if #content > 0 then
      out.content = content
    end
  end
  return out
end

function M.equal(a, b)
  return vim.deep_equal(M.normalize(a), M.normalize(b))
end

local function preserved(expected, actual)
  if expected.type ~= actual.type or expected.text ~= actual.text then
    return false
  end
  for key, value in pairs(expected.attrs or {}) do
    if not vim.deep_equal(value, (actual.attrs or {})[key]) then
      return false
    end
  end
  local em, am = expected.marks or {}, actual.marks or {}
  if #em ~= #am then
    return false
  end
  for i, m in ipairs(em) do
    if m.type ~= am[i].type then
      return false
    end
    for key, value in pairs(m.attrs or {}) do
      if not vim.deep_equal(value, (am[i].attrs or {})[key]) then
        return false
      end
    end
  end
  local ec, ac = expected.content or {}, actual.content or {}
  local limit = #ac
  if expected.type == 'doc' then
    while limit > #ec do
      local extra = ac[limit]
      if extra.type ~= 'paragraph' or extra.content then
        break
      end
      limit = limit - 1
    end
  end
  if #ec ~= limit then
    return false
  end
  for i = 1, #ec do
    if not preserved(ec[i], ac[i]) then
      return false
    end
  end
  return true
end

function M.matches(expected, actual)
  if type(expected) ~= 'table' or type(actual) ~= 'table' then
    return false
  end
  return preserved(M.normalize(expected), M.normalize(actual))
end

local function quote(value)
  if value == '' or value:match('^%s') or value:match('%s$') or value:match('^"') then
    return vim.json.encode(value)
  end
  return value
end

function M.front(meta)
  local c = require('docmost.config').get()
  if not c.edit_title then
    return {}
  end
  local lines = { '---', 'title: ' .. quote(type(meta.title) == 'string' and meta.title or '') }
  if type(meta.icon) == 'string' and meta.icon ~= '' then
    lines[#lines + 1] = 'icon: ' .. quote(meta.icon)
  end
  lines[#lines + 1] = '---'
  lines[#lines + 1] = ''
  return lines
end

function M.read_front(text)
  local c = require('docmost.config').get()
  if not c.edit_title then
    return nil, text, 0
  end
  local lines = vim.split(text, '\n', { plain = true })
  if lines[1] ~= '---' then
    return nil, text, 0
  end
  local fields, stop = {}, nil
  for i = 2, math.min(#lines, 20) do
    if lines[i] == '---' then
      stop = i
      break
    end
  end
  if not stop then
    return nil, text, 0, 'Front matter needs a closing --- line'
  end
  for i = 2, stop - 1 do
    local key, value = lines[i]:match('^(%a+):%s?(.*)$')
    if not key then
      return nil, text, 0, 'Front matter lines look like "title: My page"'
    end
    if value:match('^"') then
      local ok, decoded = pcall(vim.json.decode, value)
      if not ok or type(decoded) ~= 'string' then
        return nil, text, 0, 'Quoted front matter values must be valid JSON strings'
      end
      value = decoded
    end
    fields[key] = value
  end
  local offset = stop
  if lines[stop + 1] == '' then
    offset = stop + 1
  end
  return fields, table.concat(vim.list_slice(lines, offset + 1), '\n'), offset
end

function M.text(page, safe)
  local body = M.split_tail(page.json)
  local text, anchors = serialize.document(body.content, { safe = safe })
  local front = M.front(page.meta or {})
  for _, a in ipairs(anchors) do
    a.row = a.row + #front
  end
  local full = table.concat(front, '\n') .. (#front > 0 and '\n' or '') .. text
  return full, anchors
end

local function walk(list, fn)
  for _, node in ipairs(list or {}) do
    fn(node)
    walk(node.content, fn)
  end
end

local function signature(node)
  local copy = M.normalize(node)
  copy.attrs = nil
  return vim.json.encode(copy)
end

function M.entries(anchors)
  local out = {}
  for _, a in ipairs(anchors) do
    local hidden = schema.split(a.node)
    out[#out + 1] = { row = a.row, col = a.col, type = a.node.type, hidden = hidden }
  end
  return out
end

function M.assign(content, positions, entries, baseline, offset)
  offset = offset or 0
  local by_row = {}
  for _, e in ipairs(entries or {}) do
    by_row[e.row] = by_row[e.row] or {}
    table.insert(by_row[e.row], e)
  end
  local prose = { paragraph = true, heading = true }
  local used, unmatched = {}, {}
  walk(content, function(node)
    if not prose[node.type] then
      return
    end
    local pos = positions[node]
    local found
    if pos then
      local distance = math.huge
      for _, e in ipairs(by_row[pos.row + offset] or {}) do
        if not used[e] and prose[e.type] and math.abs(e.col - pos.col) < distance then
          found, distance = e, math.abs(e.col - pos.col)
        end
      end
    end
    if found then
      used[found] = true
      local attrs = vim.deepcopy(found.hidden)
      for key, value in pairs(node.attrs or {}) do
        attrs[key] = value
      end
      if found.hidden.id ~= nil then
        attrs.id = found.hidden.id
      end
      node.attrs = next(attrs) and attrs or nil
    else
      unmatched[#unmatched + 1] = node
    end
  end)
  if not baseline then
    return
  end
  local taken = {}
  walk(content, function(node)
    local id = node.attrs and node.attrs.id
    if prose[node.type] and type(id) == 'string' then
      taken[id] = true
    end
  end)
  local candidates, counts = {}, {}
  walk(baseline.content, function(node)
    local id = node.attrs and node.attrs.id
    if prose[node.type] and type(id) == 'string' and not taken[id] then
      local sig = signature(node)
      counts[sig] = (counts[sig] or 0) + 1
      candidates[sig] = node
    end
  end)
  local wanted = {}
  for _, node in ipairs(unmatched) do
    local sig = signature(node)
    wanted[sig] = (wanted[sig] or 0) + 1
  end
  local function adopt(node, source)
    local attrs = vim.deepcopy((schema.split(source)))
    for key, value in pairs(node.attrs or {}) do
      attrs[key] = value
    end
    node.attrs = next(attrs) and attrs or nil
  end
  for _, node in ipairs(unmatched) do
    local sig = signature(node)
    if counts[sig] == 1 and wanted[sig] == 1 then
      adopt(node, candidates[sig])
    end
  end
  local mine, theirs, index = {}, {}, {}
  walk(content, function(node)
    if prose[node.type] then
      mine[#mine + 1] = node
      local id = node.attrs and node.attrs.id
      if type(id) == 'string' then
        taken[id] = true
      end
    end
  end)
  walk(baseline.content, function(node)
    if prose[node.type] then
      theirs[#theirs + 1] = node
      local id = node.attrs and node.attrs.id
      if type(id) == 'string' then
        index[id] = #theirs
      end
    end
  end)
  local last, gap = 0, {}
  local function settle(stop)
    local free = {}
    for b = last + 1, stop - 1 do
      local id = theirs[b].attrs and theirs[b].attrs.id
      if not (type(id) == 'string' and taken[id]) then
        free[#free + 1] = theirs[b]
      end
    end
    if #free == #gap then
      for i, node in ipairs(gap) do
        if free[i].type == node.type or prose[free[i].type] then
          adopt(node, free[i])
        end
      end
    end
  end
  for _, node in ipairs(mine) do
    local id = node.attrs and node.attrs.id
    local at = type(id) == 'string' and index[id]
    if at and at > last then
      settle(at)
      last, gap = at, {}
    elseif not at then
      gap[#gap + 1] = node
    else
      gap = {}
      last = math.huge
    end
  end
  if last ~= math.huge then
    settle(#theirs + 1)
  end
end

function M.assemble(content, baseline, tail)
  local doc = { type = 'doc', content = content }
  if baseline and baseline.attrs then
    doc.attrs = vim.deepcopy(baseline.attrs)
  end
  if #content == 0 then
    local paragraph = { type = 'paragraph' }
    local first = (tail or {})[1]
    if first then
      paragraph.attrs = vim.deepcopy(first.attrs)
    end
    doc.content = { paragraph }
  else
    for _, item in ipairs(tail or {}) do
      doc.content[#doc.content + 1] = vim.deepcopy(item)
    end
  end
  return doc
end

local function compare(expected, actual)
  local failing = {}
  if #expected ~= #actual then
    for i = 1, #expected do
      failing[i] = true
    end
    return failing, false
  end
  local all = true
  for i = 1, #expected do
    if not M.equal(expected[i], actual[i]) then
      failing[i] = true
      all = false
    end
  end
  return failing, all
end

function M.load(page, cb)
  local body, tail = M.split_tail(page.json)
  local front = M.front(page.meta or {})
  local current
  local handle = {
    cancel = function()
      if current then
        current.cancel()
      end
    end,
  }
  local function attempt(safe, final)
    local rendered, text, anchors = pcall(serialize.document, body.content, { safe = safe })
    if not rendered then
      cb(nil, {
        text = page.markdown or '',
        anchors = {},
        tail = tail,
        editable = false,
        reason = 'Page content has an unexpected structure',
      })
      return
    end
    current = parse.parse(text, function(err, content, positions, errors)
      if err then
        cb(err)
        return
      end
      if #errors == 0 then
        M.assign(content, positions, M.entries(anchors))
      end
      local failing, ok = compare(body.content, content)
      if ok and #errors == 0 then
        for _, a in ipairs(anchors) do
          a.row = a.row + #front
        end
        local full = table.concat(front, '\n') .. (#front > 0 and '\n' or '') .. text
        cb(nil, { text = full, anchors = anchors, tail = tail, editable = true })
        return
      end
      if final then
        local index = 1
        for i = 1, #body.content do
          if failing[i] then
            index = i
            break
          end
        end
        local node = body.content[index]
        cb(nil, {
          text = select(2, pcall(M.text, page)) or '',
          anchors = {},
          tail = tail,
          editable = false,
          reason = 'Round trip failed for content[' .. index .. '] (' .. tostring(
            node and node.type
          ) .. ')',
        })
        return
      end
      local next_safe = {}
      for i in pairs(failing) do
        next_safe[i] = true
      end
      if #errors > 0 or not next(next_safe) then
        for i = 1, #body.content do
          next_safe[i] = true
        end
      end
      attempt(next_safe, true)
    end)
  end
  attempt(nil, false)
  return handle
end

function M.known(baseline)
  local nodes, marks = vim.deepcopy(schema.known), vim.deepcopy(schema.marks)
  walk({ baseline }, function(node)
    nodes[node.type] = true
    for _, m in ipairs(node.marks or {}) do
      marks[m.type] = true
    end
  end)
  return nodes, marks
end

function M.validate(doc, positions, baseline)
  local nodes, marks = M.known(baseline or { type = 'doc' })
  local errors = {}
  local anchor
  local function fail(node, message)
    local pos = positions[node] or anchor
    errors[#errors + 1] = { row = pos and pos.row or 0, message = message }
  end
  local function visit(node, parent)
    local saved = anchor
    anchor = positions[node] or anchor
    if not nodes[node.type] then
      fail(node, 'Unknown Docmost block type "' .. node.type .. '"')
    end
    for _, m in ipairs(node.marks or {}) do
      if not marks[m.type] then
        fail(node, 'Unknown text style ".' .. m.type .. '"')
      end
    end
    if node.type == 'heading' then
      local level = node.attrs and node.attrs.level
      if type(level) ~= 'number' or level < 1 or level > 6 then
        fail(node, 'Headings have levels 1 to 6')
      end
    end
    if node.type == 'listItem' or node.type == 'taskItem' then
      local first = (node.content or {})[1]
      if not first or first.type ~= 'paragraph' then
        fail(node, 'A list item must start with a line of text')
      end
    end
    if node.type == 'tableRow' and parent and parent.type ~= 'table' then
      fail(node, 'Table rows belong inside a table')
    end
    if
      (node.type == 'tableCell' or node.type == 'tableHeader')
      and parent
      and parent.type ~= 'tableRow'
    then
      fail(node, 'Table cells belong inside a row')
    end
    for _, child in ipairs(node.content or {}) do
      visit(child, node)
    end
    anchor = saved
  end
  visit(doc)
  return errors
end

function M.build(text, entries, baseline, tail, cb)
  local fields, body, offset, front_error = M.read_front(text)
  if front_error then
    cb({
      kind = 'validation',
      message = front_error,
      errors = { { row = 0, message = front_error } },
    })
    return { cancel = function() end }
  end
  return parse.parse(body, function(err, content, positions, errors)
    if err then
      cb(err)
      return
    end
    for _, e in ipairs(errors) do
      e.row = e.row + offset
    end
    M.assign(content, positions, entries, baseline, offset)
    local doc = M.assemble(content, baseline, tail)
    local shifted = {}
    for node, pos in pairs(positions) do
      shifted[node] = { row = pos.row + offset, col = pos.col }
    end
    vim.list_extend(errors, M.validate(doc, shifted, baseline))
    if #errors > 0 then
      cb({
        kind = 'validation',
        message = 'Line ' .. (errors[1].row + 1) .. ': ' .. errors[1].message,
        errors = errors,
      })
      return
    end
    cb(nil, doc, fields, shifted)
  end)
end

return M
