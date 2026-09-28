local layout = require('docmost.ui.layout')
local checks = 0
local function eq(a, b)
  assert(vim.deep_equal(a, b), 'expected ' .. vim.inspect(b) .. ', got ' .. vim.inspect(a))
  checks = checks + 1
end
local opts = { width = 0.9, height = 0.86, border = 'rounded' }
local function fits(box, screen)
  assert(box.row >= 0 and box.col >= 0, vim.inspect(box))
  assert(box.width >= 1 and box.height >= 1, vim.inspect(box))
  assert(box.col + box.width + 2 <= screen.columns, vim.inspect(box))
  assert(box.row + box.height + 2 <= screen.lines, vim.inspect(box))
  checks = checks + 1
end

local wide = { columns = 160, lines = 45, cmdheight = 1 }
local w = layout.compute(wide, opts)
eq(w.mode, 'wide')
fits(w.list, wide)
fits(w.preview, wide)
eq(w.preview.col, w.list.col + w.list.width + 2)
eq(w.list.row, w.preview.row)
assert(w.list.width + 2 >= 34 and w.list.width + 2 <= 64)
eq(layout.compute(wide, opts, { preview = false }).preview, nil)

local search = layout.compute(wide, opts, { search = true })
eq(search.prompt.height, 1)
eq(search.list.row, search.prompt.row + 3)
eq(search.list.height + 2 + 3, search.height)

for _, screen in ipairs({
  { columns = 80, lines = 24 },
  { columns = 60, lines = 16 },
  { columns = 40, lines = 12 },
  { columns = 20, lines = 6 },
  { columns = 8, lines = 4 },
}) do
  local out = layout.compute(screen, opts, { search = true })
  eq(out.preview, nil)
  fits(out.list, screen)
end
eq(layout.compute({ columns = 80, lines = 24 }, opts).mode, 'narrow')
eq(layout.compute({ columns = 40, lines = 12 }, opts).mode, 'tiny')
eq(
  layout.compute({ columns = 100, lines = 40 }, { width = 50, height = 20, border = 'none' }).list,
  {
    relative = 'editor',
    row = 8,
    col = 25,
    width = 50,
    height = 20,
  }
)

local items = { { 'a', 'one' }, { 'b', 'two' }, { '?', 'help' } }
eq(#layout.fit(items, 100), 3)
eq(layout.fit(items, 15), { { 'a', 'one' }, { '?', 'help' } })
eq(layout.fit(items, 8), { { '?', 'help' } })
eq(layout.truncate('Grüezi 世界', 20), 'Grüezi 世界')
eq(layout.truncate('Grüezi 世界 long title', 10), 'Grüezi 世…')
eq(layout.truncate('abcdef', 4, '~'), 'abc~')
eq(layout.truncate('abc', 0), '')
print('SUCCESS layout: ' .. checks .. ' assertions')
vim.cmd('qa!')
