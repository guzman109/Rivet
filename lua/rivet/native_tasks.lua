local rt, json = require('rivet.runtime'), require('rivet.json')
local python_tool =
  rt.absolute(debug.getinfo(1, 'S').source:sub(2):gsub('native_tasks%.lua$', 'python_tool.py'))
local M = {
  task_names = {
    'configure',
    'check',
    'build',
    'test',
    'run',
    'format',
    'lint',
    'package',
    'xcode',
  },
}
function M.names(root)
  local language = require('rivet.project').inspect(root).language
  local names = { 'configure', 'check', 'build', 'test', 'run', 'format', 'lint' }
  if language == 'python' or language == 'rust' then
    names[#names + 1] = 'package'
  end
  if language == 'swift' and rt.run({ 'uname', '-s' }).stdout:match('Darwin') then
    names[#names + 1] = 'xcode'
  end
  return names
end
local function command(name)
  return assert(
    rt.executable(name),
    'Install ' .. name .. ' or select it explicitly in .rivet.local.json'
  )
end
local function run_json(argv, root)
  local result = rt.run(argv, { cwd = root })
  assert(result.code == 0, result.stderr)
  return json.decode(result.stdout)
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
function M.python(root, options)
  if options and options.python then
    return command(options.python)
  end
  local local_python = rt.join(rt.confined(root, '.venv'), 'bin/python')
  if rt.executable(local_python) then
    return local_python
  end
  if os.getenv('VIRTUAL_ENV') then
    local active = rt.join(os.getenv('VIRTUAL_ENV'), 'bin/python')
    if rt.executable(active) then
      return active
    end
  end
  for _, name in ipairs({ 'python3.14', 'python3.13', 'python3.12', 'python3.11', 'python3' }) do
    if rt.executable(name) then
      return rt.executable(name)
    end
  end
  error('Python 3.11+ is required')
end
function M.targets(root)
  local spec = require('rivet.project').inspect(root)
  if spec.language == 'rust' then
    local metadata =
      run_json({ command('cargo'), 'metadata', '--format-version', '1', '--no-deps' }, root)
    local members = {}
    for _, id in ipairs(metadata.workspace_members) do
      members[id] = true
    end
    local result = {}
    for _, pkg in ipairs(metadata.packages) do
      if members[pkg.id] then
        for _, t in ipairs(pkg.targets) do
          if t.kind[1] == 'bin' then
            result[#result + 1] = {
              name = pkg.name .. '::' .. t.name,
              label = pkg.name .. ' / ' .. t.name,
              type = 'executable',
              package = pkg.name,
              package_id = pkg.id,
              bin = t.name,
            }
          end
        end
      end
    end
    return result
  elseif spec.language == 'swift' then
    local data = run_json(
      { command('swift'), 'package', '--package-path', root, 'describe', '--type', 'json' },
      root
    )
    local result = {}
    for _, p in ipairs(data.products or {}) do
      if p.type and p.type.executable then
        result[#result + 1] = { name = p.name, type = 'executable' }
      end
    end
    return result
  end
  local options = require('rivet.task_options').load(root)
  if spec.external then
    return options.python_module and { { name = options.python_module, type = 'executable' } } or {}
  end
  return spec.targets or {}
end
function M.tasks(root, preset, target, options)
  local spec = require('rivet.project').inspect(root)
  local local_options = require('rivet.task_options').load(root)
  preset = preset or 'debug'
  assert(preset == 'debug' or preset == 'release', 'Choose debug or release')
  local result = { sequences = {} }
  for _, name in ipairs(M.task_names) do
    result.sequences[name] = { name }
  end
  local lang = spec.language
  if lang == 'rust' then
    local cargo = command('cargo')
    local function args(name, diagnostics)
      local a = { cargo, name, '--manifest-path', rt.join(root, 'Cargo.toml') }
      if name ~= 'metadata' and name ~= 'fmt' then
        if name ~= 'run' then
          a[#a + 1] = '--workspace'
        end
        if preset == 'release' then
          a[#a + 1] = '--release'
        end
        if local_options.jobs then
          a[#a + 1] = '--jobs'
          a[#a + 1] = tostring(local_options.jobs)
        end
        if diagnostics then
          a[#a + 1] = '--message-format=json'
        end
      end
      return a
    end
    result.configure = {
      cargo,
      'metadata',
      '--manifest-path',
      rt.join(root, 'Cargo.toml'),
      '--format-version',
      '1',
      '--no-deps',
    }
    for _, name in ipairs({ 'build', 'check', 'test' }) do
      result[name] = args(name, true)
    end
    result.format = args('fmt')
    result.format[#result.format + 1] = '--all'
    result.lint = args('clippy', true)
    result.lint[#result.lint + 1] = '--'
    result.lint[#result.lint + 1] = '-D'
    result.lint[#result.lint + 1] = 'warnings'
    result.package = {
      cargo,
      'package',
      '--manifest-path',
      rt.join(root, 'Cargo.toml'),
      '--workspace',
      '--no-verify',
    }
    local candidates = M.targets(root)
    local chosen
    if target then
      for _, entry in ipairs(candidates) do
        if entry.name == target then
          chosen = entry
          break
        end
      end
      if not chosen then
        local matches, names = {}, {}
        for _, entry in ipairs(candidates) do
          if entry.bin == target then
            matches[#matches + 1] = entry
            names[#names + 1] = entry.name
          end
        end
        table.sort(names)
        assert(
          #matches <= 1,
          'Ambiguous Cargo binary: '
            .. target
            .. '; choose a package::binary target: '
            .. table.concat(names, ', ')
        )
        chosen = matches[1]
      end
    end
    if not target and #candidates == 1 then
      chosen = candidates[1]
    end
    if target then
      assert(chosen, 'Unknown Cargo binary: ' .. target)
    end
    if chosen then
      local artifact
      result.after_step = function(step, process)
        if step == 'build' then
          for line in process.stdout:gmatch('[^\n]+') do
            local ok, item = pcall(json.decode, line)
            if
              ok
              and item.reason == 'compiler-artifact'
              and item.package_id == chosen.package_id
              and item.target.name == chosen.bin
              and item.executable
              and item.executable ~= json.null
            then
              artifact = item.executable
            end
          end
        end
      end
      result.executable = function()
        return assert(artifact, 'Build the selected Cargo binary before profiling')
      end
      result.run = args('run', true)
      for _, arg in ipairs({ '--package', chosen.package, '--bin', chosen.bin, '--' }) do
        result.run[#result.run + 1] = arg
      end
    end
  elseif lang == 'swift' then
    local swift = command('swift')
    local configuration = preset == 'debug' and 'debug' or 'release'
    local function args(name)
      local a = { swift, name, '--package-path', root, '--configuration', configuration }
      if local_options.jobs then
        a[#a + 1] = '--jobs'
        a[#a + 1] = tostring(local_options.jobs)
      end
      return a
    end
    result.configure = { swift, 'package', '--package-path', root, 'describe' }
    result.build = args('build')
    result.check = result.build
    result.test = args('test')
    result.format = {
      swift,
      'format',
      'format',
      '--in-place',
      '--recursive',
      rt.join(root, 'Sources'),
      rt.join(root, 'Tests'),
    }
    result.lint = {
      swift,
      'format',
      'lint',
      '--strict',
      '--recursive',
      rt.join(root, 'Sources'),
      rt.join(root, 'Tests'),
    }
    if rt.run({ 'uname', '-s' }).stdout:match('Darwin') then
      result.xcode = { 'open', '-a', 'Xcode', rt.join(root, 'Package.swift') }
    end
    for _, name in ipairs({ 'format', 'lint' }) do
      local argv = result[name]
      for i = #argv, 1, -1 do
        if
          (argv[i] == rt.join(root, 'Tests') or argv[i] == rt.join(root, 'Sources'))
          and not rt.is_dir(argv[i])
        then
          table.remove(argv, i)
        end
      end
    end
    local candidates = M.targets(root)
    local chosen
    for _, t in ipairs(candidates) do
      if t.name == target then
        chosen = t
      end
    end
    if not target and #candidates == 1 then
      chosen = candidates[1]
    end
    if target then
      assert(chosen, 'Unknown Swift product: ' .. target)
    end
    if chosen then
      result.executable = function()
        local argv = args('build')
        argv[#argv + 1] = '--show-bin-path'
        local reply = rt.run(argv, { cwd = root })
        assert(reply.code == 0, reply.stderr)
        return rt.join(reply.stdout:gsub('%s+$', ''), chosen.name)
      end
      result.run =
        { swift, 'run', '--package-path', root, '--configuration', configuration, chosen.name }
    end
  elseif lang == 'python' then
    local python = M.python(root, local_options)
    local uv = spec.manager == 'uv'
      or spec.external and rt.read(rt.confined(root, 'uv.lock')) ~= nil
    local function py(...)
      local a = uv and { command('uv'), 'run', '--project', root, '--no-sync', 'python' }
        or { python }
      for _, arg in ipairs({ ... }) do
        a[#a + 1] = arg
      end
      if not spec.external then
        a = require('rivet.presets').environment_command(a, {
          PYTHONPATH = rt.join(root, 'src')
            .. (os.getenv('PYTHONPATH') and ':' .. os.getenv('PYTHONPATH') or ''),
        })
      end
      return a
    end
    local function tool(module, ...)
      return py(
        '-E',
        '-P',
        python_tool,
        module,
        root,
        not spec.external and rt.join(root, 'src') or '',
        ...
      )
    end
    if uv then
      result.configure =
        { command('uv'), 'sync', '--project', root, '--inexact', '--no-python-downloads' }
      if local_options.python then
        result.configure[#result.configure + 1] = '--python'
        result.configure[#result.configure + 1] = python
      end
    elseif
      rt.is_dir(rt.confined(root, '.venv'))
      or os.getenv('VIRTUAL_ENV')
      or local_options.python
    then
      result.configure = { python, '--version' }
    else
      result.configure = { python, '-m', 'venv', rt.confined(root, '.venv') }
    end
    result.build =
      tool('compileall', '-q', rt.join(root, rt.is_dir(rt.join(root, 'src')) and 'src' or '.'))
    result.check = result.build
    result.test = local_options.test_runner == 'pytest' and tool('pytest', root)
      or tool('unittest', 'discover', '-s', rt.join(root, 'tests'), '-v')
    result.format = tool('ruff', 'format', root)
    result.lint = tool('ruff', 'check', root)
    result.package = uv and { command('uv'), 'build', '--project', root } or tool('build', root)
    local module = local_options.python_module
      or (not spec.external and spec.kind == 'app' and spec.name)
    if module then
      result.run = py('-m', module)
    end
  end
  if options and options.task then
    assert(
      result[options.task] or local_options[options.task],
      'Task '
        .. options.task
        .. ' is unavailable for '
        .. lang
        .. '; select a runnable product or install/configure its native tool'
    )
  end
  return result
end
return M
