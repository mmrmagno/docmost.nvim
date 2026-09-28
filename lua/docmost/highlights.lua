local M = {}

local links = {
  DocmostNormal = 'NormalFloat',
  DocmostBorder = 'FloatBorder',
  DocmostTitle = 'FloatTitle',
  DocmostSelection = 'Visual',
  DocmostDim = 'Comment',
  DocmostKey = 'Special',
  DocmostSpace = 'Directory',
  DocmostPage = 'NormalFloat',
  DocmostOk = 'DiagnosticOk',
  DocmostWarn = 'DiagnosticWarn',
  DocmostError = 'DiagnosticError',
  DocmostInfo = 'DiagnosticInfo',
  DocmostBusy = 'DiagnosticHint',
  DocmostMatch = 'Special',
  DocmostHeading = 'Title',
  DocmostWinbar = 'WinBar',
  DocmostPromptPrefix = 'Special',
}

local applied = {}

local function color(name, key)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl[key] or nil
end

local function computed()
  local accent = color('Special', 'fg') or color('Title', 'fg') or color('Directory', 'fg')
  local base = color('NormalFloat', 'bg') or color('Normal', 'bg')
  local dim = color('Comment', 'fg')
  local brand = accent and base and { fg = base, bg = accent, bold = true }
    or { link = 'IncSearch' }
  return {
    DocmostBrand = brand,
    DocmostSection = dim and { fg = dim, bold = true } or { link = 'Comment' },
  }
end

function M.apply()
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  for name, spec in pairs(computed()) do
    local current = vim.api.nvim_get_hl(0, { name = name })
    if vim.tbl_isempty(current) or vim.deep_equal(current, applied[name]) then
      vim.api.nvim_set_hl(0, name, spec)
      applied[name] = vim.api.nvim_get_hl(0, { name = name })
    end
  end
end

function M.setup()
  M.apply()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('DocmostHighlights', { clear = true }),
    callback = M.apply,
  })
end

return M
