-- End-to-end coverage for existing projects, lifecycle, native providers, and domain profiles.
local repo = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/batches%.lua$') or '.'
package.path = repo .. '/lua/?.lua;' .. package.path
local rt, project, model =
  require('rivet.runtime'), require('rivet.project'), require('rivet.model')
local base = assert(
  rt.run({ 'mktemp', '-d', rt.join(os.getenv('TMPDIR') or '/tmp', 'rivet-batches.XXXXXX') }).stdout
    :match('%S+')
)
base = project.canonical(base)
local passed, failed, skipped = 0, 0, 0
local function skip(reason)
  error({ skip = reason }, 0)
end
local function test(name, fn)
  if os.getenv('RIVET_TEST_FILTER') and not name:find(os.getenv('RIVET_TEST_FILTER'), 1, true) then
    return
  end
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print('ok - ' .. name)
  elseif type(err) == 'table' and err.skip then
    skipped = skipped + 1
    print('SKIP - ' .. name .. ': ' .. err.skip)
  else
    failed = failed + 1
    io.stderr:write('FAIL - ' .. name .. ': ' .. tostring(err) .. '\n')
  end
end
local function create(name, opts)
  opts.name = name
  local plan = project.plan(opts, rt.join(base, name))
  project.apply(plan.root, plan)
  return plan.root, plan.spec
end
local function task(root, name, preset, target)
  local tasks = require('rivet.tasks')
  local plan = tasks.plan(root, preset, target, { task = name })
  for _, step in ipairs(tasks.sequence(name, plan)) do
    if step == 'configure' and plan.prepare then
      plan.prepare()
    end
    local argv, cwd = tasks.command(root, plan, step)
    local r = rt.run(argv, { cwd = cwd })
    if step == 'run' and r.code == 77 then
      skip('runtime reports unavailable hardware/context')
    end
    assert(r.code == 0, table.concat(argv, ' ') .. '\n' .. r.stdout .. r.stderr)
    if step == 'test' and r.stdout:find('***Skipped', 1, true) then
      skip('CTest reported a skipped runtime check; inspect ' .. root)
    end
    if plan.after_step then
      plan.after_step(step, r)
    end
    if step == 'configure' and plan.after_configure then
      plan.after_configure()
    end
  end
end
local function rejects(fn)
  assert(not pcall(fn), 'Expected rejection')
end
local function read(root, path)
  return assert(rt.read(rt.join(root, path)))
end

