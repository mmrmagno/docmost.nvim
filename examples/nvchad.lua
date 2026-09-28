-- Add this entry to the table returned by ~/.config/nvim/lua/plugins/init.lua.
-- For a local checkout, replace the first line with dir = '/path/to/docmost.nvim'.
return {
  {
    'mmrmagno/docmost.nvim',
    cmd = 'Docmost',
    opts = {
      base_url = 'https://docs.example.com',
      -- Keep the session across restarts, in a private file under stdpath('state').
      persist_session = true,
      -- For browser/SSO sessions instead, use a local provider:
      -- session_token = function() return vim.env.DOCMOST_SESSION_TOKEN end,
    },
  },
}
