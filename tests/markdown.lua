require('docmost.config').setup({ base_url = 'https://invalid.example', timeout_ms = 2000 })
local md, fidelity = require('docmost.markdown'), require('docmost.fidelity')
local checks = 0
local function eq(a, b)
  assert(vim.deep_equal(a, b), 'expected ' .. vim.inspect(b) .. ', got ' .. vim.inspect(a))
  checks = checks + 1
end
local function parse(text, expect_error)
  local completed, err, doc
  md.parse(text, function(e, d)
    err, doc, completed = e, d, true
  end)
  assert(vim.wait(4000, function()
    return completed
  end, 5))
  if expect_error then
    assert(err, 'Expected parser rejection: ' .. text)
    checks = checks + 1
  else
    assert(not err, vim.inspect(err))
  end
  return doc
end
local function identify(doc)
  local n = 0
  local function visit(node)
    if node.type == 'paragraph' or node.type == 'heading' then
      n = n + 1
      node.attrs = vim.tbl_extend(
        'force',
        node.attrs or {},
        { id = 'block-' .. n, textAlign = 'left', indent = 0, dir = 'auto' }
      )
    end
    for _, child in ipairs(node.content or {}) do
      visit(child)
    end
  end
  visit(doc)
  return doc
end
local function prepare(original, edited, transform)
  local base = parse(original)
  local json = identify(vim.deepcopy(base))
  if transform then
    transform(json)
  end
  return md.prepare({ json = json, markdown = original }, base, parse(edited))
end

local function run()
  local doc = assert(
    prepare(
      '# Old\n\nText **bold**.\n\n- one\n- two',
      '# New\n\nText _italic_ 🦊.\n\n- one\n- two'
    )
  )
  eq(doc.content[1].attrs.id, 'block-1')
  eq(doc.content[1].attrs.textAlign, 'left')
  eq(doc.content[2].attrs.id, 'block-2')
  eq(doc.content[3].content[2].content[1].attrs.id, 'block-4')
  eq(fidelity.check(doc), true)
  eq(md.matches(doc, vim.deepcopy(doc)), true)
  local damaged = vim.deepcopy(doc)
  damaged.content[1].attrs.id = 'changed'
  eq(md.matches(doc, damaged), false)
  damaged = vim.deepcopy(doc)
  damaged.content[2].attrs.textAlign = 'right'
  eq(md.matches(doc, damaged), false)
  damaged = vim.deepcopy(doc)
  damaged.content[2].content[1].text = 'wrong'
  eq(md.matches(doc, damaged), false)

  doc = assert(prepare('# H\n\nA\n\nB', '# H\n\nInserted\n\nA\n\nB'))
  eq(doc.content[2].attrs, nil)
  eq(doc.content[3].attrs.id, 'block-2')
  eq(doc.content[4].attrs.id, 'block-3')
  doc = assert(prepare('A\n\nB', 'B\n\nA'))
  eq(doc.content[1].attrs.id, 'block-2')
  eq(doc.content[2].attrs.id, 'block-1')
  eq(prepare('A', 'Edited\n\nInserted'), nil)
  eq(prepare('A\n\nA', 'A\n\nA\n\nA'), nil)
  eq(prepare('A\n\nB\n\nC', 'B\n\nA\n\nChanged'), nil)
  doc = assert(prepare('A\n\nB', 'A'))
  eq(#doc.content, 1)
  eq(doc.content[1].attrs.id, 'block-1')
  doc = assert(prepare('A', '# Heading'))
  eq(doc.content[1].type, 'heading')
  eq(doc.content[1].attrs.id, 'block-1')
  eq(doc.content[1].attrs.level, 1)

  doc = assert(prepare('Paragraph', 'Edited', function(json)
    json.content[2] = { type = 'paragraph', attrs = { id = 'trailing' } }
  end))
  eq(doc.content[2].attrs.id, 'trailing')
  doc = assert(prepare('Paragraph', ''))
  eq(fidelity.empty(doc), true)
  eq(doc.content[1].attrs.id, 'block-1')
  doc = assert(prepare('', 'First text'))
  eq(doc.content[1].attrs.id, 'block-1')
  eq(
    prepare('Visible', 'Edited', function(json)
      json.content[1].content[1].text = 'Hidden different text'
    end),
    nil
  )

  doc = assert(
    prepare(
      '> quote\n\n1. first\n2. second\n\n```lua\n  print("hi")\n\n```',
      '> changed\n\n1. first\n2. second\n\n```lua\n  print("bye")\n\n```'
    )
  )
  eq(doc.content[1].content[1].attrs.id, 'block-1')
  eq(doc.content[3].content[1].text, '  print("bye")\n')
  eq(doc.content[3].attrs.language, 'lua')
  for _, input in ipairs({
    '![image](x)',
    '| a |\n|---|\n| b |',
    '[link](https://example.com)',
    '<div>raw</div>',
    'hard  \nbreak',
    '- [x] done',
  }) do
    parse(input, true)
  end
  local executable = vim.fn.executable
  vim.fn.executable = function(name)
    return name == 'pandoc' and 0 or executable(name)
  end
  eq(fidelity.check(identify({ type = 'doc', content = { { type = 'paragraph' } } })), false)
  vim.fn.executable = executable
  local done, failure
  local handle = md.parse('cancelled', function(err)
    done, failure = true, err
  end)
  handle.cancel()
  assert(vim.wait(4000, function()
    return done
  end, 5))
  eq(failure.kind, 'cancelled')
  print('PASS Markdown/JSON adapter: ' .. checks .. ' assertions using real Pandoc')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
