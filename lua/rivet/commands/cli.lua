local M = {}
local source = debug.getinfo(1, 'S').source:sub(2)
local launcher = vim.fn.fnamemodify(source, ':p:h:h:h:h') .. '/bin/rivet'

---Link this plugin installation's CLI into a shell command directory.
---@param directory? string Defaults to ~/.local/bin; must be on the shell PATH.
---@return string
function M.install_cli(directory)
  local uv = vim.uv
  local target = assert(uv.fs_realpath(launcher), 'Cannot find Rivet CLI: ' .. launcher)
  local dir = vim.fn.fnamemodify(vim.fn.expand(directory or '~/.local/bin'), ':p'):gsub('/+$', '')
  local destination = dir .. '/rivet'
  local existing, stat_error, stat_code = uv.fs_lstat(destination)
  if existing then
    assert(
      existing.type == 'link' and uv.fs_realpath(destination) == target,
      'Refusing to replace existing path: ' .. destination
    )
  else
    assert(stat_code == 'ENOENT', stat_error)
    vim.fn.mkdir(dir, 'p')
    local ok, err = uv.fs_symlink(target, destination)
    assert(ok, err)
  end

  local message = 'Rivet CLI linked: ' .. destination .. '\nRun rivet --help in your terminal.'
  local on_path = false
  for entry in (vim.env.PATH or ''):gmatch('[^:]+') do
    if uv.fs_realpath(entry) == uv.fs_realpath(dir) then
      on_path = true
      break
    end
  end
  if not on_path then
    message = message .. '\nAdd this directory to your shell PATH: ' .. dir
  end
  if vim.fn.executable(vim.env.RIVET_LUA or 'lua') == 0 then
    message = message .. '\nThe CLI needs Lua 5.1+ or LuaJIT (set RIVET_LUA=luajit).'
  end
  require('rivet.ui').notify(message)
  return destination
end

return M
