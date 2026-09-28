local M = {}

local reserved = { id = true, class = true, wrapper = true }

function M.key(name)
  if reserved[name] or name:match('^x%-') or name:match('^data%-') or name:match('^dfm%-') then
    return 'x-' .. name
  end
  return name
end

function M.unkey(name)
  return (name:gsub('^x%-', '', 1))
end

function M.valid_key(name)
  return type(name) == 'string' and name:match('^[%a_][%w_:.-]*$') ~= nil
end

local function pct(text)
  return (text:gsub('[%%"%c]', function(c)
    return string.format('%%%02X', c:byte())
  end))
end

local function unpct(text)
  return (text:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function scalar(text)
  if text == 'true' or text == 'false' or text == 'null' then
    return true
  end
  if not text:match('^%-?%d') then
    return false
  end
  local ok, value = pcall(vim.json.decode, text)
  return ok and type(value) == 'number'
end

function M.encode(value)
  if value == vim.NIL or value == nil then
    return 'null'
  end
  local kind = type(value)
  if kind == 'boolean' then
    return tostring(value)
  end
  if kind == 'number' then
    return vim.json.encode(value)
  end
  if kind == 'string' then
    if scalar(value) or value:match('^j:') or value:find('[%c"]') then
      return 'j:' .. pct(vim.json.encode(value))
    end
    return value
  end
  return 'j:' .. pct(vim.json.encode(value))
end

function M.decode(text)
  if text:match('^j:') then
    local ok, value = pcall(vim.json.decode, unpct(text:sub(3)), { luanil = { object = false } })
    if ok then
      return value
    end
    return nil, 'Unreadable encoded attribute value'
  end
  if text == 'true' then
    return true
  elseif text == 'false' then
    return false
  elseif text == 'null' then
    return vim.NIL
  end
  if scalar(text) then
    return vim.json.decode(text)
  end
  return text
end

function M.format(classes, attrs, order)
  local parts = {}
  if not M.plain(attrs) then
    for _, class in ipairs(classes or {}) do
      parts[#parts + 1] = '.' .. class
    end
    parts[#parts + 1] = 'dfm-attrs="' .. M.encode(attrs) .. '"'
    return '{' .. table.concat(parts, ' ') .. '}'
  end
  for _, class in ipairs(classes or {}) do
    parts[#parts + 1] = '.' .. class
  end
  local keys = order or {}
  if not order then
    for key in pairs(attrs or {}) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
  end
  for _, key in ipairs(keys) do
    local value = attrs[key]
    if value ~= nil then
      parts[#parts + 1] = M.key(key) .. '="' .. M.encode(value) .. '"'
    end
  end
  if #parts == 0 then
    return ''
  end
  return '{' .. table.concat(parts, ' ') .. '}'
end

function M.plain(attrs)
  for key in pairs(attrs or {}) do
    if not M.valid_key(key) then
      return false
    end
  end
  return true
end

return M
