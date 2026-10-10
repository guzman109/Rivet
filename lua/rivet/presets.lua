-- CMake validates schemas, conditions and availability and executes the presets.
-- Resolve only metadata needed by the editor (paths, associations and environment).
local rt, json = require('rivet.runtime'), require('rivet.json')
local M = {}
local kinds = { configure = 'configurePresets', build = 'buildPresets', test = 'testPresets' }
local function clean_name(name)
  assert(type(name) == 'string' and name ~= '' and not name:find('[%z\r\n]'), 'Invalid preset name')
  return name
end
local function absolute(root, path)
  return rt.absolute(path:sub(1, 1) == '/' and path or rt.join(root, path))
end
local function expand(text, context, env, origin)
  if type(text) ~= 'string' then
    return text
  end
  return (
    text:gsub('%$([%w_]*){([^}]+)}', function(namespace, key)
      if namespace == 'penv' then
        return os.getenv(key) or ''
      end
      if namespace == 'env' then
        return env(key)
      end
      assert(namespace == '', 'Unsupported preset macro namespace: ' .. namespace)
      if key == 'fileDir' then
        return (origin and origin.version >= 12) and origin.dir or context.fileDir
      end
      assert(context[key] ~= nil, 'Unknown preset macro: ' .. key)
      return context[key]
    end)
  )
