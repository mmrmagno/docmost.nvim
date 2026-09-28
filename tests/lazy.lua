-- Optional offline smoke test using an already installed lazy.nvim checkout.
local path = vim.env.DOCMOST_TEST_LAZY_PATH
if not path or vim.fn.isdirectory(path) == 0 then
  print('SKIP lazy.nvim smoke: set DOCMOST_TEST_LAZY_PATH to an installed checkout')
  vim.cmd('qa!')
  return
end
local root = vim.env.DOCMOST_TEST_DIR
vim.go.loadplugins = true -- -u NONE disables it; normal NvChad startup enables it.
vim.opt.rtp:prepend(path)
local spec = dofile('examples/nvchad.lua')
spec[1].opts.base_url = vim.env.DOCMOST_TEST_URL
spec[1].opts.allow_insecure_localhost = true
spec[1].opts.state_dir = root .. '/lazy-docmost-state'
require('lazy').setup(spec, {
  root = root .. '/lazy',
  lockfile = root .. '/lazy-lock.json',
  state = root .. '/lazy-state.json',
  install = { missing = false },
  checker = { enabled = false },
  change_detection = { enabled = false },
  rocks = { enabled = false },
  pkg = { enabled = false },
  readme = { enabled = false },
  performance = { cache = { enabled = false }, rtp = { reset = false } },
})
assert(require('docmost.config').values == nil, 'Plugin should be lazy')
require('lazy').load({ plugins = { 'docmost.nvim' } })
assert(require('docmost.config').get().base_url == vim.env.DOCMOST_TEST_URL)
assert(vim.fn.exists(':Docmost') == 2)
vim.cmd('help docmost')
assert(vim.bo.filetype == 'help')
print('PASS installed lazy.nvim loads NvChad spec, configuration, command and help')
vim.cmd('qa!')
