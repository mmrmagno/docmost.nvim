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
spec[1].dir = vim.fn.getcwd()
spec[1].opts.persist_session = false
-- The other tests preload runtimepath. Let lazy own it here, as in NvChad.
vim.opt.rtp:remove(spec[1].dir)
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
assert(package.loaded['docmost.config'] == nil, 'Plugin should be lazy')
vim.cmd('Docmost')
assert(require('docmost.config').get().base_url == vim.env.DOCMOST_TEST_URL)
assert(vim.fn.exists(':Docmost') == 2)
local state = require('docmost.ui').state
assert(state and vim.api.nvim_get_current_win() == state.list.win)
assert(vim.bo.filetype == 'docmost')
assert(vim.fn.hlexists('DocmostBrand') == 1)
require('docmost.ui').close()
vim.cmd('help docmost')
assert(vim.bo.filetype == 'help')
print('PASS installed lazy.nvim loads NvChad spec, workspace command, configuration and help')
vim.cmd('qa!')
