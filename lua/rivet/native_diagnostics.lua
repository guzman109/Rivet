local M = {}
function M.parse(line, cwd)
  if line:sub(1, 1) == '{' then
    local ok, item = pcall(require('rivet.json').decode, line)
    if
      ok
      and type(item) == 'table'
      and item.reason == 'compiler-message'
      and type(item.message) == 'table'
      and type(item.message.message) == 'string'
      and type(item.message.spans) == 'table'
    then
      local m = item.message
      for _, span in ipairs(m.spans or {}) do
        if
          type(span) == 'table'
          and span.is_primary
          and type(span.file_name) == 'string'
          and type(span.line_start) == 'number'
          and type(span.column_start) == 'number'
        then
          local path = span.file_name
          return {
            filename = path:sub(1, 1) == '/' and path or cwd .. '/' .. path,
            lnum = span.line_start,
            col = span.column_start,
            text = m.message,
            type = m.level == 'warning' and 'W' or 'E',
          }
        end
      end
    end
  end
  local path, row = line:match('^%s*File "(.-)", line (%d+)')
  if path and path:sub(1, 1) ~= '<' then
    return {
      filename = path:sub(1, 1) == '/' and path or cwd .. '/' .. path,
      lnum = tonumber(row),
      col = 1,
      text = 'Python traceback / syntax error',
      type = 'E',
    }
  end
  return require('rivet.diagnostics').parse(line, cwd)
end
function M.render(line)
  if line:sub(1, 1) == '{' then
    local ok, item = pcall(require('rivet.json').decode, line)
    if ok and type(item) == 'table' then
      if item.reason == 'compiler-message' and type(item.message) == 'table' then
        local message = item.message.rendered or item.message.message
        if type(message) == 'string' then
          return message
        end
      end
      if
        item.reason == 'compiler-artifact'
        and type(item.target) == 'table'
        and type(item.target.name) == 'string'
      then
        return 'Built ' .. item.target.name
      end
      if item.reason == 'build-finished' and type(item.success) == 'boolean' then
        return item.success and 'Build finished' or 'Build failed'
      end
    end
  end
  return line
end
function M.render_for(argv)
  for _, arg in ipairs(argv or {}) do
    if arg:match('^%-%-message%-format=json') then
      return M.render
    end
  end
  -- Application output, Python tools, and Swift tools are plain text even
  -- when a line happens to look like a Cargo protocol message.
end
return M
