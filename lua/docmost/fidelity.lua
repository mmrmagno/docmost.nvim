local M = {}
local nodes = {
  doc = true,
  paragraph = true,
  text = true,
  heading = true,
  blockquote = true,
  bulletList = true,
  orderedList = true,
  listItem = true,
  codeBlock = true,
  horizontalRule = true,
}
local marks = { bold = true, italic = true, strike = true, code = true }
local function null(v)
  return v == vim.NIL or v == nil
end

local function attribute(kind, key, value)
  if kind == 'paragraph' or kind == 'heading' then
    if key == 'id' then
      return null(value) or type(value) == 'string'
    end
    if key == 'textAlign' then
      return null(value) or value == 'left'
    end
    if key == 'indent' then
      return value == 0
    end
  end
  if key == 'dir' then
    return null(value) or value == 'auto'
  end
  if kind == 'heading' and key == 'level' then
    return type(value) == 'number' and value >= 1 and value <= 6
  end
  if kind == 'orderedList' and key == 'start' then
    return type(value) == 'number' and value >= 1
  end
  if kind == 'orderedList' and key == 'type' then
    return null(value)
  end
  if kind == 'codeBlock' and key == 'language' then
    return null(value) or type(value) == 'string'
  end
  return false
end

function M.check(doc)
  if type(doc) ~= 'table' or doc.type ~= 'doc' then
    return false, 'Missing or unknown JSON document'
  end
  local function visit(node, depth, mark)
    if depth > 100 or type(node) ~= 'table' then
      return 'Invalid document structure'
    end
    if not (mark and marks or nodes)[node.type] then
      return 'Unsupported ' .. (mark and 'mark' or 'node') .. ': ' .. tostring(node.type)
    end
    for key in pairs(node) do
      if
        key ~= 'type'
        and key ~= 'attrs'
        and key ~= 'content'
        and key ~= 'marks'
        and key ~= 'text'
      then
        return 'Unknown document field: ' .. key
      end
    end
    if node.attrs ~= nil and type(node.attrs) ~= 'table' then
      return 'Invalid attributes'
    end
    for key, value in pairs(node.attrs or {}) do
      if not attribute(node.type, key, value) then
        return 'Unsupported attribute: ' .. node.type .. '.' .. key
      end
    end
    if node.text ~= nil and type(node.text) ~= 'string' then
      return 'Invalid text'
    end
    for _, field in ipairs({ 'content', 'marks' }) do
      if node[field] ~= nil and (type(node[field]) ~= 'table' or not vim.islist(node[field])) then
        return 'Invalid ' .. field
      end
      for _, child in ipairs(node[field] or {}) do
        local reason = visit(child, depth + 1, field == 'marks')
        if reason then
          return reason
        end
      end
    end
  end
  local reason = visit(doc, 0, false)
  if
    not reason
    and require('docmost.markdown').needed(doc)
    and vim.fn.executable('pandoc') ~= 1
  then
    reason = 'Install pandoc to preserve block IDs and default attributes when saving'
  end
  return not reason, reason
end

function M.empty(doc)
  return type(doc) == 'table'
    and doc.type == 'doc'
    and type(doc.content) == 'table'
    and #doc.content == 1
    and type(doc.content[1]) == 'table'
    and doc.content[1].type == 'paragraph'
    and (
      doc.content[1].content == nil
      or (type(doc.content[1].content) == 'table' and #doc.content[1].content == 0)
    )
end

-- No trimming: blank lines, hard-break spaces and code indentation are meaningful.
function M.normalize(md)
  return (md:gsub('\r\n', '\n'))
end

function M.local_check(md)
  -- Do not knowingly introduce rich content through replacement. The server is
  -- still authoritative; novel Markdown syntax may fail read-back verification.
  local fence
  for line in (md .. '\n'):gmatch('(.-)\n') do
    local run = line:match('^%s*(```+)') or line:match('^%s*(~~~+)')
    if run then
      if not fence then
        fence = run:sub(1, 1)
      elseif run:sub(1, 1) == fence then
        fence = nil
      end
    elseif not fence then
      if
        line:find('!%[')
        or line:find('<[/!%a]')
        or line:match('^%s*:::')
        or line:match('^%s*[-*+] %[[ xX]%]')
        or line:find('%[%^')
        or line:match('^%s*|')
      then
        return false, 'New rich Markdown/HTML is outside the supported subset'
      end
    end
  end
  return true
end
return M
