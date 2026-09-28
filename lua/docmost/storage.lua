local M = {}
local uv = vim.uv or vim.loop

function M.directory(path)
  vim.fn.mkdir(path, 'p', 448)
  local st = uv.fs_lstat(path)
  assert(st and st.type == 'directory', 'docmost: unsafe state directory')
  assert(uv.fs_chmod(path, 448), 'docmost: cannot secure state directory')
end

function M.write(path, data)
  -- Exclusive staging file prevents following symlinks and avoids partial records.
  local tmp = path .. '.' .. tostring(uv.hrtime())
  local fd = assert(uv.fs_open(tmp, 'wx', 384), 'docmost: cannot create private file')
  local offset = 0
  while offset < #data do
    local count = uv.fs_write(fd, data:sub(offset + 1), offset)
    if not count or count == 0 then
      uv.fs_close(fd)
      uv.fs_unlink(tmp)
      error('docmost: cannot write private file')
    end
    offset = offset + count
  end
  local ok = uv.fs_fsync(fd)
  uv.fs_close(fd)
  if not ok then
    uv.fs_unlink(tmp)
    error('docmost: cannot write private file')
  end
  local renamed = uv.fs_rename(tmp, path)
  if not renamed then
    uv.fs_unlink(tmp)
    error('docmost: cannot commit private file')
  end
end

function M.read(path)
  local st = uv.fs_lstat(path)
  if not st then
    return nil
  end
  assert(
    st.type == 'file' and st.mode % 64 == 0,
    'docmost: session file must be private (chmod 600)'
  )
  assert(st.size < 65536, 'docmost: session file too large')
  local fd = assert(uv.fs_open(path, 'r', 0), 'docmost: cannot read session file')
  local data = uv.fs_read(fd, st.size, 0)
  uv.fs_close(fd)
  return data
end

function M.backup(state, snapshot)
  local c = require('docmost.config').get()
  local dir = c.state_dir .. '/backups/' .. vim.fn.sha256(c.base_url .. '/' .. state.id):sub(1, 24)
  M.directory(c.state_dir)
  M.directory(c.state_dir .. '/backups')
  M.directory(dir)
  local path = dir
    .. '/'
    .. os.date('!%Y%m%dT%H%M%S')
    .. string.format('-%020.0f.json', uv.hrtime())
  M.write(
    path,
    vim.json.encode({
      base_url = c.base_url,
      page_id = state.id,
      baseline = state.baseline,
      local_markdown = snapshot,
      pending = state.pending,
      timestamp = os.time(),
    })
  )
  local files = vim.fn.glob(dir .. '/*.json', false, true)
  table.sort(files, function(a, b)
    return #a == #b and a < b or #a < #b
  end)
  while #files > c.backup_retention do
    uv.fs_unlink(table.remove(files, 1))
  end
  return path
end
return M
