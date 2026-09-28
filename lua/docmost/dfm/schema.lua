local M = {}

M.inline_nodes = {
  hardBreak = true,
  mention = true,
  mathInline = true,
  status = true,
  footnoteReference = true,
  emoji = true,
}

M.textblocks = { paragraph = true, heading = true, codeBlock = true, detailsSummary = true }

M.media = {
  image = { url = 'src', text = 'alt' },
  video = { url = 'src' },
  audio = { url = 'src' },
  pdf = { url = 'src' },
  drawio = { url = 'src' },
  excalidraw = { url = 'src' },
  attachment = { url = 'url', text = 'name', link = true },
}

M.known = {
  doc = true,
  paragraph = true,
  heading = true,
  blockquote = true,
  bulletList = true,
  orderedList = true,
  listItem = true,
  taskList = true,
  taskItem = true,
  codeBlock = true,
  horizontalRule = true,
  hardBreak = true,
  text = true,
  callout = true,
  details = true,
  detailsSummary = true,
  detailsContent = true,
  mathInline = true,
  mathBlock = true,
  table = true,
  tableRow = true,
  tableCell = true,
  tableHeader = true,
  image = true,
  video = true,
  audio = true,
  pdf = true,
  attachment = true,
  drawio = true,
  excalidraw = true,
  embed = true,
  youtube = true,
  mention = true,
  status = true,
  subpages = true,
  pageBreak = true,
  columns = true,
  column = true,
  footnotes = true,
  footnote = true,
  footnoteReference = true,
  transclusionSource = true,
  transclusionReference = true,
}

M.marks = {
  bold = true,
  italic = true,
  strike = true,
  code = true,
  link = true,
  underline = true,
  highlight = true,
  textStyle = true,
  subscript = true,
  superscript = true,
  comment = true,
}

local defaults = {
  textAlign = { 'left' },
  indent = { 0 },
  dir = { 'auto' },
}

local function null(v)
  return v == nil or v == vim.NIL
end

function M.is_inline(node)
  return node.type == 'text' or M.inline_nodes[node.type] == true
end

function M.split(node)
  local hidden, visible = {}, {}
  if node.type ~= 'paragraph' and node.type ~= 'heading' then
    return hidden, vim.deepcopy(node.attrs or {})
  end
  for key, value in pairs(node.attrs or {}) do
    if key == 'level' and node.type == 'heading' then
      hidden[key] = nil
    elseif key == 'id' or null(value) then
      hidden[key] = value
    elseif defaults[key] and vim.tbl_contains(defaults[key], value) then
      hidden[key] = value
    else
      visible[key] = value
    end
  end
  return hidden, visible
end

function M.canonical_cell(attrs)
  if type(attrs) ~= 'table' then
    return false
  end
  for key, value in pairs(attrs) do
    if key == 'colspan' or key == 'rowspan' then
      if value ~= 1 then
        return false
      end
    elseif not null(value) then
      return false
    end
  end
  return attrs.colspan == 1 and attrs.rowspan == 1
end

M.cell = { colspan = 1, rowspan = 1, colwidth = vim.NIL }

function M.item_extra(item)
  local extra = vim.deepcopy(item.attrs or {})
  if item.type == 'taskItem' then
    extra.checked = nil
  end
  return extra
end

return M