test('native Python package test/run and existing environment', function()
  local root = create('python_demo', { language = 'python' })
  task(root, 'test')
  task(root, 'run')
  task(root, 'build')
  assert(read(root, 'pyproject.toml'):find('[project.scripts]', 1, true))
  local plan = project.file_plan(root, { name = 'extra' })
  project.apply(root, plan)
  assert(read(root, 'src/python_demo/extra.py'):find('module', 1, true))
  local p = require('rivet.task_options').plan(root, {
    args = {},
    env = { RIVET_TEST = 'yes' },
    python = require('rivet.native_tasks').python(root, {}),
  })
  project.apply(root, p)
  task(root, 'configure')
  assert(not rt.is_dir(rt.join(root, '.venv')), 'Replaced selected environment')
end)
test('native Rust app, workspace, library, and additional binary', function()
  for _, kind in ipairs({ 'app', 'workspace', 'library' }) do
    local root = create('rust_' .. kind, { language = 'rust', kind = kind })
    task(root, 'test')
    task(root, 'check')
    task(root, 'format')
    task(root, 'lint')
    if kind ~= 'library' then
      task(root, 'run')
    end
    if kind == 'workspace' then
      project.apply(root, project.target_plan(root, { name = 'utility', kind = 'app' }))
      task(root, 'run', nil, 'utility')
    end
  end
end)
test('native SwiftPM app/library build test and metadata', function()
  for _, kind in ipairs({ 'app', 'library' }) do
    local root = create('swift_' .. kind, { language = 'swift', kind = kind })
    task(root, 'test')
    if kind == 'app' then
      task(root, 'run')
    end
    task(root, 'format')
    task(root, 'lint')
    local manifest = read(root, 'Package.swift')
    local customized = manifest:gsub(
      '(name: "' .. 'swift_' .. kind .. '",)',
      '%1\n    platforms: [.macOS(.v13)],',
      1
    )
    assert(customized ~= manifest)
    rt.write(rt.join(root, 'Package.swift'), customized)
    project.apply(root, project.file_plan(root, { name = 'Feature' }))
    assert(read(root, 'Package.swift') == customized, 'Source addition rewrote Package.swift')
    rejects(function()
      project.target_plan(root, { name = 'another', kind = 'app' })
    end)
    task(root, 'build')
  end
end)
test('Doctor reports missing optional Rust tools without installing them', function()
  local root = create('rust_doctor', { language = 'rust' })
  local original = rt.run
  rt.run = function(argv, options)
    if argv[2] == 'fmt' or argv[2] == 'clippy' then
      assert(argv[3] == '--version', 'Doctor tried to modify the project')
      return { code = 1, stdout = '', stderr = 'component is unavailable' }
    end
    return original(argv, options)
  end
  local ok, report = pcall(require('rivet.native_doctor').inspect, root)
  rt.run = original
  assert(ok, report)
  local warnings = {}
  for _, item in ipairs(report) do
    if item.level == 'warn' then
      warnings[#warnings + 1] = item.message
    end
  end
  local text = table.concat(warnings, '\n')
  assert(
    text:find('rustfmt unavailable', 1, true) and text:find('Clippy unavailable', 1, true),
    text
  )
end)
test('C project test, C++ ABI header, and file registration', function()
  local root = create('c_demo', { language = 'c' })
  task(root, 'test')
  task(root, 'run')
  assert(read(root, 'include/c_demo.h'):find('extern "C"', 1, true))
  project.apply(root, project.file_plan(root, { name = 'extra' }))
  task(root, 'build')
end)
test('external CMake without presets discovers and runs File API artifacts', function()
  local root = rt.join(base, 'external')
  rt.mkdir(root)
  rt.write(
    rt.join(root, 'CMakeLists.txt'),
    'cmake_minimum_required(VERSION 3.30)\nproject(example LANGUAGES CXX)\ninclude(CTest)\nadd_executable(sample main.cpp)\nset_target_properties(sample PROPERTIES OUTPUT_NAME renamed RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")\nadd_test(NAME sample COMMAND sample)\n'
  )
  rt.write(rt.join(root, 'main.cpp'), 'int main() { return 0; }\n')
  assert(project.root(root) == root and project.inspect(root).external)
  task(root, 'configure')
  local targets = require('rivet.tasks').targets(root, 'debug')
  local found = false
  for _, t in ipairs(targets) do
    if t.name == 'sample' then
      found = true
    end
  end
  assert(found)
  task(root, 'run', 'debug', 'sample')
  task(root, 'test')
  assert(not rt.exists(rt.join(root, '.rivet.json')))
  local cmake = read(root, 'CMakeLists.txt')
  local plan = project.file_plan(root, { name = 'no_ownership' })
  assert(plan.files['no_ownership.cpp'] and not plan.files['.rivet.json'])
  assert(not plan.files['CMakeLists.txt'] and not rt.exists(rt.join(root, 'no_ownership.cpp')))
  project.apply(root, plan)
  assert(read(root, 'no_ownership.cpp') == plan.files['no_ownership.cpp'])
  assert(read(root, 'CMakeLists.txt') == cmake and not rt.exists(rt.join(root, '.rivet.json')))
  rejects(function()
    project.file_plan(root, { name = 'no_ownership' })
  end)
end)
test('existing CMake discovery skips nested source fragments', function()
  local root = rt.join(base, 'nested_cmake')
  rt.mkdir(rt.join(root, 'src/detail'))
  rt.write(
    rt.join(root, 'CMakeLists.txt'),
    'cmake_minimum_required(VERSION 3.30)\nPROJECT(actual_root LANGUAGES C)\n'
  )
  rt.write(
    rt.join(root, 'src/CMakeLists.txt'),
    '# project(comment)\n#[=[\nproject(bracket_comment)\n]=]\nset(example "project(quoted)")\nadd_library(core core.c)\n'
  )
  rt.write(rt.join(root, 'src/detail/core.c'), 'int answer(void) { return 42; }\n')
  assert(project.root(rt.join(root, 'src/detail/core.c')) == root)
  rt.write(rt.join(root, 'src/CMakeLists.txt'), 'project(independent LANGUAGES C)\n')
  assert(project.root(rt.join(root, 'src/detail')) == rt.join(root, 'src'))
end)
test('CLI run configures and discovers a fresh existing CMake project', function()
  local root = rt.join(base, 'first_existing_run')
  rt.mkdir(root)
  rt.write(
    rt.join(root, 'CMakeLists.txt'),
    'cmake_minimum_required(VERSION 3.30)\nproject(first_run LANGUAGES C)\nadd_executable(sample main.c)\nset_target_properties(sample PROPERTIES OUTPUT_NAME actual_binary RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")\n'
  )
  rt.write(
    rt.join(root, 'main.c'),
    '#include <stdio.h>\nint main(void) { puts("first run succeeded"); }\n'
  )
  local r = rt.run({ rt.join(rt.absolute(repo), 'bin/rivet'), 'run', '--root', root })
  assert(r.code == 0 and r.stdout:find('first run succeeded', 1, true), r.stdout .. r.stderr)
  assert(not rt.exists(rt.join(root, '.rivet.json')))
  rt.write(
    rt.join(root, 'CMakeLists.txt'),
    read(root, 'CMakeLists.txt') .. 'add_executable(second main.c)\n'
  )
  r = rt.run({ rt.join(rt.absolute(repo), 'bin/rivet'), 'run', '--root', root })
  assert(r.code ~= 0 and r.stderr:find('Choose an application', 1, true), r.stdout .. r.stderr)
  r = rt.run({
    rt.join(rt.absolute(repo), 'bin/rivet'),
    'run',
    '--root',
    root,
    '--target',
    'second',
  })
  assert(r.code == 0 and r.stdout:find('first run succeeded', 1, true), r.stdout .. r.stderr)
end)
test('reviewed lifecycle preserves edits, snapshots, and module identities', function()
  local root, spec = create('lifecycle', {
    standard = 26,
    modules = true,
    module_layout = 'single',
    compiler = rt.detect_tools().clangxx,
  })
  local name, entry = next(spec.module_names)
  local before = read(root, entry.path)
  local plan =
    project.lifecycle_plan(root, { action = 'move', from = entry.path, to = 'src/renamed.cppm' })
  assert(plan.files[entry.path] == false and plan.files['src/renamed.cppm'] == before)
  project.apply(root, plan)
  task(root, 'test')
  local main = rt.join(root, 'app/main.cpp')
  local main_text = read(root, 'app/main.cpp')
  main_text = main_text:gsub(
    '(import ' .. name:gsub('%.', '%%.') .. ';)',
    "constexpr auto count = 1'000;\n%1",
    1
  )
  rt.write(main, main_text)
  plan = project.lifecycle_plan(root, { action = 'module', from = name, to = 'lifecycle.renamed' })
  project.apply(root, plan)
  task(root, 'test')
  assert(read(root, 'app/main.cpp'):find('import lifecycle.renamed;', 1, true))
  rejects(function()
    project.lifecycle_plan(root, { action = 'remove', from = 'src/renamed.cppm' })
  end)
  local added = project.file_plan(root, { name = 'extra', kind = 'source' })
  project.apply(root, added)
  local path
  for p in pairs(added.files) do
    if p:match('extra%.cpp$') then
      path = p
    end
  end
  plan = project.lifecycle_plan(root, { action = 'remove', from = path })
  rt.write(rt.join(root, path), read(root, path) .. '// changed after preview\n')
  rejects(function()
    project.apply(root, plan)
  end)
  plan = project.lifecycle_plan(root, { action = 'remove', from = path })
  project.apply(root, plan)
  assert(not rt.exists(rt.join(root, path)))
  task(root, 'test')
  local text =
    '// import old.name;\nconst char* s="import old.name;";\nauto r=R"tag(import old.name;)tag";\nexport module old.name;\nimport old.name;\n'
  local updated, n = require('rivet.lifecycle').module_references(text, 'old.name', 'new.name')
  assert(n == 2 and updated:find('"import old.name;"', 1, true))
end)
test('task settings validate argv and preserve argument boundaries', function()
  local opts = require('rivet.task_options')
  rejects(function()
    opts.validate({ jobs = 0 })
  end)
  rejects(function()
    opts.validate({ cwd = '../escape' })
  end)
  local argv, cwd = opts.command(base, { '/tmp/app' }, {
    args = { 'a b', '$(literal)' },
    threads = 4,
    launcher = { 'mpiexec', '-n', '{ranks}' },
    ranks = 2,
  }, 'run')
  assert(argv[#argv] == '$(literal)' and argv[#argv - 1] == 'a b' and cwd == base)
end)
test('CPU and OpenMP profiles execute correctness checks', function()
  for _, profile in ipairs({ 'cpu', 'openmp' }) do
    local root = create(
      'parallel_' .. profile,
      { profile = profile, standard = 20, modules = false, compiler = rt.detect_tools().clangxx }
    )
    if profile == 'openmp' and rt.is_dir('/opt/homebrew/opt/libomp') then
      local path = rt.join(root, 'CMakeUserPresets.json')
      local json = require('rivet.json')
      local presets = json.decode(read(root, 'CMakeUserPresets.json'))
      for _, p in ipairs(presets.configurePresets) do
        p.cacheVariables.CMAKE_PREFIX_PATH = '/opt/homebrew/opt/libomp'
      end
      rt.write(path, json.encode(presets))
    end
    task(root, 'test')
    task(root, 'run', nil, 'parallel_' .. profile .. '_' .. profile)
  end
end)
test('GPU and MPI profiles register sources, shaders, and independent standards', function()
  for _, profile in ipairs({ 'cuda', 'mpi', 'metal', 'webgpu', 'vulkan', 'opengl' }) do
    local p = model.plan({ name = 'gpu_example', profile = profile, standard = 26 })
    assert(p.files['cmake/Profile.cmake'] and p.files['cmake/ProfileSetup.cmake'])
    model.normalize(p.spec)
    if profile == 'cuda' then
      assert(p.spec.cuda_standard == 20 and p.spec.standard == 26)
      assert(p.files['cmake/Profile.cmake']:find('CUDA_STANDARD_REQUIRED YES', 1, true))
    end
    if profile == 'metal' or profile == 'vulkan' or profile == 'webgpu' or profile == 'opengl' then
      assert(p.files['shaders/triangle.' .. ({
        metal = 'metal',
        webgpu = 'wgsl',
        vulkan = 'vert',
        opengl = 'vert',
      })[profile]])
    end
  end
  rejects(function()
    model.plan({ profile = 'cuda', cuda_standard = 26 })
  end)
  rejects(function()
    model.plan({ profile = 'cuda', cuda_architectures = '86);execute_process(foo)' })
  end)
  rejects(function()
    model.plan({ profile = 'webgpu', standard = 17 })
  end)
end)
test('Metal profile compiles shaders and performs GPU readback', function()
  local sdk = os.getenv('RIVET_METAL_CPP_DIR')
  if not sdk then
    skip('set RIVET_METAL_CPP_DIR to run this hardware check')
  end
  local root = create(
    'metal_demo',
    { profile = 'metal', standard = 17, modules = false, compiler = '/usr/bin/clang++' }
  )
  local json = require('rivet.json')
  local path = rt.join(root, 'CMakeUserPresets.json')
  local presets = json.decode(read(root, 'CMakeUserPresets.json'))
  for _, p in ipairs(presets.configurePresets) do
    p.cacheVariables.RIVET_METAL_CPP_DIR = sdk
  end
  rt.write(path, json.encode(presets))
  task(root, 'test')
  task(root, 'run', nil, 'metal_demo_metal')
end)
test('WebGPU Dawn profile compiles WGSL and performs GPU readback', function()
  local sdk = os.getenv('RIVET_DAWN_DIR')
  if not sdk then
    skip('set RIVET_DAWN_DIR to run this hardware check')
  end
  local root = create(
    'webgpu_demo',
    { profile = 'webgpu', standard = 20, modules = false, compiler = '/usr/bin/clang++' }
  )
  local json = require('rivet.json')
  local path = rt.join(root, 'CMakeUserPresets.json')
  local presets = json.decode(read(root, 'CMakeUserPresets.json'))
  for _, p in ipairs(presets.configurePresets) do
    p.cacheVariables.CMAKE_PREFIX_PATH = sdk
  end
  rt.write(path, json.encode(presets))
  task(root, 'test')
  task(root, 'run', nil, 'webgpu_demo_webgpu')
end)
test('OpenGL profile loads core functions and renders through GLFW', function()
  local sdk = os.getenv('RIVET_GLFW_DIR')
  if not sdk then
    skip('set RIVET_GLFW_DIR to run this hardware check')
  end
  local root = create(
    'opengl_demo',
    { profile = 'opengl', standard = 17, modules = false, compiler = '/usr/bin/clang++' }
  )
  local json = require('rivet.json')
  local path = rt.join(root, 'CMakeUserPresets.json')
  local presets = json.decode(read(root, 'CMakeUserPresets.json'))
  for _, p in ipairs(presets.configurePresets) do
    p.cacheVariables.CMAKE_PREFIX_PATH = sdk
  end
  rt.write(path, json.encode(presets))
  project.apply(root, require('rivet.task_options').plan(root, { args = { '--test' } }))
  task(root, 'test')
  task(root, 'run', nil, 'opengl_demo_opengl')
end)
test('Vulkan starter compiles against Khronos headers', function()
  local headers = os.getenv('RIVET_VULKAN_HEADERS')
  if not headers then
    skip('set RIVET_VULKAN_HEADERS to run the Vulkan syntax check')
  end
  local p = model.plan({ name = 'vk_check', profile = 'vulkan', standard = 17, modules = false })
  local source = rt.join(base, 'vulkan.cpp')
  rt.write(source, p.files['examples/vulkan/main.cpp'])
  local r = rt.run({
    rt.detect_tools().clangxx,
    '-std=c++17',
    '-fsyntax-only',
    '-I',
    headers,
    '-DRIVET_SHADER_DIR="shaders"',
    '-DRIVET_VULKAN_VALIDATION=1',
    source,
  })
  assert(r.code == 0, r.stdout .. r.stderr)
end)
test('managed-file repair preserves edits and stale previews', function()
  local root = create('repair_demo', { standard = 17, modules = false })
  local path = 'cmake/RivetTargets.cmake'
  local original = read(root, path)
  local edited = original .. '\n# custom edit\n'
  rt.write(rt.join(root, path), edited)
  local plan = project.repair_plan(root, path)
  local backup
  for p in pairs(plan.files) do
    if p:match('^%.rivet%-recovery/') then
      backup = p
    end
  end
  assert(backup and plan.files[backup] == edited)
  rt.write(rt.join(root, path), edited .. '# later\n')
  rejects(function()
    project.apply(root, plan)
  end)
  assert(not rt.exists(rt.join(root, backup)))
  plan = project.repair_plan(root, path)
  project.apply(root, plan)
  assert(read(root, path) == original and read(root, backup) == edited .. '# later\n')
  project.apply(root, project.file_plan(root, { name = 'extra', kind = 'source' }))
  task(root, 'test')
end)
test('mixed C and C++ compile and link across the C ABI', function()
  local root, spec =
    create('mixed_demo', { standard = 23, modules = false, compiler = rt.detect_tools().clangxx })
  local target = spec.targets[1].name
  project.apply(
    root,
    project.file_plan(root, { name = 'interop', kind = 'c_source', target = target })
  )
  project.apply(
    root,
    project.file_plan(root, { name = 'interop', kind = 'c_header', target = target })
  )
  rt.write(
    rt.join(root, 'app/main.cpp'),
    '#include "../src/core/interop.h"\nint main() { return interop()==42 ? 0 : 1; }\n'
  )
  task(root, 'test')
  task(root, 'run')
end)
test(
  'Cargo profiling resolves a built artifact and structured diagnostics locate errors',
  function()
    local root = create('profile_rust', { language = 'rust' })
    project.apply(
      root,
      require('rivet.task_options').plan(root, { profile = { 'env', '{executable}' } })
    )
    task(root, 'profile')
    rt.write(rt.join(root, 'src/lib.rs'), 'pub fn add(_: i32, _: i32) -> i32 { missing_value }\n')
    local plan = require('rivet.tasks').plan(root, 'debug', nil, { task = 'build' })
    local argv, cwd = require('rivet.tasks').command(root, plan, 'build')
    local r = rt.run(argv, { cwd = cwd })
    assert(r.code ~= 0)
    local diagnostic
    for line in r.stdout:gmatch('[^\n]+') do
      diagnostic = diagnostic or require('rivet.native_diagnostics').parse(line, root)
    end
    assert(
      diagnostic
        and diagnostic.filename:match('src/lib.rs$')
        and diagnostic.lnum == 1
        and diagnostic.type == 'E'
    )
  end
)
test('Python headers preserve URLs and executable preambles', function()
  local headers = require('rivet.python_headers')
  local text = headers.render(
    { style = 'compact', description = 'https://example.org' },
    { filename = 'main.py', project = 'demo' }
  )
  assert(text:find('https://example.org', 1, true))
  local preamble = '#!/usr/bin/env python3\n# coding: utf-8\n'
  assert(headers.preamble(preamble .. 'print(42)\n') == preamble)
  assert(headers.extract(text).description == 'https://example.org')
end)
test('uv configuration run test format lint and package', function()
  if not os.getenv('RIVET_TEST_UV') then
    skip('set RIVET_TEST_UV=1 to allow dependency installation in a fixture')
  end
  local root = create('uv_demo', { language = 'python', manager = 'uv' })
  task(root, 'configure')
  task(root, 'test')
  task(root, 'run')
  task(root, 'package')
  local install = rt.run(
    { 'uv', 'pip', 'install', '--python', rt.join(root, '.venv/bin/python'), 'ruff' },
    { cwd = root }
  )
  assert(install.code == 0, install.stderr)
  task(root, 'format')
  task(root, 'lint')
  local settings = { python = rt.join(root, '.venv/bin/python') }
  project.apply(root, require('rivet.task_options').plan(root, settings))
  task(root, 'configure')
  assert(rt.read(rt.join(root, 'uv.lock')))
  for _, check in ipairs(require('rivet.native_doctor').inspect(root)) do
    assert(check.level ~= 'error', check.message)
    assert(not check.message:find('build missing', 1, true), 'uv packaging needs no build module')
  end
end)
print(
  string.format('%d passed; %d failed; %d skipped; fixtures: %s', passed, failed, skipped, base)
)
os.exit(failed == 0 and 0 or 1)
