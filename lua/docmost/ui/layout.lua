local M = {}

local function size(value, total)
  return value <= 1 and math.floor(total * value) or value
end

function M.compute(screen, opts, flags)
  flags = flags or {}
  local columns, lines = screen.columns, screen.lines
  local available = math.max(3, lines - (screen.cmdheight or 1) - 2)
  local edge = opts.border == 'none' and 0 or 1
  local width = math.max(1, math.min(size(opts.width, columns), columns - 2))
  local height = math.max(1, math.min(size(opts.height, available), available))
  local mode = 'narrow'
  if width < 44 or height < 10 then
    mode = 'tiny'
    width = math.max(1, math.min(columns, math.max(width, columns - 2)))
    height = math.max(1, math.min(available, math.max(height, available)))
  elseif width >= 96 and height >= 12 and flags.preview ~= false then
    mode = 'wide'
  end
  local row = math.max(0, math.floor((available - height) / 2))
  local col = math.max(0, math.floor((columns - width) / 2))
  local list_width = width
  if mode == 'wide' then
    list_width = math.max(34, math.min(64, math.floor(width * 0.42)))
  end
  local function box(r, c, w, h)
    return {
      relative = 'editor',
      row = r,
      col = c,
      width = math.max(1, w - 2 * edge),
      height = math.max(1, h - 2 * edge),
    }
  end
  local out = { mode = mode, edge = edge, width = width, height = height }
  out.list = box(row, col, list_width, height)
  if flags.search then
    local prompt_height = 1 + 2 * edge
    if height - prompt_height >= 1 + 2 * edge + 1 then
      out.prompt = box(row, col, list_width, prompt_height)
      out.list = box(row + prompt_height, col, list_width, height - prompt_height)
    else
      out.prompt = box(row, col, list_width, prompt_height)
    end
  end
  if mode == 'wide' then
    out.preview = box(row, col + list_width, width - list_width, height)
  end
  return out
end

function M.fit(items, width)
  local function cost(item)
    return vim.fn.strdisplaywidth(item[1] .. ' ' .. item[2]) + 2
  end
  local last = items[#items]
  local used = cost(last)
  local chosen = {}
  for index = 1, #items - 1 do
    if used + cost(items[index]) > width then
      break
    end
    chosen[#chosen + 1] = items[index]
    used = used + cost(items[index])
  end
  if used <= width then
    chosen[#chosen + 1] = last
  end
  return chosen
end

function M.truncate(text, width, ellipsis)
  ellipsis = ellipsis or '…'
  if width <= 0 then
    return ''
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local out, used = {}, 0
  for _, char in ipairs(vim.fn.split(text, '\\zs')) do
    local w = vim.fn.strdisplaywidth(char)
    if used + w > width - 1 then
      break
    end
    out[#out + 1] = char
    used = used + w
  end
  return table.concat(out) .. ellipsis
end

return M
