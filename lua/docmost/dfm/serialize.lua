local M = {}
local attr = require('docmost.dfm.attr')
local schema = require('docmost.dfm.schema')

local function null(v)
  return v == nil or v == vim.NIL
end

local function has_attrs(attrs)
  for _, value in pairs(attrs or {}) do
    if not null(value) then
      return true
    end
  end
  return false
end

local function whitespace(text, first, last)
  text = text:gsub('\t', '&#9;'):gsub('\r', '&#13;'):gsub('\n', '&#10;')
  text = text:gsub('  +', function(run)
    return ' ' .. string.rep('&#32;', #run - 1)
  end)
  if first then
    text = text:gsub('^ ', '&#32;')
  end
  if last then
    text = text:gsub(' $', '&#32;')
  end
  return text
end

local function escape(text, ctx, first, last)
  local out
  if ctx.safe then
    out = text:gsub('%p', '\\%0')
  else
    out = text:gsub('[\\`*_%[%]<~^$|&{}]', '\\%0')
  end
  out = whitespace(out, first, last)
  if first and ctx.line_start then
    out = out:gsub('^([#>+=:-])', '\\%1')
    out = out:gsub('^(%d+)([.)])', '%1\\%2')
  end
  return out
end
M.escape = escape

local function url_safe(url)
  return type(url) == 'string' and url ~= '' and not url:find('[%s()<>\\]')
end

local function mark_equal(a, b)
  return a.type == b.type and vim.deep_equal(a.attrs or {}, b.attrs or {})
end

local function has_mark(list, mark)
  for _, m in ipairs(list or {}) do
    if mark_equal(m, mark) then
      return true
    end
  end
  return false
end

local function fence_for(text, char)
  local longest = 0
  for run in text:gmatch(char .. '+') do
    longest = math.max(longest, #run)
  end
  return string.rep(char, math.max(3, longest + 1))
end

local inline, inlines

local function code_span(text)
  if text == '' or text:find('\n') then
    return nil
  end
  local longest = 0
  for run in text:gmatch('`+') do
    longest = math.max(longest, #run)
  end
  local ticks = string.rep('`', longest + 1)
  local pad = text:match('^`') or text:match('`$') or (text:match('^ ') and text:match(' $'))
  if text:match('^ +$') then
    pad = false
  end
  if pad then
    return ticks .. ' ' .. text .. ' ' .. ticks
  end
  return ticks .. text .. ticks
end

local function span(inner, class, attrs, extra)
  local spec = attr.format({ class }, attrs or {})
  if extra then
    spec = spec:sub(1, -2) .. ' ' .. extra .. '}'
  end
  return '[' .. inner .. ']' .. spec
end

local function wrap(mark, inner, ctx, segs, nested)
  local t = mark.type
  if not ctx.safe and not has_attrs(mark.attrs) then
    if t == 'bold' then
      return '**' .. inner .. '**'
    elseif t == 'italic' then
      return '*' .. inner .. '*'
    elseif t == 'strike' then
      return '~~' .. inner .. '~~'
    end
  end
  if t == 'code' and not ctx.safe and not has_attrs(mark.attrs) then
    local covered = #segs == 1 and segs[1].node.type == 'text'
    for _, m in ipairs(covered and segs[1].marks or {}) do
      covered = covered and has_mark(nested, m)
    end
    if covered and not (ctx.indented and segs[1].node.text:find('\t')) then
      local code = code_span(segs[1].node.text)
      if code then
        return code
      end
    end
  end
  if t == 'link' and not ctx.safe then
    local rest = vim.deepcopy(mark.attrs or {})
    local href = rest.href
    if url_safe(href) then
      rest.href = nil
      return '[' .. inner .. '](' .. href .. ')' .. attr.format({}, rest)
    end
  end
  return span(inner, t, mark.attrs)
end

local function atom(node, ctx, first, last)
  local t, a = node.type, node.attrs or {}
  if t == 'hardBreak' and not has_attrs(a) and not ctx.safe and not last then
    return '\\\n'
  end
  if t == 'mathInline' and not ctx.safe then
    local text = a.text
    local only = true
    for key, value in pairs(a) do
      if key ~= 'text' and not null(value) then
        only = false
      end
    end
    if
      only
      and type(text) == 'string'
      and text ~= ''
      and not text:find('[%$\n]')
      and not text:match('^%s')
      and not text:match('%s$')
    then
      return '$' .. text .. '$'
    end
  end
  if t == 'mention' and type(a.label) == 'string' and a.label ~= '' then
    local rest = vim.deepcopy(a)
    rest.label = nil
    return span('@' .. escape(a.label, ctx, false, false), 'mention', rest)
  end
  local inner = node.content and inlines(node.content, ctx, false) or ''
  return span(inner, t, a, not schema.inline_nodes[t] and 'dfm-node="true"' or nil)
end

inline = function(node, ctx, first, last)
  if node.type == 'text' then
    return escape(node.text or '', ctx, first, last)
  end
  return atom(node, ctx, first, last)
end

inlines = function(list, ctx, line_start)
  local segs = {}
  for _, node in ipairs(list or {}) do
    segs[#segs + 1] = { node = node, marks = node.marks or {} }
  end
  local sub = vim.tbl_extend('force', ctx, { line_start = line_start })
  local function render(i, j, active)
    local out, k = {}, i
    while k <= j do
      local candidates = {}
      for _, mark in ipairs(segs[k].marks) do
        if not has_mark(active, mark) then
          candidates[#candidates + 1] = mark
        end
      end
      if #candidates == 0 then
        sub.line_start = line_start and k == 1 and #active == 0
        out[#out + 1] = inline(segs[k].node, sub, k == 1, k == #segs)
        k = k + 1
      else
        local best, best_end = nil, k - 1
        for _, mark in ipairs(candidates) do
          local r = k
          while r + 1 <= j and has_mark(segs[r + 1].marks, mark) do
            r = r + 1
          end
          if r > best_end or (r == best_end and mark.type == 'link') then
            best, best_end = mark, r
          end
        end
        local nested = vim.list_extend(vim.deepcopy(active), { best })
        local inner = render(k, best_end, nested)
        local slice = {}
        for x = k, best_end do
          slice[#slice + 1] = segs[x]
        end
        out[#out + 1] = wrap(best, inner, sub, slice, nested)
        k = best_end + 1
      end
    end
    return table.concat(out)
  end
  return render(1, #segs, {})
end
M.inlines = inlines

local blocks, block

local function lines_of(text)
  return vim.split(text, '\n', { plain = true })
end

local function result(lines, anchors, divs)
  return { lines = lines, anchors = anchors or {}, divs = divs or 0 }
end

local function prefix(r, first, rest)
  local out, anchors = {}, {}
  for i, line in ipairs(r.lines) do
    local p = i == 1 and first or rest
    if line == '' then
      out[i] = (p:gsub('%s+$', ''))
    else
      out[i] = p .. line
    end
  end
  for _, a in ipairs(r.anchors) do
    local p = a.row == 0 and first or rest
    anchors[#anchors + 1] = { row = a.row, col = a.col + #p, node = a.node }
  end
  return result(out, anchors, r.divs)
end

local function join(parts, tight)
  local lines, anchors, divs = {}, {}, 0
  for index, part in ipairs(parts) do
    if index > 1 and not (tight and tight(index)) then
      lines[#lines + 1] = ''
    end
    local offset = #lines
    vim.list_extend(lines, part.lines)
    for _, a in ipairs(part.anchors) do
      anchors[#anchors + 1] = { row = a.row + offset, col = a.col, node = a.node }
    end
    divs = math.max(divs, part.divs)
  end
  return result(lines, anchors, divs)
end

local function fenced(classes, attrs, inner, extra)
  local depth = inner and inner.divs or 0
  local colons = string.rep(':', 3 + depth)
  local spec = attr.format(classes, attrs or {})
  if extra then
    spec = spec == '' and ('{' .. extra .. '}') or (spec:sub(1, -2) .. ' ' .. extra .. '}')
  end
  local lines = { colons .. (spec ~= '' and (' ' .. spec) or '') }
  local anchors = {}
  if inner then
    for _, a in ipairs(inner.anchors) do
      anchors[#anchors + 1] = { row = a.row + 1, col = a.col, node = a.node }
    end
    vim.list_extend(lines, inner.lines)
  end
  lines[#lines + 1] = colons
  return result(lines, anchors, depth + 1)
end

local function generic(node, ctx)
  local content = node.content
  local inner
  local extra
  if content and #content > 0 then
    if schema.is_inline(content[1]) then
      inner = result(lines_of(inlines(content, ctx, true)))
      if not schema.textblocks[node.type] then
        extra = 'dfm-inline="true"'
      end
    else
      inner = blocks(content, ctx)
    end
  end
  return fenced({ node.type }, node.attrs, inner, extra)
end

local function with_visible(node, r)
  local _, visible = schema.split(node)
  if not has_attrs(visible) then
    return r
  end
  return fenced({}, visible, r)
end

local function textblock(node, ctx)
  local text = inlines(node.content, ctx, true)
  if text == '' then
    text = '\\'
  end
  return lines_of(text)
end

local function list_items(node, ctx, marker)
  local parts = {}
  local number = (node.attrs and type(node.attrs.start) == 'number') and node.attrs.start or 1
  for index, item in ipairs(node.content or {}) do
    local mark
    if node.type == 'orderedList' then
      mark = tostring(number + index - 1) .. marker .. ' '
    else
      mark = marker .. ' '
    end
    local children = item.content or {}
    local task = ''
    if item.type == 'taskItem' then
      task = (item.attrs and item.attrs.checked == true) and '[x] ' or '[ ] '
    end
    local body
    if #children == 0 then
      body = result({ '' })
    else
      body = blocks(children, vim.tbl_extend('force', ctx, { indented = true }), function(i)
        return children[i - 1].type == 'paragraph'
          and (
            children[i].type == 'bulletList'
            or children[i].type == 'orderedList'
            or children[i].type == 'taskList'
          )
      end)
    end
    if task ~= '' then
      body = prefix(body, task, '')
    end
    parts[#parts + 1] = prefix(body, mark, string.rep(' ', #mark))
  end
  local loose = false
  for _, item in ipairs(node.content or {}) do
    local count = 0
    for _, child in ipairs(item.content or {}) do
      if
        not (
          count > 0
          and (
            child.type == 'bulletList'
            or child.type == 'orderedList'
            or child.type == 'taskList'
          )
        )
      then
        count = count + 1
      end
    end
    loose = loose or count > 1
  end
  return join(parts, function()
    return not loose
  end)
end

local function list_ok(node)
  for _, item in ipairs(node.content or {}) do
    local expect = node.type == 'taskList' and 'taskItem' or 'listItem'
    if item.type ~= expect or has_attrs(schema.item_extra(item)) then
      return false
    end
    if node.type == 'taskList' then
      local first = (item.content or {})[1]
      if not first or first.type ~= 'paragraph' then
        return false
      end
    end
  end
  return true
end

local function pipe_table(node, ctx)
  local rows = node.content or {}
  if #rows < 1 or has_attrs(node.attrs) then
    return nil
  end
  local width
  local grid = {}
  for r, row in ipairs(rows) do
    if row.type ~= 'tableRow' or has_attrs(row.attrs) then
      return nil
    end
    local cells = row.content or {}
    width = width or #cells
    if #cells ~= width or width == 0 then
      return nil
    end
    grid[r] = {}
    for c, cell in ipairs(cells) do
      if cell.type ~= (r == 1 and 'tableHeader' or 'tableCell') then
        return nil
      end
      if not schema.canonical_cell(cell.attrs) then
        return nil
      end
      local content = cell.content or {}
      if #content ~= 1 or content[1].type ~= 'paragraph' then
        return nil
      end
      local _, visible = schema.split(content[1])
      if has_attrs(visible) then
        return nil
      end
      local text = inlines(content[1].content, vim.tbl_extend('force', ctx, { cell = true }), false)
      if text:find('\n') then
        return nil
      end
      grid[r][c] = { text = text == '' and '\\' or text, node = content[1] }
    end
  end
  local lines, anchors = {}, {}
  local function emit(cells)
    local line = '|'
    for _, cell in ipairs(cells) do
      line = line .. ' '
      anchors[#anchors + 1] = { row = #lines, col = #line, node = cell.node }
      line = line .. cell.text .. ' |'
    end
    lines[#lines + 1] = line
  end
  emit(grid[1])
  local sep = '|'
  for _ = 1, width do
    sep = sep .. ' --- |'
  end
  lines[#lines + 1] = sep
  for r = 2, #grid do
    emit(grid[r])
  end
  return result(lines, anchors)
end

local function media(node, ctx)
  local spec = schema.media[node.type]
  if not spec or ctx.safe then
    return nil
  end
  local rest = vim.deepcopy(node.attrs or {})
  local url = rest[spec.url]
  local label = spec.text and rest[spec.text]
  local text = ''
  if type(label) == 'string' and label ~= '' then
    text = escape(label, ctx, false, false)
    rest[spec.text] = nil
  end
  local target = ''
  if url_safe(url) then
    target = url
    rest[spec.url] = nil
  end
  local body = (spec.link and '' or '!') .. '[' .. text .. '](' .. target .. ')'
  return result({ body .. attr.format({ node.type }, rest) })
end

block = function(node, ctx)
  local t = node.type
  if not attr.plain(node.attrs) then
    return generic(node, ctx)
  end
  if t == 'paragraph' then
    local r = result(textblock(node, ctx), { { row = 0, col = 0, node = node } })
    return with_visible(node, r)
  end
  if t == 'heading' then
    local level = node.attrs and node.attrs.level
    local text = inlines(node.content, ctx, false)
    if type(level) ~= 'number' or level < 1 or level > 6 or text:find('\n') then
      return generic(node, ctx)
    end
    text = text:gsub('#$', '\\#')
    local marks = string.rep('#', level)
    local r = result(
      { text == '' and marks or (marks .. ' ' .. text) },
      { { row = 0, col = text == '' and 0 or (#marks + 1), node = node } }
    )
    return with_visible(node, r)
  end
  if t == 'blockquote' then
    if has_attrs(node.attrs) then
      return generic(node, ctx)
    end
    return prefix(
      blocks(node.content or {}, vim.tbl_extend('force', ctx, { indented = true })),
      '> ',
      '> '
    )
  end
  if t == 'bulletList' or t == 'orderedList' or t == 'taskList' then
    if not list_ok(node) or (ctx.safe and t == 'taskList') then
      return generic(node, ctx)
    end
    local extra = vim.deepcopy(node.attrs or {})
    if t == 'orderedList' then
      if type(extra.start) == 'number' and extra.start >= 0 and extra.start % 1 == 0 then
        extra.start = nil
      end
    end
    local marker
    if t == 'orderedList' then
      marker = ctx.alternate and ')' or '.'
    else
      marker = ctx.alternate and '*' or '-'
    end
    local r = list_items(node, ctx, marker)
    if has_attrs(extra) then
      return fenced({}, extra, r)
    end
    return r
  end
  if t == 'codeBlock' then
    local text, plain = '', true
    for _, child in ipairs(node.content or {}) do
      if child.type ~= 'text' or child.marks then
        plain = false
      end
      text = text .. (child.text or '')
    end
    local rest = vim.deepcopy(node.attrs or {})
    local language = rest.language
    local info = ''
    if type(language) == 'string' and language:match('^[%w_+.#-]+$') then
      info, rest.language = language, nil
    elseif null(language) then
      rest.language = nil
    end
    if not plain or (ctx.indented and text:find('\t')) then
      return generic(node, ctx)
    end
    local fence = fence_for(text, '`')
    local lines = { fence .. info }
    if text ~= '' then
      vim.list_extend(lines, lines_of(text))
    end
    lines[#lines + 1] = fence
    local r = result(lines)
    if has_attrs(rest) then
      return fenced({}, rest, r)
    end
    return r
  end
  if t == 'horizontalRule' and not has_attrs(node.attrs) and not node.content then
    return result({ '---' })
  end
  if t == 'mathBlock' and not ctx.safe then
    local text = (node.attrs or {}).text
    local only = true
    for key, value in pairs(node.attrs or {}) do
      if key ~= 'text' and not null(value) then
        only = false
      end
    end
    if
      only
      and type(text) == 'string'
      and text ~= ''
      and not text:find('%$')
      and not text:find('\n%s*\n')
      and not text:match('^%s')
      and not text:match('%s$')
    then
      return result(lines_of('$$' .. text .. '$$'))
    end
  end
  if t == 'table' and not ctx.safe then
    local r = pipe_table(node, ctx)
    if r then
      return r
    end
  end
  local m = media(node, ctx)
  if m then
    return m
  end
  return generic(node, ctx)
end

blocks = function(list, ctx, tight)
  local parts = {}
  local previous
  for _, node in ipairs(list) do
    local sub = ctx
    local kind = (node.type == 'bulletList' or node.type == 'taskList') and 'bullet'
      or (node.type == 'orderedList' and 'ordered' or nil)
    if kind and previous and previous.kind == kind then
      sub = vim.tbl_extend('force', ctx, { alternate = not previous.alternate })
    elseif ctx.alternate then
      sub = vim.tbl_extend('force', ctx, { alternate = false })
    end
    parts[#parts + 1] = block(node, sub)
    previous = { kind = kind, alternate = sub.alternate }
  end
  return join(parts, tight)
end
M.blocks = blocks

function M.document(content, opts)
  opts = opts or {}
  local parts = {}
  local previous
  for index, node in ipairs(content) do
    local ctx = { safe = opts.safe and opts.safe[index] or false }
    local kind = (node.type == 'bulletList' or node.type == 'taskList') and 'bullet'
      or (node.type == 'orderedList' and 'ordered' or nil)
    if kind and previous and previous.kind == kind then
      ctx.alternate = not previous.alternate
    end
    parts[#parts + 1] = block(node, ctx)
    previous = { kind = kind, alternate = ctx.alternate }
  end
  local r = join(parts)
  return table.concat(r.lines, '\n'), r.anchors
end

return M
