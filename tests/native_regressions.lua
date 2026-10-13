local repo = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/native_regressions%.lua$')
  or '.'
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local rt, json, project, model =
  require('rivet.runtime'), require('rivet.json'), require('rivet.project'), require('rivet.model')
local base = project.canonical(
  assert(rt.run({ 'mktemp', '-d', '/tmp/rivet-native-regressions.XXXXXX' }).stdout:match('%S+'))
)
local passed, failed = 0, 0
local function test(name, fn)
  local ok, message = pcall(fn)
  if ok then
    passed = passed + 1
    print('ok - ' .. name)
  else
    failed = failed + 1
    io.stderr:write('FAIL - ' .. name .. ': ' .. tostring(message) .. '\n')
  end
end
local function rejects(fn)
  local ok, message = pcall(fn)
  assert(not ok, 'Expected rejection')
  return tostring(message)
end
local function write(root, path, text)
  rt.mkdir(rt.dirname(rt.confined(root, path)))
  rt.write(rt.confined(root, path), text)
end
local function create(language, name, extra)
  local options = extra or {}
  options.language, options.name = language, name
  local root = rt.join(base, name)
  local plan = project.plan(options, root)
  assert(not rt.exists(root), 'Preview wrote files')
  project.apply(root, plan)
  return root, plan.spec
end
local function task(root, name)
  local tasks = require('rivet.tasks')
  local plan = tasks.plan(root, 'debug', nil, { task = name })
  local argv, cwd = tasks.command(root, plan, name)
  return rt.run(argv, { cwd = cwd })
end
local function succeeded(result)
  assert(result.code == 0, result.stdout .. result.stderr)
end

test('conflicting native project names are rejected while defaults are normalized', function()
  for _, name in ipairs({ 'unittest', 'compileall', 'pytest', 'ruff', 'build' }) do
    assert(model.default_name(name, 'python') == 'project_' .. name)
    rejects(function()
      model.plan({ language = 'python', name = name })
    end)
    assert(
      model.normalize({ language = 'python', name = name }).name == name,
      'Legacy Python manifest cannot be inspected'
    )
  end
  rejects(function()
    model.plan({ language = 'rust', name = 'std' })
  end)
  assert(model.default_name('std', 'rust') == 'project_std')
  rejects(function()
    model.plan({ language = 'c', name = 'stdio' })
  end)
  assert(model.default_name('stdio', 'c') == 'project_stdio')
  assert(model.normalize({ language = 'c', name = 'stdio' }).name == 'stdio')
  for _, name in ipairs({ 'core', 'alloc' }) do
    assert(model.plan({ language = 'rust', name = name }).spec.name == name)
  end
  local rust = model.plan({ language = 'rust', name = 'sample' })
  assert(model.add_file(rust.spec, { name = 'std.rs' }).files['src/std.rs'])
end)

test('legacy Python unittest and compileall projects cannot falsely pass', function()
  for _, name in ipairs({ 'unittest', 'compileall' }) do
    local root = rt.join(base, 'legacy_' .. name)
    rt.mkdir(root)
    local prefix = 'src/' .. name .. '/'
    write(root, prefix .. '__init__.py', 'def add(a, b):\n    return a + b\n')
    write(root, prefix .. '__main__.py', 'print("SHADOW RUNNER EXECUTED")\n')
    write(root, 'tests/test_core.py', 'raise RuntimeError("The test must fail")\n')
    write(root, prefix .. 'invalid.py', 'invalid syntax !!!\n')
    write(
      root,
      '.rivet.json',
      json.encode({
        schema_version = 1,
        language = 'python',
        name = name,
        kind = 'app',
        files = {
          prefix .. '__init__.py',
          prefix .. '__main__.py',
          prefix .. 'invalid.py',
          'tests/test_core.py',
        },
        targets = {},
      })
    )
    local result = task(root, name == 'unittest' and 'test' or 'build')
    assert(result.code ~= 0, result.stdout .. result.stderr)
    assert(not (result.stdout .. result.stderr):find('SHADOW RUNNER EXECUTED', 1, true))
  end
end)

