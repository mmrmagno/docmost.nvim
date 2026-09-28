local M = {}
local function select_pages(route, params, prompt, on_item, seen, depth)
  seen, depth = seen or {}, depth or 1
  if depth > require('docmost.config').get().max_pages then
    vim.notify('docmost: pagination limit reached')
    return
  end
  require('docmost.api').list(route, params, function(err, items, next_cursor)
    if err then
      vim.notify('docmost: ' .. err.message, vim.log.levels.ERROR)
      return
    end
    local choices = {}
    for _, item in ipairs(items) do
      choices[#choices + 1] = { item = item, label = item.title or item.name or item.id }
    end
    if next_cursor and not seen[next_cursor] then
      choices[#choices + 1] = { more = true, label = 'Load more…' }
    end
    vim.ui.select(choices, {
      prompt = prompt,
      format_item = function(v)
        return v.label
      end,
    }, function(choice)
      if not choice then
        return
      end
      if choice.more then
        seen[next_cursor] = true
        params[route == '/search' and 'offset' or 'cursor'] = next_cursor
        select_pages(route, params, prompt, on_item, seen, depth + 1)
      else
        on_item(choice.item)
      end
    end)
  end)
end

function M.pages(space_id, parent)
  select_pages(
    '/pages/sidebar-pages',
    { spaceId = space_id, pageId = parent },
    'Docmost pages',
    function(page)
      vim.ui.select(
        { 'Open page', 'Browse children' },
        { prompt = page.title or page.id },
        function(choice)
          if choice == 'Open page' then
            require('docmost.buffer').open(page.id)
          elseif choice == 'Browse children' then
            M.pages(space_id, page.id)
          end
        end
      )
    end
  )
end

function M.spaces()
  select_pages('/spaces', {}, 'Docmost spaces', function(space)
    M.pages(space.id)
  end)
end

function M.search(query)
  if not query or query == '' then
    vim.ui.input({ prompt = 'Search Docmost: ' }, function(input)
      if input and input ~= '' then
        M.search(input)
      end
    end)
    return
  end
  select_pages('/search', { query = query, offset = 0 }, 'Docmost search', function(page)
    require('docmost.buffer').open(page.id)
  end)
end
return M
