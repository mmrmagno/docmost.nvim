local M = {}
function M.check()
  vim.health.start('docmost.nvim')
  if vim.fn.executable('pandoc') == 1 then
    vim.health.ok('Pandoc available for Markdown saves preserving block IDs')
  else
    vim.health.warn('Install pandoc to edit pages with block IDs/default alignment')
  end
  if vim.fn.has('nvim-0.10') == 1 then
    vim.health.ok('Neovim >= 0.10')
  else
    vim.health.error('Neovim 0.10+ required')
  end
  if vim.fn.executable('curl') == 1 then
    vim.health.ok('curl available')
  else
    vim.health.error('Install curl')
  end
  local c = require('docmost.config').values
  if not c then
    vim.health.error('Call setup with base_url')
    return
  end
  vim.health.ok('Configured origin: ' .. c.base_url)
  vim.health.info(
    'Authentication: ' .. require('docmost.auth').status .. ' (use :Docmost status to validate)'
  )
  vim.health.info('Compatibility: ' .. require('docmost.buffer').compatibility)
  vim.health.info(
    'Private backups: ' .. c.state_dir .. '; retained per page: ' .. c.backup_retention
  )
  vim.health.info(
    string.format(
      'Workspace: icons=%s, preview=%s, winbar=%s, border=%s',
      c.ui.icons,
      tostring(c.ui.preview),
      tostring(c.ui.winbar),
      c.ui.border
    )
  )
  vim.health.warn('Internal endpoints; use one active editor per page. No atomic compare-and-swap.')
end
return M