test(
  'external Python runner discovery ignores cwd shadows and preserves import settings',
  function()
    local root = rt.join(base, 'external_python')
    rt.mkdir(root)
    write(root, 'pyproject.toml', '[project]\nname="external-python"\nversion="0.1.0"\n')
    write(
      root,
      'unittest.py',
      'open("runner-executed", "w").write("bad")\nprint("SHADOW RUNNER EXECUTED")\n'
    )
    write(
      root,
      'compileall.py',
      'open("runner-executed", "w").write("bad")\nprint("SHADOW RUNNER EXECUTED")\n'
    )
    write(root, 'tests/test_fail.py', 'raise RuntimeError("The test must fail")\n')
    assert(task(root, 'test').code ~= 0)
    assert(not rt.exists(rt.join(root, 'runner-executed')))
    write(root, 'src/example/__init__.py', 'def answer():\n    return 42\n')
    write(
      root,
      'tests/test_fail.py',
      'import os\nimport unittest\nimport example\nclass EnvironmentTests(unittest.TestCase):\n    def test_environment(self):\n        self.assertEqual(example.answer(), 42)\n        self.assertEqual(os.environ["RIVET_TEST_ENV"], "kept")\n'
    )
    project.apply(
      root,
      require('rivet.task_options').plan(
        root,
        { env = { PYTHONPATH = rt.join(root, 'src'), RIVET_TEST_ENV = 'kept' } }
      )
    )
    succeeded(task(root, 'test'))
    write(root, 'src/invalid.py', 'invalid syntax !!!\n')
    assert(task(root, 'build').code ~= 0)
    assert(not rt.exists(rt.join(root, 'runner-executed')))
  end
)

test('normal Python tests keep the selected interpreter and application src imports', function()
  local root = create('python', 'normal_python')
  local python = require('rivet.native_tasks').python(root, {})
  project.apply(root, require('rivet.task_options').plan(root, { python = python }))
  succeeded(task(root, 'build'))
  succeeded(task(root, 'test'))
  assert(task(root, 'run').stdout:find('42', 1, true))
  local has_pytest = rt.run({ python, '-E', '-P', '-c', 'import pytest' }).code == 0
  if has_pytest then
    project.apply(
      root,
      require('rivet.task_options').plan(root, { python = python, test_runner = 'pytest' })
    )
    succeeded(task(root, 'test'))
  end
end)

test('Python Doctor discovers installed runners without project shadows', function()
  local root = create('python', 'doctor_python')
  local python = require('rivet.native_tasks').python(root, {})
  local environment = rt.join(root, 'tool-environment')
  succeeded(rt.run({ python, '-E', '-P', '-m', 'venv', '--without-pip', environment }))
  project.apply(
    root,
    require('rivet.task_options').plan(root, { python = rt.join(environment, 'bin/python') })
  )
  write(root, 'ruff.py', 'raise RuntimeError("This is application source, not Ruff")\n')
  write(root, 'build.py', 'raise RuntimeError("This is application source, not build")\n')
  local result = rt.run(
    { rt.absolute(repo .. '/bin/rivet'), 'doctor', '--root', root },
    { cwd = root }
  )
  succeeded(result)
  assert(result.stdout:find('WARN: ruff missing in this interpreter', 1, true), result.stdout)
  assert(result.stdout:find('WARN: build missing in this interpreter', 1, true), result.stdout)
end)

test(
  'Rust run selection rejects ambiguous binary names and accepts exact package targets',
  function()
    if not rt.executable('cargo') then
      print('SKIP Rust binary selection: Cargo is unavailable')
      return
    end
    local root = rt.join(base, 'ambiguous_rust')
    write(root, 'Cargo.toml', '[workspace]\nmembers=["a", "b"]\nresolver="3"\n')
    for _, name in ipairs({ 'a', 'b' }) do
      write(
        root,
        name .. '/Cargo.toml',
        '[package]\nname="'
          .. name
          .. '"\nversion="0.1.0"\nedition="2024"\n[[bin]]\nname="tool"\npath="src/main.rs"\n'
      )
      write(root, name .. '/src/main.rs', 'fn main() {}\n')
    end
    write(root, 'a/src/bin/solo.rs', 'fn main() {}\n')
    local native = require('rivet.native_tasks')
    local message = rejects(function()
      native.tasks(root, 'debug', 'tool', { task = 'run' })
    end)
    assert(message:find('Ambiguous Cargo binary', 1, true), message)
    assert(message:find('a::tool, b::tool', 1, true), message)
    local exact = table.concat(native.tasks(root, 'debug', 'a::tool', { task = 'run' }).run, ' ')
    assert(exact:find('--package a --bin tool --', 1, true), exact)
    local unique = table.concat(native.tasks(root, 'debug', 'solo', { task = 'run' }).run, ' ')
    assert(unique:find('--package a --bin solo --', 1, true), unique)
  end
)

