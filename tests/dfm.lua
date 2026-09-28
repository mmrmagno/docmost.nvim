require('docmost.config').setup({ base_url = 'https://invalid.example', timeout_ms = 4000 })
local dfm, attr = require('docmost.dfm'), require('docmost.dfm.attr')
local identity = require('docmost.dfm.identity')
local checks = 0
local function eq(a, b, message)
  assert(
    vim.deep_equal(a, b),
    (message or 'mismatch') .. '\nexpected ' .. vim.inspect(b) .. '\ngot ' .. vim.inspect(a)
  )
  checks = checks + 1
end
local function ok(value, message)
  assert(value, message or 'assertion failed')
  checks = checks + 1
end
local function await(start)
  local result
  start(function(...)
    result = { ... }
  end)
  assert(
    vim.wait(8000, function()
      return result ~= nil
    end, 5),
    'timed out'
  )
  return unpack(result, 1, 4)
end
local function load(doc, meta)
  local err, loaded = await(function(cb)
    dfm.load({ json = doc, meta = meta or { title = 'T' } }, cb)
  end)
  assert(not err, vim.inspect(err))
  return loaded
end
local function build(text, entries, baseline, tail)
  return await(function(cb)
    dfm.build(text, entries or {}, baseline, tail, cb)
  end)
end

local n = 0
local function id()
  n = n + 1
  return 'block-' .. n
end
local function T(text, marks)
  return { type = 'text', text = text, marks = marks }
end
local function P(content, attrs)
  return {
    type = 'paragraph',
    attrs = attrs or { id = id(), textAlign = 'left', indent = 0, dir = 'auto' },
    content = content,
  }
end
local cell = { colspan = 1, rowspan = 1, colwidth = vim.NIL }
local function C(kind, text)
  return { type = kind, attrs = vim.deepcopy(cell), content = { P(text and { T(text) } or nil) } }
end

local rich = {
  type = 'doc',
  content = {
    {
      type = 'heading',
      attrs = { level = 2, id = id(), textAlign = 'center', indent = 0 },
      content = { T('Title #') },
    },
    P({
      T('Hello '),
      T('bold', { { type = 'bold' } }),
      T(' and '),
      T('link', { { type = 'link', attrs = { href = 'https://x.y/a', target = '_blank' } } }),
      T(' 1. * [x] {a} $5 | ~ ^ '),
      T('code`x', { { type = 'code' } }),
      T('  two  spaces '),
    }),
    P({ T('# not heading') }),
    P(nil),
    P({
      T('u', { { type = 'underline' } }),
      T('hl', { { type = 'highlight', attrs = { color = '#ff0' } } }),
      { type = 'mention', attrs = { id = 'u1', label = 'Marcos', entityType = 'user' } },
      { type = 'hardBreak' },
      T('next'),
      { type = 'mathInline', attrs = { text = 'x^2' } },
    }),
    {
      type = 'bulletList',
      content = {
        {
          type = 'listItem',
          content = {
            P({ T('one') }),
            {
              type = 'bulletList',
              content = { { type = 'listItem', content = { P({ T('nested') }) } } },
            },
          },
        },
        { type = 'listItem', content = { P({ T('[x] literal') }) } },
      },
    },
    { type = 'bulletList', content = { { type = 'listItem', content = { P({ T('second') }) } } } },
    {
      type = 'taskList',
      content = {
        { type = 'taskItem', attrs = { checked = true }, content = { P({ T('done') }) } },
        { type = 'taskItem', attrs = { checked = false }, content = { P({ T('todo') }) } },
      },
    },
    {
      type = 'orderedList',
      attrs = { start = 3, type = vim.NIL },
      content = { { type = 'listItem', content = { P({ T('three') }) } } },
    },
    { type = 'codeBlock', attrs = { language = 'lua' }, content = { T('print("```")\n') } },
    { type = 'blockquote', content = { P({ T('quoted') }), P({ T('two') }) } },
    { type = 'callout', attrs = { type = 'warning' }, content = { P({ T('careful') }) } },
    {
      type = 'details',
      attrs = { open = false },
      content = {
        { type = 'detailsSummary', content = { T('Summary') } },
        { type = 'detailsContent', content = { P({ T('hidden') }) } },
      },
    },
    {
      type = 'table',
      content = {
        { type = 'tableRow', content = { C('tableHeader', 'A'), C('tableHeader', 'Grü|x') } },
        { type = 'tableRow', content = { C('tableCell', '1'), C('tableCell') } },
      },
    },
    {
      type = 'table',
      content = {
        {
          type = 'tableRow',
          content = {
            {
              type = 'tableCell',
              attrs = { colspan = 2, rowspan = 1, colwidth = { 120, 80 } },
              content = { P({ T('merged') }) },
            },
          },
        },
      },
    },
    {
      type = 'image',
      attrs = {
        src = '/files/a.png',
        alt = 'An image',
        width = 300,
        align = 'center',
        attachmentId = 'a1',
      },
    },
    {
      type = 'attachment',
      attrs = { url = '/files/r.pdf', name = 'report.pdf', mime = 'application/pdf', size = 99 },
    },
    { type = 'mathBlock', attrs = { text = '\\int x' } },
    { type = 'embed', attrs = { src = 'https://youtube.com/x', provider = 'youtube' } },
    { type = 'horizontalRule' },
    {
      type = 'futureThing',
      attrs = { weird = { nested = { 1, 2 } }, s = 'has "quotes"', n = '12' },
      content = { P({ T('inside') }) },
    },
    P({ T('last', { { type = 'comment', attrs = { commentId = 'c1', resolved = false } } }) }, {
      id = id(),
      textAlign = 'right',
    }),
    P(nil),
  },
}

