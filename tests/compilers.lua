local repo = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/compilers%.lua$') or '.'
package.path = repo .. '/lua/?.lua;' .. package.path
local rt, json = require('rivet.runtime'), require('rivet.json')
local project, compilers = require('rivet.project'), require('rivet.compilers')
local tmp = rt.run({ 'mktemp', '-d' }).stdout:gsub('%s+$', '')
local function run(argv, cwd)
  local result = rt.run(argv, { cwd = cwd })
  assert(result.code == 0, table.concat(argv, ' ') .. '\n' .. result.stdout .. result.stderr)
  return result.stdout
end
local root = tmp .. '/project with spaces'
project.apply(root, project.plan({ name = 'compiler_test', standard = 20, modules = false }, root))
local original = rt.read(root .. '/.rivet.json')
-- Fake drivers verify discovery, versioned names, alias deduplication, and failures.
local bin = tmp .. '/bin'
rt.mkdir(bin)
for name, banner in pairs({
  ['clang++-21'] = 'clang version 21.1.0',
  ['g++-16'] = 'g++ (GCC) 16.1.0',
  ['clang++-99'] = 'unrelated program',
}) do
  rt.write(bin .. '/' .. name, '#!/bin/sh\nprintf "%s\\n" ' .. rt.quote(banner) .. '\n')
  rt.chmod(bin .. '/' .. name, tonumber('755', 8))
end
run({ 'ln', '-s', bin .. '/clang++-21', bin .. '/clang++' })
local found = compilers.discover({ path = bin, directories = { bin } })
assert(#found == 2)
assert(found[1].family == 'Clang' and found[2].family == 'GCC')
assert(not pcall(compilers.plan, root, bin .. '/clang++-99'))
-- Older generated recipes are upgraded together with their manifest snapshot.
local legacy = '# Previous generated Just recipes\n'
local manifest = json.decode(original)
manifest.template_baselines.justfile = legacy
rt.write(root .. '/justfile', legacy)
rt.write(root .. '/.rivet.json', json.encode(manifest))
original = rt.read(root .. '/.rivet.json')
local a = compilers.plan(root, bin .. '/clang++-21')
assert(
  rt.read(root .. '/.rivet.json') == original and not rt.read(root .. '/CMakeUserPresets.json')
)
project.apply(root, a)
assert(rt.read(root .. '/justfile'):find('RivetJust.cmake', 1, true))
local local_path = root .. '/CMakeUserPresets.json'
local settings = json.decode(rt.read(local_path))
settings.vendor = { ['example.org/test'] = { kept = true } }
settings.configurePresets[1].cacheVariables.MY_OPTION = 'ON'
rt.write(local_path, json.encode(settings))
local first = require('rivet.cmake').context(root, 'debug', { tasks = true })
assert(first.build_preset == 'local-debug' and first.test_preset == 'local-debug')
local b = compilers.plan(root, bin .. '/g++-16')
project.apply(root, b)
local second = require('rivet.cmake').context(root, 'debug', { tasks = true })
assert(first.binaryDir ~= second.binaryDir)
assert(second.cache.MY_OPTION == 'ON')
assert(json.decode(rt.read(local_path)).vendor['example.org/test'].kept)
project.apply(root, compilers.plan(root, bin .. '/clang++-21'))
assert(require('rivet.cmake').context(root, 'debug').binaryDir == first.binaryDir)
local stale = compilers.plan(root, bin .. '/g++-16')
rt.write(local_path, rt.read(local_path) .. '\n')
assert(not pcall(project.apply, root, stale), 'Stale preview was accepted')
-- User recipes survive selection.
rt.write(root .. '/justfile', '# custom recipes\n')
local preview_before = rt.read(local_path)
local preview = run({
  'lua',
  rt.absolute(repo .. '/bin/rivet.lua'),
  'compiler',
  bin .. '/g++-16',
  '--root',
  root,
  '--preview',
})
assert(preview:find('CMakeUserPresets.json', 1, true))
assert(rt.read(local_path) == preview_before)
local custom = compilers.plan(root, bin .. '/g++-16')
assert(
  not custom.files.justfile
    and table.concat(custom.notes):find('Preserved custom justfile', 1, true)
)
-- Toolchain-file presets must not be silently overridden.
settings = json.decode(rt.read(local_path))
settings.configurePresets[1].toolchainFile = '${sourceDir}/toolchain.cmake'
rt.write(local_path, json.encode(settings))
assert(not pcall(compilers.plan, root, bin .. '/g++-16'))
print('ok - discovery, isolated presets, preservation, and review safety')
-- Real configure/build/test/run across installed native toolchains.
local real = compilers.discover()
local built = 0
for _, compiler in ipairs(real) do
  if compiler.path:find('clang++', 1, true) or compiler.path:find('g++', 1, true) then
    local directory = tmp .. '/real-' .. tostring(built)
    project.apply(
      directory,
      project.plan({ name = 'switch_test', standard = 20, modules = false }, directory)
    )
    for _, choice in ipairs({ real[1], compiler }) do
      project.apply(directory, compilers.plan(directory, choice.path))
      if rt.executable('just') then
        run({ 'just', 'test' }, directory)
        assert(run({ 'just', 'run' }, directory):find('Worker 0:', 1, true))
      else
        run({ 'cmake', '--preset', 'local-debug' }, directory)
        run({ 'cmake', '--build', '--preset', 'local-debug' }, directory)
        run({ 'ctest', '--preset', 'local-debug' }, directory)
      end
    end
    built = built + 1
    print('ok - native switch/build/test: ' .. compiler.label)
  end
end
assert(built > 0, 'No native C++ compiler available')
run({ 'rm', '-rf', tmp })
