-- A deliberately bounded Pandoc AST -> Docmost JSON adapter. No remote
-- conversion/probe writes: both the baseline and edits are parsed locally.
local M = {}

local function abort(message)
  error(message, 0)
end
local function null(value)
  return value == nil or value == vim.NIL
end
local function nonempty(value)
  return not null(value) and value ~= ''
end

local function append_text(out, text, marks)
  if text == '' then
    return
  end
  local mark_list = vim.deepcopy(marks or {})
  table.sort(mark_list, function(a, b)
    return a.type < b.type
  end)
  local last = out[#out]
  if last and last.type == 'text' and vim.deep_equal(last.marks or {}, mark_list) then
    last.text = last.text .. text
  else
    local node = { type = 'text', text = text }
    if #mark_list > 0 then
      node.marks = mark_list
    end
    out[#out + 1] = node
  end
end

local function inlines(items, inherited)
  local out = {}
  for _, item in ipairs(items) do
    local t, c = item.t, item.c
    if t == 'Str' then
      append_text(out, c, inherited)
    elseif t == 'Space' or t == 'SoftBreak' then
      append_text(out, ' ', inherited)
    elseif t == 'Strong' or t == 'Emph' or t == 'Strikeout' then
      local marks = vim.deepcopy(inherited or {})
      marks[#marks + 1] = { type = ({ Strong = 'bold', Emph = 'italic', Strikeout = 'strike' })[t] }
      for _, child in ipairs(inlines(c, marks)) do
        append_text(out, child.text, child.marks)
      end
    elseif t == 'Code' then
      if c[1][1] ~= '' or #c[1][2] > 0 or #c[1][3] > 0 then
        abort('Code span attributes are unsupported')
      end
      local marks = vim.deepcopy(inherited or {})
      marks[#marks + 1] = { type = 'code' }
      append_text(out, c[2], marks)
    else
      abort('Unsupported Markdown inline: ' .. tostring(t))
    end
  end
  return out
end

local function blocks(items, depth)
  if depth > 50 then
    abort('Markdown nesting exceeds safe limit')
  end
  local out = {}
  for _, item in ipairs(items) do
    local t, c, node = item.t, item.c
    if t == 'Para' or t == 'Plain' then
      node = { type = 'paragraph', content = inlines(c) }
    elseif t == 'Header' then
      -- Pandoc's generated heading slug is not a Docmost block ID.
      if #c[2][2] > 0 or #c[2][3] > 0 then
        abort('Heading attributes are unsupported')
      end
      node = { type = 'heading', attrs = { level = c[1] }, content = inlines(c[3]) }
    elseif t == 'CodeBlock' then
      if c[1][1] ~= '' or #c[1][2] > 1 or #c[1][3] > 0 then
        abort('Code block attributes are unsupported')
      end
      node = { type = 'codeBlock', content = {} }
      if c[1][2][1] then
        node.attrs = { language = c[1][2][1] }
      end
      append_text(node.content, c[2])
    elseif t == 'HorizontalRule' then
      node = { type = 'horizontalRule' }
    elseif t == 'BlockQuote' then
      node = { type = 'blockquote', content = blocks(c, depth + 1) }
    elseif t == 'BulletList' or t == 'OrderedList' then
      node = { type = t == 'BulletList' and 'bulletList' or 'orderedList', content = {} }
      local children = c
      if t == 'OrderedList' then
        if c[1][2].t ~= 'Decimal' or c[1][3].t ~= 'Period' then
          abort('Unsupported ordered-list style')
        end
        node.attrs, children = { start = c[1][1] }, c[2]
      end
      for _, child in ipairs(children) do
        node.content[#node.content + 1] = { type = 'listItem', content = blocks(child, depth + 1) }
      end
    else
      abort('Unsupported Markdown block: ' .. tostring(t))
    end
    if node.content and #node.content == 0 then
      node.content = nil
    end
    out[#out + 1] = node
  end
  return out
end

function M.from_ast(ast)
  if type(ast) ~= 'table' or type(ast.blocks) ~= 'table' or next(ast.meta or {}) then
    abort('Unsupported Markdown document/metadata')
  end
  local content = blocks(ast.blocks, 0)
  if #content == 0 then
    content = { { type = 'paragraph' } }
  end
  return { type = 'doc', content = content }
end

function M.parse(markdown, cb)
  local c = require('docmost.config').get()
  if not require('docmost.fidelity').local_check(markdown) then
    cb({ kind = 'parser', message = 'Markdown is outside the supported JSON adapter subset' })
    return { cancel = function() end }
  end
  if vim.fn.executable('pandoc') ~= 1 then
    cb({ message = 'Pandoc is required to preserve Docmost block IDs/default attributes' })
    return { cancel = function() end }
  end
  if #markdown > c.max_response_bytes then
    cb({ message = 'Markdown exceeds configured size limit' })
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
  local ok, result = pcall(vim.system, { 'pandoc', '--from=gfm', '--to=json', '--sandbox' }, {
    stdin = markdown,
    timeout = c.timeout_ms,
    stdout = function(_, chunk)
      if chunk then
        size = size + #chunk
        if size > c.max_response_bytes then
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
  }, function(exit)
    vim.schedule(function()
      if cancelled or oversized or exit.code ~= 0 then
        cb({
          kind = cancelled and 'cancelled' or 'parser',
          message = cancelled and 'Markdown parsing cancelled'
            or 'Markdown parser failed, timed out, or exceeded size limit',
        })
        return
      end
      local decoded, value = pcall(function()
        return M.from_ast(vim.json.decode(table.concat(chunks)))
      end)
      if not decoded then
        -- Only static adapter messages are exposed, never Pandoc's stderr/input.
        cb({ kind = 'parser', message = 'Markdown is outside the supported JSON adapter subset' })
      else
        cb(nil, value)
      end
    end)
  end)
  if not ok then
    cb({ message = 'Could not start Pandoc' })
  else
    process = result
  end
  return handle
end

function M.needed(doc)
  local needed = false
  local function visit(node)
    local a = node.attrs or {}
    if nonempty(a.id) or (not null(a.textAlign) and a.textAlign ~= '') then
      needed = true
    end
    for _, child in ipairs(node.content or {}) do
      visit(child)
    end
  end
  visit(doc)
  return needed
end

-- Semantic keys represented by this Markdown subset. All other allowed
-- attributes are carried from the original nodes, never invented or discarded.
local semantic = { heading = { 'level' }, orderedList = { 'start' }, codeBlock = { 'language' } }
local function normalized(node, with_ids)
  local out = { type = node.type }
  if node.text then
    out.text = node.text
  end
  local attrs = {}
  for _, key in ipairs(semantic[node.type] or {}) do
    local value = (node.attrs or {})[key]
    if key == 'start' and null(value) then
      value = 1
    end
    if key == 'language' and value == '' then
      value = nil
    end
    if not null(value) then
      attrs[key] = value
    end
  end
  if with_ids and nonempty((node.attrs or {}).id) then
    attrs.id = node.attrs.id
  end
  if next(attrs) then
    out.attrs = attrs
  end
  local marks = vim.deepcopy(node.marks or {})
  for _, mark in ipairs(marks) do
    if type(mark.attrs) == 'table' and not next(mark.attrs) then
      mark.attrs = nil
    end
  end
  table.sort(marks, function(a, b)
    return a.type < b.type
  end)
  if #marks > 0 then
    out.marks = marks
  end
  local content = {}
  for _, child in ipairs(node.content or {}) do
    local value = normalized(child, with_ids)
    if value.type == 'text' then
      append_text(content, value.text, value.marks)
    else
      content[#content + 1] = value
    end
  end
  if #content > 0 then
    out.content = content
  end
  return out
end

local function split_tail(doc)
  local copy, tail = vim.deepcopy(doc), {}
  while #(copy.content or {}) > 0 do
    local last = copy.content[#copy.content]
    if last.type ~= 'paragraph' or #(last.content or {}) > 0 then
      break
    end
    table.insert(tail, 1, table.remove(copy.content))
  end
  return copy, tail
end

local function same(a, b)
  return vim.deep_equal(normalized(a), normalized(b))
end
local function anchored(node)
  if nonempty((node.attrs or {}).id) then
    return true
  end
  for _, child in ipairs(node.content or {}) do
    if anchored(child) then
      return true
    end
  end
  return false
end

local merge, align
function merge(old, new)
  if same(old, new) then
    return vim.deepcopy(old)
  end
  local prose = { paragraph = true, heading = true }
  if old.type ~= new.type and not (prose[old.type] and prose[new.type]) then
    if anchored(old) then
      abort('Cannot map block IDs across this structural change; edit structure separately')
    end
    return vim.deepcopy(new)
  end
  local result = vim.deepcopy(new)
  local attrs = vim.deepcopy(old.attrs or {})
  for _, key in ipairs(semantic[old.type] or {}) do
    attrs[key] = nil
  end
  for key, value in pairs(new.attrs or {}) do
    attrs[key] = value
  end
  if next(attrs) then
    result.attrs = attrs
  end
  if not prose[new.type] and new.type ~= 'codeBlock' then
    result.content = align(old.content or {}, new.content or {})
    if #result.content == 0 then
      result.content = nil
    end
  end
  return result
end

function align(old, new)
  -- LCS anchors identify unchanged sibling blocks. Ambiguous mixed insertions
  -- and edits are refused instead of assigning an old ID to an arbitrary block.
  if #old * #new > 65536 then
    abort('Too many blocks to map IDs safely in one edit')
  end
  local exact, complete = {}, #old == #new
  for j, value in ipairs(new) do
    local found
    for i, original in ipairs(old) do
      if same(original, value) then
        if found then
          found = nil
          break
        end
        found = i
      end
    end
    exact[j] = found
    if not found then
      complete = false
    end
  end
  if complete then
    local used, result = {}, {}
    for j = 1, #new do
      if used[exact[j]] then
        complete = false
        break
      end
      used[exact[j]], result[j] = true, vim.deepcopy(old[exact[j]])
    end
    if complete then
      return result
    end -- Pure reorder preserves each unique ID.
  end
  for _, original in ipairs(old) do
    if anchored(original) then
      local old_count, new_count = 0, 0
      for _, value in ipairs(old) do
        if same(original, value) then
          old_count = old_count + 1
        end
      end
      for _, value in ipairs(new) do
        if same(original, value) then
          new_count = new_count + 1
        end
      end
      if old_count ~= new_count and new_count > 0 and math.max(old_count, new_count) > 1 then
        abort('Repeated blocks have ambiguous IDs; save those structural changes separately')
      end
    end
  end
  local dp, matches = {}, {}
  for i = #old + 1, 1, -1 do
    dp[i], matches[i] = {}, {}
    for j = #new + 1, 1, -1 do
      if i > #old or j > #new then
        dp[i][j] = 0
      else
        matches[i][j] = same(old[i], new[j])
        dp[i][j] = matches[i][j] and (1 + dp[i + 1][j + 1]) or math.max(dp[i + 1][j], dp[i][j + 1])
      end
    end
  end
  local anchors, i, j = { { 0, 0 } }, 1, 1
  while i <= #old and j <= #new do
    if matches[i][j] then
      anchors[#anchors + 1] = { i, j }
      i, j = i + 1, j + 1
    elseif dp[i + 1][j] >= dp[i][j + 1] then
      i = i + 1
    else
      j = j + 1
    end
  end
  anchors[#anchors + 1] = { #old + 1, #new + 1 }
  local result = {}
  for index = 2, #anchors do
    local before, after = anchors[index - 1], anchors[index]
    local m, n = after[1] - before[1] - 1, after[2] - before[2] - 1
    for old_index = before[1] + 1, after[1] - 1 do
      if anchored(old[old_index]) then
        for new_index, match in pairs(exact) do
          if match == old_index and (new_index <= before[2] or new_index >= after[2]) then
            abort('Mixed block moves and edits have ambiguous IDs; save them separately')
          end
        end
      end
    end
    if m ~= n and m > 0 and n > 0 then
      local protected = false
      for k = before[1] + 1, after[1] - 1 do
        protected = protected or anchored(old[k])
      end
      if protected then
        abort('Ambiguous block IDs: save text edits and inserted/deleted blocks separately')
      end
    end
    for k = 1, n do
      local value = new[before[2] + k]
      result[#result + 1] = m == n and merge(old[before[1] + k], value) or vim.deepcopy(value)
    end
    if after[1] <= #old then
      result[#result + 1] = vim.deepcopy(old[after[1]])
    end
  end
  return result
end

function M.prepare(baseline, parsed_base, parsed_edit)
  local original, tail = split_tail(baseline.json)
  local base_projection = split_tail(parsed_base)
  if not same(original, base_projection) then
    return nil, 'Original Markdown does not represent the page JSON losslessly; save blocked'
  end
  local ok, result = pcall(function()
    local empty = require('docmost.fidelity').empty(parsed_edit)
    if empty then
      local first = tail[1] or (baseline.json.content or {})[1]
      local paragraph = { type = 'paragraph' }
      if first and first.type == 'paragraph' then
        paragraph.attrs = vim.deepcopy(first.attrs)
      end
      return { type = 'doc', attrs = vim.deepcopy(baseline.json.attrs), content = { paragraph } }
    end
    local out = {
      type = 'doc',
      attrs = vim.deepcopy(baseline.json.attrs),
      content = align(original.content or {}, parsed_edit.content or {}),
    }
    if #(original.content or {}) == 0 and #tail == 1 and out.content[1].type == 'paragraph' then
      out.content[1].attrs = vim.deepcopy(tail[1].attrs)
    else
      for _, item in ipairs(tail) do
        out.content[#out.content + 1] = item
      end
    end
    return out
  end)
  if not ok then
    return nil, result
  end
  return result
end

function M.matches(expected, actual)
  if not same(expected, actual) then
    return false
  end
  local function preserved(a, b)
    -- Verify every submitted attribute, including IDs/default styling. The
    -- server may add defaults/new IDs to new blocks, but cannot change ours.
    for key, value in pairs(a.attrs or {}) do
      if not null(value) and not vim.deep_equal(value, (b.attrs or {})[key]) then
        return false
      end
    end
    for i, child in ipairs(a.content or {}) do
      if child.type ~= 'text' and not preserved(child, (b.content or {})[i] or {}) then
        return false
      end
    end
    return true
  end
  return preserved(expected, actual)
end

return M