local function text_of(loaded)
  return loaded.text
end

local function run()
  for _, value in ipairs({
    'plain',
    '',
    '12',
    'true',
    'null',
    'j:odd',
    'has "quotes" and %25',
    'multi\nline',
    12,
    -3.5,
    true,
    false,
    vim.NIL,
    { 1, 2 },
    { a = { b = 'c' } },
  }) do
    eq(attr.decode(attr.encode(value)), value, 'attribute value ' .. vim.inspect(value))
  end
  eq(attr.unkey(attr.key('id')), 'id')
  eq(attr.unkey(attr.key('x-y')), 'x-y')

  local loaded = load(rich, { title = 'My "page"', icon = '📄' })
  eq(loaded.editable, true, loaded.reason)
  local text = text_of(loaded)
  for _, expected in ipairs({
    'title: My "page"',
    'icon: 📄',
    '## Title \\#',
    '**bold**',
    '[link](https://x.y/a){target="_blank"}',
    '\\[x\\] literal',
    '* second',
    '- [x] done',
    '- [ ] todo',
    '3. three',
    '````lua',
    '> quoted',
    '::: {.callout type="warning"}',
    '| A | Grü\\|x |',
    '| 1 | \\ |',
    'colspan="2"',
    '![An image](/files/a.png){.image',
    '[report.pdf](/files/r.pdf){.attachment',
    '$$\\int x$$',
    '[@Marcos]{.mention',
    '$x^2$',
    '::: {.embed',
    '[last]{.comment',
    '::: {textAlign="right"}',
  }) do
    ok(text:find(expected, 1, true), 'missing ' .. expected .. '\n' .. text)
  end
  local body, tail = dfm.split_tail(rich)
  eq(#tail, 1)
  local err, doc = build(text, dfm.entries(loaded.anchors), rich, tail)
  assert(not err, vim.inspect(err))
  for i = 1, math.max(#doc.content, #rich.content) do
    if not dfm.equal(doc.content[i] or {}, rich.content[i] or {}) then
      print(
        i,
        vim.inspect(dfm.normalize(rich.content[i] or {})),
        vim.inspect(dfm.normalize(doc.content[i] or {}))
      )
    end
  end
  ok(dfm.equal(doc, rich), 'identity round trip is exact')
  eq(doc.content[1].attrs.id, rich.content[1].attrs.id)
  eq(doc.content[1].attrs.textAlign, 'center')

  local edited = text:gsub('Hello ', 'Hi there '):gsub('%- %[ %] todo', '- [x] todo')
  err, doc = build(edited, dfm.entries(loaded.anchors), rich, tail)
  assert(not err, vim.inspect(err))
  eq(doc.content[2].attrs.id, rich.content[2].attrs.id)
  eq(doc.content[2].content[1].text, 'Hi there ')
  eq(doc.content[8].content[2].attrs.checked, true)
  eq(doc.content[16], rich.content[16])

  math.randomseed(20260928)
  local alphabet = {
    'a',
    'b',
    'Z',
    ' ',
    '  ',
    '*',
    '_',
    '`',
    '#',
    '[',
    ']',
    '(',
    ')',
    '{',
    '}',
    '<',
    '>',
    '!',
    '$',
    '|',
    '~',
    '^',
    '\\',
    '&',
    ';',
    ':',
    '-',
    '+',
    '.',
    '1.',
    '@',
    '"',
    "'",
    'ü',
    '世',
    '🦊',
    '\t',
  }
  local function words()
    local out = {}
    for _ = 1, math.random(1, 6) do
      out[#out + 1] = alphabet[math.random(#alphabet)]
    end
    return table.concat(out)
  end
  local mark_pool = {
    { type = 'bold' },
    { type = 'italic' },
    { type = 'strike' },
    { type = 'code' },
    { type = 'underline' },
    { type = 'link', attrs = { href = 'https://e.x/p?q=1' } },
    { type = 'highlight', attrs = { color = 'red' } },
  }
  local function inline()
    local out = {}
    for _ = 1, math.random(1, 4) do
      local marks
      if math.random() < 0.5 then
        marks = { vim.deepcopy(mark_pool[math.random(#mark_pool)]) }
        if math.random() < 0.3 then
          local second = vim.deepcopy(mark_pool[math.random(#mark_pool)])
          if second.type ~= marks[1].type then
            marks[2] = second
          end
        end
      end
      out[#out + 1] = T(words(), marks)
      if math.random() < 0.1 then
        out[#out + 1] = { type = 'hardBreak' }
      end
    end
    return out
  end
  local function block(depth)
    local r = math.random()
    if depth > 1 or r < 0.4 then
      return P(inline())
    elseif r < 0.5 then
      return {
        type = 'heading',
        attrs = { level = math.random(1, 6), id = id() },
        content = { T(words()) },
      }
    elseif r < 0.6 then
      local kind = math.random() < 0.5 and 'bulletList' or 'orderedList'
      local items = {}
      for _ = 1, math.random(1, 3) do
        local content = { P(inline()) }
        if math.random() < 0.3 then
          content[2] = block(depth + 1)
        end
        items[#items + 1] = { type = 'listItem', content = content }
      end
      return { type = kind, attrs = kind == 'orderedList' and { start = 1 } or nil, content = items }
    elseif r < 0.7 then
      return { type = 'blockquote', content = { block(depth + 1), block(depth + 1) } }
    elseif r < 0.75 then
      return {
        type = 'codeBlock',
        attrs = { language = vim.NIL },
        content = { T(words() .. '\n```\n' .. words()) },
      }
    elseif r < 0.85 then
      return {
        type = 'callout',
        attrs = { type = words(), n = math.random(1, 9) },
        content = { block(depth + 1) },
      }
    else
      return {
        type = 'taskList',
        content = {
          {
            type = 'taskItem',
            attrs = { checked = math.random() < 0.5 },
            content = { P(inline()) },
          },
        },
      }
    end
  end
  local safe_mode = 0
  for round = 1, 60 do
    local generated = { type = 'doc', content = {} }
    for _ = 1, math.random(1, 5) do
      generated.content[#generated.content + 1] = block(0)
    end
    local l = load(generated)
    eq(
      l.editable,
      true,
      'round ' .. round .. ': ' .. tostring(l.reason) .. '\n' .. vim.inspect(generated)
    )
    local e, rebuilt = build(l.text, dfm.entries(l.anchors), generated, {})
    assert(not e, vim.inspect(e))
    ok(dfm.equal(rebuilt, generated), 'random round trip ' .. round .. '\n' .. l.text)
    if l.text:find('{.bold}', 1, true) or l.text:find('{.italic}', 1, true) then
      safe_mode = safe_mode + 1
    end
  end
  print('random documents needing span fallback: ' .. safe_mode .. '/60')

  local buf = vim.api.nvim_create_buf(false, true)
  local page = {
    type = 'doc',
    content = { P({ T('Alpha') }), P({ T('Beta') }), P({ T('Gamma') }), P({ T('Delta') }) },
  }
  local l = load(page)
  local s = { buf = buf }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(l.text, '\n', { plain = true }))
  identity.attach(s, l.anchors)
  local function row_of(word)
    for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line == word then
        return i - 1
      end
    end
  end
  vim.api.nvim_buf_set_lines(buf, row_of('Alpha'), row_of('Alpha'), false, { 'Inserted', '' })
  vim.api.nvim_buf_set_text(buf, row_of('Beta'), 0, row_of('Beta'), 4, { 'Beta changed a lot' })
  vim.api.nvim_buf_set_lines(buf, row_of('Gamma'), row_of('Gamma') + 2, false, {})
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '', 'Gamma' })
  local current = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  err, doc = build(current, identity.collect(s), page, {})
  assert(not err, vim.inspect(err))
  local ids = {}
  for _, node in ipairs(doc.content) do
    ids[#ids + 1] = { node.content[1].text, node.attrs and node.attrs.id }
  end
  eq(ids, {
    { 'Inserted', nil },
    { 'Alpha', page.content[1].attrs.id },
    { 'Beta changed a lot', page.content[2].attrs.id },
    { 'Delta', page.content[4].attrs.id },
    { 'Gamma', page.content[3].attrs.id },
  })
  vim.api.nvim_buf_set_lines(buf, row_of('Delta') + 1, row_of('Delta') + 1, false, { '', 'Delta' })
  current = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  err, doc = build(current, identity.collect(s), page, {})
  local deltas = {}
  for _, node in ipairs(doc.content) do
    if node.content[1].text == 'Delta' then
      deltas[#deltas + 1] = node.attrs and node.attrs.id or false
    end
  end
  eq(#vim.tbl_filter(function(v)
    return v == page.content[4].attrs.id
  end, deltas), 1)

  for source, fragment in pairs({
    ['::: {a="1"}\none\n\ntwo\n:::'] = 'exactly one block',
    ['text ![i](x){.image} more'] = 'own line',
    ['[x]{k="v"}'] = 'need a class',
    ['::: {.nonsense}\n:::'] = 'Unknown Docmost block',
    ['[x]{.glitter}'] = 'Unknown text style',
    ['---\ntitle: x\nno closing'] = 'closing ---',
    ['- ```\n  code\n  ```'] = 'must start with a line of text',
  }) do
    local e = build(source, {}, { type = 'doc', content = {} }, {})
    ok(e and e.kind == 'validation', 'expected validation error for ' .. source)
    ok(e.message:find(fragment, 1, true), e.message)
    ok(type(e.errors[1].row) == 'number')
  end
  local _, split = build('- [ ] task\n- plain', {}, nil, {})
  eq(split.content[1].type, 'taskList')
  eq(split.content[2].type, 'bulletList')
  local e, parsed, fields = build('---\ntitle: "  spaced"\nicon: x\n---\n\nBody', {}, nil, {})
  assert(not e, vim.inspect(e))
  eq(fields, { title = '  spaced', icon = 'x' })
  eq(parsed.content[1].content[1].text, 'Body')
  e, parsed = build('', {}, nil, {})
  eq(parsed, { type = 'doc', content = { { type = 'paragraph' } } })

  local expected = { type = 'doc', content = { P({ T('x') }, {}), P({ T('y') }, { id = 'k' }) } }
  local actual = vim.deepcopy(expected)
  actual.content[1].attrs = { id = 'server', textAlign = 'left' }
  actual.content[3] = { type = 'paragraph', attrs = { id = 'trailing' } }
  ok(dfm.matches(expected, actual), 'server defaults and trailing node accepted')
  actual.content[2].attrs.id = 'changed'
  ok(not dfm.matches(expected, actual), 'changed ID rejected')
  actual = vim.deepcopy(expected)
  actual.content[1].content[1].text = 'z'
  ok(not dfm.matches(expected, actual), 'changed text rejected')
  actual = vim.deepcopy(expected)
  actual.content[2].content[1].marks = { { type = 'bold' } }
  ok(not dfm.matches(expected, actual), 'added mark rejected')

  local luasnip_path = vim.env.DOCMOST_TEST_LUASNIP_PATH
  if luasnip_path and vim.fn.isdirectory(luasnip_path) == 1 then
    vim.opt.rtp:prepend(luasnip_path)
    local parser = require('luasnip.util.parser')
    for _, spec in ipairs(require('docmost.snippets').list) do
      local snippet = parser.parse_snippet(spec.trigger, spec.body)
      local expanded = table.concat(snippet:get_static_text(), '\n')
      local e, built = build(expanded, {}, { type = 'doc', content = {} }, {})
      ok(not e, spec.trigger .. ': ' .. vim.inspect(e) .. '\n' .. expanded)
      ok(#built.content >= 1)
    end
    print('snippets expand to valid pages: ' .. #require('docmost.snippets').list)
  else
    print('SKIP snippet expansion: set DOCMOST_TEST_LUASNIP_PATH')
  end
  print('SUCCESS dfm: ' .. checks .. ' assertions')
end

local passed, failure = xpcall(run, debug.traceback)
if not passed then
  io.stderr:write(failure .. '\n')
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
