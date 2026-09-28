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
      { ':Docmost cheatsheet', 'syntax for every kind of Docmost block' },
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
    'Every page opens as Markdown and :w saves it. Saving is asynchronous: the winbar shows checking, saving, verifying and finally verified once two fresh reads match.',
    'Plain Markdown covers headings, paragraphs, lists, task lists (- [ ]), quotes, code, tables, links, bold, italic, strikethrough and inline code.',
    'Everything else uses attributes: [text]{.underline}, [text]{.highlight color="#ff0"}, [@Name]{.mention ...}, ::: {.callout type="info"} blocks, ![caption](src){.image ...}. The {...} parts are hidden until the cursor is on the line.',
    'Add a block by writing it between blank lines. Copy an existing ::: block to make another of the same kind. Block IDs follow your edits automatically.',
    'The title: line at the top renames the page. A # heading only changes the body. Creating pages and uploading new files still need the browser.',
    ':Docmost check marks problems without sending anything. :Docmost inspect shows the construct under the cursor. <C-x><C-o> completes names.',
    'Close the browser editor for a page before saving it here. If a save is uncertain, :w checks again by reading and never resends.',
    'New to this? Try a disposable page first.',
  },
}

M.cheatsheet = {
  { 'Page title', '---  title: New name  ---   (top of the page)' },
  { 'Bold, italic', '**bold**  *italic*  ~~strike~~  `code`' },
  { 'Link, new tab', '[text](https://x)   [text](https://x){target="_blank"}' },
  { 'Underline', '[text]{.underline}' },
  { 'Highlight', '[text]{.highlight color="#fef08a"}' },
  { 'Text colour', '[text]{.textStyle color="#e03131"}' },
  { 'Sub, superscript', '[2]{.subscript}  [2]{.superscript}   or  H~2~O  x^2^' },
  { 'Math', '$x^2$   and   $$E = mc^2$$ alone on a line' },
  { 'Line break', 'end the line with \\' },
  { 'Empty paragraph', 'a line holding only \\' },
  { 'Task list', '- [ ] todo    - [x] done' },
  { 'Table', '| a | b |  then  | --- | --- |  then rows' },
  { 'Callout', '::: {.callout type="warning"}  text  :::' },
  { 'Details', ':::: details / ::: detailsSummary / ::: detailsContent' },
  { 'Columns', ':::: columns / ::: column / ::: column' },
  { 'Centered', '::: {textAlign="center"}  paragraph  :::' },
  { 'Image', '![caption](url){.image align="center"}' },
  { 'Embed', '::: {.embed provider="youtube" src="url"}  :::' },
  { 'Mention, comment', 'copy an existing one; IDs come from Docmost' },
  { 'Snippets', 'type callout, details, columns, task, highlight, center, math,' },
  { '', 'image, embed, newtab, mergedtable or table, then Tab through fields' },
  { 'Tools', ':Docmost check   :Docmost inspect   <C-x><C-o> completes names' },
}

function M.sheet(width)
  local lines, marks = { ' CHEATSHEET' }, { { 0, 'DocmostSection' } }
  for _, entry in ipairs(M.cheatsheet) do
    local key = string.format('   %-18s', entry[1])
    lines[#lines + 1] = key .. entry[2]
    marks[#marks + 1] = { #lines - 1, 'DocmostKey', #key }
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = ' q closes this panel'
  marks[#marks + 1] = { #lines - 1, 'DocmostDim' }
  return lines, marks
end

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
