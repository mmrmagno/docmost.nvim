local M = {}

function M.empty(doc)
  return type(doc) == 'table'
    and doc.type == 'doc'
    and type(doc.content) == 'table'
    and #doc.content == 1
    and type(doc.content[1]) == 'table'
    and doc.content[1].type == 'paragraph'
    and (
      doc.content[1].content == nil
      or (type(doc.content[1].content) == 'table' and #doc.content[1].content == 0)
    )
end

-- No trimming: blank lines, hard-break spaces and code indentation are meaningful.
function M.normalize(md)
  return (md:gsub('\r\n', '\n'))
end

return M
