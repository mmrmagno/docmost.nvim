local M = {}
local attr = require('docmost.dfm.attr')
local schema = require('docmost.dfm.schema')

M.format = table.concat({
  'commonmark_x',
  '-smart',
  '-emoji',
  '-alerts',
  '-definition_lists',
  '-fancy_lists',
  '-raw_html',
  '-raw_attribute',
  '-yaml_metadata_block',
  '-implicit_header_references',
  '-gfm_auto_identifiers',
  '+sourcepos',
})

function M.run(text, cb)
  local c = require('docmost.config').get()
  if vim.fn.executable('pandoc') ~= 1 then
    cb({ kind = 'dependency', message = 'Install pandoc to edit Docmost pages' })
    return { cancel = function() end }
  end
  if #text > c.max_response_bytes then
    cb({ kind = 'parser', message = 'Page text exceeds configured size limit' })
    return { cancel = function() end }
  end
  local process, cancelled, oversized, size, chunks = nil, false, false, 0, {}
  local handle = {
    cancel = function()
      cancelled = true
      if process then
        process:kill(15)
      end
    end,
  }
  local ok, spawned = pcall(
    vim.system,
    { 'pandoc', '--from=' .. M.format, '--to=json', '--sandbox', '--preserve-tabs' },
    {
      stdin = text,
      timeout = math.max(c.timeout_ms, 10000),
      stdout = function(_, chunk)
        if chunk then
          size = size + #chunk
          if size > c.max_response_bytes * 8 then
            oversized = true
            if process then
              process:kill(15)
            end
          else
            chunks[#chunks + 1] = chunk
          end
        end
      end,
      stderr = function() end,
    },
    function(exit)
      vim.schedule(function()
        if cancelled or oversized or exit.code ~= 0 then
          cb({
            kind = cancelled and 'cancelled' or 'parser',
            message = cancelled and 'Markdown parsing cancelled'
              or 'Markdown parser failed, timed out, or exceeded size limit',
          })
          return
        end
        local decoded, ast = pcall(vim.json.decode, table.concat(chunks))
        if not decoded or type(ast) ~= 'table' or type(ast.blocks) ~= 'table' then
          cb({ kind = 'parser', message = 'Markdown parser returned unreadable output' })
          return
        end
        cb(nil, ast)
      end)
    end
  )
  if not ok then
    cb({ kind = 'dependency', message = 'Could not start Pandoc' })
  else
    process = spawned
  end
  return handle
end

local function byte_col(line, col)
  if not line or col <= 1 then
    return 0
  end
  local ok, index = pcall(vim.str_byteindex, line, 'utf-32', col - 1, false)
  if not ok then
    ok, index = pcall(vim.str_byteindex, line, col - 1)
  end
  return ok and index or (col - 1)
end

local Converter = {}
Converter.__index = Converter

function M.converter(lines)
  return setmetatable({ lines = lines, positions = {}, errors = {}, row = 0 }, Converter)
end

function Converter:fail(message, pos)
  local row = pos and pos.row or self.row
  local key = row .. '\0' .. message
  self.seen = self.seen or {}
  if self.seen[key] then
    return
  end
  self.seen[key] = true
  self.errors[#self.errors + 1] = { row = row, message = message }
end

function Converter:pos(text)
  if type(text) ~= 'string' then
    return nil
  end
  local row, col = text:match('(%d+):(%d+)')
  if not row then
    return nil
  end
  row = tonumber(row)
  return { row = row - 1, col = byte_col(self.lines[row], tonumber(col)) }
end

function Converter:attr(a, pos_hint)
  local identifier, classes, pairs_ = a[1], a[2] or {}, a[3] or {}
  local kv, flags, pos, keys = {}, {}, nil, 0
  for _, pair in ipairs(pairs_) do
    local key, value = pair[1], pair[2]
    if key == 'data-pos' then
      pos = self:pos(value)
    elseif key == 'wrapper' then
      flags.wrapper = true
    elseif key == 'dfm-node' or key == 'dfm-inline' then
      flags[key] = true
    elseif key == 'dfm-attrs' then
      local decoded, err = attr.decode(value)
      if type(decoded) ~= 'table' then
        self:fail(err or 'dfm-attrs must hold an encoded object', pos or pos_hint)
      else
        for k, v in pairs(decoded) do
          kv[k] = v
          keys = keys + 1
        end
      end
    else
      local decoded, err = attr.decode(value)
      if err then
        self:fail(err .. ' (' .. key .. ')', pos or pos_hint)
      end
      kv[attr.unkey(key)] = decoded
      keys = keys + 1
    end
  end
  if identifier and identifier ~= '' and kv.id == nil then
    kv.id = identifier
    keys = keys + 1
  end
  return { classes = classes, kv = kv, keys = keys, flags = flags, pos = pos }
end

local function append_text(out, text, marks)
  if text == '' then
    return
  end
  local list = {}
  for _, m in ipairs(marks or {}) do
    list[#list + 1] = vim.deepcopy(m)
  end
  local last = out[#out]
  if last and last.type == 'text' and vim.deep_equal(last.marks or {}, list) then
    last.text = last.text .. text
    return
  end
  local node = { type = 'text', text = text }
  if #list > 0 then
    node.marks = list
  end
  out[#out + 1] = node
end

local function with_marks(node, marks)
  if #marks > 0 then
    node.marks = vim.deepcopy(marks)
  end
  return node
end

local function mark(list, entry)
  local out = vim.deepcopy(list)
  out[#out + 1] = entry
  return out
end

local simple_marks = {
  Emph = 'italic',
  Strong = 'bold',
  Strikeout = 'strike',
  Subscript = 'subscript',
  Superscript = 'superscript',
  Underline = 'underline',
}

function Converter:unwrap(list)
  local out = {}
  for _, item in ipairs(list or {}) do
    if item.t == 'Span' then
      local a = self:attr(item.c[1])
      if a.flags.wrapper then
        out[#out + 1] = { t = '__pos', pos = a.pos }
        vim.list_extend(out, self:unwrap(item.c[2]))
      else
        out[#out + 1] = item
      end
    else
      out[#out + 1] = item
    end
  end
  return out
end

function Converter:first_pos(list)
  for _, item in ipairs(list or {}) do
    if item.t == 'Span' then
      local a = self:attr(item.c[1])
      if a.pos then
        return a.pos
      end
    end
    local c = item.c
    if type(c) == 'table' and type(c[1]) == 'table' and type(c[1][3]) == 'table' then
      local a = self:attr(c[1])
      if a.pos then
        return a.pos
      end
    end
  end
end

local function plain_text(converter, list)
  local out = {}
  for _, node in ipairs(converter:inlines(list, {})) do
    if node.type ~= 'text' or node.marks then
      return nil
    end
    out[#out + 1] = node.text
  end
  return table.concat(out)
end

function Converter:inlines(list, marks)
  local out = {}
  for _, item in ipairs(self:unwrap(list)) do
    local t, c = item.t, item.c
    if t == '__pos' then
      if item.pos then
        self.row = item.pos.row
      end
    elseif t == 'Str' then
      append_text(out, c, marks)
    elseif t == 'Space' or t == 'SoftBreak' then
      append_text(out, ' ', marks)
    elseif t == 'LineBreak' then
      out[#out + 1] = { type = 'hardBreak' }
    elseif simple_marks[t] then
      for _, node in ipairs(self:inlines(c, mark(marks, { type = simple_marks[t] }))) do
        if node.type == 'text' then
          append_text(out, node.text, node.marks)
        else
          out[#out + 1] = node
        end
      end
    elseif t == 'Code' then
      local a = self:attr(c[1])
      local entry = { type = 'code' }
      if a.keys > 0 then
        entry.attrs = a.kv
      end
      append_text(out, c[2], mark(marks, entry))
    elseif t == 'Math' then
      if c[1].t == 'DisplayMath' then
        self:fail('Display math ($$ … $$) must be alone in its own paragraph')
      else
        out[#out + 1] = with_marks({ type = 'mathInline', attrs = { text = c[2] } }, marks)
      end
    elseif t == 'Link' then
      local a = self:attr(c[1])
      if #a.classes > 0 then
        self:fail(
          'Links with a class, such as attachments, must be alone in their paragraph',
          a.pos
        )
      end
      local attrs = a.kv
      if c[3][1] ~= '' then
        attrs.href = c[3][1]
      end
      for _, node in ipairs(self:inlines(c[2], mark(marks, { type = 'link', attrs = attrs }))) do
        if node.type == 'text' then
          append_text(out, node.text, node.marks)
        else
          out[#out + 1] = node
        end
      end
    elseif t == 'Span' then
      local a = self:attr(c[1])
      local class = a.classes[1]
      if not class then
        if a.keys > 0 then
          self:fail(
            'Attributes on text need a class, for example [text]{.highlight color="yellow"}',
            a.pos
          )
        end
        for _, node in ipairs(self:inlines(c[2], marks)) do
          if node.type == 'text' then
            append_text(out, node.text, node.marks)
          else
            out[#out + 1] = node
          end
        end
      elseif schema.inline_nodes[class] or a.flags['dfm-node'] then
        local node = { type = class }
        if a.keys > 0 then
          node.attrs = a.kv
        end
        local inner = self:inlines(c[2], {})
        if class == 'mention' then
          local label = plain_text(self, c[2])
          if label and label:sub(1, 1) == '@' and (node.attrs or {}).label == nil then
            node.attrs = node.attrs or {}
            node.attrs.label = label:sub(2)
          end
        elseif #inner > 0 then
          node.content = inner
        end
        out[#out + 1] = with_marks(node, marks)
      else
        local entry = { type = class }
        if a.keys > 0 then
          entry.attrs = a.kv
        end
        for _, node in ipairs(self:inlines(c[2], mark(marks, entry))) do
          if node.type == 'text' then
            append_text(out, node.text, node.marks)
          else
            out[#out + 1] = node
          end
        end
      end
    elseif t == 'Image' then
      self:fail('Images and other media must be on their own line')
    elseif t == 'Note' then
      self:fail('Markdown footnotes are not supported; copy an existing footnote block instead')
    elseif t == 'Quoted' then
      local q = c[1].t == 'DoubleQuote' and '"' or "'"
      append_text(out, q, marks)
      for _, node in ipairs(self:inlines(c[2], marks)) do
        if node.type == 'text' then
          append_text(out, node.text, node.marks)
        else
          out[#out + 1] = node
        end
      end
      append_text(out, q, marks)
    elseif t == 'RawInline' then
      append_text(out, c[2], marks)
    else
      self:fail('Unsupported inline Markdown: ' .. tostring(t))
    end
  end
  return out
end

function Converter:place(node, pos)
  if pos then
    self.positions[node] = pos
  end
  return node
end

local function sole(list)
  local found
  for _, item in ipairs(list) do
    if item.t ~= '__pos' and item.t ~= 'Space' and item.t ~= 'SoftBreak' then
      if found then
        return nil
      end
      found = item
    end
  end
  return found
end

function Converter:media(item, pos)
  local t, c = item.t, item.c
  if t ~= 'Image' and t ~= 'Link' then
    return nil
  end
  local a = self:attr(c[1])
  local class = a.classes[1]
  local spec = class and schema.media[class]
  if not spec or (spec.link and t ~= 'Link') or (not spec.link and t ~= 'Image') then
    return nil
  end
  local attrs = a.kv
  if c[3][1] ~= '' then
    attrs[spec.url] = c[3][1]
  end
  local text = plain_text(self, c[2])
  if text == nil then
    self:fail('Media captions must be plain text', pos)
  elseif text ~= '' and spec.text then
    attrs[spec.text] = text
  end
  local node = { type = class }
  if next(attrs) then
    node.attrs = attrs
  end
  return self:place(node, pos)
end

function Converter:empty_marker(c, pos)
  local items = self:unwrap(c)
  local only = sole(items)
  if not (only and only.t == 'Str' and only.c == '\\') then
    return false
  end
  local at = self:first_pos(c) or pos
  local line = at and self.lines[at.row + 1]
  if line then
    return line:sub(at.col + 1, at.col + 2) ~= '\\\\'
  end
  return true
end

function Converter:paragraph(c, pos)
  local items = self:unwrap(c)
  local only = sole(items)
  local inline_pos = self:first_pos(c) or pos
  if only then
    if self:empty_marker(c, pos) then
      return self:place({ type = 'paragraph' }, inline_pos)
    end
    local m = self:media(only, pos)
    if m then
      return m
    end
    if only.t == 'Math' and only.c[1].t == 'DisplayMath' then
      return self:place({ type = 'mathBlock', attrs = { text = only.c[2] } }, pos)
    end
  end
  local node = { type = 'paragraph' }
  local content = self:inlines(c, {})
  if #content > 0 then
    node.content = content
  end
  return self:place(node, inline_pos)
end

local function merge(node, kv)
  node.attrs = node.attrs or {}
  for key, value in pairs(kv) do
    node.attrs[key] = value
  end
end

local function unwrap_block(converter, b)
  if b.t == 'Div' then
    local a = converter:attr(b.c[1])
    if a.flags.wrapper and #b.c[2] == 1 then
      return b.c[2][1]
    end
  end
  return b
end

function Converter:task(item)
  local first = item[1] and unwrap_block(self, item[1])
  if not first or (first.t ~= 'Plain' and first.t ~= 'Para') then
    return nil
  end
  for _, x in ipairs(self:unwrap(first.c)) do
    if x.t ~= '__pos' then
      if x.t == 'Str' and (x.c:sub(1, 3) == '☐' or x.c:sub(1, 3) == '☒') then
        return x.c:sub(1, 3) == '☒', 'glyph'
      end
      break
    end
  end
  local pos = self:first_pos(first.c)
  local line = pos and self.lines[pos.row + 1]
  if not line then
    return nil
  end
  local rest = line:sub(pos.col + 1)
  local box = rest:match('^%[([ xX])%] ') or rest:match('^%[([ xX])%]$')
  if box then
    return box ~= ' ', 'source'
  end
  return nil
end

local function token_length(token)
  if token.t == 'Str' then
    return #token.c
  elseif token.t == 'Space' or token.t == 'SoftBreak' then
    return 1
  end
  return math.huge
end

function Converter:consume(list, n)
  local out = {}
  for _, item in ipairs(list) do
    if n <= 0 then
      out[#out + 1] = item
    else
      local wrapped = item.t == 'Span' and self:attr(item.c[1]).flags.wrapper
      local inner = wrapped and item.c[2] or { item }
      local length = 0
      for _, token in ipairs(inner) do
        length = length + token_length(token)
      end
      if length <= n then
        n = n - length
      elseif #inner == 1 and inner[1].t == 'Str' then
        local copy = vim.deepcopy(item)
        local target = wrapped and copy.c[2][1] or copy
        target.c = target.c:sub(n + 1)
        n = 0
        out[#out + 1] = copy
      else
        n = 0
        out[#out + 1] = item
      end
    end
  end
  return out
end

function Converter:list_item(item, task_mode)
  local blocks = {}
  for _, b in ipairs(item) do
    blocks[#blocks + 1] = unwrap_block(self, b)
  end
  local checked
  if task_mode then
    local how
    checked, how = self:task(item)
    local first = vim.deepcopy(blocks[1])
    if how == 'glyph' then
      local rest, stripped = {}, false
      for _, x in ipairs(first.c) do
        local token = x
        if x.t == 'Span' and self:attr(x.c[1]).flags.wrapper then
          token = x.c[2][1] or x
        end
        if
          not stripped
          and token.t == 'Str'
          and (token.c:sub(1, 3) == '☐' or token.c:sub(1, 3) == '☒')
        then
          stripped = true
          if token.c:sub(4) ~= '' then
            rest[#rest + 1] = { t = 'Str', c = token.c:sub(4) }
          end
        elseif not (stripped and #rest == 0 and token.t == 'Space') then
          rest[#rest + 1] = x
        end
      end
      first.c = rest
    else
      first.c = self:consume(first.c, 4)
    end
    if #first.c == 0 and #blocks > 1 then
      table.remove(blocks, 1)
    else
      blocks[1] = first
    end
  end
  local content = self:blocks(blocks)
  if #content == 0 then
    content = { { type = 'paragraph' } }
  end
  local node = { type = task_mode and 'taskItem' or 'listItem', content = content }
  if task_mode then
    node.attrs = { checked = checked == true }
  end
  return node
end

function Converter:list(t, c, pos)
  local items = t == 'OrderedList' and c[2] or c
  local tasks, plain = 0, 0
  if t == 'BulletList' then
    for _, item in ipairs(items) do
      if self:task(item) ~= nil then
        tasks = tasks + 1
      else
        plain = plain + 1
      end
    end
    if tasks > 0 and plain > 0 then
      self:fail('A list mixes task items (- [ ]) and plain items; use one kind per list', pos)
    end
  end
  local task_mode = tasks > 0 and plain == 0
  local node = {
    type = task_mode and 'taskList' or (t == 'OrderedList' and 'orderedList' or 'bulletList'),
    content = {},
  }
  if t == 'OrderedList' then
    node.attrs = { start = c[1][1] }
  end
  for _, item in ipairs(items) do
    node.content[#node.content + 1] = self:list_item(item, task_mode)
  end
  return self:place(node, pos)
end

function Converter:cell(cell, header)
  local blocks = cell[5]
  local node = {
    type = header and 'tableHeader' or 'tableCell',
    attrs = vim.deepcopy(schema.cell),
  }
  node.attrs.colspan, node.attrs.rowspan = cell[4], cell[3]
  local content = self:blocks(blocks)
  if #content == 0 then
    content = { { type = 'paragraph' } }
  end
  node.content = content
  return node
end

function Converter:table(c, pos)
  local node = { type = 'table', content = {} }
  local function rows(list, header)
    for _, row in ipairs(list) do
      local r = { type = 'tableRow', content = {} }
      for _, cell in ipairs(row[2]) do
        r.content[#r.content + 1] = self:cell(cell, header)
      end
      node.content[#node.content + 1] = r
    end
  end
  rows(c[4][2], true)
  for _, body in ipairs(c[5]) do
    rows(body[3], true)
    rows(body[4], false)
  end
  rows(c[6][2], false)
  return self:place(node, pos)
end

function Converter:div(c, pos)
  local a = self:attr(c[1])
  pos = a.pos or pos
  if a.flags.wrapper then
    local out = {}
    for index, child in ipairs(c[2]) do
      for _, node in ipairs(self:block(child, index == 1 and pos or nil)) do
        out[#out + 1] = node
      end
    end
    return out
  end
  local class = a.classes[1]
  if not class then
    local children = self:blocks(c[2])
    if a.keys == 0 then
      return children
    end
    if #children ~= 1 then
      self:fail('An attribute block {…} must wrap exactly one block', pos)
      return children
    end
    merge(children[1], a.kv)
    return children
  end
  local node = { type = class }
  if a.keys > 0 then
    node.attrs = a.kv
  end
  if schema.textblocks[class] or a.flags['dfm-inline'] then
    local body = {}
    for _, child in ipairs(c[2]) do
      if child.t == 'Div' and self:attr(child.c[1]).flags.wrapper then
        vim.list_extend(body, child.c[2])
      else
        body[#body + 1] = child
      end
    end
    if #body > 1 or (body[1] and body[1].t ~= 'Para' and body[1].t ~= 'Plain') then
      self:fail('A ' .. class .. ' block holds a single line of text', pos)
    elseif body[1] then
      if not self:empty_marker(body[1].c, pos) then
        local content = self:inlines(body[1].c, {})
        if #content > 0 then
          node.content = content
        end
      end
    end
  else
    local content = self:blocks(c[2])
    if #content > 0 then
      node.content = content
    end
  end
  return { self:place(node, pos) }
end

function Converter:block(item, pos)
  local t, c = item.t, item.c
  if pos then
    self.row = pos.row
  end
  if t == 'Div' then
    return self:div(c, pos)
  end
  if t == 'Para' or t == 'Plain' then
    return { self:paragraph(c, pos) }
  end
  if t == 'Header' then
    local a = self:attr(c[2])
    pos = a.pos or pos
    local node = { type = 'heading', attrs = { level = c[1] } }
    local content = self:inlines(c[3], {})
    if #content > 0 then
      node.content = content
    end
    local kv = a.kv
    kv.id = nil
    merge(node, kv)
    return { self:place(node, self:first_pos(c[3]) or pos) }
  end
  if t == 'CodeBlock' then
    local a = self:attr(c[1])
    local node = { type = 'codeBlock' }
    if a.classes[1] then
      node.attrs = { language = a.classes[1] }
    end
    if #a.classes > 1 then
      self:fail('A code block takes one language', a.pos or pos)
    end
    local kv = a.kv
    kv.id = nil
    if next(kv) then
      merge(node, kv)
    end
    if c[2] ~= '' then
      node.content = { { type = 'text', text = c[2] } }
    end
    return { self:place(node, a.pos or pos) }
  end
  if t == 'HorizontalRule' then
    return { self:place({ type = 'horizontalRule' }, pos) }
  end
  if t == 'BlockQuote' then
    local node = { type = 'blockquote' }
    local content = self:blocks(c)
    if #content > 0 then
      node.content = content
    end
    return { self:place(node, pos) }
  end
  if t == 'BulletList' or t == 'OrderedList' then
    return { self:list(t, c, pos) }
  end
  if t == 'Table' then
    local a = self:attr(c[1])
    return { self:table(c, a.pos or pos) }
  end
  if t == 'Null' then
    return {}
  end
  self:fail('Unsupported Markdown block: ' .. tostring(t), pos)
  return {}
end

function Converter:blocks(list)
  local out = {}
  for _, item in ipairs(list or {}) do
    for _, node in ipairs(self:block(item)) do
      out[#out + 1] = node
    end
  end
  return out
end

function M.convert(ast, text)
  local converter = M.converter(vim.split(text, '\n', { plain = true }))
  local content = converter:blocks(ast.blocks)
  return content, converter.positions, converter.errors
end

function M.parse(text, cb)
  return M.run(text, function(err, ast)
    if err then
      cb(err)
      return
    end
    local ok, content, positions, errors = pcall(M.convert, ast, text)
    if not ok then
      cb({ kind = 'parser', message = 'Could not interpret the Markdown: ' .. tostring(content) })
      return
    end
    cb(nil, content, positions, errors)
  end)
end

return M
