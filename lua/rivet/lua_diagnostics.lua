local M = {}

function M.parse(line, cwd)
  local standard = require('rivet.diagnostics').parse(line, cwd)
  if standard then
    return standard
  end
  -- Lua/LuaJIT errors have no explicit "error:" marker; luacheck includes columns.
  local path, row, col, message = line:match('^%s*(.-%.lua):(%d+):(%d+):%s*(.*)$')
  if not path then
    path, row, message = line:match('^%s*(.-%.lua):(%d+):%s*(.*)$')
  end
  if not path then
    return
  end
  -- Interpreter banners precede the source path in an uncaught runtime error.
  path = path:gsub('^.-:%s+', '')
  return {
    filename = path:sub(1, 1) == '/' and path or cwd .. '/' .. path,
    lnum = tonumber(row),
    col = tonumber(col) or 1,
    text = message,
    type = message:match('^%(W%d+%)') and 'W' or 'E',
  }
end

return M
