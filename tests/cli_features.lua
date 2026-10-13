-- Real CLI coverage for Lua creation, mixed files, configuration, and upgrades.
local repo = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/cli_features%.lua$') or '.'
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local rt, project, json = require('rivet.runtime'), require('rivet.project'), require('rivet.json')
local bin = rt.join(rt.absolute(repo), 'bin/rivet')
local temporary = assert(
  rt.run({ 'mktemp', '-d', rt.join(os.getenv('TMPDIR') or '/tmp', 'rivet-cli.XXXXXX') }).stdout
    :match('%S+')
)
local passed = 0
local function test(name, fn)
  fn()
  passed = passed + 1
  print('ok - ' .. name)
end
local function run(args)
  local argv = { bin }
  for _, argument in ipairs(args) do
    argv[#argv + 1] = argument
  end
  local result = rt.run(argv, { cwd = temporary })
  assert(result.code == 0, result.stdout .. result.stderr)
  return result.stdout
end
local function contains(text, fragment)
  assert(text:find(fragment, 1, true), 'Missing CLI output: ' .. fragment .. '\n' .. text)
end
local ok, err = pcall(function()
  test('help parses and advertises the new command and runtime options', function()
    local help = run({ 'help' })
    contains(help, '--runtime lua|luajit|neovim')
    contains(help, 'rivet config [TOOL [KEY VALUE]]')
    contains(help, 'rivet upgrade')
    contains(help, 'module_pair')
    contains(help, 'c_pair')
  end)

  test('tool catalogs are descriptive and available without a project', function()
    local listing = run({ 'config' })
    contains(listing, 'clang-format')
    contains(listing, 'Controls indentation')
    contains(listing, '.clangd')
    local settings = run({ 'config', 'clang-format' })
    contains(settings, 'IndentWidth (integer)')
    contains(settings, 'Number of columns')
    contains(settings, 'Google C++ conventions')
    contains(settings, 'https://clang.llvm.org/docs/ClangFormatStyleOptions.html')
  end)

  test('Lua runtime selection survives preview and project creation', function()
    local directory = rt.join(temporary, 'lua-project')
    local preview = run({
      'new',
      directory,
      '--language',
      'lua',
      '--runtime',
      'luajit',
      '--kind',
      'library',
      '--name',
      'sample_lua',
      '--preview',
    })
    contains(preview, 'LuaJIT')
    contains(preview, '.luarc.json')
    assert(not rt.exists(directory), 'Lua preview created project files')
    run({
      'new',
      directory,
      '--language',
      'lua',
      '--runtime',
      'luajit',
      '--kind',
      'library',
      '--name',
      'sample_lua',
    })
    local spec = project.load(directory)
    assert(spec.language == 'lua' and spec.runtime == 'luajit' and spec.kind == 'library')
    local manifest = rt.read(rt.join(directory, '.rivet.json'))
    local module = run({ 'file', 'helper', '--kind', 'module', '--root', directory, '--preview' })
    contains(module, 'lua/sample_lua/helper.lua')
    assert(rt.read(rt.join(directory, '.rivet.json')) == manifest)
    assert(not rt.exists(rt.join(directory, 'lua/sample_lua/helper.lua')))
    local rejected = rt.run({
      bin,
      'new',
      rt.join(temporary, 'bad-runtime'),
      '--language',
      'lua',
      '--runtime',
      'unsupported',
    })
    assert(rejected.code ~= 0 and not rt.exists(rt.join(temporary, 'bad-runtime')))
  end)

  local directory = rt.join(temporary, 'mixed-project')
  run({ 'new', directory, '--name', 'mixed', '--standard', '20', '--modules', 'true' })
  local spec = project.load(directory)
  local target = assert(spec.targets[1]).name
  test('C++ module pairs, C pairs, and loose Lua files are available through the CLI', function()
    local manifest = rt.read(rt.join(directory, '.rivet.json'))
    local module = run({
      'file',
      'added_module',
      '--kind',
      'module_pair',
      '--module',
      'mixed.added_module',
      '--target',
      target,
      '--root',
      directory,
      '--preview',
    })
    contains(module, 'added_module.cppm')
    contains(module, 'added_module.cpp')
    contains(module, 'export module mixed.added_module')
    local c_pair = run({
      'file',
      'bridge',
      '--kind',
      'c_pair',
      '--target',
      target,
      '--root',
      directory,
      '--preview',
    })
    contains(c_pair, 'bridge.c')
    contains(c_pair, 'bridge.h')
    local script = run({
      'file',
      'helper',
      '--language',
      'lua',
      '--kind',
      'script',
      '--root',
      directory,
      '--preview',
    })
    contains(script, 'scripts/helper.lua')
    local loose = run({
      'file',
      'helper',
      '--language',
      'lua',
      '--kind',
      'module',
      '--root',
      directory,
      '--preview',
    })
    contains(loose, 'lua/mixed/helper.lua')
    assert(
      rt.read(rt.join(directory, '.rivet.json')) == manifest,
      'File preview changed the manifest'
    )
    assert(not rt.exists(rt.join(directory, 'scripts/helper.lua')))
  end)

  test('config preview shows explanations and apply preserves unrelated YAML', function()
    local path = rt.join(directory, '.clang-format')
    rt.write(path, '# Team formatting\nBasedOnStyle: LLVM\nTabWidth: 8\n')
    local before, manifest = rt.read(path), rt.read(rt.join(directory, '.rivet.json'))
    local preview =
      run({ 'config', 'clang-format', 'IndentWidth', '4', '--root', directory, '--preview' })
    contains(preview, 'IndentWidth: 4')
    contains(preview, 'Number of columns per indentation level')
    assert(rt.read(path) == before, 'Configuration preview wrote YAML')
    run({ 'config', 'format', 'IndentWidth', '4', '--root', directory })
    contains(rt.read(path), '# Team formatting')
    contains(rt.read(path), 'TabWidth: 8')
    contains(rt.read(path), 'IndentWidth: 4')
    assert(
      rt.read(rt.join(directory, '.rivet.json')) == manifest,
      'Config changed template ownership'
    )
    local rejected = rt.run({ bin, 'config', 'format', 'IndentWidth', '--root', directory })
    assert(rejected.code ~= 0 and rejected.stderr:find('Usage: rivet config', 1, true))
  end)

  test('embedded Lua preview exposes its host and build changes without applying them', function()
    local manifest = rt.read(rt.join(directory, '.rivet.json'))
    local cmake = rt.read(rt.join(directory, 'CMakeLists.txt'))
    local preview = run({
      'file',
      'embedded',
      '--language',
      'lua',
      '--kind',
      'embedded',
      '--root',
      directory,
      '--preview',
    })
    contains(preview, 'examples/embedded/main.cpp')
    contains(preview, 'scripts/embedded.lua')
    contains(preview, 'find_package(Lua REQUIRED)')
    assert(rt.read(rt.join(directory, '.rivet.json')) == manifest)
    assert(rt.read(rt.join(directory, 'CMakeLists.txt')) == cmake)
    assert(not rt.exists(rt.join(directory, 'examples/embedded/main.cpp')))
  end)

  test(
    'upgrade previews report conflicts and restore missing supplements while preserving source',
    function()
      local style = rt.read(rt.join(directory, '.clang-format'))
      local manifest = rt.read(rt.join(directory, '.rivet.json'))
      local source_path
      for _, item in ipairs(spec.targets) do
        for _, path in ipairs(item.sources or {}) do
          if path:match('%.cpp$') then
            source_path = path
            break
          end
        end
        if source_path then
          break
        end
      end
      assert(source_path, 'Missing user source fixture')
      local source = rt.read(rt.join(directory, source_path))
        .. '\n// User implementation stays here.\n'
      rt.write(rt.join(directory, source_path), source)
      assert(os.remove(rt.join(directory, '.clangd')))
      local preview = run({ 'upgrade', '--root', directory, '--preview' })
      contains(preview, 'Skipped .clang-format:')
      contains(preview, '--- .clangd ---')
      assert(not rt.exists(rt.join(directory, '.clangd')), 'Upgrade preview recreated a file')
      assert(rt.read(rt.join(directory, '.rivet.json')) == manifest)
      local output = run({ 'upgrade', '--root', directory })
      contains(output, 'Skipped .clang-format:')
      assert(rt.exists(rt.join(directory, '.clangd')))
      assert(rt.read(rt.join(directory, '.clang-format')) == style)
      assert(rt.read(rt.join(directory, source_path)) == source)
      local upgraded = project.load(directory)
      assert(upgraded.rivet_version == require('rivet.version'))
      assert(upgraded.template_baselines['.clangd'])
      assert(
        json.encode(upgraded.targets) == json.encode(spec.targets),
        'Upgrade changed target sources'
      )
    end
  )
end)
local removed = rt.run({ 'rm', '-rf', temporary })
assert(removed.code == 0, removed.stderr)
assert(ok, err)
print(passed .. ' CLI feature checks passed')