end
function M.load(root)
  root = rt.absolute(root)
  local db = {
    root = root,
    configure = {},
    build = {},
    test = {},
    available = { configure = {}, build = {}, test = {} },
  }
  db.host = rt.run({ 'uname', '-s' }).stdout:gsub('%s+$', '')
  local visited, active = {}, {}
  local function read(filename, optional)
    filename = absolute(root, filename)
    assert(not active[filename], 'Cycle in CMake preset includes: ' .. filename)
    if visited[filename] then
      return
    end
    local raw = rt.read(filename)
    if not raw and optional then
      return
    end
    assert(raw, 'Missing CMake preset file: ' .. filename)
    local data = json.decode(raw)
    assert(type(data.version) == 'number', 'Missing preset schema version')
    active[filename] = true
    local origin = { dir = rt.dirname(filename), version = data.version, file = filename }
    local context = {
      sourceDir = root,
      sourceParentDir = rt.dirname(root),
      sourceDirName = root:match('[^/]+$'),
      hostSystemName = db.host,
      fileDir = origin.dir,
      dollar = '$',
      pathListSep = ':',
    }
    for _, include in ipairs(data.include or {}) do
      local name = expand(include, context, function()
        error('$env is unavailable in preset includes')
      end, origin)
      read(absolute(origin.dir, name))
    end
    for kind, key in pairs(kinds) do
      for _, preset in ipairs(data[key] or {}) do
        clean_name(preset.name)
        assert(not db[kind][preset.name], 'Duplicate ' .. kind .. ' preset: ' .. preset.name)
        db[kind][preset.name] = { value = preset, origin = origin }
      end
    end
    active[filename], visited[filename] = nil, true
  end
  read(rt.join(root, 'CMakePresets.json'), true)
  read(rt.join(root, 'CMakeUserPresets.json'), true)
  db.cmake = assert(rt.executable('cmake'), 'CMake was not found')
  local result = rt.run({ 'env', 'LC_ALL=C', db.cmake, '--list-presets=all' }, { cwd = root })
  assert(result.code == 0, 'CMake could not read presets:\n' .. result.stderr .. result.stdout)
  local section
  for line in result.stdout:gmatch('[^\r\n]+') do
    local kind = line:match('^Available (%w+) presets:')
    if kind then
      section = kinds[kind] and kind or nil
    end
    if section then
      for name in pairs(db[section]) do
        if line:sub(1, #name + 4) == '  "' .. name .. '"' then
          db.available[section][name] = true
        end
      end
    end
  end
  return db
end
local function inherited(db, kind, name, active)
  local source = assert(db[kind][name], 'Unknown ' .. kind .. ' preset: ' .. name)
  active = active or {}
  assert(not active[name], 'Cycle in preset inheritance: ' .. name)
  active[name] = true
  local value, origins = {}, {}
  local parents = source.value.inherits or {}
  if type(parents) == 'string' then
    parents = { parents }
  end
  for _, parent in ipairs(parents) do
    local base, base_origins = inherited(db, kind, parent, active)
    for key, item in pairs(base) do
      if key == 'environment' or key == 'cacheVariables' then
        value[key], origins[key] = value[key] or {}, origins[key] or {}
        for k, v in pairs(item) do
          if value[key][k] == nil then
            value[key][k], origins[key][k] = v, base_origins[key][k]
          end
        end
      elseif
        value[key] == nil
        and not ({
          name = true,
          hidden = true,
          inherits = true,
          description = true,
          displayName = true,
        })[key]
      then
        value[key], origins[key] = item, base_origins[key]
      end
    end
  end
  for key, item in pairs(source.value) do
    if key == 'environment' or key == 'cacheVariables' then
      value[key], origins[key] = value[key] or {}, origins[key] or {}
      for k, v in pairs(item) do
        value[key][k], origins[key][k] = v, source.origin
      end
    else
      value[key], origins[key] = item, source.origin
    end
  end
  active[name] = nil
  return value, origins
end
function M.resolve(db, kind, name)
  clean_name(name)
  local value, origins = inherited(db, kind, name)
  local context = {
    sourceDir = db.root,
    sourceParentDir = rt.dirname(db.root),
    sourceDirName = db.root:match('[^/]+$'),
    presetName = name,
    hostSystemName = db.host,
    fileDir = db[kind][name].origin.dir,
    dollar = '$',
    pathListSep = ':',
  }
  context.generator = value.generator or ''
  local environment, resolving = {}, {}
  local function env(key)
    if environment[key] ~= nil then
      return environment[key] == false and '' or environment[key]
    end
    local raw = (value.environment or {})[key]
    if raw == nil then
      return os.getenv(key) or ''
    end
    if raw == json.null then
      -- null masks inherited preset values; CMake retains the process environment.
      return os.getenv(key) or ''
    end
    assert(not resolving[key], 'Cycle in preset environment: ' .. key)
    resolving[key] = true
    environment[key] = expand(raw, context, env, origins.environment[key])
    resolving[key] = nil
    return environment[key]
  end
  for key in pairs(value.environment or {}) do
    env(key)
  end
  local result = {
    name = name,
    value = value,
    environment = environment,
    cache = {},
    origin = db[kind][name].origin,
  }
  for key, raw in pairs(value.cacheVariables or {}) do
    if raw ~= json.null then
      if type(raw) == 'table' then
        raw = raw.value
      end
      result.cache[key] = expand(raw, context, env, origins.cacheVariables[key])
    end
  end
  for _, key in ipairs({ 'binaryDir', 'toolchainFile', 'configuration' }) do
    result[key] = expand(value[key], context, env, origins[key])
  end
  if kind == 'configure' then
    assert(
      result.binaryDir and result.binaryDir ~= '',
      'Preset ' .. name .. ' needs an explicit binaryDir (in-source builds are not supported)'
    )
    result.binaryDir = absolute(db.root, result.binaryDir)
    local relative = result.binaryDir:sub(#db.root + 2)
    assert(
      result.binaryDir:sub(1, #db.root + 1) == db.root .. '/'
        and relative ~= ''
        and relative ~= '.git'
        and not relative:match('^%.git/'),
      'Rivet build directories must be inside the project and outside .git: ' .. result.binaryDir
    )
    result.binaryDir = rt.confined(db.root, relative)
  end
  return result
end
function M.select(db, name)
  name = clean_name(name or 'debug')
  local local_name = 'local-' .. name
  -- Compatibility with compiler/cache presets generated by earlier Rivet versions.
  local local_value = db.configure[local_name] and db.configure[local_name].value or {}
  local override = (local_value.vendor or {})['rivet.nvim/overrides/1']
  if
    db.available.configure[local_name]
    and (name == 'debug' or name == 'release' or override and override.configurePreset == name)
  then
    name = local_name
  end
  assert(db.available.configure[name], 'Configure preset is unavailable on this host: ' .. name)
  local result = M.resolve(db, 'configure', name)
  local origin = (result.value.vendor or {})['rivet.nvim/overrides/1']
  result.association = origin and origin.configurePreset or name
  return result
end
function M.list(db, kind, configure)
  local result = {}
  for name in pairs(db.available[kind]) do
    local value = inherited(db, kind, name)
    if not configure or value.configurePreset == configure then
      result[#result + 1] = {
        name = name,
        label = value.displayName and (name .. ' — ' .. value.displayName) or name,
        configure = value.configurePreset,
      }
    end
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result
end
function M.associated(db, kind, configure, requested)
  local entries = M.list(db, kind, configure)
  if requested == false or requested == '' then
    return nil
  end
  for _, entry in ipairs(entries) do
    if entry.name == requested or not requested and entry.name == configure then
      return entry.name
    end
  end
  assert(
    not requested,
    kind
      .. ' preset is unavailable or belongs to a different configure preset: '
      .. tostring(requested)
  )
  if #entries == 1 then
    return entries[1].name
  end
  assert(
    #entries < 2,
    'Choose a '
      .. kind
      .. ' preset for '
      .. configure
      .. ' (:'
      .. (kind == 'build' and 'RivetBuildPreset' or 'RivetTestPreset')
      .. ' or --'
      .. kind
      .. '-preset NAME)'
  )
end
function M.environment_command(argv, environment)
  local result, keys = { 'env' }, {}
  for key in pairs(environment or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    if environment[key] == false then
      result[#result + 1] = '-u'
      result[#result + 1] = key
    end
  end
  for _, key in ipairs(keys) do
    if environment[key] ~= false then
      result[#result + 1] = key .. '=' .. environment[key]
    end
  end
  for _, arg in ipairs(argv) do
    result[#result + 1] = arg
  end
  return #keys == 0 and argv or result
end
function M.executable(name, environment, root)
  if name:find('/', 1, true) then
    return rt.executable(absolute(root, name))
  end
  local path = (environment or {}).PATH or os.getenv('PATH') or ''
  for directory in (path .. ':'):gmatch('(.-):') do
    local executable = rt.executable(rt.join(directory == '' and root or directory, name))
    if executable then
      return executable
    end
  end
  return false
end
return M
