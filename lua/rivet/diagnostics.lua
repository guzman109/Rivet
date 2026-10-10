local M = {}
function M.parse(line, cwd)
  local path, row, col, kind, message = line:match('^(.-):(%d+):(%d+):%s*([%a ]+):%s*(.*)$')
  if not path then
    path, row, kind, message = line:match('^(.-):(%d+):%s*([%a ]+):%s*(.*)$')
  end
  local types = { error = 'E', ['fatal error'] = 'E', warning = 'W', note = 'I' }
  if not path or not types[kind] then
    return
  end
  path = path:match('^%s*(.-)%s*$')
  if path == '' or path:match('^<.*>$') then
    return
  end
  if not path:match('^/') and not path:match('^%a:[/\\]') then
    path = cwd .. '/' .. path
  end
  return {
    filename = path,
    lnum = tonumber(row),
    col = tonumber(col) or 1,
    text = message,
    type = types[kind],
  }
end

return M
