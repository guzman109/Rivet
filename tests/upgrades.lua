-- Reviewed template upgrades preserve user code, edits, permissions, and provenance.
local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/upgrades%.lua$') or '.'
package.path = root .. '/lua/?.lua;' .. package.path
local rt, json = require('rivet.runtime'), require('rivet.json')
local model, project = require('rivet.model'), require('rivet.project')
local upgrade = require('rivet.upgrade')
local temporary = assert(
  rt.run({ 'mktemp', '-d', rt.join(os.getenv('TMPDIR') or '/tmp', 'rivet-upgrades.XXXXXX') }).stdout
    :match('%S+')
)
local latest, passed = {}, 0
local provider = {
  normalize = function(opts)
    return json.decode(json.encode(opts))
  end,
  upgrade_files = function()
    return json.decode(json.encode(latest))
  end,
}
for _, name in ipairs({ 'plan', 'add_file', 'add_target', 'add_dependency' }) do
  provider[name] = function()
    error('An upgrade must not regenerate a project')
  end
end
model.register('upgrade_fixture', provider)

local function fixture(name, files, baselines, generated)
  local directory = rt.join(temporary, name)
  rt.mkdir(directory)
  files['src/custom.cc'] = files['src/custom.cc'] or '// User implementation.\n'
  files['tests/custom_test.cc'] = files['tests/custom_test.cc'] or '// User test.\n'
  local spec = {
    schema_version = 1,
    language = 'upgrade_fixture',
    name = 'custom_project',
    rivet_version = baselines and '0.0.1' or nil,
    template_baselines = baselines,
    generated = generated,
    files = json.array(),
    targets = json.array({
      { name = 'custom_engine', sources = json.array({ 'src/custom.cc' }) },
      { name = 'custom_test', test = true, sources = json.array({ 'tests/custom_test.cc' }) },
    }),
  }
  for path, content in pairs(files) do
    rt.mkdir(rt.dirname(rt.join(directory, path)))
    rt.write(rt.join(directory, path), content)
    spec.files[#spec.files + 1] = path
  end
  table.sort(spec.files)
  rt.write(rt.join(directory, '.rivet.json'), json.encode(spec))
  return directory, spec
end

local function test(name, fn)
  fn()
  passed = passed + 1
  print('ok - ' .. name)
end
local function notes(plan, fragment)
  assert(table.concat(plan.notes, '\n'):find(fragment, 1, true), 'Missing note: ' .. fragment)
end
local function rejects(fn, fragment)
  local ok, err = pcall(fn)
  assert(not ok, 'Expected rejection')
  assert(tostring(err):find(fragment, 1, true), tostring(err))
end

local ok, err = pcall(function()
  test(
    'unchanged supplementary and managed files upgrade without regenerating user code',
    function()
      local directory, before = fixture('unchanged', {
        ['.clang-format'] = 'old style\n',
        ['cmake/RivetTargets.cmake'] = 'old targets\n',
        ['retired.cmake'] = 'retained retired template\n',
      }, {
        ['.clang-format'] = 'old style\n',
        ['retired.cmake'] = 'retained retired template\n',
      }, { ['cmake/RivetTargets.cmake'] = 'old targets\n' })
      latest = {
        ['.clang-format'] = 'new style\n',
        ['cmake/RivetTargets.cmake'] = 'new targets\n',
        ['src/custom.cc'] = '// Replacement source.\n',
        ['tests/custom_test.cc'] = '// Replacement test.\n',
      }
      rt.chmod(rt.join(directory, '.clang-format'), tonumber('600', 8))
      rt.chmod(rt.join(directory, 'cmake/RivetTargets.cmake'), tonumber('640', 8))
      local manifest = rt.read(rt.join(directory, '.rivet.json'))
      local plan = upgrade.plan(directory)
      assert(rt.read(rt.join(directory, '.rivet.json')) == manifest, 'Preview changed the manifest')
      assert(
        rt.read(rt.join(directory, '.clang-format')) == 'old style\n',
        'Preview wrote a template'
      )
      assert(plan.files['.clang-format'] == 'new style\n')
      assert(plan.expected['.clang-format'] == 'old style\n')
      assert(plan.spec.generated['cmake/RivetTargets.cmake'] == 'new targets\n')
      assert(plan.files['src/custom.cc'] == nil and plan.files['tests/custom_test.cc'] == nil)
      assert(plan.files['retired.cmake'] == nil, 'Retired file was deleted')
      notes(plan, 'application sources and tests are preserved')
      project.apply(directory, plan)
      local after = project.load(directory)
      assert(after.rivet_version == require('rivet.version'))
      assert(after.template_baselines['.clang-format'] == 'new style\n')
      assert(after.template_baselines['cmake/RivetTargets.cmake'] == 'new targets\n')
      assert(after.template_baselines['retired.cmake'] == 'retained retired template\n')
      assert(
        json.encode(before.targets) == json.encode(after.targets),
        'Target identity was changed'
      )
      assert(rt.read(rt.join(directory, 'src/custom.cc')) == '// User implementation.\n')
      assert(rt.read(rt.join(directory, 'tests/custom_test.cc')) == '// User test.\n')
      assert(rt.read(rt.join(directory, 'retired.cmake')) == 'retained retired template\n')
      assert(rt.mode(rt.join(directory, '.clang-format')) == tonumber('600', 8))
      assert(rt.mode(rt.join(directory, 'cmake/RivetTargets.cmake')) == tonumber('640', 8))
    end
  )

  test('conflicts preserve user edits and their original baselines', function()
    local directory = fixture('conflicts', {
      ['.clang-format'] = 'my custom style\n',
      ['.clangd'] = 'old clangd\n',
      ['README.md'] = 'My project documentation.\n',
    }, { ['.clang-format'] = 'old style\n', ['.clangd'] = 'old clangd\n' })
    latest = {
      ['.clang-format'] = 'new style\n',
      ['.clangd'] = 'new clangd\n',
      ['README.md'] = 'New generated documentation.\n',
    }
    local plan = upgrade.plan(directory)
    assert(plan.files['.clang-format'] == nil and plan.files['README.md'] == nil)
    assert(plan.spec.template_baselines['.clang-format'] == 'old style\n')
    assert(plan.spec.template_baselines['README.md'] == nil, 'Custom file was claimed')
    notes(plan, 'Skipped .clang-format: local edits conflict')
    notes(plan, 'Skipped README.md: original template provenance is unavailable')
    project.apply(directory, plan)
    assert(rt.read(rt.join(directory, '.clang-format')) == 'my custom style\n')
    assert(rt.read(rt.join(directory, 'README.md')) == 'My project documentation.\n')
    assert(rt.read(rt.join(directory, '.clangd')) == 'new clangd\n')
  end)

  test('missing known supplements are recreated without recreating missing source code', function()
    local directory = fixture('missing', {}, { ['.clangd'] = 'old clangd\n' })
    assert(os.remove(rt.join(directory, 'src/custom.cc')))
    latest = {
      ['.clangd'] = 'current clangd\n',
      ['.editorconfig'] = 'current editor config\n',
      ['src/custom.cc'] = '// Regenerated implementation.\n',
    }
    local plan = upgrade.plan(directory)
    assert(plan.expected['.clangd'] == false and plan.expected['.editorconfig'] == false)
    assert(plan.files['src/custom.cc'] == nil, 'Missing source was recreated')
    project.apply(directory, plan)
    assert(rt.read(rt.join(directory, '.clangd')) == 'current clangd\n')
    assert(rt.read(rt.join(directory, '.editorconfig')) == 'current editor config\n')
    assert(not rt.exists(rt.join(directory, 'src/custom.cc')))
    assert(project.load(directory).template_baselines['.editorconfig'] == 'current editor config\n')
  end)

  test('destination and ancestor collisions are skipped without claiming ownership', function()
    local directory = fixture('collisions', { cmake = 'This is a user file.\n' })
    rt.mkdir(rt.join(directory, '.clangd'))
    assert(rt.run({ 'mkfifo', rt.join(directory, '.clang-tidy') }).code == 0)
    latest = {
      ['.clangd'] = 'template\n',
      ['cmake/Options.cmake'] = 'template\n',
      ['.clang-tidy'] = 'template\n',
    }
    local plan = upgrade.plan(directory)
    assert(plan.files['.clangd'] == nil and plan.files['cmake/Options.cmake'] == nil)
    assert(plan.spec.template_baselines['.clangd'] == nil)
    notes(plan, 'the destination is a directory')
    notes(plan, 'a parent path is not a directory')
    notes(plan, 'the destination is not a regular file')
    assert(plan.files['.clang-tidy'] == nil)
    project.apply(directory, plan)
    assert(rt.is_dir(rt.join(directory, '.clangd')))
    assert(rt.read(rt.join(directory, 'cmake')) == 'This is a user file.\n')
  end)

  test('legacy files need an exact current template or recorded managed baseline', function()
    local directory = fixture(
      'legacy',
      {
        ['.clang-format'] = 'older unrecorded style\n',
        ['.editorconfig'] = 'current editor config\n',
        ['cmake/RivetTargets.cmake'] = 'recorded targets\n',
        ['cmake/Dependencies.cmake'] = 'user dependencies\n',
      },
      nil,
      {
        ['cmake/RivetTargets.cmake'] = 'recorded targets\n',
        ['cmake/Dependencies.cmake'] = 'recorded dependencies\n',
      }
    )
    latest = {
      ['.clang-format'] = 'current style\n',
      ['.editorconfig'] = 'current editor config\n',
      ['cmake/RivetTargets.cmake'] = 'current targets\n',
      ['cmake/Dependencies.cmake'] = 'current dependencies\n',
    }
    local plan = upgrade.plan(directory)
    assert(plan.files['.clang-format'] == nil)
    assert(plan.files['cmake/RivetTargets.cmake'] == 'current targets\n')
    assert(plan.files['.editorconfig'] == 'current editor config\n', 'Adoption lacks a stale check')
    assert(plan.files['cmake/Dependencies.cmake'] == nil)
    assert(plan.spec.generated['cmake/Dependencies.cmake'] == 'recorded dependencies\n')
    notes(plan, 'Original supplementary template provenance is unavailable')
    project.apply(directory, plan)
    local spec = project.load(directory)
    assert(spec.template_baselines['.clang-format'] == nil)
    assert(spec.template_baselines['.editorconfig'] == 'current editor config\n')
    assert(rt.read(rt.join(directory, '.clang-format')) == 'older unrecorded style\n')
    assert(rt.read(rt.join(directory, 'cmake/Dependencies.cmake')) == 'user dependencies\n')
  end)

  test('forward upgrades keep the last applied snapshot until conflicts are reconciled', function()
    local directory = fixture(
      'forward',
      { ['.clang-format'] = 'v1\n' },
      { ['.clang-format'] = 'v1\n' }
    )
    latest = { ['.clang-format'] = 'v2\n' }
    project.apply(directory, upgrade.plan(directory))
    assert(project.load(directory).template_baselines['.clang-format'] == 'v2\n')
    rt.write(rt.join(directory, '.clang-format'), 'my edits\n')
    latest = { ['.clang-format'] = 'v3\n' }
    project.apply(directory, upgrade.plan(directory))
    assert(project.load(directory).template_baselines['.clang-format'] == 'v2\n')
    rt.write(rt.join(directory, '.clang-format'), 'v2\n')
    project.apply(directory, upgrade.plan(directory))
    assert(rt.read(rt.join(directory, '.clang-format')) == 'v3\n')
    assert(project.load(directory).template_baselines['.clang-format'] == 'v3\n')
    assert(upgrade.plan(directory).files['.clang-format'] == nil, 'Current template was rewritten')
  end)

  test('stale changed and adopted templates reject the complete plan before writing', function()
    for _, adopt in ipairs({ false, true }) do
      local baselines
      if not adopt then
        baselines = { ['.clang-format'] = 'old style\n' }
      end
      local directory = fixture(adopt and 'stale-adoption' or 'stale-change', {
        ['.clang-format'] = adopt and 'latest style\n' or 'old style\n',
      }, baselines)
      latest = { ['.clang-format'] = 'latest style\n', ['.editorconfig'] = 'new file\n' }
      local before = rt.read(rt.join(directory, '.rivet.json'))
      local plan = upgrade.plan(directory)
      rt.write(rt.join(directory, '.clang-format'), 'edited after preview\n')
      rejects(function()
        project.apply(directory, plan)
      end, 'File changed since preview: .clang-format')
      assert(rt.read(rt.join(directory, '.rivet.json')) == before)
      assert(not rt.exists(rt.join(directory, '.editorconfig')))
    end
  end)

  test('stale manifest and formatter failure leave all project files untouched', function()
    local directory = fixture(
      'stale-manifest',
      { ['.clang-format'] = 'old\n' },
      { ['.clang-format'] = 'old\n' }
    )
    latest = { ['.clang-format'] = 'new\n' }
    local plan = upgrade.plan(directory)
    local manifest = json.decode(rt.read(rt.join(directory, '.rivet.json')))
    manifest.name = 'changed_after_preview'
    rt.write(rt.join(directory, '.rivet.json'), json.encode(manifest))
    rejects(function()
      project.apply(directory, plan)
    end, 'File changed since preview: .rivet.json')
    assert(rt.read(rt.join(directory, '.clang-format')) == 'old\n')
    provider.formatter = function()
      return { '/bin/sh', '-c', 'exit 1' }
    end
    rejects(function()
      upgrade.plan(directory)
    end, 'Formatting failed')
    provider.formatter = nil
    assert(rt.read(rt.join(directory, '.clang-format')) == 'old\n')
  end)

  test('formatter output matches the applied supplemental snapshot', function()
    local directory = fixture('formatted', { ['.config'] = 'OLD\n' }, { ['.config'] = 'OLD\n' })
    latest = { ['.config'] = 'new\n' }
    provider.formatter = function()
      return { 'tr', 'a-z', 'A-Z' }
    end
    local plan = upgrade.plan(directory)
    assert(plan.files['.config'] == 'NEW\n' and plan.spec.template_baselines['.config'] == 'NEW\n')
    project.apply(directory, plan)
    assert(rt.read(rt.join(directory, '.config')) == 'NEW\n')
    assert(upgrade.plan(directory).files['.config'] == nil)
    provider.formatter = nil
  end)

  test('adopting an already current managed file validates its new generated snapshot', function()
    local directory = fixture('managed-adoption', {
      ['cmake/RivetTargets.cmake'] = 'current targets\n',
    }, {
      ['cmake/RivetTargets.cmake'] = 'current targets\n',
    }, { ['cmake/RivetTargets.cmake'] = 'older targets\n' })
    latest = { ['cmake/RivetTargets.cmake'] = 'current targets\n' }
    local plan = upgrade.plan(directory)
    assert(plan.files['cmake/RivetTargets.cmake'] == 'current targets\n')
    assert(plan.spec.generated['cmake/RivetTargets.cmake'] == 'current targets\n')
    rt.write(rt.join(directory, 'cmake/RivetTargets.cmake'), 'user edit after preview\n')
    rejects(function()
      project.apply(directory, plan)
    end, 'File changed since preview: cmake/RivetTargets.cmake')
  end)

  test('malformed snapshots fail instead of treating an existing file as untracked', function()
    local directory = fixture(
      'malformed',
      { ['.clang-format'] = 'current\n' },
      { ['.clang-format'] = false }
    )
    latest = { ['.clang-format'] = 'current\n' }
    rejects(function()
      upgrade.plan(directory)
    end, 'Invalid template snapshot: .clang-format')
  end)

  test('unsafe paths and symlink destinations fail before writing outside the project', function()
    local directory = fixture('unsafe', {})
    latest = { ['../escape'] = 'template\n' }
    rejects(function()
      upgrade.plan(directory)
    end, 'Path traversal')
    local outside = rt.join(temporary, 'outside')
    rt.write(outside, 'Keep this file.\n')
    assert(rt.run({ 'ln', '-s', outside, rt.join(directory, '.clang-format') }).code == 0)
    latest = { ['.clang-format'] = 'template\n' }
    rejects(function()
      upgrade.plan(directory)
    end, 'Refusing symlink')
    assert(rt.read(outside) == 'Keep this file.\n')
  end)
end)
local removed = rt.run({ 'rm', '-rf', temporary })
assert(removed.code == 0, removed.stderr)
assert(ok, err)
print(passed .. ' upgrade checks passed')
