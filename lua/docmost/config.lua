local M = {}

function M.setup(opts)
  local c = vim.tbl_deep_extend('force', {
    base_url = '',
    timeout_ms = 15000,
    max_response_bytes = 8 * 1024 * 1024,
    verify_timeout_ms = 60000,
    verify_interval_ms = 2000,
    verify_reads = 2,
    page_size = 50,
    max_pages = 100,
    backup_retention = 20,
    state_dir = vim.fn.stdpath('state') .. '/docmost',
    persist_session = false,
    allow_insecure_localhost = false,
    ui = {
      width = 0.9,
      height = 0.86,
      border = 'rounded',
      icons = 'unicode',
      preview = true,
      winbar = true,
      search_debounce_ms = 250,
      preview_debounce_ms = 150,
    },
  }, opts or {})
  c.base_url = c.base_url:gsub('/+$', '')
  local scheme, authority = c.base_url:match('^(https?)://([^/]+)$')
  assert(
    scheme and not authority:find('[@%s?#]'),
    'docmost: base_url must be an HTTPS origin, without a path or credentials'
  )
  assert(
    scheme == 'https' or (c.allow_insecure_localhost and authority:match('^127%.0%.0%.1:%d+$')),
    'docmost: HTTP is only allowed for explicitly enabled loopback mocks'
  )
  for _, k in ipairs({
    'timeout_ms',
    'max_response_bytes',
    'verify_timeout_ms',
    'verify_interval_ms',
    'verify_reads',
    'page_size',
    'max_pages',
    'backup_retention',
  }) do
    assert(type(c[k]) == 'number' and c[k] >= 1 and c[k] % 1 == 0, 'docmost: invalid ' .. k)
  end
  assert(c.verify_reads >= 2, 'docmost: verification requires at least two reads')
  assert(c.page_size <= 100, 'docmost: page_size must be <= 100')
  for _, key in ipairs({ 'width', 'height' }) do
    local value = c.ui[key]
    assert(
      type(value) == 'number' and value > 0 and (value <= 1 or value % 1 == 0),
      'docmost: ui.' .. key .. ' must be a positive fraction or integer'
    )
  end
  assert(
    vim.tbl_contains({ 'none', 'single', 'double', 'rounded', 'solid', 'shadow' }, c.ui.border),
    'docmost: invalid ui.border'
  )
  assert(
    c.ui.icons == 'unicode' or c.ui.icons == 'ascii',
    "docmost: ui.icons must be 'unicode' or 'ascii'"
  )
  for _, key in ipairs({ 'preview', 'winbar' }) do
    assert(type(c.ui[key]) == 'boolean', 'docmost: ui.' .. key .. ' must be a boolean')
  end
  for _, key in ipairs({ 'search_debounce_ms', 'preview_debounce_ms' }) do
    local value = c.ui[key]
    assert(
      type(value) == 'number' and value >= 0 and value % 1 == 0,
      'docmost: ui.' .. key .. ' must be a non-negative integer'
    )
  end
  assert(
    not c.session_token or type(c.session_token) == 'function',
    'docmost: session_token must be a function'
  )
  c.authority = authority
  M.values = c
  return c
end

function M.get()
  assert(M.values, 'docmost: call setup({base_url = ...}) first')
  return M.values
end
return M
