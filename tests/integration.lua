-- Offline filesystem/CLI/CMake integration tests. Retains its temp directory.
local script = debug.getinfo(1, 'S').source:sub(2)
local root = script:match('^(.*)/tests/integration%.lua$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
local rt = require('rivet.runtime')
local project = require('rivet.project')
local cmake = require('rivet.cmake')
local json = require('rivet.json')
root = rt.absolute(root)
local passed, failed, skipped = 0, 0, 0
io.stdout:setvbuf('line')
local function check(condition, message)
  assert(condition, message or 'assertion failed')
end
local function rejects(fn, message)
  check(not pcall(fn), message or 'expected rejection')
end
local function run(argv, cwd)
  local result = rt.run(argv, { cwd = cwd })
  check(result.code == 0, table.concat(argv, ' ') .. '\n' .. result.stdout .. result.stderr)
  return result.stdout
end
local temporary = run({
  'mktemp',
  '-d',
  rt.join(os.getenv('TMPDIR') or '/tmp', 'rivet-tests.XXXXXX'),
}):gsub('%s+$', '')
temporary = project.canonical(temporary)
local tools = rt.detect_tools()
check(
  tools.clangxx and tools.cmake and tools.ninja,
  'integration tests require clang++, CMake, and Ninja'
)
local function test(name, fn)
  local filter = os.getenv('RIVET_TEST_FILTER')
  if filter and not name:find(filter, 1, true) then
    skipped = skipped + 1
    return
  end
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    io.write('ok - ' .. name .. '\n')
  else
    failed = failed + 1
    io.stderr:write('FAIL - ' .. name .. ': ' .. tostring(err) .. '\n')
  end
end
local function create(name, options)
  options = options or {}
  options.name = options.name or 'engine'
  options.compiler = tools.clangxx
  local directory = rt.join(temporary, name)
  local plan = project.plan(options, directory)
  project.apply(directory, plan)
  return directory, plan
end
local function destination(spec)
  for _, item in ipairs(spec.targets) do
    if item.type == 'static' then
      return item.name
    end
  end
  return spec.targets[1].name
end
local function build(directory, preset, should_run)
  local tasks = cmake.tasks(directory, preset)
  run(tasks.configure, directory)
  run(tasks.build, directory)
  run(tasks.test, directory)
  if should_run and tasks.run then
    local output = run(tasks.run, directory)
    check(not output:find('\\n', 1, true), 'executable printed a literal backslash-n')
  end
  check(
    rt.read(rt.join(directory, 'build/' .. preset .. '/compile_commands.json')),
    'missing compile database'
  )
end

test('supported standards build and test with headers and both module arrangements', function()
  for _, standard in ipairs({ 17, 20, 23, 26 }) do
    local directory = create('standard-' .. standard, { standard = standard, modules = false })
    build(directory, 'debug', true)
    if standard >= 20 then
      for _, layout in ipairs({ 'single', 'split' }) do
        local modules = create(
          'standard-' .. standard .. '-' .. layout,
          { standard = standard, module_layout = layout }
        )
        build(modules, 'debug', true)
      end
    end
  end
end)

test('custom presets use native includes conditions environment and File API artifacts', function()
  local directory = create('custom-presets', { standard = 20, modules = false })
  local canonical = project.canonical(directory)
  rt.mkdir(rt.join(directory, 'presets'))
  rt.write(
    rt.join(directory, 'presets/base.json'),
    json.encode({
      version = 12,
      configurePresets = {
        {
          name = 'base',
          hidden = true,
          generator = 'Ninja',
          binaryDir = '${sourceDir}/output/$env{BUILD_FOLDER}',
          environment = { BUILD_FOLDER = '${presetName}', RIVET_TEST_VALUE = 'from-configure' },
          cacheVariables = {
            CMAKE_CXX_COMPILER = tools.clangxx,
            CMAKE_EXPORT_COMPILE_COMMANDS = true,
            BUILD_TESTING = true,
            CMAKE_BUILD_TYPE = 'Debug',
            ORIGIN_DIRECTORY = '${fileDir}',
          },
        },
      },
    })
  )
  rt.write(
    rt.join(directory, 'CMakePresets.json'),
    json.encode({
      version = 12,
      include = { 'presets/base.json' },
      configurePresets = {
        { name = 'cpu dev', inherits = 'base' },
        { name = 'unavailable', inherits = 'base', condition = false },
      },
      buildPresets = { { name = 'compile', configurePreset = 'cpu dev', jobs = 2 } },
      testPresets = {
        { name = 'checks', configurePreset = 'cpu dev', output = { outputOnFailure = true } },
      },
    })
  )
  -- Old generated user presets inherit debug/release, which this fixture replaces.
  os.remove(rt.join(directory, 'CMakeUserPresets.json'))
  local presets = require('rivet.presets')
  local db = presets.load(directory)
  local entries = presets.list(db, 'configure')
  check(
    #entries == 1 and entries[1].name == 'cpu dev',
    'CMake availability/conditions were ignored'
  )
  local resolved = presets.resolve(db, 'configure', 'cpu dev')
  check(
    resolved.binaryDir == rt.join(directory, 'output/cpu dev'),
    'environment macro did not determine build directory'
  )
  check(
    resolved.cache.ORIGIN_DIRECTORY == rt.join(directory, 'presets'),
    'v12 fileDir used the inheriting file'
  )
  local root_file = rt.join(directory, 'CMakeLists.txt')
  rt.write(
    root_file,
    rt.read(root_file)
      .. '\nif(NOT "$ENV{RIVET_TEST_VALUE}" STREQUAL "from-configure")\n message(FATAL_ERROR "configure environment lost")\nendif()\nset_target_properties(engine PROPERTIES OUTPUT_NAME viewer RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")\n'
  )
  local tasks = cmake.tasks(directory, 'cpu dev', 'engine')
  check(tasks.context.build_preset == 'compile' and tasks.context.test_preset == 'checks')
  tasks.prepare()
  run(tasks.configure, directory)
  check(tasks.after_configure())
  run(tasks.build, directory)
  run(tasks.test, directory)
  check(
    run(tasks.run_command(), directory):find('Worker 0', 1, true),
    'File API did not resolve renamed executable'
  )
  local active = json.decode(rt.read(rt.join(directory, '.cache/rivet/selection.json')))
  check(active.binaryDir == canonical .. '/output/cpu dev')
  local report = require('rivet.doctor').inspect(canonical, 'cpu dev')
  for _, entry in ipairs(report) do
    check(entry.level ~= 'error', entry.message)
  end
  local raw = 'CompileFlags:\n  CompilationDatabase: custom/database\n# user configuration\n'
  rt.write(rt.join(directory, '.clangd'), raw)
  check(not tasks.after_configure(), 'custom clangd configuration was overwritten')
  check(rt.read(rt.join(directory, '.clangd')) == raw)
end)

test('standard-library modules build in C++23 with a single-file interface', function()
  local directory =
    create('std-23-single', { standard = 23, std_modules = true, module_layout = 'single' })
  build(directory, 'debug', true)
end)

test('custom cache overrides retain macro paths and native task associations', function()
  local directory = create('custom-cache', { standard = 17 })
  os.remove(rt.join(directory, 'CMakeUserPresets.json'))
  rt.write(
    rt.join(directory, 'CMakePresets.json'),
    json.encode({
      version = 6,
      configurePresets = {
        {
          name = 'hpc',
          generator = 'Ninja',
          binaryDir = '${sourceDir}/build/${presetName}',
          environment = { BUILD_LABEL = '${presetName}' },
          cacheVariables = {
            CMAKE_CXX_COMPILER = tools.clangxx,
            CMAKE_BUILD_TYPE = 'Debug',
            CMAKE_EXPORT_COMPILE_COMMANDS = true,
          },
        },
      },
      buildPresets = { { name = 'hpc-build', configurePreset = 'hpc' } },
      testPresets = { { name = 'hpc-test', configurePreset = 'hpc' } },
    })
  )
  local tasks = cmake.tasks(directory, 'hpc')
  tasks.prepare()
  run(tasks.configure, directory)
  local chosen
  for _, entry in ipairs(cmake.cache(directory, 'hpc')) do
    if entry.name == 'RIVET_WARNINGS' then
      chosen = entry
    end
  end
  run(cmake.set_cache(directory, 'hpc', chosen, 'OFF'), directory)
  local next_tasks = cmake.tasks(directory, 'hpc')
  check(next_tasks.context.name == 'local-hpc')
  check(
    next_tasks.context.binaryDir == project.canonical(directory) .. '/build/hpc',
    'cache edit changed the build directory'
  )
  check(
    next_tasks.context.environment.BUILD_LABEL == 'hpc',
    'cache override reinterpreted presetName'
  )
  check(
    next_tasks.context.build_preset == 'hpc-build' and next_tasks.context.test_preset == 'hpc-test'
  )
  run(next_tasks.build, directory)
  run(next_tasks.test, directory)
  local raw = rt.read(rt.join(directory, 'build/hpc/CMakeCache.txt'))
  check(raw:find('RIVET_WARNINGS:BOOL=OFF', 1, true))
end)

test('Doctor identifies the configured compiler and reports changed preset intent', function()
  local directory = create('doctor-project', { standard = 17 })
  local tasks = cmake.tasks(directory, 'debug')
  tasks.prepare()
  run(tasks.configure, directory)
  check(tasks.after_configure())
  local report = require('rivet.doctor').inspect(project.canonical(directory), 'debug')
  local selected, database = false, false
  for _, entry in ipairs(report) do
    check(entry.level ~= 'error', entry.message)
    selected = selected or entry.message:find('Configured compiler:', 1, true)
    database = database
      or entry.message == 'clangd compilation database follows the selected preset'
  end
  check(selected and database)
  local local_path = rt.join(directory, 'CMakeUserPresets.json')
  local data = json.decode(rt.read(local_path))
  data.configurePresets[1].cacheVariables.CMAKE_CXX_COMPILER = assert(rt.executable('false'))
  rt.write(local_path, json.encode(data))
  local mismatch = false
  for _, entry in ipairs(require('rivet.doctor').inspect(project.canonical(directory), 'debug')) do
    mismatch = mismatch
      or entry.level == 'error' and entry.message:find('but the cache uses', 1, true)
  end
  check(mismatch, 'Doctor guessed the compiler from PATH or missed the changed preset')
end)

test('multi-config presets run the selected artifact and prepare its clangd commands', function()
  local directory = create('multi-config', { standard = 17 })
  os.remove(rt.join(directory, 'CMakeUserPresets.json'))
  rt.write(
    rt.join(directory, 'CMakePresets.json'),
    json.encode({
      version = 6,
      configurePresets = {
        {
          name = 'multi',
          generator = 'Ninja Multi-Config',
          binaryDir = '${sourceDir}/build/multi',
          cacheVariables = {
            CMAKE_CXX_COMPILER = tools.clangxx,
            CMAKE_EXPORT_COMPILE_COMMANDS = true,
          },
        },
      },
      buildPresets = {
        { name = 'optimized', configurePreset = 'multi', configuration = 'Release' },
      },
      testPresets = {
        { name = 'optimized-tests', configurePreset = 'multi', configuration = 'Release' },
      },
    })
  )
  local tasks = cmake.tasks(directory, 'multi', 'engine', { task = 'run' })
  tasks.prepare()
  run(tasks.configure, directory)
  check(tasks.after_configure())
  run(tasks.build, directory)
  check(run(tasks.run_command(), directory):find('Worker 0', 1, true))
  local database = rt.read(rt.join(directory, '.cache/rivet/compile_commands.json'))
  check(
    database:find('Release', 1, true)
      and not database:find('RelWithDebInfo', 1, true)
      and not database:find('Debug', 1, true)
  )
  for _, entry in ipairs(require('rivet.doctor').inspect(project.canonical(directory), 'multi')) do
    check(entry.level ~= 'error', entry.message)
  end
end)

test('interactive CLI preserves explicit standard and module constraints', function()
  local directory = rt.join(temporary, 'interactive-conflict')
  local result = rt.run({
    tools.lua or 'lua',
    rt.join(root, 'bin/rivet.lua'),
    'new',
    directory,
    '--standard',
    '17',
    '--modules',
    'true',
    '--interactive',
    '--preview',
  }, { stdin = string.rep('\n', 20) })
  check(
    result.code ~= 0 and result.stderr:find('conflict with --modules', 1, true),
    'interactive mode silently replaced an explicit module choice'
  )
  check(not rt.exists(directory))
end)

test('JSON preserves arbitrary project text across runtimes', function()
  local original = {
    newline = 'one\ntwo',
    quote = 'a"b',
    slash = 'a\\b',
    unicode = 'graphics ∑',
    bool = false,
    empty = json.array(),
  }
  local decoded = json.decode(json.encode(original))
  for _, key in ipairs({ 'newline', 'quote', 'slash', 'unicode', 'bool' }) do
    check(decoded[key] == original[key], key .. ' failed round trip')
  end
  check(json.encode(decoded.empty):match('^%[%]'), 'empty arrays must stay arrays')
  check(json.decode('"\\uD83D\\uDE00"') == '😀', 'surrogate-pair decoding')
  for _, bad in ipairs({ '{"a":1,"a":2}', '[1,]', '"\\uD800"', '01', '1e', '{} trailing' }) do
    rejects(function()
      json.decode(bad)
    end, 'accepted invalid JSON ' .. bad)
  end
end)

test('process arguments with spaces, quotes, and shell syntax remain literal', function()
  local expected = "space ' quote $(should_not_run) `nothing` ; end"
  local output = run({ 'printf', '%s', expected })
  check(output == expected, 'process adapter altered argument text')
end)

test('process execution preserves exit status and output on success and failure', function()
  for _, code in ipairs({ 0, 1, 7, 38, 127, 255 }) do
    local result = rt.run({
      'sh',
      '-c',
      'printf output; printf diagnostic >&2; exit ' .. code,
    })
    check(result.code == code, 'expected exit ' .. code .. ', received ' .. result.code)
    check(result.stdout == 'output' and result.stderr == 'diagnostic', 'process output changed')
  end
  local missing = rt.run({ 'rivet-nonexistent-test-command' })
  check(missing.code == 127 and missing.stderr ~= '', 'missing command did not report failure')
  local unavailable = rt.run({ 'printf', 'must not run' }, {
    cwd = rt.join(temporary, 'nonexistent-working-directory'),
  })
  check(
    unavailable.code ~= 0 and unavailable.stdout == '' and unavailable.stderr ~= '',
    'missing working directory did not report failure'
  )
end)

test('preview does not create the destination and apply refuses overwrites', function()
  local directory = rt.join(temporary, 'preview-only')
  local plan = project.plan({ name = 'engine', compiler = tools.clangxx }, directory)
  check(not rt.exists(directory), 'planning created destination')
  project.apply(directory, plan)
  local cmake_file = rt.read(rt.join(directory, 'CMakeLists.txt'))
  rejects(function()
    project.plan({ name = 'engine' }, directory)
  end)
  check(rt.read(rt.join(directory, 'CMakeLists.txt')) == cmake_file, 'existing file changed')
  check(project.root(rt.join(directory, 'src')) == plan.root, 'nested root discovery failed')
  check(project.load(directory).name == 'engine', 'manifest load failed')
end)

test('stale mutation preview fails before any file is created', function()
  local directory = create('stale')
  local spec = project.load(directory)
  local plan = project.file_plan(
    directory,
    { name = 'memory/page', kind = 'pair', target = destination(spec) }
  )
  local manifest_path = rt.join(directory, '.rivet.json')
  local changed = rt.read(manifest_path) .. '\n'
  rt.write(manifest_path, changed)
  rejects(function()
    project.apply(directory, plan)
  end)
  check(rt.read(manifest_path) == changed, 'stale apply replaced newer manifest')
  for path in pairs(plan.files) do
    if path:match('page%.cpp$') or path:match('page%.hpp$') then
      check(not rt.exists(rt.join(directory, path)), 'stale apply partially wrote files')
    end
  end
end)

test('hand-edited managed CMake files are protected', function()
  local directory = create('edited-cmake')
  local path = rt.join(directory, 'cmake/RivetTargets.cmake')
  local custom = rt.read(path) .. '\n# user edit\n'
  rt.write(path, custom)
  rejects(function()
    project.target_plan(directory, { name = 'extra', kind = 'library' })
  end)
  check(rt.read(path) == custom, 'hand-edited CMake changed')
end)

test('new source files cannot follow a directory symlink outside the project', function()
  local directory = create('symlink-source')
  local outside = rt.join(temporary, 'outside-source')
  rt.mkdir(outside)
  local spec = project.load(directory)
  local selected
  for _, item in ipairs(spec.targets) do
    if item.name == destination(spec) then
      selected = item
    end
  end
  local linked = rt.join(directory, 'external')
  run({ 'ln', '-s', outside, linked })
  rejects(function()
    project.file_plan(
      directory,
      { name = 'external/escape', kind = 'source', target = selected.name }
    )
  end)
  check(not rt.exists(rt.join(outside, 'escape.cpp')), 'source escaped project')
end)

test('language providers can update their own managed build files', function()
  local provider, model = {}, require('rivet.model')
  function provider.normalize(opts)
    check(opts.language == 'service_example', 'wrong custom provider')
    return opts
  end
  function provider.plan(opts)
    return {
      spec = { schema_version = 1, language = 'service_example', name = opts.name, generation = 1 },
      files = { ['build.recipe'] = 'build version 1\n' },
      managed = { ['build.recipe'] = true },
    }
  end
  function provider.add_file(spec, opts)
    local next_spec = json.decode(json.encode(spec))
    next_spec.generation = next_spec.generation + 1
    return {
      spec = next_spec,
      files = {
        ['build.recipe'] = 'build version ' .. next_spec.generation .. '\n',
        [opts.name] = 'payload\n',
      },
      managed = { ['build.recipe'] = true },
    }
  end
  provider.add_target, provider.add_dependency = provider.add_file, provider.add_file
  model.register('service_example', provider)
  local directory = rt.join(temporary, 'custom-provider')
  project.apply(
    directory,
    project.plan({ language = 'service_example', name = 'example' }, directory)
  )
  project.apply(directory, project.file_plan(directory, { name = 'payload.txt' }))
  check(
    rt.read(rt.join(directory, 'build.recipe')) == 'build version 2\n',
    'custom managed file was not updated'
  )
  check(project.load(directory).generation == 2, 'custom manifest was not updated')
  rt.write(rt.join(directory, 'build.recipe'), 'custom user build\n')
  rejects(function()
    project.file_plan(directory, { name = 'other.txt' })
  end, 'custom managed file lost edit protection')
end)

for _, layout in ipairs({ 'flat', 'feature', 'library' }) do
  for _, modules in ipairs({ false, true }) do
    local name = layout .. (modules and '-modules' or '-headers')
    test(name .. ' configures, builds, and tests Debug and Release offline', function()
      local directory =
        create(name, { layout = layout, modules = modules, style = modules and 'LLVM' or 'Google' })
      build(directory, 'debug', true)
      build(directory, 'release', true)
    end)
  end
end

test('Make supports a C++26 conventional-header project', function()
  local directory = create('make-headers', { modules = false, generator = 'Unix Makefiles' })
  build(directory, 'debug', true)
end)

for _, modules in ipairs({ false, true }) do
  local mode = modules and 'project-modules' or 'project-headers'
  test('std modules ' .. mode .. ' build, run, and test Debug and Release offline', function()
    local directory, plan = create('std-' .. mode, { modules = modules, std_modules = true })
    for path, body in pairs(plan.files) do
      if path ~= 'CMakeUserPresets.json' then
        check(
          not body:find(tools.clangxx, 1, true),
          'compiler path leaked into shared file ' .. path
        )
        check(not body:find(directory, 1, true), 'project path leaked into shared file ' .. path)
        local home = os.getenv('HOME')
        check(
          not home or not body:find(home, 1, true),
          'home path leaked into shared file ' .. path
        )
      end
    end
    build(directory, 'debug', true)
    build(directory, 'release', true)
    local spec = project.load(directory)
    check(
      spec.std_modules == true and spec.modules == modules,
      'std modules choice was not preserved'
    )
    local selected = destination(spec)
    local additions = {
      { name = 'memory/page', kind = 'pair', target = selected },
      { name = 'memory/Arena', kind = 'class', target = selected },
    }
    if modules then
      additions[#additions + 1] = {
        name = 'memory/pool',
        kind = 'module',
        module = 'engine.memory.pool',
        target = selected,
      }
      additions[#additions + 1] = {
        name = 'memory/pool_impl',
        kind = 'module_impl',
        module = 'engine.memory.pool',
        target = selected,
      }
    end
    for _, options in ipairs(additions) do
      project.apply(directory, project.file_plan(directory, options))
    end
    project.apply(directory, project.target_plan(directory, { name = 'viewer', kind = 'app' }))
    build(directory, 'debug', true)
    run(cmake.tasks(directory, 'debug', 'viewer').run, directory)
    if tools.clangd then
      local result = rt.run({
        tools.clangd,
        '--experimental-modules-support',
        '--check=' .. rt.join(directory, 'app/main.cpp'),
        '--compile-commands-dir=' .. rt.join(directory, 'build/debug'),
        '--enable-config',
      }, { cwd = directory })
      check(
        result.code == 0,
        'clangd could not analyze built import std project:\n' .. result.stdout .. result.stderr
      )
    end
  end)
end

test(
  'std modules CLI preview with build creates nothing and explicit build produces runnable code',
  function()
    local directory = rt.join(temporary, 'std-cli')
    local cli = rt.join(root, 'bin/rivet.lua')
    local command = {
      tools.lua or 'lua',
      cli,
      'new',
      '--root',
      directory,
      '--name',
      'engine',
      '--modules',
      'false',
      '--std-modules',
      'true',
      '--compiler',
      tools.clangxx,
      '--preset',
      'debug',
      '--build',
      '--preview',
    }
    run(command)
    check(not rt.exists(directory), '--preview --build wrote a project')
    table.remove(command)
    run(command)
    local manifest = project.load(directory)
    for _, key in ipairs({ 'root', 'compiler', 'build', 'preview', 'interactive', 'preset' }) do
      check(manifest[key] == nil, 'transient CLI option leaked into manifest: ' .. key)
    end
    check(
      not rt.read(rt.join(directory, '.rivet.json')):find(directory, 1, true),
      'CLI root leaked into shared manifest'
    )
    check(
      rt.read(rt.join(directory, 'build/debug/compile_commands.json')),
      '--build did not configure'
    )
    run(cmake.tasks(directory, 'debug').run, directory)
    run(cmake.tasks(directory, 'debug').test, directory)
    local bad_root = rt.join(temporary, 'std-cli-invalid')
    for _, invalid in ipairs({ 'yes', '1', 'FALSE' }) do
      local result = rt.run({
        tools.lua or 'lua',
        cli,
        'new',
        bad_root,
        '--std-modules',
        invalid,
      })
      check(result.code ~= 0 and not rt.exists(bad_root), 'invalid std modules flag caused a write')
    end
    local invalid_preset = rt.run({
      tools.lua or 'lua',
      cli,
      'new',
      bad_root,
      '--std-modules',
      'true',
      '--build',
      '--preset',
      'fast',
    })
    check(
      invalid_preset.code ~= 0 and not rt.exists(bad_root),
      'invalid initial-build preset caused a write'
    )
  end
)

test('std modules CMake gate rejects unverified versions and unsupported generators', function()
  local directory = rt.join(temporary, 'std-gate-check')
  rt.mkdir(directory)
  local helper =
    require('rivet.model').plan({ name = 'engine', std_modules = true }).files['cmake/StandardModules.cmake']
  rt.write(rt.join(directory, 'StandardModules.cmake'), helper)
  local driver = rt.join(directory, 'gate.cmake')
  for _, version in ipairs({ '3.30.0', '4.4.5', '5.0.0' }) do
    rt.write(
      driver,
      'set(CMAKE_VERSION "'
        .. version
        .. '")\nset(CMAKE_GENERATOR "Ninja")\ninclude("${CMAKE_CURRENT_LIST_DIR}/StandardModules.cmake")\n'
    )
    local result = rt.run({ tools.cmake, '-P', driver }, { cwd = directory })
    check(
      result.code ~= 0 and result.stderr:find('verified', 1, true),
      'unverified CMake version was not rejected: ' .. version
    )
  end
  rt.write(
    driver,
    'set(CMAKE_VERSION "4.4.4")\nset(CMAKE_GENERATOR "Unix Makefiles")\ninclude("${CMAKE_CURRENT_LIST_DIR}/StandardModules.cmake")\n'
  )
  local result = rt.run({ tools.cmake, '-P', driver }, { cwd = directory })
  check(
    result.code ~= 0 and result.stderr:find('Ninja', 1, true),
    'unsupported generator was not rejected'
  )
end)

test('templates and additional targets remain buildable after mutation', function()
  local directory = create('mutations')
  local spec = project.load(directory)
  local selected = destination(spec)
  for _, options in ipairs({
    { name = 'memory/page', kind = 'pair', target = selected },
    { name = 'memory/Arena', kind = 'class', target = selected },
    { name = 'memory/pool', kind = 'module', module = 'engine.memory.pool', target = selected },
    {
      name = 'memory/pool_impl',
      kind = 'module_impl',
      module = 'engine.memory.pool',
      target = selected,
    },
  }) do
    project.apply(directory, project.file_plan(directory, options))
  end
  project.apply(directory, project.target_plan(directory, { name = 'renderer', kind = 'library' }))
  project.apply(directory, project.target_plan(directory, { name = 'viewer', kind = 'app' }))
  build(directory, 'debug', true)
  build(directory, 'release', true)
end)

test('library layout places new public headers separately and compiles their sources', function()
  local directory = create(
    'library-templates',
    { layout = 'library', modules = false, kind = 'library', header_guard = 'ifndef' }
  )
  for _, options in ipairs({
    { name = 'page', kind = 'pair', target = 'engine' },
    { name = 'Arena', kind = 'class', target = 'engine' },
    { name = 'flags', kind = 'header', target = 'engine' },
  }) do
    project.apply(directory, project.file_plan(directory, options))
  end
  project.apply(directory, project.target_plan(directory, { name = 'renderer', kind = 'library' }))
  project.apply(
    directory,
    project.file_plan(directory, { name = 'Vertex', kind = 'class', target = 'renderer' })
  )
  for _, file in ipairs({
    'include/engine/page.hpp',
    'include/engine/Arena.hpp',
    'include/engine/flags.hpp',
    'src/page.cpp',
    'include/engine/renderer/Vertex.hpp',
  }) do
    check(rt.read(rt.join(directory, file)), 'library layout misplaced ' .. file)
  end
  check(
    rt.read(rt.join(directory, 'src/page.cpp')):find('"engine/page.hpp"', 1, true),
    'source must use its public include path'
  )
  build(directory, 'debug', false)
end)

test('CMake cache edits persist to user presets and reconfigure', function()
  local directory = create('cache-options', { modules = false })
  run(cmake.tasks(directory, 'debug').configure, directory)
  local selected
  for _, entry in ipairs(cmake.cache(directory, 'debug')) do
    if entry.name == 'BUILD_TESTING' then
      selected = entry
    end
  end
  check(selected and selected.type == 'BOOL', 'BUILD_TESTING cache option missing')
  local command = cmake.set_cache(directory, 'debug', selected, 'OFF')
  run(command, directory)
  local found
  for _, entry in ipairs(cmake.cache(directory, 'debug')) do
    if entry.name == 'BUILD_TESTING' then
      found = entry.value
    end
  end
  check(found == 'OFF', 'cache edit was not applied by configure')
  rejects(function()
    cmake.set_cache(
      directory,
      'debug',
      { name = 'CMAKE_CXX_COMPILER', type = 'FILEPATH' },
      '/tmp/other'
    )
  end)
end)

test('CLI preview and creation handle roots containing spaces and apostrophes', function()
  local directory = rt.join(temporary, "CLI's sandbox")
  local cli = rt.join(root, 'bin/rivet.lua')
  check(rt.exists(cli), 'CLI entry point missing')
  local command = {
    tools.lua or 'lua',
    cli,
    'new',
    directory,
    '--name',
    'cli_demo',
    '--modules',
    'false',
    '--compiler',
    tools.clangxx,
    '--preview',
  }
  run(command)
  check(not rt.exists(directory), 'CLI preview created project')
  table.remove(command)
  run(command)
  run({
    tools.lua or 'lua',
    cli,
    'file',
    'memory/page',
    '--kind',
    'pair',
    '--target',
    destination(project.load(directory)),
    '--root',
    directory,
  })
  run({ tools.lua or 'lua', cli, 'test', '--root', directory, '--preset', 'debug' })
  run({ tools.lua or 'lua', cli, 'run', '--root', directory, '--preset', 'debug' })
end)

if tools.just then
  test('Just recipes configure the chosen compiler before build, test, and run', function()
    local directory = create('just-workflow')
    local recipes = run({ tools.just, '--list' }, directory)
    check(recipes:find('test', 1, true) and recipes:find('run', 1, true), 'missing Just tasks')
    run({ tools.just, 'test' }, directory)
    local output = run({ tools.just, 'run' }, directory)
    check(output:find('Worker 0:', 1, true), 'Just run did not launch generated app')
    run({ tools.just, 'test', 'release' }, directory)
  end)
end

test('first-project tutorial examples build, run, and report the intended typo', function()
  local source = assert(rt.read(rt.join(root, 'docs/src/content/first-project.svx')))
  local snippets = {}
  for body in source:gmatch('```cpp\n(.-)\n```') do
    snippets[#snippets + 1] = body .. '\n'
  end
  check(#snippets == 2, 'expected the module and application examples')
  local directory = create(
    'first-project-tutorial',
    { comment_header = { style = 'xcode', author = 'Ada Lovelace' } }
  )
  build(directory, 'debug', true)
  local plan = project.file_plan(
    directory,
    { kind = 'module', name = 'number', module = 'engine.number', target = 'engine_core' }
  )
  project.apply(directory, plan)
  local module_path = rt.join(directory, 'src/core/number.cppm')
  local main_path = rt.join(directory, 'app/main.cpp')
  rt.write(module_path, snippets[1])
  rt.write(main_path, snippets[2])
  build(directory, 'debug', true)
  local tasks = cmake.tasks(directory, 'debug')
  local output = run(tasks.run, directory)
  check(output == 'Answer: 42\nWorker 0: [0, 4)\n', output)
  rt.write(main_path, (snippets[2]:gsub('engine::answer', 'engine::answr')))
  local failed_build = rt.run(tasks.build, { cwd = directory })
  check(
    failed_build.code ~= 0 and (failed_build.stdout .. failed_build.stderr):find('answr', 1, true),
    'the tutorial typo did not produce a compiler error'
  )
  rt.write(main_path, snippets[2])
  build(directory, 'debug', true)
end)

test('comment headers survive formatting, project reload, defaults edits, and builds', function()
  for _, modules in ipairs({ false, true }) do
    local directory, initial = create('comment-headers-' .. tostring(modules), {
      modules = modules,
      comment_header = { style = 'xcode', author = 'Ada Lovelace', created = 'today' },
    })
    local saved = project.load(directory)
    check(saved.comment_header.author == 'Ada Lovelace')
    local before = rt.read(rt.join(directory, 'src/core/core.cpp'))
    check(before:find('Author: Ada Lovelace', 1, true))
    local update = project.header_plan(directory, { style = 'doc', author = 'Grace Hopper' })
    check(
      project.load(directory).comment_header.author == 'Ada Lovelace',
      'preview mutated defaults'
    )
    project.apply(directory, update)
    check(
      rt.read(rt.join(directory, 'src/core/core.cpp')) == before,
      'defaults rewrote an existing source'
    )
    local addition =
      project.file_plan(directory, { name = 'extra', kind = 'pair', target = destination(saved) })
    check(addition.files['src/core/extra.hpp']:find('@author Grace Hopper', 1, true))
    project.apply(directory, addition)
    rejects(function()
      project.apply(directory, update)
    end, 'stale defaults preview was accepted')
    build(directory, 'debug', true)
    check(initial.files['src/core/core.cpp']:find('Author: Ada Lovelace', 1, true))
  end
end)

test(
  'project creation in the current folder infers its name and only initializes Git on apply',
  function()
    local directory = rt.join(temporary, '123 My-Engine')
    rt.mkdir(directory)
    rt.write(rt.join(directory, 'notes.txt'), 'Keep me.\n')
    local cli = { 'lua', rt.join(root, 'bin/rivet.lua'), 'new', '.', '--git', 'true', '--preview' }
    local preview = run(cli, directory)
    check(preview:find('Name: project_123_My_Engine', 1, true))
    check(preview:find('Git: initialize', 1, true))
    check(
      not rt.exists(rt.join(directory, '.git')) and not rt.exists(rt.join(directory, '.rivet.json'))
    )
    table.remove(cli)
    run(cli, directory)
    local spec = project.load(directory)
    check(spec.name == 'project_123_My_Engine' and spec.git == nil)
    check(rt.is_dir(rt.join(directory, '.git')))
    check(not rt.exists(rt.join(directory, spec.name)), 'created a nested project folder')
    check(rt.read(rt.join(directory, 'notes.txt')) == 'Keep me.\n')
    check(run({ 'git', 'ls-files', '--cached' }, directory) == '', 'staged generated files')
    check(
      rt.run({ 'git', 'rev-parse', '--verify', 'HEAD' }, { cwd = directory }).code ~= 0,
      'created a commit'
    )
    for _, path in ipairs({
      'build/debug/app',
      'example.o',
      'sample.pcm',
      'CMakeUserPresets.json',
      '.cache/CPM/file',
    }) do
      run({ 'git', 'check-ignore', path }, directory)
    end
    local source_ignore = rt.run({ 'git', 'check-ignore', 'app/main.cpp' }, { cwd = directory })
    check(
      source_ignore.code == 1,
      'source ignore check returned '
        .. source_ignore.code
        .. ': '
        .. source_ignore.stdout
        .. source_ignore.stderr
    )
    build(directory, 'debug', true)
  end
)

test(
  'project creation preserves ignore rules and reuses existing or enclosing Git repositories',
  function()
    local directory = rt.join(temporary, 'existing-git')
    rt.mkdir(directory)
    run({ 'git', 'init', '--quiet', directory })
    local git_config = rt.read(rt.join(directory, '.git/config'))
    local ignore = '# Local exceptions\n!important.o\n/local-data/\n'
    rt.write(rt.join(directory, '.gitignore'), ignore)
    local plan = project.plan({ name = 'engine', git = true }, directory)
    check(plan.git.existing and plan.git.summary:find('use existing', 1, true))
    check(
      plan.expected['.gitignore'] == ignore and rt.read(rt.join(directory, '.gitignore')) == ignore
    )
    project.apply(directory, plan)
    check(rt.read(rt.join(directory, '.gitignore')):sub(-#ignore) == ignore)
    local exception_ignore = rt.run({ 'git', 'check-ignore', 'important.o' }, { cwd = directory })
    check(
      exception_ignore.code == 1,
      'user exception ignore check returned '
        .. exception_ignore.code
        .. ': '
        .. exception_ignore.stdout
        .. exception_ignore.stderr
    )
    run({ 'git', 'check-ignore', 'local-data/file' }, directory)
    check(rt.read(rt.join(directory, '.git/config')) == git_config, 'existing Git config changed')
    local child = rt.join(directory, 'child')
    local nested = project.plan({ name = 'child', git = true }, child)
    check(nested.git.existing == plan.git.existing)
    project.apply(child, nested)
    check(not rt.exists(rt.join(child, '.git')), 'created a nested Git repository')
  end
)

test('project creation refuses stale Git and ignore previews before writing', function()
  local directory = rt.join(temporary, 'stale-git')
  local plan = project.plan({ name = 'engine', git = true }, directory)
  run({ 'git', 'init', '--quiet', directory })
  rejects(function()
    project.apply(directory, plan)
  end)
  check(not rt.exists(rt.join(directory, '.rivet.json')))
  rt.write(rt.join(directory, '.gitignore'), 'before\n')
  plan = project.plan({ name = 'engine', git = true }, directory)
  rt.write(rt.join(directory, '.gitignore'), 'after\n')
  rejects(function()
    project.apply(directory, plan)
  end)
  check(not rt.exists(rt.join(directory, 'CMakeLists.txt')))
  check(rt.read(rt.join(directory, '.gitignore')) == 'after\n')
  rt.write(rt.join(directory, 'README.md'), 'Existing readme\n')
  rejects(function()
    project.plan({ name = 'engine', git = true }, directory)
  end)
end)

test('project creation recognizes worktrees and isolates Git environment paths', function()
  local repository = rt.join(temporary, 'git-host')
  run({ 'git', 'init', '--quiet', repository })
  run({
    'git',
    '-c',
    'user.name=Ada Lovelace',
    '-c',
    'user.email=ada@example.test',
    '-c',
    'commit.gpgSign=false',
    '-c',
    'core.hooksPath=/dev/null',
    'commit',
    '--quiet',
    '--allow-empty',
    '-m',
    'Disposable test fixture',
  }, repository)
  local worktree = rt.join(temporary, 'git-worktree')
  run({ 'git', 'worktree', 'add', '--quiet', '--detach', worktree }, repository)
  local git_file = rt.read(rt.join(worktree, '.git'))
  local plan = project.plan({ name = 'engine', git = true }, worktree)
  check(plan.git.existing:find('/worktrees/', 1, true))
  project.apply(worktree, plan)
  check(rt.read(rt.join(worktree, '.git')) == git_file, 'worktree metadata was replaced')
  check(run({ 'git', 'ls-files', '--cached' }, worktree) == '')

  local directory = rt.join(temporary, 'git-environment')
  local config = rt.read(rt.join(repository, '.git/config'))
  run({
    'env',
    'GIT_DIR=' .. rt.join(repository, '.git'),
    'GIT_WORK_TREE=' .. repository,
    'GIT_OBJECT_DIRECTORY=' .. rt.join(repository, '.git/objects'),
    'GIT_CONFIG_COUNT=1',
    'GIT_CONFIG_KEY_0=init.defaultBranch',
    'GIT_CONFIG_VALUE_0=rivet-test',
    'lua',
    rt.join(root, 'bin/rivet.lua'),
    'new',
    directory,
    '--git',
    'true',
  })
  check(rt.is_dir(rt.join(directory, '.git')))
  check(run({ 'git', 'symbolic-ref', 'HEAD' }, directory):match('refs/heads/rivet%-test'))
  check(rt.read(rt.join(repository, '.git/config')) == config, 'Git environment redirected setup')

  local bare = rt.join(temporary, 'git-bare')
  run({ 'git', 'init', '--quiet', '--bare', bare })
  rejects(function()
    project.plan({ name = 'engine', git = true }, bare)
  end)
  check(not rt.exists(rt.join(bare, '.rivet.json')))
end)

test(
  'project creation without Git still generates ignore rules and accepts an explicit name',
  function()
    local directory = rt.join(temporary, 'explicit-name')
    run({
      'lua',
      rt.join(root, 'bin/rivet.lua'),
      'new',
      directory,
      '--name',
      'chosen',
      '--git',
      'false',
    })
    check(project.load(directory).name == 'chosen')
    check(not rt.exists(rt.join(directory, '.git')))
    check(rt.read(rt.join(directory, '.gitignore')):find('*.pcm', 1, true))
    check(
      rt.run({ 'lua', rt.join(root, 'bin/rivet.lua'), 'new', directory, '--git', 'yes' }).code ~= 0
    )
    check(rt.run({ 'lua', rt.join(root, 'bin/rivet.lua'), 'doctor', '--git', 'true' }).code ~= 0)
  end
)

test(
  'project creation rejects unavailable Git and preserves files if Git initialization fails',
  function()
    local original_executable, original_run = rt.executable, rt.run
    local directory = rt.join(temporary, 'missing-git')
    rt.executable = function(name)
      return name ~= 'git' and original_executable(name) or false
    end
    local ok = pcall(project.plan, { name = 'engine', git = true }, directory)
    rt.executable = original_executable
    check(not ok and not rt.exists(directory))
    local plan = project.plan({ name = 'engine', git = true }, directory)
    rt.run = function(argv, options)
      for _, arg in ipairs(argv) do
        if arg == 'init' then
          return { code = 1, stdout = '', stderr = 'test init failure' }
        end
      end
      return original_run(argv, options)
    end
    local applied, err = pcall(project.apply, directory, plan)
    rt.run = original_run
    check(not applied and tostring(err):find('Project files were saved', 1, true))
    check(
      project.load(directory).name == 'engine' and not rt.exists(rt.join(directory, '.rivet-lock'))
    )
  end
)

io.write(
  string.format(
    '\n%d passed; %d failed; %d skipped (%s)\nArtifacts: %s\n',
    passed,
    failed,
    skipped,
    _VERSION,
    temporary
  )
)
os.exit(failed == 0 and 0 or 1)
