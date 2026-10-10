-- Pure header templates shared by generation and the editor preview.
local M = {}
M.example = { filename = 'example.cpp', body = 'int main() {\n  return 0;\n}\n' }
function M.accepts(path, filetype)
  local extensions = {
    c = true,
    rs = true,
    swift = true,
    cu = true,
    cuh = true,
    metal = true,
    mm = true,
    h = true,
    cc = true,
    hh = true,
    cpp = true,
    hpp = true,
    cxx = true,
    hxx = true,
    cppm = true,
    ixx = true,
  }
  return filetype == 'c' or filetype == 'cpp' or extensions[path:match('%.([^%.]+)$')] == true
end
M.styles = {
  { id = 'compact', label = 'Compact', description = 'A small, labeled line-comment header.' },
  {
    id = 'xcode',
    label = 'Xcode-style',
    description = 'Filename and project, with breathing room around the credits.',
  },
  {
    id = 'doc',
    label = 'Documentation block',
    description = 'A Doxygen-style file comment with optional documentation fields.',
  },
  {
    id = 'spdx',
    label = 'SPDX first',
    description = 'Put your supplied license expression and copyright notice first.',
  },
  { id = 'none', label = 'No header', description = 'Leave the file without a comment header.' },
}
M.fields = {
  { key = 'author', label = 'Author' },
  { key = 'email', label = 'Email' },
  { key = 'organization', label = 'Organization' },
  { key = 'created', label = 'Created', prompt = 'Creation date (today, YYYY-MM-DD, or blank)' },
  {
    key = 'copyright',
    label = 'Copyright',
    prompt = 'Copyright notice (for example, 2026 Ada Lovelace)',
  },
  { key = 'license', label = 'SPDX-License-Identifier', prompt = 'SPDX license expression' },
  { key = 'description', label = 'Description' },
}

