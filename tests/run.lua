-- Run with lua tests/run.lua or luajit tests/run.lua. No external Lua libraries.
local script = debug.getinfo(1, 'S').source:sub(2)
local root = script:match('^(.*)/tests/run%.lua$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local model = require('rivet.model')
local passed, failed = 0, 0
local function check(value, message)
  if not value then
    error(message or 'assertion failed', 2)
  end
  return value
end
local function eq(actual, expected, message)
  check(
    actual == expected,
    (message or 'values differ')
      .. ': expected '
      .. tostring(expected)
      .. ', got '
      .. tostring(actual)
  )
end
local function has(value, fragment, message)
  check(
    type(value) == 'string' and value:find(fragment, 1, true),
    message or ('missing ' .. fragment)
  )
end
local function lacks(value, fragment, message)
  check(
    type(value) == 'string' and not value:find(fragment, 1, true),
    message or ('unexpected ' .. fragment)
  )
end
local function rejects(fn, message)
  local ok = pcall(fn)
  check(not ok, message or 'expected rejection')
end
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write('ok - ' .. name .. '\n')
  else
    failed = failed + 1
    io.stderr:write('FAIL - ' .. name .. ': ' .. tostring(err) .. '\n')
  end
end
local function snapshot(value)
  if type(value) ~= 'table' then
    return type(value) .. ':' .. tostring(value)
  end
  local keys, out = {}, {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    out[#out + 1] = snapshot(key) .. '=' .. snapshot(value[key])
  end
  return '{' .. table.concat(out, ',') .. '}'
end
local function content(plan, path)
  local value = plan.files[path]
  if type(value) == 'string' then
    return value
  end
  if type(value) == 'table' then
    return value.content
  end
  for _, entry in ipairs(plan.files) do
    if entry.path == path then
      return entry.content
    end
  end
  return nil
end
local function each_file(plan, fn)
  for key, value in pairs(plan.files) do
    if type(key) == 'string' then
      fn(key, type(value) == 'string' and value or value.content)
    else
      fn(value.path, value.content)
    end
  end
end
local function find_file(plan, suffix)
  local path, body
  each_file(plan, function(candidate, value)
    if candidate:sub(-#suffix) == suffix then
      path, body = candidate, value
    end
  end)
  return path, body
end
local function target(spec)
  for _, item in ipairs(spec.targets) do
    if item.type == 'static' or item.kind == 'library' then
      return item.name
    end
  end
  return spec.targets[1].name
end
local function base(opts)
  opts = opts or {}
  opts.name = opts.name or 'engine'
  return model.plan(opts)
end

test('default project requests C++26 and registers module file sets', function()
  local plan = base()
  check(type(plan.spec) == 'table' and type(plan.files) == 'table')
  local cmake = check(content(plan, 'CMakeLists.txt'), 'CMakeLists.txt missing')
  local targets = check(content(plan, 'cmake/RivetTargets.cmake'))
  has(cmake .. targets, 'CXX_STANDARD 26')
  has(targets, 'CXX_MODULES')
  local _, interface = find_file(plan, '.cppm')
  has(interface, 'export module ')
  check(content(plan, 'CMakePresets.json'))
  check(content(plan, '.clang-format'))
  check(content(plan, '.clang-tidy'))
  check(content(plan, '.clangd'))
end)

test('CPM bootstrap keeps its pinned checksum verification intact', function()
  local cpm = check(content(base(), 'cmake/CPM.cmake'), 'cmake/CPM.cmake missing')
  has(cpm, 'releases/download/v0.43.1/CPM.cmake')
  has(cpm, '\n  list(GET _wb_download_status 0 _wb_download_code)\n')
  lacks(cpm, 'spec_helpers')
end)
test('standards enforce module boundaries and preserve old manifests', function()
  for _, standard in ipairs({ 17, 20, 23, 26 }) do
    local plan = base({ standard = standard, modules = false })
    has(
      plan.files['cmake/RivetTargets.cmake'],
      'CXX_STANDARD ' .. standard .. ' CXX_STANDARD_REQUIRED YES'
    )
    has(plan.files['README.md'], 'C++' .. standard)
    has(plan.files['AGENTS.md'], 'C++' .. standard)
    if standard >= 20 then
      check(base({ standard = standard }).spec.modules)
    end
  end
  eq(base({ standard = 17 }).spec.modules, false)
  rejects(function()
    base({ standard = 17, modules = true })
  end)
  rejects(function()
    base({ standard = 20, std_modules = true })
  end)
  for _, standard in ipairs({ 11, 14, 22, 27 }) do
    rejects(function()
      base({ standard = standard })
    end)
  end
  local old = base().spec
  old.module_layout = nil
  eq(model.normalize(old).module_layout, 'split')
  eq(old.module_layout, nil)
end)

test('single-file modules contain both declarations and definitions without a companion', function()
  local plan = base({ standard = 20, module_layout = 'single' })
  has(
    plan.files['src/core/core.cppm'],
    'WorkRange partition_work(int total, int workers, int index) {'
  )
  check(not plan.files['src/core/core.cpp'])
  lacks(plan.files['cmake/RivetTargets.cmake'], '/src/core/core.cpp"')
  rejects(function()
    base({ module_layout = 'combined' })
  end)
  local std = base({ standard = 23, std_modules = true, module_layout = 'single' })
  has(std.files['CMakeLists.txt'], 'rivet_check_std_modules(23)')
end)

test('provider profiles contain reusable choices without user identity or project data', function()
  local spec = base({
    name = 'engine',
    standard = 20,
    compiler = '/machine/clang++',
    comment_header = { style = 'compact', author = 'Ada Lovelace' },
  }).spec
  local profile = model.profile(spec)
  eq(profile.standard, 20)
  eq(profile.language, 'cpp')
  for _, key in ipairs({
    'name',
    'compiler',
    'comment_header',
    'files',
    'targets',
    'dependencies',
    'git',
  }) do
    eq(profile[key], nil)
  end
  check(#model.questions('new', spec) > 0)
  check(#model.questions('file', spec) > 0)
end)

test('module scanning rejects Unix Makefiles', function()
  rejects(function()
    base({ modules = true, generator = 'Unix Makefiles' })
  end)
end)

test('header projects support Make without module scanning', function()
  local plan = base({ modules = false, generator = 'Unix Makefiles' })
  has(content(plan, 'CMakePresets.json'), 'Unix Makefiles')
  lacks(content(plan, 'cmake/RivetTargets.cmake'), 'CXX_MODULES')
  local cmake = content(plan, 'CMakeLists.txt') .. content(plan, 'cmake/RivetTargets.cmake')
  has(cmake, 'CXX_SCAN_FOR_MODULES')
  has(cmake, 'OFF')
end)

test('standard-library modules are opt-in and older manifests preserve includes', function()
  local default = base()
  eq(default.spec.std_modules, false)
  local _, main = find_file(default, 'main.cpp')
  has(main, '#include <iostream>')
  lacks(main, 'import std;')
  lacks(content(default, 'CMakeLists.txt'), 'StandardModules.cmake')
  lacks(content(default, 'cmake/RivetTargets.cmake'), 'CXX_MODULE_STD ON')
  default.spec.std_modules = nil
  local next_plan = model.add_target(default.spec, { name = 'viewer', kind = 'app' })
  eq(next_plan.spec.std_modules, false)
  local _, source = find_file(next_plan, '.cpp')
  lacks(source, 'import std;')
end)

test('standard-library module options reject non-booleans and Make', function()
  for _, value in ipairs({ 'true', 'false', 0, 1, {} }) do
    rejects(function()
      base({ std_modules = value })
    end, 'accepted non-boolean std_modules')
  end
  for _, modules in ipairs({ false, true }) do
    rejects(function()
      base({ modules = modules, std_modules = true, generator = 'Unix Makefiles' })
    end, 'accepted import std with Make')
  end
end)

test(
  'standard-library modules configure before compiler discovery and enable C++26 scanning',
  function()
    for _, modules in ipairs({ false, true }) do
      local plan = base({ modules = modules, std_modules = true })
      local cmake = content(plan, 'CMakeLists.txt')
      local helper =
        check(content(plan, 'cmake/StandardModules.cmake'), 'std modules helper missing')
      local include_at = check(cmake:find('StandardModules.cmake', 1, true))
      local project_at = check(cmake:find('project(', 1, true))
      check(include_at < project_at, 'experimental gate must be set before project()')
      has(helper, 'CMAKE_EXPERIMENTAL_CXX_IMPORT_STD')
      has(cmake .. helper, 'CMAKE_CXX_COMPILER_IMPORT_STD')
      local targets = content(plan, 'cmake/RivetTargets.cmake')
      has(targets, 'CXX_MODULE_STD ON')
      has(targets, 'CXX_SCAN_FOR_MODULES ON')
      if not modules then
        lacks(targets, 'TYPE CXX_MODULES')
      end
      local _, main = find_file(plan, 'main.cpp')
      has(main, 'import std;')
      lacks(main, '#include <iostream>')
    end
  end
)

test('new module templates import std after their module declaration', function()
  local original = base({ std_modules = true }).spec
  local selected = target(original)
  local interface = model.add_file(original, {
    name = 'memory/pool',
    kind = 'module',
    module = 'engine.memory.pool',
    target = selected,
  })
  local _, interface_body = find_file(interface, '.cppm')
  check(
    interface_body:find('export module engine.memory.pool;', 1, true)
      < check(interface_body:find('import std;', 1, true)),
    'std import precedes module declaration'
  )
  local implementation = model.add_file(interface.spec, {
    name = 'memory/pool_impl',
    kind = 'module_impl',
    module = 'engine.memory.pool',
    target = selected,
  })
  local _, implementation_body = find_file(implementation, '.cpp')
  check(
    implementation_body:find('module engine.memory.pool;', 1, true)
      < check(implementation_body:find('import std;', 1, true)),
    'std import precedes implementation declaration'
  )
  for _, kind in ipairs({ 'source', 'pair', 'class' }) do
    local added =
      model.add_file(implementation.spec, { name = 'Extra', kind = kind, target = selected })
    local _, source = find_file(added, '.cpp')
    has(source, 'import std;')
    local _, header = find_file(added, '.hpp')
    if header then
      lacks(header, 'import std;', 'headers must remain textually includable')
    end
  end
  local app = model.add_target(implementation.spec, { name = 'viewer', kind = 'app' })
  local _, app_source = find_file(app, '.cpp')
  has(app_source, 'import std;')
  has(content(app, 'cmake/RivetTargets.cmake'), 'CXX_MODULE_STD ON')
end)

test('layout choices produce distinct source organization', function()
  local outputs = {}
  for _, layout in ipairs({ 'flat', 'feature', 'library' }) do
    local plan = base({ layout = layout, modules = false })
    local paths = {}
    each_file(plan, function(path)
      if path:match('%.cpp$') or path:match('%.hpp$') then
        paths[#paths + 1] = path
      end
    end)
    table.sort(paths)
    outputs[layout] = table.concat(paths, ',')
    check(#paths > 0, 'layout has no C++ files')
  end
  check(
    outputs.flat ~= outputs.feature
      and outputs.flat ~= outputs.library
      and outputs.feature ~= outputs.library,
    'each offered layout should change the source tree'
  )
end)

test('generated paths stay relative to the project', function()
  each_file(base(), function(path, body)
    check(path:sub(1, 1) ~= '/' and not path:find('..', 1, true), 'unsafe generated path: ' .. path)
    check(type(body) == 'string', 'file content must be text')
    check(body:sub(-1) == '\n', 'generated text must end with newline: ' .. path)
  end)
end)

test('invalid project names and unknown options fail', function()
  for _, name in ipairs({ '../escape', '/absolute', 'x;message(FATAL_ERROR)', 'x\nboom' }) do
    rejects(function()
      base({ name = name })
    end, 'accepted unsafe project name ' .. name)
  end
  for _, opts in ipairs({
    { style = 'not-a-style' },
    { layout = 'not-a-layout' },
    { generator = 'Xcode' },
    { kind = 'unknown' },
  }) do
    rejects(function()
      base(opts)
    end)
  end
end)

test('chosen formatting and guard style are project-local', function()
  local pragma = base({ modules = false, style = 'Google', header_guard = 'pragma' })
  has(content(pragma, '.clang-format'), 'Google')
  local _, pheader = find_file(pragma, '.hpp')
  has(pheader, '#pragma once')
  local guarded = base({ modules = false, style = 'Microsoft', header_guard = 'ifndef' })
  local _, gheader = find_file(guarded, '.hpp')
  has(gheader, '#ifndef ')
  has(gheader, '#define ')
  has(gheader, '#endif')
  lacks(gheader, '#pragma once')
end)

test('adding a source/header pair registers both and leaves input unchanged', function()
  local original = base({ modules = false }).spec
  local before = snapshot(original)
  local plan =
    model.add_file(original, { name = 'memory/page', kind = 'pair', target = target(original) })
  eq(snapshot(original), before, 'mutation changed the caller spec')
  local source, source_body = find_file(plan, '.cpp')
  local header, header_body = find_file(plan, '.hpp')
  check(source and header and source_body and header_body, 'pair must create a source and header')
  has(source_body, '#include ')
  local cmake = content(plan, 'cmake/RivetTargets.cmake')
  has(cmake, source)
  has(cmake, header)
  rejects(function()
    model.add_file(plan.spec, { name = 'memory/page', kind = 'pair', target = target(plan.spec) })
  end)
end)

test('adding module interface and implementation preserves registration categories', function()
  local spec = base().spec
  local destination = target(spec)
  local iface = model.add_file(
    spec,
    { name = 'memory/page', kind = 'module', module = 'engine.memory', target = destination }
  )
  local iface_path, iface_body = find_file(iface, '.cppm')
  has(iface_body, 'export module engine.memory;')
  has(content(iface, 'cmake/RivetTargets.cmake'), iface_path)
  local implementation = model.add_file(iface.spec, {
    name = 'memory/page_impl',
    kind = 'module_impl',
    module = 'engine.memory',
    target = destination,
  })
  local implementation_path, implementation_body = find_file(implementation, '.cpp')
  has(implementation_body, 'module engine.memory;')
  lacks(implementation_body, 'export module')
  local selected
  for _, item in ipairs(implementation.spec.targets) do
    if item.name == destination then
      selected = item
    end
  end
  local found_source, found_module = false, false
  for _, path in ipairs(selected.sources) do
    if path == implementation_path then
      found_source = true
    end
  end
  for _, path in ipairs(selected.modules) do
    if path == implementation_path then
      found_module = true
    end
  end
  check(found_source and not found_module, 'implementation must be an ordinary source')
  rejects(function()
    model.add_file(
      implementation.spec,
      { name = 'memory/another', kind = 'module', module = 'engine.memory', target = destination }
    )
  end, 'duplicate named module should be rejected')
end)

test('file mutations reject escaped paths and missing targets', function()
  local spec = base().spec
  for _, name in ipairs({
    '../evil',
    '/tmp/evil',
    'a/../../evil',
    'a\\..\\evil',
    'a;evil',
    'a\nboom',
  }) do
    rejects(function()
      model.add_file(spec, { name = name, kind = 'source', target = target(spec) })
    end, 'accepted unsafe file ' .. name)
  end
  rejects(function()
    model.add_file(spec, { name = 'valid', kind = 'source', target = 'missing' })
  end)
  rejects(function()
    model.add_file(spec, { name = 'valid', kind = 'unknown', target = target(spec) })
  end)
  rejects(function()
    model.add_file(spec, { name = 'impl', kind = 'module_impl', target = target(spec) })
  end)
end)

test('new target is registered and duplicate/unsafe names fail', function()
  local spec = base().spec
  local before = snapshot(spec)
  local plan = model.add_target(spec, { name = 'renderer', kind = 'library' })
  eq(snapshot(spec), before)
  has(content(plan, 'cmake/RivetTargets.cmake'), 'renderer')
  rejects(function()
    model.add_target(plan.spec, { name = 'renderer', kind = 'library' })
  end)
  rejects(function()
    model.add_target(spec, { name = '../renderer', kind = 'library' })
  end)
  rejects(function()
    model.add_target(spec, { name = 'valid', kind = 'unknown' })
  end)
end)

test('dependency mutation pins source and links the selected target', function()
  local spec = base().spec
  local before = snapshot(spec)
  local plan = model.add_dependency(spec, {
    name = 'fmt',
    repository = 'fmtlib/fmt',
    version = '11.2.0',
    target = 'fmt::fmt',
    link_to = target(spec),
  })
  eq(snapshot(spec), before)
  local dependencies = content(plan, 'cmake/Dependencies.cmake')
  has(dependencies, 'fmtlib/fmt')
  has(dependencies, '11.2.0')
  has(content(plan, 'cmake/RivetTargets.cmake'), 'fmt::fmt')
  rejects(function()
    model.add_dependency(plan.spec, {
      name = 'fmt',
      repository = 'fmtlib/fmt',
      version = '11.2.0',
      target = 'fmt::fmt',
      link_to = target(spec),
    })
  end)
  rejects(function()
    model.add_dependency(spec, {
      name = 'fmt',
      repository = 'fmtlib/fmt',
      version = '11.2.0',
      target = 'fmt::fmt',
      link_to = 'missing',
    })
  end)
end)

test('dependency and module identifiers cannot inject CMake or C++', function()
  local spec = base().spec
  for _, name in ipairs({ 'bad;name', 'bad-name', 'bad\nname', '../bad' }) do
    rejects(function()
      model.add_file(
        spec,
        { name = 'valid', kind = 'module', module = name, target = target(spec) }
      )
    end)
  end
  rejects(function()
    model.add_dependency(spec, {
      name = 'fmt',
      repository = 'fmtlib/fmt;evil',
      version = '11.2.0',
      target = 'fmt::fmt',
      link_to = target(spec),
    })
  end)
  rejects(function()
    model.add_dependency(spec, {
      name = 'fmt',
      repository = 'fmtlib/fmt',
      version = 'v1\nset(EVIL ON)',
      target = 'fmt::fmt',
      link_to = target(spec),
    })
  end)
end)

test('language provider registry dispatches without replacing built-ins', function()
  local provider = {}
  function provider.normalize(opts)
    return { language = 'testlang', name = opts.name or 'example' }
  end
  function provider.plan(opts)
    return { spec = provider.normalize(opts), files = { ['main.test'] = 'example\n' } }
  end
  function provider.add_file(spec, opts)
    return { spec = spec, files = { [opts.name] = 'file\n' } }
  end
  provider.add_target = provider.add_file
  provider.add_dependency = provider.add_file
  model.register('testlang', provider)
  check(model.supports('testlang') and model.supports('cpp'))
  local planned = model.plan({ language = 'testlang', name = 'custom' })
  eq(planned.spec.name, 'custom')
  eq(planned.files['main.test'], 'example\n')
  eq(model.add_file(planned.spec, { name = 'extra.test' }).files['extra.test'], 'file\n')
  rejects(function()
    model.register('cpp', provider)
  end)
  rejects(function()
    model.register('broken', {})
  end)
  rejects(function()
    model.plan({ language = 'unknown_language' })
  end)
end)

test('folder names become valid default C++ names without changing explicit names', function()
  for folder, name in pairs({
    engine = 'engine',
    ['my-engine'] = 'my_engine',
    ['123 My__Engine'] = 'project_123_My_Engine',
    class = 'project_class',
    std = 'project_std',
    std23 = 'project_std23',
    ['---'] = 'project',
  }) do
    eq(model.default_name(folder, 'cpp'), name)
    eq(model.plan({ name = name }).spec.name, name)
  end
  rejects(function()
    model.plan({ name = 'my-engine' })
  end)
end)

test('comment header styles use only supplied fields and preserve editable metadata', function()
  local headers = require('rivet.headers')
  local values = {
    author = 'Ada Lovelace',
    email = 'ada@example.test',
    organization = 'Example Lab',
    created = 'today',
    copyright = '2026 Example Lab',
    license = 'MIT',
    description = 'Work partitioning.',
  }
  for _, style in ipairs(headers.styles) do
    values.style = style.id
    local body =
      headers.render(values, { filename = 'src/core.cpp', project = 'engine', date = '2026-10-09' })
    if style.id == 'none' then
      eq(body, '')
    else
      has(body, 'core.cpp')
      has(body, 'engine')
      eq(headers.leading(body .. 'export module engine.core;\n'), #body)
      local extracted = headers.extract(body)
      eq(extracted.author, values.author)
      eq(extracted.email, values.email)
      eq(extracted.copyright, values.copyright)
      eq(extracted.created, '2026-10-09')
      eq(extracted.license, values.license)
    end
  end
  local body = headers.render({ style = 'xcode' }, { filename = 'core.cpp' })
  lacks(body, 'Copyright')
  lacks(body, 'SPDX')
end)

test('comment header values cannot escape comments or contain malformed dates', function()
  local headers = require('rivet.headers')
  for _, value in ipairs({
    'name\nint injected;',
    'name\r',
    'name\0',
    '*/ code',
    'name\\',
    false,
    7,
  }) do
    rejects(function()
      headers.normalize({ style = 'compact', author = value })
    end)
  end
  for _, date in ipairs({ 'yesterday', '2026-02-29', '2026-13-01', '2026-01-00' }) do
    rejects(function()
      headers.normalize({ created = date })
    end)
  end
  eq(headers.normalize({ created = '2024-02-29' }).created, '2024-02-29')
  rejects(function()
    headers.normalize({ style = 'spdx' })
  end)
end)

test('leading comment detection never consumes adjacent code', function()
  local headers = require('rivet.headers')
  for _, body in ipairs({
    '/* license */ int main() {}\n',
    '// escaped\\\nint main() {}\n',
    '/* unfinished\nint main() {}\n',
    'export module engine;\n',
  }) do
    eq(headers.leading(body), 0)
  end
  local body = '\n/* header */\n\n  int x;\n'
  eq(body:sub(headers.leading(body) + 1), '  int x;\n')
  body = '// header\n// author\n\n// useful code comment\nint x;\n'
  eq(body:sub(headers.leading(body) + 1), '// useful code comment\nint x;\n')
end)

test('project header defaults reach new source, module, pair, and target templates', function()
  local plan = base({ comment_header = { style = 'xcode', author = 'Ada Lovelace' } })
  each_file(plan, function(path, body)
    if path:match('%.cpp[m]?$') then
      has(body, 'Author: Ada Lovelace')
    end
  end)
  for _, kind in ipairs({ 'source', 'pair', 'class', 'module' }) do
    local next_plan =
      model.add_file(plan.spec, { name = 'extra', kind = kind, target = target(plan.spec) })
    each_file(next_plan, function(path, body)
      if path:match('%.cpp[m]?$') or path:match('%.hpp$') then
        has(body, 'Author: Ada Lovelace')
      end
    end)
  end
  local next_plan = model.add_target(plan.spec, { name = 'viewer', kind = 'app' })
  local _, body = find_file(next_plan, '.cpp')
  has(body, 'Author: Ada Lovelace')
end)

test('native names use complete language-specific keyword rules', function()
  for language, names in pairs({
    python = { 'lambda', 'False', 'with', 'nonlocal', 'raise' },
    rust = { 'gen', 'abstract', 'become', 'unsized', 'typeof' },
    swift = { 'nil', 'rethrows', 'typealias', 'fallthrough' },
    c = { 'int', 'typedef', 'restrict', 'sizeof' },
  }) do
    local plan = model.plan({ language = language, name = 'sample' })
    for _, name in ipairs(names) do
      rejects(function()
        model.plan({ language = language, name = name })
      end)
      rejects(function()
        model.add_file(plan.spec, { name = name })
      end)
      rejects(function()
        model.add_target(plan.spec, { name = name })
      end)
      has(model.default_name(name, language), 'project_')
    end
  end
  eq(model.plan({ language = 'python', name = 'fn' }).spec.name, 'fn')
  eq(model.plan({ language = 'rust', name = 'lambda' }).spec.name, 'lambda')
  eq(model.plan({ language = 'rust', name = 'gen', edition = '2021' }).spec.name, 'gen')
end)

test('module refactoring skips literals but handles numeric separators', function()
  local input = [[export module old.name;
constexpr auto count = 1'000;
constexpr auto bits = 0xDEAD'BEEF;
constexpr auto ratio = 1.2'3e+4;
const char quote = '\'';
const char* text = "import old.name;";
auto raw = R"tag(import old.name;)tag";
// import old.name;
import old.name;
]]
  local text, count = require('rivet.lifecycle').module_references(input, 'old.name', 'new.name')
  eq(count, 2)
  has(text, 'export module new.name;')
  has(text, '\nimport new.name;')
  has(text, '"import old.name;"')
  has(text, "1'000")
end)

test('module refactoring preserves encoding-prefixed raw string payloads', function()
  for _, prefix in ipairs({ 'R', 'u8R', 'uR', 'UR', 'LR' }) do
    local literal = 'auto text = ' .. prefix .. '"tag(example " import old.name; )tag";'
    local text, count = require('rivet.lifecycle').module_references(
      'export module old.name;\n' .. literal .. '\nimport old.name;\n',
      'old.name',
      'new.name'
    )
    eq(count, 2)
    has(text, literal)
    has(text, 'export module new.name;')
    has(text, '\nimport new.name;')
  end
end)

test('ordinary application JSON stays visible in native task output', function()
  local diagnostics = require('rivet.native_diagnostics')
  local render = diagnostics.render
  eq(diagnostics.render_for({ 'python', '-m', 'sample' }), nil)
  eq(diagnostics.render_for({ './rust_binary' }), nil)
  eq(diagnostics.render_for({ 'cargo', 'build', '--message-format=json' }), render)
  for _, line in ipairs({
    '{"reason":"completed","count":42}',
    '{"reason":"unknown"}',
    '{"reason":"compiler-artifact"}',
    '{"reason":"build-finished","success":"maybe"}',
    '{"reason":"compiler-message","message":{}}',
  }) do
    eq(render(line), line)
    eq(diagnostics.parse(line, '/tmp'), nil)
  end
  eq(
    diagnostics.parse(
      '{"reason":"compiler-message","message":{"message":"application data","spans":[{"is_primary":true}]}}',
      '/tmp'
    ),
    nil
  )
end)

io.write(string.format('\n%d passed; %d failed (%s)\n', passed, failed, _VERSION))
os.exit(failed == 0 and 0 or 1)
