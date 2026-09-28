if vim.g.loaded_docmost then
  return
end
vim.g.loaded_docmost = true
require('docmost').register()
