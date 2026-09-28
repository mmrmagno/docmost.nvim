local M = {}
local commands = {
  'ui',
  'login',
  'logout',
  'spaces',
  'search',
  'open',
  'save',
  'reload',
  'status',
  'diff',
  'cancel',
  'version',
  'guide',
  'check',
  'inspect',
  'cheatsheet',
}
local function report(err, message)
  vim.notify(
    'docmost: ' .. (err and err.message or message),
    err and vim.log.levels.ERROR or vim.log.levels.INFO
  )
end

function M.setup(opts)
  if require('docmost.config').values then
    assert(
      next(require('docmost.buffer').states) == nil,
      'docmost: restart Neovim to reconfigure with open pages'
    )
    assert(next(require('docmost.http').active) == nil, 'docmost: requests are still running')
  end
  require('docmost.config').setup(opts)
  require('docmost.auth').reset()
  M.register()
  require('docmost.highlights').setup()
  local group = vim.api.nvim_create_augroup('DocmostLifecycle', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
    group = group,
    callback = function()
      vim.schedule(require('docmost.status').sweep)
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      require('docmost.buffer').backup_all()
      require('docmost.http').cancel_all()
    end,
  })
end

function M.login(callback)
  callback = callback
    or function(err)
      if not err or err.kind ~= 'cancelled' then
        report(err, 'Authenticated')
      end
    end
  vim.ui.input({ prompt = 'Docmost email: ' }, function(email)
    if not email or email == '' then
      callback({ kind = 'cancelled', message = 'Login cancelled' })
      return
    end
    -- vim.ui.input has no portable secret mode (including NvChad providers).
    local ok, password = pcall(vim.fn.inputsecret, 'Docmost password: ')
    if not ok or password == '' then
      callback({ kind = 'cancelled', message = 'Login cancelled' })
      return
    end
    require('docmost.auth').login(email, password, callback)
    password = nil
  end)
end

function M.status()
  require('docmost.auth').validate(function(err)
    local s = require('docmost.buffer').current()
    local message = require('docmost.auth').status
      .. '; '
      .. require('docmost.buffer').compatibility
    if s then
      local d = require('docmost.status').describe(s)
      message = message .. '; page: ' .. d.label .. (d.hint and ('. ' .. d.hint) or '')
    end
    report(err, message)
  end)
end

function M.register()
  vim.api.nvim_create_user_command('Docmost', function(args)
    local action, rest = args.args:match('^(%S*)%s*(.-)$')
    local ok, err = pcall(function()
      require('docmost.config').get()
      if action == '' or action == 'ui' then
        require('docmost.ui').open()
      elseif action == 'login' then
        M.login()
      elseif action == 'logout' then
        require('docmost.auth').logout()
        report(nil, 'Logged out locally; external session sources are unchanged')
      elseif action == 'spaces' then
        require('docmost.picker').spaces()
      elseif action == 'search' then
        require('docmost.picker').search(rest)
      elseif action == 'open' then
        require('docmost.buffer').open(rest)
      elseif action == 'save' then
        require('docmost.buffer').save()
      elseif action == 'reload' then
        require('docmost.buffer').reload(args.bang)
      elseif action == 'status' then
        M.status()
      elseif action == 'diff' then
        local s = require('docmost.buffer').current()
        if s then
          require('docmost.conflict').show(s)
        else
          report({ message = 'Not a Docmost buffer' })
        end
      elseif action == 'cancel' then
        require('docmost.buffer').cancel()
      elseif action == 'check' then
        require('docmost.buffer').check()
      elseif action == 'inspect' then
        require('docmost.dfm.decorate').inspect()
      elseif action == 'cheatsheet' then
        require('docmost.ui').guide('cheatsheet')
      elseif action == 'guide' then
        require('docmost.ui').guide()
      elseif action == 'version' then
        require('docmost.api').post('/version', {}, function(e, data)
          if not e and (type(data) ~= 'table' or type(data.currentVersion) ~= 'string') then
            e = { message = 'Version not exposed by server' }
          end
          report(e, not e and ('Server version: ' .. data.currentVersion) or '')
        end)
      else
        report({ message = 'Unknown Docmost command' })
      end
    end)
    if not ok then
      -- Internal error text can contain user-supplied provider values. Keep
      -- command errors static; setup validation remains available to the caller.
      report({
        message = require('docmost.config').values
            and 'Operation failed locally; run :checkhealth docmost'
          or 'Call require("docmost").setup({base_url = ...}) first',
      })
    end
  end, {
    nargs = '*',
    bang = true,
    force = true,
    complete = function(lead, line)
      if #vim.split(line, '%s+') > 2 then
        return {}
      end
      return vim.tbl_filter(function(cmd)
        return cmd:sub(1, #lead) == lead
      end, commands)
    end,
  })
end
return M
