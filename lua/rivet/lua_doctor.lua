local rt = require('rivet.runtime')
local M = {}

function M.inspect(root)
  local spec = require('rivet.project').inspect(root)
  local settings = require('rivet.task_options').load(root)
  local ok, executable, runtime = pcall(require('rivet.lua_tasks').runtime, spec, settings)
  if not ok then
    return { { level = 'error', message = tostring(executable) } }
  end
  local version = rt.run(
    { executable, runtime == 'neovim' and '--version' or '-v' },
    { cwd = root }
  )
  local report = {
    {
      level = version.code == 0 and 'ok' or 'error',
      message = executable
        .. ' · '
        .. (
          (version.stdout .. version.stderr):match('[^\r\n]+') or 'No runtime version was reported'
        ),
    },
  }
  for _, name in ipairs({ 'stylua', 'luacheck' }) do
    local command = rt.executable(name)
    report[#report + 1] = {
      level = command and 'ok' or 'warn',
      message = command and (name .. ' available: ' .. command)
        or (name .. ' is optional; install it explicitly to use its task'),
    }
  end
  report[#report + 1] = {
    level = 'info',
    message = 'Lua checks compile source without executing it; Test and Run execute project code in the selected runtime. No packages are installed by Doctor.',
  }
  return report
end

return M
