-- Standalone provider checks, including real Lua/LuaJIT/Neovim processes.
local repo = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/lua_provider%.lua$') or '.'
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local rt, project, model =
  require('rivet.runtime'), require('rivet.project'), require('rivet.model')
local provider = require('rivet.languages.lua')
if not model.supports('lua') then
  model.register('lua', provider)
end
local base = project.canonical(
  assert(rt.run({ 'mktemp', '-d', '/tmp/rivet-lua-provider.XXXXXX' }).stdout:match('%S+'))
)
local passed, failed, skipped = 0, 0, 0
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
  assert(not pcall(fn), 'Expected rejection')
end
local function create(name, opts)
  opts = opts or {}
  opts.language, opts.name = 'lua', name
  local root = rt.join(base, name)
  local plan = project.plan(opts, root)
  assert(not rt.exists(root), 'Preview wrote files')
  project.apply(root, plan)
  return root, plan.spec
end
local function task(root, name, target, expected)
  local tasks = require('rivet.tasks')
  local plan = tasks.plan(root, 'debug', target, { task = name })
  local argv, cwd = tasks.command(root, plan, name)
  local value = rt.run(argv, { cwd = cwd })
  assert(
    value.code == (expected or 0),
    table.concat(argv, ' ') .. '\n' .. value.stdout .. value.stderr
  )
  return value
end
local function read(root, path)
  return assert(rt.read(rt.confined(root, path)))
end

test('Lua options reject keywords, invalid paths, and incompatible plugin runtimes', function()
  for _, name in ipairs({
    'and',
    'end',
    'function',
    'goto',
    'repeat',
    'math',
    'package',
    'ffi',
    'vim',
  }) do
    rejects(function()
      provider.plan({ name = name })
    end)
    assert(provider.default_name(name):match('^project_'))
  end
  for _, path in ipairs({ '../escape', '/absolute', 'lua/../escape', 'lua//extra', 'lua/extra/' }) do
    rejects(function()
      provider.file_template({ name = path })
    end)
  end
  assert(provider.plan({ name = 'plug', kind = 'plugin' }).spec.runtime == 'neovim')
  rejects(function()
    provider.plan({ name = 'plug', kind = 'plugin', runtime = 'lua' })
  end)
  rejects(function()
    provider.plan({ name = 'sample', runtime = 'unknown' })
  end)
end)

