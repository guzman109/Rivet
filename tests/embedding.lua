-- Offline integration: Lua host previews, native ownership, and C/C++ builds.
local repo = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/embedding%.lua$') or '.'
package.path = repo .. '/lua/?.lua;' .. package.path
local rt, project, embedding =
  require('rivet.runtime'), require('rivet.project'), require('rivet.embedding')
local root = project.canonical(rt.run({ 'mktemp', '-d' }).stdout:gsub('%s+$', ''))
local function run(argv, cwd)
  local result = rt.run(argv, { cwd = cwd })
  assert(result.code == 0, table.concat(argv, ' ') .. '\n' .. result.stdout .. result.stderr)
  return result.stdout
end
local function rejects(fn)
  local ok = pcall(fn)
  assert(not ok, 'Expected rejection')
end
local function owned(language, kind)
  local path = root .. '/' .. language .. '-' .. (kind or 'app')
  project.apply(
    path,
    project.plan({
      language = language,
      kind = kind,
      name = 'host',
      standard = 17,
      modules = false,
      comment_header = { style = 'compact', author = 'Ada' },
    }, path)
  )
  return path
end
local cmake = rt.executable('cmake')
local ninja = rt.executable('ninja')
local native_builds = 0
for _, language in ipairs({ 'c', 'cpp' }) do
  local path = owned(language)
  local original = rt.read(path .. '/CMakeLists.txt')
  local manifest = rt.read(path .. '/.rivet.json')
  local existing_sources = {}
  for _, file in ipairs(project.load(path).files) do
    if require('rivet.headers').accepts(file) then
      existing_sources[file] = rt.read(path .. '/' .. file)
    end
  end
  local plan = embedding.plan(path, { name = 'game/demo' })
  assert(
    rt.read(path .. '/CMakeLists.txt') == original and rt.read(path .. '/.rivet.json') == manifest
  )
  assert(not rt.exists(path .. '/scripts/game/demo.lua'), 'Preview created a script')
  for file, content in pairs(existing_sources) do
    assert(rt.read(path .. '/' .. file) == content, 'Preview changed existing source: ' .. file)
    assert(not plan.files[file], 'Embedding would rewrite existing source: ' .. file)
  end
  local ext = language == 'c' and 'c' or 'cpp'
  local host_source = 'examples/game/demo/main.' .. ext
  local host_header = require('rivet.headers').render(
    plan.spec.comment_header,
    { filename = host_source, project = plan.spec.name }
  )
  local lua_header = require('rivet.lua_headers').render(
    plan.spec.comment_header,
    { filename = 'scripts/game/demo.lua', project = plan.spec.name }
  )
  assert(plan.files[host_source]:sub(1, #host_header) == host_header)
  assert(plan.files['scripts/game/demo.lua']:sub(1, #lua_header) == lua_header)
  assert(not plan.files['cmake/Lua_game_demo.cmake']:find('Author: Ada', 1, true))
  assert(plan.expected['.rivet.json'] == manifest)
  assert(plan.files['CMakeLists.txt']:sub(1, #original) == original)
  assert(plan.spec.targets[#plan.spec.targets].external)
  project.apply(path, plan)
  assert(project.load(path).targets[#plan.spec.targets].name == 'game_demo_lua')
  local owner = plan.spec.targets[1].name
  project.apply(
    path,
    project.file_plan(path, { name = 'followup', kind = 'source', target = owner })
  )
  assert(
    not rt.read(path .. '/cmake/RivetTargets.cmake'):find('add_executable(game_demo_lua', 1, true)
  )
  -- An upgrade must preserve the appended extension instead of treating it as replaceable baseline.
  if require('rivet.model').provider(plan.spec).upgrade_files then
    local upgraded = require('rivet.upgrade').plan(path)
    assert(not upgraded.files['CMakeLists.txt'], 'Upgrade would erase the embedding include')
  end
  assert(rt.read(path .. '/examples/game/demo/main.' .. ext):find('lua_register', 1, true))
  rejects(function()
    embedding.plan(path, { name = 'game/demo' })
  end)
  -- Changing the native manifest after preview invalidates the complete transaction.
  local stale = embedding.plan(path, { name = 'second' })
  rt.write(path .. '/CMakeLists.txt', rt.read(path .. '/CMakeLists.txt') .. '# concurrent edit\n')
  rejects(function()
    project.apply(path, stale)
  end)
  assert(not rt.exists(path .. '/scripts/second.lua'))
  if cmake and ninja then
    local build = path .. '/build/lua-review'
    run({ cmake, '-S', path, '-B', build, '-G', 'Ninja' })
    run({ cmake, '--build', build, '--target', 'game_demo_lua' })
    assert(run({ build .. '/game_demo_lua' }, root):find('Lua says: 42', 1, true))
    -- A module created by the ordinary Lua file flow must be usable by its host.
    project.apply(
      path,
      project.file_plan(path, { language = 'lua', name = 'feature', kind = 'module' })
    )
    rt.write(path .. '/lua/host/feature.lua', 'return { answer = 42 }\n')
    rt.write(
      path .. '/scripts/game/demo.lua',
      'assert(require("host.feature").answer == 42)\n' .. rt.read(path .. '/scripts/game/demo.lua')
    )
    assert(run({ build .. '/game_demo_lua' }, root):find('Lua says: 42', 1, true))
    rt.write(path .. '/scripts/override.lua', 'print("alternate script")\n')
    assert(
      run({ build .. '/game_demo_lua', path .. '/scripts/override.lua' }, root):find(
        'alternate script',
        1,
        true
      )
    )
    rt.write(path .. '/scripts/broken.lua', 'error("expected script error")\n')
    assert(
      rt.run({ build .. '/game_demo_lua', path .. '/scripts/broken.lua' }, { cwd = root }).code ~= 0
    )
    native_builds = native_builds + 1
  end
end
-- Ordinary external CMake projects gain an extension, never a Rivet manifest.
local external = root .. '/external-c'
rt.mkdir(external)
rt.write(
  external .. '/CMakeLists.txt',
  '# Preserve this project\ncmake_minimum_required(VERSION 3.30)\nproject(external LANGUAGES C)\n'
)
local external_plan = embedding.plan(external, { name = 'example' })
assert(external_plan.files['.rivet.json'] == nil)
project.apply(external, external_plan)
assert(not rt.exists(external .. '/.rivet.json'))
if cmake and ninja then
  run({ cmake, '-S', external, '-B', external .. '/build', '-G', 'Ninja' })
  run({ cmake, '--build', external .. '/build' })
  assert(run({ external .. '/build/example_lua' }, root):find('Lua says: 42', 1, true))
  native_builds = native_builds + 1
end
-- All source collisions and symlinks fail before touching the native manifest.
rt.mkdir(external .. '/scripts')
rt.write(external .. '/scripts/taken.lua', '-- mine\n')
local before = rt.read(external .. '/CMakeLists.txt')
rejects(function()
  embedding.plan(external, { name = 'taken' })
end)
rejects(function()
  embedding.plan(external, { name = '../escape' })
end)
assert(rt.read(external .. '/CMakeLists.txt') == before)
run({ 'ln', '-s', root, external .. '/scripts/linked' })
rejects(function()
  embedding.plan(external, { name = 'linked/escape' })
end)
-- Rust single packages and generated workspaces retain their main/library files.
local rust_paths = {}
for _, kind in ipairs({ 'app', 'workspace' }) do
  local path = owned('rust', kind)
  local prefix = kind == 'workspace' and 'crates/host/' or ''
  local main = rt.read(path .. '/' .. prefix .. 'src/main.rs')
  local before_cargo = rt.read(path .. '/' .. prefix .. 'Cargo.toml')
  local plan = embedding.plan(path, { name = 'example' })
  assert(rt.read(path .. '/' .. prefix .. 'src/main.rs') == main, 'Preview changed Rust main')
  assert(not plan.files[prefix .. 'src/main.rs'], 'Embedding would rewrite Rust main')
  assert(not rt.exists(path .. '/' .. prefix .. 'examples/example.rs'))
  local example_header = require('rivet.headers').render(
    plan.spec.comment_header,
    { filename = prefix .. 'examples/example.rs', project = plan.spec.name }
  )
  local script_header = require('rivet.lua_headers').render(
    plan.spec.comment_header,
    { filename = 'scripts/example.lua', project = plan.spec.name }
  )
  assert(plan.files[prefix .. 'examples/example.rs']:sub(1, #example_header) == example_header)
  assert(plan.files['scripts/example.lua']:sub(1, #script_header) == script_header)
  local cargo = plan.files[prefix .. 'Cargo.toml']
  assert(cargo:sub(1, #before_cargo) == before_cargo)
  assert(cargo:find('version = "=0.12.2"', 1, true))
  assert(cargo:find('features = ["lua54", "vendored"]', 1, true))
  local relative = kind == 'workspace' and '../../../' or '../'
  assert(
    plan.files[prefix .. 'examples/example.rs']:find(
      'include_str!("' .. relative .. 'scripts/example.lua")',
      1,
      true
    )
  )
  project.apply(path, plan)
  assert(rt.read(path .. '/' .. prefix .. 'src/main.rs') == main)
  project.apply(
    path,
    project.file_plan(path, { language = 'lua', name = 'feature', kind = 'module' })
  )
  rt.write(path .. '/lua/host/feature.lua', 'return { answer = 42 }\n')
  rt.write(
    path .. '/scripts/example.lua',
    'assert(require("host.feature").answer == 42)\n' .. rt.read(path .. '/scripts/example.lua')
  )
  rejects(function()
    embedding.plan(path, { name = 'another' })
  end)
  rust_paths[#rust_paths + 1] = path
end
local rust_external = root .. '/external-rust'
rt.mkdir(rust_external)
rt.write(
  rust_external .. '/Cargo.toml',
  '[package]\nname="external"\nversion="0.1.0"\nedition="2024"\n'
)
local rust_plan = embedding.plan(rust_external, { name = 'example' })
assert(not rust_plan.files['.rivet.json'])
rt.write(
  rust_external .. '/Cargo.toml',
  '[package]\nname="external"\nversion="0.1.0"\n[dependencies]\nmlua={version="0.11",features=["luajit"]}\n'
)
rejects(function()
  embedding.plan(rust_external, { name = 'example' })
end)
assert(not rt.exists(rust_external .. '/scripts'))
rt.write(
  rust_external .. '/Cargo.toml',
  '[package]\nname="external"\nversion="0.1.0"\n[[example]]\nname="example"\npath="custom/demo.rs"\n'
)
rejects(function()
  embedding.plan(rust_external, { name = 'example' })
end)
assert(not rt.exists(rust_external .. '/scripts'))
local cargo = rt.executable('cargo')
if cargo then
  -- --offline is essential: this test never downloads the pinned binding/runtime.
  for _, rust_path in ipairs(rust_paths) do
    local result = rt.run(
      { cargo, 'run', '--offline', '--example', 'example' },
      { cwd = rust_path }
    )
    if result.code == 0 then
      assert(result.stdout:find('Lua says: 42', 1, true))
      print('Rust mlua example compiled and ran with cached dependencies: ' .. rust_path)
    elseif
      result.stderr:find('offline', 1, true)
      or result.stderr:find('no matching package', 1, true)
      or result.stderr:find('failed to select a version', 1, true)
    then
      print(
        'SKIP Rust runtime build: pinned mlua 0.12.2 dependencies are not cached for offline resolution'
      )
      break
    else
      error('Rust example failed: ' .. result.stdout .. result.stderr)
    end
  end
end
print(
  'Lua embedding previews, ownership, collisions, stale plans, and '
    .. native_builds
    .. ' native hosts passed: '
    .. root
)
