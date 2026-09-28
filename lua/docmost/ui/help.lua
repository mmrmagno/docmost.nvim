local M = {}

M.sections = {
  {
    'Browse',
    {
      { 'j k  gg G', 'move between rows' },
      { 'Enter', 'open page, expand space, run action' },
      { 'l  h', 'expand children  /  collapse or go to parent' },
      { '-', 'collapse back to the space' },
      { 'C-v C-x C-t', 'open in vsplit / split / tab' },
      { 'p', 'show or hide the preview' },
      { 'r', 'refresh or retry the selected row' },
      { '.', 'actions for the selected row' },
    },
  },
  {
    'Search',
    {
      { '/', 'search; results update as you type' },
      { 'Enter  Down', 'from the query, go to results' },
      { 'Esc', 'from results, back to browsing' },
      { 'C-c', 'clear the search' },
    },
  },
  {
    'Pages',
    {
      { 'o', 'open a page by URL or ID' },
      { 'w', 'save and verify the selected or current page' },
      { 'R', 'reload a clean page' },
      { 'd', 'diff base, local and remote' },
      { ':Docmost', 'from any page buffer, return here' },
    },
  },
  {
    'Session',
    {
      { 'a', 'sign in (password via secret prompt)' },
      { 'L', 'sign out locally; edits stay' },
      { 'q  Esc', 'close; the workspace remembers where you were' },
    },
  },
}

M.editing = {
  'Editing pages',
  {
    'Pages open as ordinary Markdown buffers. Use :w to save. Saving is asynchronous: the winbar shows checking, saving, verifying and finally verified once two fresh reads match.',
    'Supported: headings, paragraphs, bullet and numbered lists, quotes, code blocks, horizontal rules, bold, italic, strikethrough and inline code.',
    'Adding blocks: write new Markdown blocks separated by a blank line. If you also changed text nearby, save the text first (:w), then add or remove blocks and save again, so existing block IDs stay attached.',
    'Tables, images, attachments, task lists, callouts and other rich content keep a page read-only. Do not force it with :set modifiable; edit those pages in the browser.',
    'A # heading changes the body, not the page title. Creating and deleting pages is not supported.',
    'Close the browser editor for a page before saving it here. Checks run before every write, but they cannot make simultaneous editing safe.',
    'If a save is uncertain, :w checks again by reading; it never resends. :Docmost diff shows base, local and remote.',
    'New to this? Try a disposable page first.',
  },
}

local function wrap(text, width, indent)
  local out, line = {}, ''
  for word in text:gmatch('%S+') do
    if line == '' then
      line = word
    elseif vim.fn.strdisplaywidth(line .. ' ' .. word) <= width then
      line = line .. ' ' .. word
    else
      out[#out + 1] = indent .. line
      line = word
    end
  end
  out[#out + 1] = indent .. line
  return out
end

function M.build(width, only_editing)
  local lines, marks = {}, {}
  local function add(text, group, stop)
    lines[#lines + 1] = text
    if group then
      marks[#marks + 1] = { #lines - 1, group, stop }
    end
  end
  if not only_editing then
    for _, section in ipairs(M.sections) do
      add(' ' .. section[1]:upper(), 'DocmostSection')
      for _, entry in ipairs(section[2]) do
        local key = string.format('   %-13s', entry[1])
        add(key .. entry[2], 'DocmostKey', #key)
      end
      add('')
    end
  end
  add(' ' .. M.editing[1]:upper(), 'DocmostSection')
  for _, text in ipairs(M.editing[2]) do
    for _, line in ipairs(wrap(text, math.max(20, width - 4), '   ')) do
      add(line)
    end
    add('')
  end
  add(' q or ? closes this panel', 'DocmostDim')
  return lines, marks
end

return M
