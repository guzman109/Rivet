local rt = require('rivet.runtime')
local json = require('rivet.json')
local project = require('rivet.project')
local M = {}
local presets = require('rivet.presets')
local api = require('rivet.file_api')
local function user_presets(root)
  local raw = rt.read(rt.confined(root, 'CMakeUserPresets.json'))
  return raw and json.decode(raw) or { version = 6, configurePresets = json.array() }, raw
end
function M.presets(root, kind, configure)
  if
    not rt.read(rt.confined(root, 'CMakePresets.json'))
    and not rt.read(rt.confined(root, 'CMakeUserPresets.json'))
  then
    if kind and kind ~= 'configure' then
      return {}
    end
    return {
      { name = 'debug', label = 'Debug (Rivet build directory)' },
      { name = 'release', label = 'Release (Rivet build directory)' },
    }
  end
  local db = presets.load(root)
  if configure and kind ~= 'configure' then
    configure = presets.select(db, configure).association
  end
  return presets.list(db, kind or 'configure', configure)
end
function M.context(root, preset, options)
  root = project.canonical(root)
  if
    not rt.read(rt.confined(root, 'CMakePresets.json'))
    and not rt.read(rt.confined(root, 'CMakeUserPresets.json'))
  then
    preset = preset or 'debug'
    assert(preset == 'debug' or preset == 'release', 'Without presets, choose debug or release')
    return {
      name = preset,
      requested = preset,
      plain = true,
      binaryDir = rt.confined(root, 'build/rivet/' .. preset),
      db = { cmake = assert(rt.executable('cmake'), 'CMake is required'), root = root },
      environment = {},
      cache = {},
      configuration = preset == 'debug' and 'Debug' or 'Release',
    }
  end
  local db = presets.load(root)
  local selected = presets.select(db, preset)
  selected.db, selected.requested = db, preset or 'debug'
  options = options or {}
  if options.tasks then
    if options.task ~= 'configure' or options.build_preset and options.build_preset ~= '' then
      selected.build_preset =
        presets.associated(db, 'build', selected.association, options.build_preset)
    end
    if options.task == nil or options.task == 'test' then
      selected.test_preset =
        presets.associated(db, 'test', selected.association, options.test_preset)
    end
    if selected.build_preset then
      selected.configuration = presets.resolve(db, 'build', selected.build_preset).configuration
    end
    if selected.test_preset then
      local test_config = presets.resolve(db, 'test', selected.test_preset).configuration
      assert(
        not test_config or not selected.configuration or test_config == selected.configuration,
        'Build and test presets select different configurations'
      )
      selected.configuration = selected.configuration or test_config
    end
  end
  return selected
