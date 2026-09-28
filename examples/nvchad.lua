-- Add this entry to the table returned by ~/.config/nvim/lua/plugins/init.lua.
return {
  {
    dir = '/path/to/docmost.nvim',
    cmd = 'Docmost',
    opts = {
      base_url = 'https://docs.example.com',
      -- Default login/session is memory-only. :Docmost login prompts locally.
      persist_session = false,
      -- For browser/SSO sessions instead, use a local provider:
      -- session_token = function() return vim.env.DOCMOST_SESSION_TOKEN end,
    },
  },
}
