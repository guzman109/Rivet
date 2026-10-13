local rt = require('rivet.runtime')
local M = {}
function M.inspect(root, preset, options)
  local spec = require('rivet.project').inspect(root)
  if spec.language == 'c' then
    local selected = require('rivet.cmake').context(root, preset)
    local report =
      { { level = 'info', message = 'C' .. (spec.standard or '') .. ' · ' .. selected.binaryDir } }
    local reply, err = require('rivet.file_api').read(selected.binaryDir)
    if not reply then
      report[#report + 1] = { level = 'warn', message = err }
      return report
    end
    for _, toolchain in ipairs((reply.toolchains or {}).toolchains or {}) do
      report[#report + 1] = {
        level = 'ok',
        message = toolchain.language .. ' compiler: ' .. (toolchain.compiler.path or 'unknown'),
      }
    end
    return report
  end
  local settings = require('rivet.task_options').load(root)
  local uv_project = spec.language == 'python'
    and (spec.manager == 'uv' or spec.external and rt.read(rt.confined(root, 'uv.lock')) ~= nil)
  local tool
  if spec.language == 'python' then
    tool = uv_project and rt.executable(rt.join(root, '.venv/bin/python'))
      or require('rivet.native_tasks').python(root, settings)
  else
    tool = rt.executable(spec.language == 'rust' and 'cargo' or 'swift')
  end
  if not tool then
    return {
      {
        level = 'error',
        message = 'Install the ' .. spec.language .. ' toolchain and add it to PATH',
      },
    }
  end
  local r = rt.run({ tool, '--version' }, { cwd = root })
  local result = {
    {
      level = r.code == 0 and 'ok' or 'error',
      message = tool .. ' · ' .. (r.stdout .. r.stderr):gsub('%s+$', ''),
    },
  }
  if spec.language == 'python' then
    if uv_project then
      local uv = rt.executable('uv')
      result[#result + 1] = {
        level = uv and 'ok' or 'error',
        message = uv and 'uv manages the project environment and packaging'
          or 'Install uv to run this project configuration',
      }
      if not rt.executable(rt.join(root, '.venv/bin/python')) then
        result[#result + 1] = {
          level = 'warn',
          message = 'uv project environment is not configured; select Configure to sync it explicitly',
        }
      end
    end
    local probe = rt.run({
      tool,
      '-E',
      '-P',
      '-c',
      'import sys; print(sys.executable); print(sys.prefix); raise SystemExit(sys.version_info < (3,11))',
    }, { cwd = root })
    result[#result + 1] = {
      level = probe.code == 0 and 'ok' or 'error',
      message = 'Python 3.11+ required; interpreter / environment:\n' .. probe.stdout,
    }
    local modules = { 'ruff' }
    if not uv_project then
      modules[#modules + 1] = 'build'
    end
    if settings.test_runner == 'pytest' then
      modules[#modules + 1] = 'pytest'
    end
    for _, module in ipairs(modules) do
      local found = rt.run({
        tool,
        '-E',
        '-P',
        '-c',
        'import importlib.util; raise SystemExit(importlib.util.find_spec("'
          .. module
          .. '") is None)',
      }, { cwd = root })
      result[#result + 1] = {
        level = found.code == 0 and 'ok' or 'warn',
        message = module
          .. (
            found.code == 0 and ' available'
            or ' missing in this interpreter; install explicitly to use its task'
          ),
      }
    end
  else
    local probes = spec.language == 'rust' and { { 'fmt', 'rustfmt' }, { 'clippy', 'Clippy' } }
      or { { 'format', 'swift format' } }
    for _, check in ipairs(probes) do
      local probe = rt.run({ tool, check[1], '--version' }, { cwd = root })
      result[#result + 1] = {
        level = probe.code == 0 and 'ok' or 'warn',
        message = check[2]
          .. (
            probe.code == 0 and ' available'
            or ' unavailable; install it explicitly to use its task'
          ),
      }
    end
    local ok, targets = pcall(require('rivet.native_tasks').targets, root)
    result[#result + 1] = {
      level = ok and 'ok' or 'error',
      message = ok and (#targets .. ' runnable products discovered through native metadata')
        or tostring(targets),
    }
  end
  result[#result + 1] = {
    level = 'info',
    message = 'Doctor does not install dependencies or build. Use check/test to verify this project.',
  }
  return result
end
return M
