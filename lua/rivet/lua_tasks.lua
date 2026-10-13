local rt = require('rivet.runtime')
local M = { task_names = { 'configure', 'check', 'build', 'test', 'run', 'format', 'lint' } }
local check_script =
  rt.absolute(debug.getinfo(1, 'S').source:sub(2):gsub('lua_tasks%.lua$', 'lua_check.lua'))

function M.runtime(spec, options)
  options = options or {}
  local kind = spec.runtime or (spec.kind == 'plugin' and 'neovim' or 'lua')
  local name = options.lua or (kind == 'neovim' and 'nvim' or kind)
  return assert(
    rt.executable(name),
    'Lua runtime is unavailable: '
      .. name
      .. '. Install it explicitly or set lua in .rivet.local.json for the selected '
      .. kind
      .. ' runtime.'
  ),
    kind
end

function M.script_command(executable, runtime, script, args)
  local argv = runtime == 'neovim'
      and { executable, '--headless', '-u', 'NONE', '-i', 'NONE', '-l', script }
    or { executable, script }
  for _, value in ipairs(args or {}) do
    argv[#argv + 1] = value
  end
  return argv
end

function M.check_command(executable, runtime, files)
  local argv = M.script_command(executable, runtime, check_script, files)
  if runtime == 'neovim' then
    return argv
  end
  -- Lua's startup environment can execute a file before the check helper runs.
  local clean = { 'env', '-u', 'LUA_INIT' }
  for minor = 1, 9 do
    clean[#clean + 1] = '-u'
    clean[#clean + 1] = 'LUA_INIT_5_' .. minor
  end
  for _, value in ipairs(argv) do
    clean[#clean + 1] = value
  end
  return clean
end

function M.presets(_, kind)
  if kind and kind ~= 'configure' then
    return {}
  end
  return {
    { name = 'debug', label = 'Debug / development' },
    { name = 'release', label = 'Release' },
  }
end

function M.targets(root)
  local spec = require('rivet.project').inspect(root)
  if not spec.external then
    return spec.targets or {}
  end
  if rt.read(rt.confined(root, 'main.lua')) then
    return {
      { name = spec.name, type = 'executable', entrypoint = 'main.lua', sources = { 'main.lua' } },
    }
  end
  return {}
end

function M.names(root)
  local names = { 'configure', 'check', 'build', 'test', 'format', 'lint' }
  for _, target in ipairs(M.targets(root)) do
    if target.type == 'executable' and not target.test then
      names[#names + 1] = 'run'
      break
    end
  end
  return names
end

local function source_files(root, spec)
  local result = {}
  if not spec.external then
    for _, path in ipairs(spec.files or {}) do
      if path:match('%.lua$') then
        result[#result + 1] = rt.confined(root, path)
      end
    end
  else
    -- External source discovery is read-only and never follows directory symlinks.
    local scan = rt.run({
      'find',
      root,
      '-type',
      'd',
      '(',
      '-name',
      '.git',
      '-o',
      '-name',
      '.cache',
      '-o',
      '-name',
      'node_modules',
      '-o',
      '-name',
      '.venv',
      ')',
      '-prune',
      '-o',
      '-type',
      'f',
      '-name',
      '*.lua',
      '-print',
    })
    assert(scan.code == 0, 'Could not discover Lua files: ' .. scan.stderr)
    for path in scan.stdout:gmatch('[^\r\n]+') do
      result[#result + 1] = rt.confined(root, path:sub(#root + 2))
    end
  end
  table.sort(result)
  assert(#result > 0, 'No Lua source files were found in this project')
  return result
end

function M.tasks(root, preset, target, options)
  options = options or {}
  local spec = require('rivet.project').inspect(root)
  local settings = require('rivet.task_options').load(root)
  assert(preset == nil or preset == 'debug' or preset == 'release', 'Choose debug or release')
  local executable, runtime = M.runtime(spec, settings)
  local files = source_files(root, spec)
  local result = { sequences = {}, commands = {} }
  for _, name in ipairs(M.task_names) do
    result.sequences[name] = { name }
  end
  result.configure = { executable, runtime == 'neovim' and '--version' or '-v' }
  result.check = M.check_command(executable, runtime, files)
  result.build = result.check
  result.test = { executable }
  result.commands.test = function()
    local path = rt.confined(root, spec.test_script or 'tests/test.lua')
    assert(
      rt.read(path),
      'No Lua test script was found; add tests/test.lua or set test_script in the project manifest'
    )
    return M.script_command(executable, runtime, path)
  end
  result.format = { 'stylua' }
  result.commands.format = function()
    local argv = {
      assert(
        rt.executable('stylua'),
        'StyLua is optional; install stylua explicitly to use Format'
      ),
    }
    for _, path in ipairs(files) do
      argv[#argv + 1] = path
    end
    return argv
  end
  result.lint = { 'luacheck' }
  result.commands.lint = function()
    local argv = {
      assert(
        rt.executable('luacheck'),
        'Luacheck is optional; install luacheck explicitly to use Lint'
      ),
    }
    for _, path in ipairs(files) do
      argv[#argv + 1] = path
    end
    return argv
  end
  local applications = {}
  for _, entry in ipairs(M.targets(root)) do
    if entry.type == 'executable' and not entry.test then
      applications[#applications + 1] = entry
    end
  end
  if #applications > 0 then
    result.run = { executable }
    result.run_command = function()
      local selected
      for _, entry in ipairs(applications) do
        if entry.name == target then
          selected = entry
        end
      end
      if not target and #applications == 1 then
        selected = applications[1]
      end
      assert(
        selected,
        target and ('Unknown Lua application: ' .. target)
          or 'Choose a Lua application with RivetRunTarget or --target'
      )
      local path =
        rt.confined(root, assert(selected.entrypoint, 'The selected target has no Lua entrypoint'))
      assert(rt.read(path), 'Lua entrypoint is missing: ' .. path)
      return M.script_command(executable, runtime, path)
    end
  elseif options.task == 'run' then
    error('This Lua project has no runnable script; add an application target')
  end
  return result
end

return M