test('native source templates accept optional extensions and explicit relative paths', function()
  for _, case in ipairs({
    { 'python', 'py', 'src/sample/feature.py' },
    { 'rust', 'rs', 'src/feature.rs' },
    { 'swift', 'swift', 'Sources/sampleCore/feature.swift' },
    { 'c', 'c', 'src/feature.c' },
  }) do
    local language, extension, expected = case[1], case[2], case[3]
    local plan = model.plan({ language = language, name = 'sample' })
    assert(model.add_file(plan.spec, { name = 'feature.' .. extension }).files[expected], language)
    local explicit = model.add_file(plan.spec, { name = 'custom/nested/feature.' .. extension })
    assert(explicit.files['custom/nested/feature.' .. extension], language)
    for _, path in ipairs({
      '../feature',
      '/feature',
      'custom/../feature',
      'custom//feature',
      'custom/feature/',
    }) do
      rejects(function()
        model.add_file(plan.spec, { name = path })
      end)
    end
    if language == 'rust' then
      assert(explicit.files['custom/nested/feature.rs']:find('mod feature;', 1, true))
    end
  end
end)

test('C and Swift unknown explicit targets are rejected', function()
  for _, language in ipairs({ 'c', 'swift' }) do
    local plan = model.plan({ language = language, name = 'sample' })
    assert(rejects(function()
      model.add_file(plan.spec, { name = 'feature', target = 'missing' })
    end):find('Unknown target', 1, true))
  end
end)

test('C headers and pairs use project protection and actual include directories', function()
  for _, guard in ipairs({ 'ifndef', 'pragma' }) do
    local name = guard == 'ifndef' and model.default_name('stdio', 'c') or 'c_' .. guard
    local root = create('c', name, { header_guard = guard })
    local pair = project.file_plan(root, { name = 'features/deep/feature.c', kind = 'pair' })
    assert(pair.files['features/deep/feature.c'] and pair.files['features/deep/feature.h'])
    assert(
      pair.files['features/deep/feature.h']:find(
        guard == 'pragma' and '#pragma once' or '#ifndef',
        1,
        true
      )
    )
    assert(
      pair.files['cmake/RivetTargets.cmake']:find('${PROJECT_SOURCE_DIR}/features/deep', 1, true)
    )
    project.apply(root, pair)
    project.apply(root, project.file_plan(root, { name = 'public/extra.h', kind = 'header' }))
    succeeded(rt.run({ 'cmake', '--preset', 'debug' }, { cwd = root }))
    succeeded(rt.run({ 'cmake', '--build', '--preset', 'debug' }, { cwd = root }))
    succeeded(rt.run({ 'ctest', '--preset', 'debug' }, { cwd = root }))
  end
end)

test(
  'native supplementary templates preserve source/native manifests and actual C targets',
  function()
    for _, language in ipairs({ 'python', 'rust', 'swift', 'c' }) do
      local plan = model.plan({ language = language, name = 'sample' })
      local spec = plan.spec
      if language == 'c' then
        spec = model.add_target(spec, { name = 'utility', kind = 'app' }).spec
      end
      local files = model.provider(spec).upgrade_files(spec)
      assert(files['README.md'] and files['AGENTS.md'] and files['.editorconfig'])
      assert(not files['pyproject.toml'] and not files['Cargo.toml'] and not files['Package.swift'])
      for path in pairs(files) do
        assert(
          not path:match('%.py$')
            and not path:match('%.rs$')
            and not path:match('%.swift$')
            and not path:match('%.c$')
            and not path:match('%.h$'),
          'Upgrade included application source: ' .. path
        )
      end
      if language == 'c' then
        assert(files['cmake/RivetTargets.cmake']:find('add_executable(utility', 1, true))
      end
    end
  end
)

test('external C embedding targets remain separate and reject unsafe generic mutations', function()
  local plan = model.plan({ language = 'c', name = 'sample' })
  local spec = plan.spec
  spec.files[#spec.files + 1] = 'examples/embed/main.c'
  spec.targets[#spec.targets + 1] =
    { name = 'embed', type = 'executable', sources = { 'examples/embed/main.c' }, external = true }
  local files = model.provider(spec).upgrade_files(spec)
  assert(not files['cmake/RivetTargets.cmake']:find('add_executable(embed', 1, true))
  assert(rejects(function()
    model.add_file(spec, { name = 'feature', target = 'embed' })
  end):find('Embedding targets', 1, true))
  assert(rejects(function()
    model
      .provider(spec)
      .lifecycle(spec, { action = 'move', from = 'examples/embed/main.c', to = 'examples/embed/other.c' }, {})
  end):find('Embedding targets', 1, true))
end)

print(string.format('%d passed, %d failed; fixtures: %s', passed, failed, base))
os.exit(failed == 0 and 0 or 1)
