-- Terminal presentation only; generated files and child-process output stay verbatim.
local M = {}
local palettes = {
  dark = {
    accent = '235;160;172',
    command = '137;180;250',
    success = '166;227;161',
    warning = '249;226;175',
    error = '243;139;168',
    muted = '166;173;200',
  },
  light = {
    accent = '145;27;43',
    command = '76;79;105',
    success = '31;92;27',
    warning = '112;70;0',
    error = '160;0;32',
    muted = '76;79;105',
  },
}
local enabled = {}
local function color_enabled(stream)
  if os.getenv('NO_COLOR') ~= nil or os.getenv('TERM') == 'dumb' then
    return false
  end
  local mode = os.getenv('RIVET_COLOR') or 'auto'
  if mode == 'never' then
    return false
  end
  if mode == 'always' then
    return true
  end
  if enabled[stream] == nil then
    local ok = os.execute('test -t ' .. (stream == 'stderr' and '2' or '1'))
    enabled[stream] = ok == true or ok == 0
  end
  return enabled[stream]
end
function M.paint(role, text, stream)
  if not color_enabled(stream or 'stdout') then
    return text
  end
  local palette = palettes[os.getenv('RIVET_THEME')] or palettes.dark
  local color = palette[role] or palette.accent
  return '\27[' .. (role == 'accent' and '1;' or '') .. '38;2;' .. color .. 'm' .. text .. '\27[0m'
end
function M.heading(text)
  print('\n' .. M.paint('accent', text))
end
function M.row(label, description)
  print(
    '  ' .. M.paint('command', label) .. string.rep(' ', math.max(2, 24 - #label)) .. description
  )
end
function M.message(role, label, text)
  print(M.paint(role, label) .. (text and ('  ' .. text) or ''))
end
function M.prompt(text)
  io.write(M.paint('accent', text))
  io.flush()
end
function M.error(message)
  -- Assertions include internal Lua locations; show the actionable message instead.
  message = tostring(message):gsub('^[^\n]-%.lua:%d+: ', '')
  io.stderr:write(M.paint('error', 'Error', 'stderr') .. '  ' .. message .. '\n')
end
return M
