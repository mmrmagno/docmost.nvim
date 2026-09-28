local M = {}
function M.show(state)
  if not state.remote then
    return vim.notify('docmost: no remote difference available')
  end
  local local_md = vim.api.nvim_buf_is_valid(state.buf)
      and table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), '\n')
    or state.snapshot
  vim.cmd('tabnew')
  for i, entry in ipairs({
    { 'BASE', state.baseline.markdown },
    { 'LOCAL', local_md },
    { 'REMOTE', state.remote.markdown },
  }) do
    if i > 1 then
      vim.cmd('vnew')
    end
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
    vim.api.nvim_buf_set_name(
      buf,
      'docmost-diff://'
        .. state.id
        .. '/'
        .. tostring((vim.uv or vim.loop).hrtime())
        .. '/'
        .. entry[1]
    )
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(entry[2] or '', '\n', { plain = true }))
    vim.bo[buf].filetype, vim.bo[buf].modifiable = 'markdown', false
    vim.cmd('diffthis')
  end
end
return M
