local M = {}

M.list = {
  {
    trigger = 'callout',
    description = 'Callout box',
    body = '::: {.callout type="${1|info,success,warning,danger|}"}\n${2:Text}\n:::',
  },
  {
    trigger = 'details',
    description = 'Collapsible section',
    body = ':::: details\n::: detailsSummary\n${1:Summary}\n:::\n\n::: detailsContent\n${2:Hidden text}\n:::\n::::',
  },
  {
    trigger = 'columns',
    description = 'Two columns',
    body = ':::: columns\n::: column\n${1:Left}\n:::\n\n::: column\n${2:Right}\n:::\n::::',
  },
  {
    trigger = 'task',
    description = 'Task list item',
    body = '- [ ] ${1:Task}',
  },
  {
    trigger = 'highlight',
    description = 'Highlighted text',
    body = '[${1:text}]{.highlight color="${2:#fef08a}"}',
  },
  {
    trigger = 'underline',
    description = 'Underlined text',
    body = '[${1:text}]{.underline}',
  },
  {
    trigger = 'color',
    description = 'Coloured text',
    body = '[${1:text}]{.textStyle color="${2:#e03131}"}',
  },
  {
    trigger = 'math',
    description = 'Inline math',
    body = '\\$${1:x^2}\\$',
  },
  {
    trigger = 'mathblock',
    description = 'Math on its own line',
    body = '\\$\\$${1:E = mc^2}\\$\\$',
  },
  {
    trigger = 'center',
    description = 'Centered paragraph',
    body = '::: {textAlign="${1|center,right,justify|}"}\n${2:Text}\n:::',
  },
  {
    trigger = 'newtab',
    description = 'Link opening in a new tab',
    body = '[${1:text}](${2:https://}){target="_blank"}',
  },
  {
    trigger = 'image',
    description = 'Image from a URL',
    body = '![${1:caption}](${2:https://}){.image align="${3|center,left,right|}"}',
  },
  {
    trigger = 'embed',
    description = 'Embedded content',
    body = '::: {.embed provider="${1|youtube,loom,figma,miro,vimeo|}" src="${2:https://}"}\n:::',
  },
  {
    trigger = 'mergedtable',
    description = 'Table with a merged header cell',
    body = table.concat({
      '::::: table',
      ':::: tableRow',
      '::: {.tableHeader colspan="2" rowspan="1"}',
      '${1:Merged header}',
      ':::',
      '::::',
      '',
      ':::: tableRow',
      '::: {.tableCell colspan="1" rowspan="1"}',
      '${2:a}',
      ':::',
      '',
      '::: {.tableCell colspan="1" rowspan="1"}',
      '${3:b}',
      ':::',
      '::::',
      ':::::',
    }, '\n'),
  },
}

local registered = false

function M.register()
  if registered then
    return true
  end
  local ok, luasnip = pcall(require, 'luasnip')
  if not ok then
    return false
  end
  local function page()
    return require('docmost.buffer').current(0) ~= nil
  end
  local snippets = {}
  for _, spec in ipairs(M.list) do
    local ok_parse, snippet = pcall(luasnip.parser.parse_snippet, {
      trig = spec.trigger,
      name = 'docmost ' .. spec.trigger,
      desc = spec.description,
      condition = page,
      show_condition = page,
    }, spec.body)
    if ok_parse then
      snippets[#snippets + 1] = snippet
    end
  end
  luasnip.add_snippets('markdown', snippets, { key = 'docmost' })
  registered = true
  return true
end

return M