local function field(value, name)
  assert(type(value) == 'string' and #value <= 512, 'Invalid header ' .. name)
  assert(
    not value:find('[%c]') and not value:find('*/', 1, true),
    'Header fields must be single-line comment text'
  )
  value = value:match('^%s*(.-)%s*$')
  assert(not value:match('\\$'), 'Header fields must not end with a backslash')
  return value
end

function M.normalize(value)
  if value == nil then
    return { style = 'none' }
  end
  assert(type(value) == 'table', 'comment_header must be a table')
  local out = { style = value.style == nil and 'none' or value.style }
  local found = false
  for _, style in ipairs(M.styles) do
    found = found or style.id == out.style
  end
  assert(found, 'Unknown comment header style: ' .. tostring(out.style))
  for _, item in ipairs(M.fields) do
    out[item.key] = field(value[item.key] == nil and '' or value[item.key], item.key)
  end
  assert(
    out.created == '' or out.created == 'today' or out.created:match('^%d%d%d%d%-%d%d%-%d%d$'),
    'Use today, YYYY-MM-DD, or a blank header date'
  )
  if out.created ~= '' and out.created ~= 'today' then
    local year, month, day = out.created:match('^(%d+)%-(%d+)%-(%d+)$')
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
    local days = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    assert(days[month] and day >= 1 and day <= days[month], 'Invalid header date')
  end
  assert(
    out.style ~= 'spdx' or out.license ~= '',
    'SPDX headers require a license expression supplied by you'
  )
  return out
end

function M.render(value, context)
  local config = M.normalize(value)
  if config.style == 'none' then
    return ''
  end
  if config.created == 'today' then
    config.created = context.date or os.date('%Y-%m-%d')
  end
  local filename = field(context.filename:match('[^/]+$') or context.filename, 'filename')
  local project = field(context.project or '', 'project')
  local out = {}
  local function add(text)
    out[#out + 1] = text
  end
  if config.style == 'doc' then
    local tags = {
      description = 'brief',
      created = 'date',
      organization = 'par Organization',
      email = 'par Email',
    }
    add('/**')
    add(' * @file ' .. filename)
    if project ~= '' then
      add(' * @par Project: ' .. project)
    end
    for _, item in ipairs(M.fields) do
      local text = config[item.key]
      if text ~= '' then
        if item.key == 'license' then
          add(' * SPDX-License-Identifier: ' .. text)
        else
          local tag = tags[item.key] or item.key
          add(' * @' .. tag .. (tag:match('^par ') and ': ' or ' ') .. text)
        end
      end
    end
    add(' */')
  else
    local prefix = config.style == 'xcode' and '//  ' or '// '
    if config.style == 'xcode' then
      add('//')
      add(prefix .. filename)
      if project ~= '' then
        add(prefix .. project)
      end
      add('//')
    elseif config.style == 'spdx' then
      add('// SPDX-License-Identifier: ' .. config.license)
      if config.copyright ~= '' then
        add('// SPDX-FileCopyrightText: ' .. config.copyright)
      end
      add('// File: ' .. filename .. (project ~= '' and ' (' .. project .. ')' or ''))
    else
      add('// ' .. filename .. (project ~= '' and ' — ' .. project or ''))
    end
    for _, item in ipairs(M.fields) do
      local text = config[item.key]
      if
        text ~= ''
        and not (config.style == 'spdx' and (item.key == 'license' or item.key == 'copyright'))
      then
        add(prefix .. item.label .. ': ' .. text)
      end
    end
    if config.style == 'xcode' then
      add('//')
    end
  end
  return table.concat(out, '\n') .. '\n\n'
end

-- Only recognize an initial, standalone comment; never consume adjacent code.
-- Returns a byte offset into the original text, including separator blank lines.
function M.preamble(text)
  return text:match('^(// swift%-tools%-version:[^\n]*\n)') or ''
end
function M.leading(text)
  local start = text:find('%S')
  if not start then
    return 0
  end
  local tail = text:sub(start)
  local ending
  if tail:sub(1, 2) == '//' then
    local pos = start
    while text:sub(pos):match('^[ \t]*//') do
      local newline = text:find('\n', pos, true)
      if not newline then
        -- A spliced line could make the following code part of the comment.
        if text:sub(pos):match('\\%s*$') then
          return 0
        end
        return #text
      end
      if text:sub(pos, newline - 1):match('\\%s*$') then
        return 0
      end
      ending, pos = newline, newline + 1
    end
  elseif tail:sub(1, 2) == '/*' then
    local close = text:find('*/', start + 2, true)
    if not close then
      return 0
    end
    local newline = text:find('\n', close + 2, true) or (#text + 1)
    if not text:sub(close + 2, newline - 1):match('^%s*$') then
      return 0
    end
    ending = math.min(newline, #text)
  end
  if not ending then
    return 0
  end
  local spaces = text:sub(ending + 1):match('^([ \t\r\n]*)') or ''
  -- Preserve indentation of the first code line.
  local blanks = spaces:match('^(.*\n)') or ''
  return ending + #blanks
end

function M.extract(text)
  local top = text:sub(1, M.leading(text))
  local out = {}
  local tags = {
    author = 'author',
    email = 'par Email:',
    organization = 'par Organization:',
    created = 'date',
    copyright = 'copyright',
    description = 'brief',
  }
  for line in top:gmatch('[^\n]+') do
    local body = line:gsub('^%s*//%s*', ''):gsub('^%s*%*%s*', '')
    for _, item in ipairs(M.fields) do
      local prefix = item.label .. ': '
      if body:sub(1, #prefix) == prefix then
        out[item.key] = body:sub(#prefix + 1)
      end
      local tag = tags[item.key] and '@' .. tags[item.key] .. ' '
      if tag and body:sub(1, #tag) == tag then
        out[item.key] = body:sub(#tag + 1)
      end
    end
    local notice = body:match('^SPDX%-FileCopyrightText: (.+)$')
    if notice then
      out.copyright = notice
    end
  end
  if top:find('^/%*%*') then
    out.style = 'doc'
  elseif top:find('^//\n//  ') then
    out.style = 'xcode'
  elseif top:find('^// SPDX%-License%-Identifier:') then
    out.style = 'spdx'
  end
  return out
end

return M
