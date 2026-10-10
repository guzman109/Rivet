local base = require('rivet.headers')
local M = {
  fields = base.fields,
  styles = {},
  normalize = base.normalize,
  example = { filename = 'example.py', body = 'def answer():\n    return 42\n' },
}
for _, style in ipairs(base.styles) do
  if style.id ~= 'doc' then
    M.styles[#M.styles + 1] = style
  end
end
function M.accepts(path, ft)
  return ft == 'python' or path:match('%.py$') ~= nil
end
function M.render(value, context)
  if value and value.style == 'doc' then
    error('Choose a line-comment header for Python')
  end
  return (base.render(value, context):gsub('^//', '#'):gsub('\n//', '\n#'))
end
function M.preamble(text)
  local prefix = ''
  local first = text:match('^[^\n]*\n') or ''
  if first:match('^#!') or first:match('^#[^\n]*coding[:=]') then
    prefix = first
  end
  local second = text:sub(#prefix + 1):match('^[^\n]*\n') or ''
  if second:match('^#[^\n]*coding[:=]') then
    prefix = prefix .. second
  end
  return prefix
end
function M.leading(text)
  if text:match('^#!') or text:match('^#[^\n]*coding[:=]') then
    return 0
  end
  local pos = 1
  while text:sub(pos):match('^[ \t]*#') do
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
  return base.extract((text:sub(1, M.leading(text)):gsub('^#', '//'):gsub('\n#', '\n//')))
end
return M