test('Lua comment headers remain executable-safe and round-trip fields', function()
  local headers = require('rivet.lua_headers')
  for _, style in ipairs({ 'compact', 'xcode', 'spdx', 'doc' }) do
    local text = headers.render(
      { style = style, author = 'Ada', license = 'MIT', description = 'Lua module' },
      { filename = 'feature.lua', project = 'sample' }
    )
    assert(not text:find('//', 1, true) and not text:find('/*', 1, true))
    assert(headers.extract(text).author == 'Ada')
    assert(headers.leading(text .. 'return {}\n') == #text)
    local loaded, err = (loadstring or load)(text .. 'return {}\n')
    assert(loaded, err)
  end
  assert(require('rivet.lua_headers').leading('--[[ long comment ]] return {}\n') == 0)
end)

for _, runtime in ipairs({ 'lua', 'luajit', 'neovim' }) do
  local command = runtime == 'neovim' and 'nvim' or runtime
  if not rt.executable(command) then
    skipped = skipped + 1
    print('SKIP - runtime not installed: ' .. runtime)
  else
    test(runtime .. ' app builds, tests, runs and checks source without executing it', function()
      local root = create(
        'app_' .. runtime,
        { runtime = runtime, comment_header = { style = 'compact', author = 'Ada' } }
      )
      local run = task(root, 'run')
      assert((run.stdout .. run.stderr):find('42', 1, true))
      local correctness = task(root, 'test')
      assert(
        (correctness.stdout .. correctness.stderr):find('Lua correctness tests passed', 1, true)
      )
      local extra = project.file_plan(root, { name = 'scripts/nested/danger', kind = 'script' })
      project.apply(root, extra)
      rt.write(
        rt.confined(root, 'scripts/nested/danger.lua'),
        'error("Check executed a source file")\n'
      )
      project.apply(
        root,
        require('rivet.task_options').plan(root, {
          env = { LUA_INIT = '@' .. rt.confined(root, 'scripts/nested/danger.lua') },
        })
      )
      task(root, 'check')
      task(root, 'build')
      rt.write(rt.confined(root, 'scripts/nested/danger.lua'), 'local invalid = !!!\n')
      local result = task(root, 'check', nil, 1)
      assert((result.stdout .. result.stderr):find('danger.lua', 1, true))
      rt.write(
        rt.confined(root, 'scripts/nested/danger.lua'),
        provider.bootstrap('scripts/nested/danger.lua')
          .. 'local project = require("app_'
          .. runtime
          .. '")\nprint(project.add(20, 22))\n'
      )
      local opts = require('rivet.task_options').plan(root, { cwd = 'scripts' })
      project.apply(root, opts)
      local nested = task(root, 'run', 'scripts_nested_danger')
      assert((nested.stdout .. nested.stderr):find('42', 1, true))
    end)
  end
end

test('Lua library mutations add modules and explicitly selected script targets', function()
  local root, spec = create('library_demo', { kind = 'library' })
  assert(not rt.exists(rt.join(root, 'main.lua')))
  assert(not require('rivet.lua_tasks').names(root)[7])
  project.apply(root, project.file_plan(root, { name = 'tools/helper.lua', kind = 'module' }))
  assert(read(root, 'tools/helper.lua'):find('return M', 1, true))
  project.apply(root, project.file_plan(root, { name = 'extra' }))
  assert(read(root, 'lua/library_demo/extra.lua'):find('return M', 1, true))
  rejects(function()
    project.file_plan(root, { name = 'wrong', target = 'missing' })
  end)
  project.apply(root, project.target_plan(root, { name = 'utility', kind = 'app' }))
  project.apply(root, project.target_plan(root, { name = 'helpers', kind = 'library' }))
  project.apply(root, project.file_plan(root, { name = 'more', target = 'helpers' }))
  assert(read(root, 'lua/helpers/more.lua'):find('return M', 1, true))
  assert(task(root, 'run', 'utility').stdout:find('Hello from utility', 1, true))
  rejects(function()
    task(root, 'run', 'missing')
  end)
  assert(spec.kind == 'library')
end)

test('Lua supplementary upgrade defaults contain no source entrypoints', function()
  local spec = provider.plan({ name = 'sample', kind = 'plugin' }).spec
  local files = provider.upgrade_files(spec)
  assert(
    files['.luarc.json']
      and files['.stylua.toml']
      and files['AGENTS.md']
      and files['doc/sample.txt']
  )
  for path in pairs(files) do
    assert(not path:match('%.lua$'), 'Upgrade included source file: ' .. path)
  end
  local map = { ['scripts/foreign.lua'] = 'lua' }
  spec.file_languages = map
  assert(provider.normalize(spec).file_languages['scripts/foreign.lua'] == 'lua')
end)

if rt.executable('nvim') then
  test('Neovim plugin smoke test loads guard, user command, and setup API', function()
    local root = create('plugin_demo', { kind = 'plugin' })
    assert(read(root, 'plugin/plugin_demo.lua'):find('loaded_plugin_demo', 1, true))
    assert(read(root, 'doc/plugin_demo.txt'):find('*plugin_demo.txt*', 1, true))
    task(root, 'check')
    task(root, 'test')
    rejects(function()
      task(root, 'run')
    end)
    local report = require('rivet.lua_doctor').inspect(root)
    assert(report[1].level == 'ok')
  end)
end

test('Missing optional tools and runtime errors are clear without installation', function()
  local root = create('tools_demo')
  local original = rt.executable
  rt.executable = function(name)
    if name == 'stylua' or name == 'luacheck' or name == 'not-a-lua-runtime' then
      return false
    end
    return original(name)
  end
  local ok, err = pcall(function()
    task(root, 'check')
    rejects(function()
      task(root, 'format')
    end)
    rejects(function()
      task(root, 'lint')
    end)
    rejects(function()
      require('rivet.lua_tasks').runtime({ runtime = 'lua' }, { lua = 'not-a-lua-runtime' })
    end)
  end)
  rt.executable = original
  assert(ok, err)
end)

test('Lua diagnostics include syntax errors and luacheck columns', function()
  local diagnostics = require('rivet.lua_diagnostics')
  local error = assert(diagnostics.parse('/tmp/main.lua:12: unexpected symbol near !', base))
  assert(error.filename == '/tmp/main.lua' and error.lnum == 12 and error.type == 'E')
  local warning =
    assert(diagnostics.parse('lua/project/init.lua:4:9: (W211) unused variable', base))
  assert(
    warning.filename == rt.join(base, 'lua/project/init.lua')
      and warning.col == 9
      and warning.type == 'W'
  )
end)

print(string.format('%d passed, %d failed, %d skipped', passed, failed, skipped))
os.exit(failed == 0 and 0 or 1)
