local M = {}
local function parse_text(line, cwd)
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
  return parse_text(line, cwd)
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
local function cargo_json(argv)
  argv = argv or {}
  local index = 1
  -- Task environment overrides wrap the executable in env. Do not search
  -- arbitrary launcher/application arguments for an executable named cargo.
  if (argv[index] or ''):match('[^/]+$') == 'env' then
    index = index + 1
    while argv[index] do
      local arg = argv[index]
      if arg == '-u' or arg == '--unset' then
        index = index + 2
      elseif arg == '-i' or arg == '--ignore-environment' or arg:match('^[%w_]+=') then
        index = index + 1
      elseif arg == '--' then
        index = index + 1
        break
      else
        break
      end
    end
  end
  if (argv[index] or ''):match('[^/]+$') ~= 'cargo' then
    return false
  end
  for i = index + 1, #argv do
    local arg = argv[i]
    if arg == '--' then
      break
    end
    local format = arg:match('^%-%-message%-format=(.*)$')
      or (arg == '--message-format' and argv[i + 1])
    for value in (format or ''):gmatch('[^,]+') do
      if
        value == 'json'
        or value == 'json-diagnostic-short'
        or value == 'json-diagnostic-rendered-ansi'
        or value == 'json-render-diagnostics'
      then
        return true
      end
    end
  end
  return false
end
local function cargo_reader(argv)
  if not cargo_json(argv) then
    return
  end
  local finished = false
  return function(line, stream)
    if finished or stream and stream ~= 'stdout' then
      return false
    end
    if line:sub(1, 1) == '{' then
      local ok, item = pcall(require('rivet.json').decode, line)
      if
        ok
        and type(item) == 'table'
        and item.reason == 'build-finished'
        and type(item.success) == 'boolean'
      then
        -- Cargo promises no further build JSON after this message. Run/test
        -- can continue emitting arbitrary application output on the same pipe.
        finished = true
      end
    end
    return true
  end
end
function M.render_for(argv)
  local reading = cargo_reader(argv)
  if reading then
    return function(line, stream)
      return reading(line, stream) and M.render(line) or line
    end
  end
end
function M.parse_for(argv)
  local reading = cargo_reader(argv)
  return function(line, cwd, stream)
    if reading and reading(line, stream) then
      return M.parse(line, cwd)
    end
    return parse_text(line, cwd)
  end
end
return M
