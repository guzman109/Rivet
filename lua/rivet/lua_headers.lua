local base = require('rivet.headers')
local M = {
  fields = base.fields,
  styles = base.styles,
  normalize = base.normalize,
  example = { filename = 'example.lua', body = 'local M = {}\nreturn M\n' },
}

function M.accepts(path, filetype)
  return filetype == 'lua' or path:match('%.lua$') ~= nil
end

function M.render(value, context)
  local text = base.render(value, context)
  if value and value.style == 'doc' then
    text = text:gsub('^/%*%*\n', ''):gsub(' %*/\n', '')
    return (text:gsub('^ %* ?', '--- '):gsub('\n %* ?', '\n--- '))
  end
  return (text:gsub('^//', '--'):gsub('\n//', '\n--'))
end

function M.preamble(text)
  return text:match('^(#![^\n]*\n)') or ''
end

function M.leading(text)
  if text:match('^#!') then
    return 0
  end
  local pos = 1
  while text:sub(pos):match('^[ \t]*%-%-') do
    -- A long comment may contain code on its closing line; leave it intact.
    if text:sub(pos):match('^[ \t]*%-%-%[=*%[') then
      return 0
    end
    local newline = text:find('\n', pos, true)
    if not newline then
      return #text
    end
    pos = newline + 1
  end
  if pos == 1 then
    return 0
  end
  local blanks = text:sub(pos):match('^([ \t\r\n]*\n)') or ''
  return pos - 1 + #blanks
end

function M.extract(text)
  local top = text:sub(1, M.leading(text))
  local doc = top:match('^%-%-%-') ~= nil
  top = top:gsub('^%-%-%-?', '//'):gsub('\n%-%-%-?', '\n//')
  local value = base.extract(top)
  if doc then
    value.style = 'doc'
  end
  return value
end

return M
