-- Discover native C++ drivers and select one through machine-local presets.
local rt, json = require('rivet.runtime'), require('rivet.json')
local M = {}
local function realpath(path)
  local result = rt.run({ 'realpath', path })
  return result.code == 0 and result.stdout:gsub('%s+$', '') or path
end
local function entries(path)
  local result = rt.run({ 'ls', '-1', path })
  local names = {}
  if result.code == 0 then
    for name in result.stdout:gmatch('[^\r\n]+') do
      names[#names + 1] = name
    end
  end
  table.sort(names, function(a, b)
    local priority = { ['clang++'] = 1, ['g++'] = 2, ['c++'] = 3 }
    local ap, bp = priority[a] or 4, priority[b] or 4
    return ap < bp or ap == bp and a < b
  end)
  return names
end
function M.inspect(path)
  path = assert(rt.executable(path), 'Compiler is not executable: ' .. path)
  local reply = rt.run({ path, '--version' }, { timeout = 3000 })
  assert(reply.code == 0, 'Cannot identify compiler: ' .. path)
  local banner = reply.stdout:match('[^\r\n]+') or ''
  local family = banner:find('Apple clang', 1, true) and 'Apple Clang'
    or banner:lower():find('clang', 1, true) and 'Clang'
    or (
        banner:find('GCC', 1, true)
        or banner:find('g++', 1, true)
        or reply.stdout:find('Free Software Foundation', 1, true)
      )
      and 'GCC'
  assert(family, 'Expected a Clang or GCC C++ compiler: ' .. path)
  local version = banner:match('(%d+%.%d+[%d%.]*)') or 'unknown'
  return {
    path = path,
    realpath = realpath(path),
    family = family,
    version = version,
    banner = banner,
    id = path,
    label = family .. ' ' .. version .. ' · ' .. path,
    preview = banner
      .. '\n\n'
      .. path
      .. '\n\nLanguage and module support are checked when configuring/building.',
  }
end
function M.discover(options)
  options = options or {}
  local dirs, seen_dirs = {}, {}
  local function directory(path)
    if path and path ~= '' and not seen_dirs[path] then
      seen_dirs[path], dirs[#dirs + 1] = true, path
    end
  end
  for path in (options.path or os.getenv('PATH') or ''):gmatch('[^:]+') do
    directory(path)
  end
  if options.directories then
    for _, path in ipairs(options.directories) do
      directory(path)
    end
  else
    for _, prefix in ipairs({ '/opt/homebrew', '/usr/local', '/home/linuxbrew/.linuxbrew' }) do
      directory(prefix .. '/bin')
      for _, name in ipairs(entries(prefix .. '/opt')) do
        if name == 'llvm' or name:match('^llvm@%d+') or name == 'gcc' or name:match('^gcc@%d+') then
          directory(prefix .. '/opt/' .. name .. '/bin')
        end
      end
    end
    directory('/usr/bin')
    if rt.executable('xcrun') then
      local reply = rt.run({ 'xcrun', '--find', 'clang++' })
      if reply.code == 0 then
        directory(rt.dirname(reply.stdout:gsub('%s+$', '')))
      end
    end
  end
  local result, seen, apple = {}, {}, {}
  for _, dir in ipairs(dirs) do
    for _, name in ipairs(entries(dir)) do
      if
        name == 'c++'
        or name == 'clang++'
        or name == 'g++'
        or name:match('^clang%+%+%-%d[%d%.]*$')
        or name:match('^g%+%+%-%d[%d%.]*$')
      then
        local path = rt.join(dir, name)
        local canonical = realpath(path)
        if not seen[canonical] then
          seen[canonical] = true
          local ok, compiler = pcall(M.inspect, path)
          if ok and not (compiler.family == 'Apple Clang' and apple[compiler.banner]) then
            result[#result + 1] = compiler
            if compiler.family == 'Apple Clang' then
              apple[compiler.banner] = true
            end
          end
        end
      end
    end
  end
  table.sort(result, function(a, b)
    return a.label < b.label
  end)
  return result
end
local function key(compiler)
  local hash = 5381
  for byte in (compiler.realpath .. '\n' .. compiler.banner):gmatch('.') do
    hash = (hash * 33 + byte:byte()) % 4294967296
  end
  return compiler.family:lower():gsub(' ', '-')
    .. '-'
    .. compiler.version
    .. '-'
    .. string.format('%08x', hash)
end
function M.plan(root, path)
  local project, presets = require('rivet.project'), require('rivet.presets')
  root = project.canonical(root)
  local spec, manifest = project.load(root)
  assert(spec.language == 'cpp', 'Compiler selection currently supports Rivet C++ projects')
  local compiler = M.inspect(path)
  local db = presets.load(root)
  local filename = 'CMakeUserPresets.json'
  local before = rt.read(rt.confined(root, filename))
  ---@type table<string, any>
  local data = before and json.decode(before) or { version = 6 }
  local plan = {
    root = root,
    spec = spec,
    files = {},
    expected = {},
    notes = {
      'Selected ' .. compiler.label,
      'Existing build directories are retained. Configure/build to check language, library, and module support.',
    },
  }
  local function upsert(kind, name)
    data[kind] = data[kind] or json.array()
    for _, preset in ipairs(data[kind]) do
      if preset.name == name then
        return preset
      end
    end
    local preset = { name = name }
    data[kind][#data[kind] + 1] = preset
    return preset
  end
  for _, mode in ipairs({ 'debug', 'release' }) do
    local name = 'local-' .. mode
    local selected = presets.select(db, mode)
    assert(
      not selected.toolchainFile and not selected.cache.CMAKE_TOOLCHAIN_FILE,
      'This preset uses a toolchain file; select its compiler in that toolchain instead'
    )
    for _, kind in ipairs({ 'configure', 'build', 'test' }) do
      assert(
        not db[kind][name] or db[kind][name].origin.file == rt.join(root, filename),
        'Local preset is defined in another file: ' .. name
      )
    end
    local configure = upsert('configurePresets', name)
    configure.inherits = configure.inherits or mode
    configure.binaryDir = '${sourceDir}/build/compilers/' .. key(compiler) .. '/' .. mode
    configure.cacheVariables = configure.cacheVariables or {}
    configure.cacheVariables.CMAKE_CXX_COMPILER = compiler.path
    -- Override inherited SDK/compiler environments as well as the cache entry.
    configure.environment = configure.environment or {}
    configure.environment.CXX = compiler.path
    if configure.vendor then
      configure.vendor['rivet.nvim/overrides/1'] = nil
    end
    for kind, field in pairs({ build = 'buildPresets', test = 'testPresets' }) do
      local preset = upsert(field, name)
      if not preset.inherits and db[kind][mode] then
        preset.inherits = mode
      end
      preset.configurePreset = name
    end
  end
  plan.files[filename], plan.expected[filename] = json.encode(data), before or false
  -- Upgrade only the Just entry points, and only with known unchanged provenance.
  local changed = false
  for file, content in pairs(require('rivet.cpp_just').files(spec)) do
    local current = rt.read(rt.confined(root, file))
    local baseline = (spec.template_baselines or {})[file] or (spec.generated or {})[file]
    if current == nil or current == content or current == baseline then
      plan.files[file], plan.expected[file] = content, current or false
      spec.template_baselines = spec.template_baselines or {}
      spec.template_baselines[file] = content
      if spec.generated and spec.generated[file] then
        spec.generated[file] = content
      end
      local found = false
      for _, item in ipairs(spec.files or {}) do
        if item == file then
          found = true
        end
      end
      if not found then
        spec.files[#spec.files + 1] = file
      end
      changed = true
    else
      plan.notes[#plan.notes + 1] = 'Preserved custom '
        .. file
        .. '; update it to use local-debug/local-release build and test presets and their binaryDir.'
    end
  end
  if changed then
    plan.files['.rivet.json'], plan.expected['.rivet.json'] = json.encode(spec), manifest
  end
  return plan
end
return M