end
function M.tasks(root, preset, target_name, options)
  root = project.canonical(root)
  options = options or {}
  local selected = M.context(root, preset, {
    tasks = true,
    task = options.task,
    build_preset = options.build_preset,
    test_preset = options.test_preset,
  })
  local spec = project.inspect(root)
  rt.confined(root, '.cache/CPM')
  local cmake, binary = selected.db.cmake, selected.binaryDir
  local ctest = rt.executable(rt.join(rt.dirname(cmake), 'ctest'))
    or rt.executable('ctest')
    or 'ctest'
  local function configured(argv)
    return presets.environment_command(argv, selected.environment)
  end
  local result = {
    context = selected,
    configure = selected.plain and {
      cmake,
      '-S',
      root,
      '-B',
      binary,
      '-G',
      'Ninja',
      '-DCMAKE_BUILD_TYPE=' .. selected.configuration,
      '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON',
    } or { cmake, '--preset', selected.name },
    build = selected.build_preset and { cmake, '--build', '--preset', selected.build_preset }
      or { cmake, '--build', binary, '--parallel' },
    test = selected.test_preset and { ctest, '--preset', selected.test_preset }
      or { ctest, '--test-dir', binary, '--output-on-failure', '--no-tests=error' },
    format = { cmake, '--build', binary, '--target', 'format' },
  }
  if selected.configuration then
    if not selected.test_preset then
      result.test[#result.test + 1] = '-C'
      result.test[#result.test + 1] = selected.configuration
    end
    result.format[#result.format + 1] = '--config'
    result.format[#result.format + 1] = selected.configuration
    if not selected.build_preset then
      result.build[#result.build + 1] = '--config'
      result.build[#result.build + 1] = selected.configuration
    end
  end
  if
    (options.task == nil or options.task == 'build')
    and options.build_target
    and options.build_target ~= ''
  then
    result.build[#result.build + 1] = '--target'
    result.build[#result.build + 1] = options.build_target
  end
  if not selected.build_preset then
    result.build = configured(result.build)
  end
  if not selected.test_preset then
    result.test = configured(result.test)
  end
  result.format = configured(result.format)
  local targets = spec.targets or {}
  if spec.external then
    local ok, discovered = pcall(api.targets, binary, selected.configuration)
    if ok then
      targets = discovered
    end
    if target_name then
      targets = { { name = target_name, type = 'executable' } }
    end
  end
  for _, target in ipairs(targets) do
    if
      target.type == 'executable'
      and not target.test
      and (not target_name or target.name == target_name)
    then
      if options.task == 'run' then
        result.build[#result.build + 1] = '--target'
        result.build[#result.build + 1] = target.name
      end
      result.run = configured({ rt.join(binary, target.name) }) -- Legacy direct consumers; workflows resolve the File API after configure.
      result.executable = function()
        return api.executable(root, binary, target.name, selected.configuration)
      end
      result.run_command = function()
        return configured({ result.executable() })
      end
      break
    end
  end
  assert(not target_name or result.run, 'No runnable application target: ' .. tostring(target_name))
  result.prepare = function()
    api.query(binary)
  end
  result.after_configure = function()
    if
      spec.external
      and (options.task == 'run' or options.task == 'benchmark' or options.task == 'profile')
    then
      -- A first configure creates the File API reply. Do not keep the empty
      -- pre-configure target list for the remainder of this workflow.
      local runnable = {}
      for _, target in ipairs(api.targets(binary, selected.configuration)) do
        if target.type == 'executable' and not target.test then
          runnable[#runnable + 1] = target
        end
      end
      local chosen
      for _, target in ipairs(runnable) do
        if target.name == target_name then
          chosen = target
        end
      end
      if not target_name and #runnable == 1 then
        chosen = runnable[1]
      end
      if not chosen then
        local names = {}
        for _, target in ipairs(runnable) do
          names[#names + 1] = target.name
        end
        table.sort(names)
        error(
          target_name and ('No runnable application target: ' .. target_name)
            or (
              #names == 0 and 'No runnable application targets were found'
              or 'Choose an application with --target (or :RivetRunTarget): '
                .. table.concat(names, ', ')
            )
        )
      end
      if options.task == 'run' then
        local found
        for i = #result.build - 1, 1, -1 do
          if result.build[i] == '--target' then
            result.build[i + 1], found = chosen.name, true
            break
          end
        end
        if not found then
          result.build[#result.build + 1] = '--target'
          result.build[#result.build + 1] = chosen.name
        end
      end
      result.run = configured({ rt.join(binary, chosen.name) })
      result.executable = function()
        return api.executable(root, binary, chosen.name, selected.configuration)
      end
      result.run_command = function()
        return configured({ result.executable() })
      end
    end
    return M.sync_clangd(root, binary, selected.configuration)
  end
  return result
end
function M.compilation_database(raw, configuration)
  if not configuration then
    return raw
  end
  local selected = json.array()
  for _, entry in ipairs(json.decode(raw)) do
    local command = entry.command or table.concat(entry.arguments or {}, ' ')
    local config = command:gsub('\\"', '"'):match('%-DCMAKE_INTDIR="([^"]+)"')
      or command:match('%-DCMAKE_INTDIR=([^%s]+)')
    if not config or config == configuration then
      selected[#selected + 1] = entry
    end
  end
  assert(#selected > 0, 'No compilation commands for configuration ' .. configuration)
  return json.encode(selected)
end
local function clangd_database(config)
  local database
  for line in ((config or '') .. '\n'):gmatch('(.-)\r?\n') do
    local value = line:match('^%s*CompilationDatabase:%s*(.-)%s*$')
    if value then
      -- Conditional/multiple fragments remain custom configuration. Recognize
      -- ordinary YAML quoting and comments without rewriting the user's file.
      if database then
        return nil
      end
      local quoted, tail = value:match("^'([^']*)'(.*)$")
      if not quoted then
        quoted, tail = value:match('^"([^"]*)"(.*)$')
      end
      if quoted and (tail:match('^%s*$') or tail:match('^%s*#')) then
        database = quoted
      else
        database = (value:match('^(.-)%s+#') or value):gsub('%s+$', '')
      end
    end
  end
  return database
end
function M.sync_clangd(root, binary, configuration)
  local source = rt.confined(binary, 'compile_commands.json')
  local raw = rt.read(source)
  if not raw then
    return false,
      'No compilation database in '
        .. binary
        .. '; enable CMAKE_EXPORT_COMPILE_COMMANDS and use Ninja or Make'
  end
  raw = M.compilation_database(raw, configuration)
  local config_path = rt.confined(root, '.clangd')
  local config = rt.read(config_path)
  local initial = 'CompileFlags:\n  CompilationDatabase: build/debug\n'
  local managed = 'CompileFlags:\n  CompilationDatabase: .cache/rivet\n'
  local destination = rt.confined(root, '.cache/rivet')
  rt.mkdir(destination)
  local temporary = rt.confined(root, '.cache/rivet/compile_commands.json.tmp')
  local path = rt.confined(root, '.cache/rivet/compile_commands.json')
  rt.write(temporary, raw)
  assert(os.rename(temporary, path))
  rt.write(
    rt.confined(root, '.cache/rivet/selection.json'),
    json.encode({ binaryDir = binary, configuration = configuration })
  )
  if config == initial then
    if rawget(_G, 'vim') then
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == config_path and vim.bo[buf].modified then
          return false, 'Save .clangd before migrating its compilation database setting'
        end
      end
    end
    assert(rt.read(config_path) == initial, '.clangd changed during configuration')
    rt.write(config_path, managed)
  elseif clangd_database(config) ~= '.cache/rivet' then
    return false,
      'Custom .clangd left intact; point CompilationDatabase at .cache/rivet to follow the active preset'
  end
  return true
end
function M.cache(root, preset)
  local selected = M.context(root, preset)
  local raw = rt.read(rt.confined(selected.binaryDir, 'CMakeCache.txt'))
  if not raw then
    return {}
  end
  local entries, properties, help = {}, {}, {}
  for line in (raw .. '\n'):gmatch('(.-)\r?\n') do
    if line:sub(1, 2) == '//' then
      help[#help + 1] = line:sub(3)
    elseif line == '' or line:sub(1, 1) == '#' then
      help = {}
    else
      local name, kind, value = line:match('^([^:]+):([^=]+)=(.*)$')
      if name then
        if kind == 'INTERNAL' then
          properties[name] = value
        elseif kind ~= 'STATIC' then
          entries[#entries + 1] =
            { name = name, type = kind, value = value, help = table.concat(help, '\n') }
        end
      end
      help = {}
    end
  end
  for _, e in ipairs(entries) do
    e.advanced = properties[e.name .. '-ADVANCED'] == '1'
    local values = properties[e.name .. '-STRINGS']
    if values then
      e.choices = {}
      for value in values:gmatch('[^;]+') do
        e.choices[#e.choices + 1] = value
      end
    end
  end
  table.sort(entries, function(a, b)
    return a.name < b.name
  end)
  return entries
end
function M.set_cache(root, preset, entry, value)
  project.inspect(root)
  local context = M.context(root, preset)
  assert(
    not context.plain,
    'Create CMake presets before saving cache overrides; source lists remain owned by the project'
  )
  local configure = { context.db.cmake, '--preset', context.name }
  assert(
    type(entry) == 'table' and type(entry.name) == 'string' and entry.name:match('^[%w_]+$'),
    'Invalid CMake cache key'
  )
  local locked = {
    CMAKE_HOME_DIRECTORY = true,
    CMAKE_CACHEFILE_DIR = true,
    CMAKE_GENERATOR = true,
    CMAKE_MAKE_PROGRAM = true,
    CMAKE_CXX_COMPILER = true,
    CMAKE_CXX_COMPILER_AR = true,
    CMAKE_CXX_COMPILER_RANLIB = true,
    CMAKE_TOOLCHAIN_FILE = true,
  }
  assert(
    not locked[entry.name]
      and not entry.name:match('^CPM_')
      and not entry.name:match('^FETCHCONTENT_'),
    'Change toolchain/build/dependency locations in presets explicitly, then use a fresh build directory'
  )
  assert(
    ({ BOOL = true, STRING = true, PATH = true, FILEPATH = true, UNINITIALIZED = true })[entry.type],
    'Cache entry is not editable'
  )
  assert(type(value) == 'string' and not value:find('[%z\r\n]'), 'Invalid cache value')
  if entry.type == 'BOOL' then
    assert(
      ({ ON = true, OFF = true, TRUE = true, FALSE = true, ['1'] = true, ['0'] = true })[value:upper()],
      'BOOL must be ON or OFF'
    )
  end
  local local_name = context.name
  local presets, before = user_presets(root)
  presets.configurePresets = presets.configurePresets or json.array()
  local selected
  for _, p in ipairs(presets.configurePresets) do
    if p.name == local_name then
      selected = p
    end
  end
  if not selected then
    local_name = 'local-' .. context.name
    assert(
      not context.db.configure[local_name],
      'Local override name is already used: ' .. local_name
    )
    selected = {
      name = local_name,
      inherits = context.name,
      binaryDir = context.binaryDir,
      vendor = { ['rivet.nvim/overrides/1'] = { configurePreset = context.association } },
      environment = {},
      cacheVariables = {},
    }
    -- A local override must keep the original macro context, not reinterpret
    -- ${presetName}/${fileDir} as the new local wrapper.
    for key, raw in pairs(context.value.environment or {}) do
      selected.environment[key] = raw == json.null and json.null or context.environment[key]
    end
    for key, raw in pairs(context.value.cacheVariables or {}) do
      selected.cacheVariables[key] = raw == json.null and json.null
        or type(raw) == 'table' and { type = raw.type, value = context.cache[key] }
        or context.cache[key]
    end
    if context.toolchainFile then
      local path = context.toolchainFile
      if path:sub(1, 1) ~= '/' then
        path = rt.read(rt.join(context.binaryDir, path)) and rt.join(context.binaryDir, path)
          or rt.join(context.db.root, path)
      end
      selected.toolchainFile = path
    end
    -- Freeze the build location; ${presetName} must not move the cache being edited.
    presets.configurePresets[#presets.configurePresets + 1] = selected
  end
  selected.cacheVariables = selected.cacheVariables or {}
  selected.cacheVariables[entry.name] =
    { type = entry.type == 'UNINITIALIZED' and 'STRING' or entry.type, value = value }
  local destination = rt.confined(root, 'CMakeUserPresets.json')
  local lock = rt.confined(root, '.rivet-lock')
  assert(rt.run({ 'mkdir', lock }).code == 0, 'Another Rivet write is active')
  local tmp = rt.join(lock, 'presets.json')
  local ok, err = pcall(function()
    rt.chmod(lock, tonumber('700', 8))
    local mode = before and rt.mode(destination)
    rt.write(tmp, json.encode(presets))
    if mode then
      rt.chmod(tmp, mode)
    end
    assert(rt.read(destination) == before, 'Presets changed while editing; reopen the cache editor')
    assert(os.rename(tmp, destination))
  end)
  os.remove(tmp)
  rt.run({ 'rmdir', lock })
  assert(ok, err)
  configure[#configure] = local_name
  return configure
end
function M.targets(root, preset, options)
  local spec = project.inspect(root)
  if not spec.external then
    return spec.targets or {}
  end
  local selected = M.context(
    root,
    preset,
    { tasks = true, task = 'build', build_preset = options and options.build_preset }
  )
  return api.targets(selected.binaryDir, selected.configuration)
end
return M
