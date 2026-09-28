local M = {}
local commands = {
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
  local group = vim.api.nvim_create_augroup('DocmostLifecycle', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      require('docmost.buffer').backup_all()
      require('docmost.http').cancel_all()
    end,
  })
end

function M.login()
  vim.ui.input({ prompt = 'Docmost email: ' }, function(email)
    if not email or email == '' then
      return
    end
    -- vim.ui.input has no portable secret mode (including NvChad providers).
    local ok, password = pcall(vim.fn.inputsecret, 'Docmost password: ')
    if not ok or password == '' then
      return
    end
    require('docmost.auth').login(email, password, function(err)
      report(err, 'Authenticated')
    end)
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
      message = message
        .. '; page: '
        .. s.status
        .. (s.baseline.reason and '; read-only: ' .. s.baseline.reason or '')
    end
    report(err, message)
  end)
end

function M.register()
  vim.api.nvim_create_user_command('Docmost', function(args)
    local action, rest = args.args:match('^(%S*)%s*(.-)$')
    local ok, err = pcall(function()
      require('docmost.config').get()
      if action == 'login' then
        M.login()
      elseif action == 'logout' then
        require('docmost.auth').logout()
        report(nil, 'Logged out locally; external session sources are unchanged')
      elseif action == 'spaces' or action == '' then
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
