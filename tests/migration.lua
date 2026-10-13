local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/migration%.lua$') or '.'
package.path = root .. '/lua/?.lua;' .. package.path
local rt, project, json = require('rivet.runtime'), require('rivet.project'), require('rivet.json')
local migration = require('rivet.migration')
local temp = assert(
  rt.run({ 'mktemp', '-d', rt.join(os.getenv('TMPDIR') or '/tmp', 'rivet-migration.XXXXXX') }).stdout
    :match('%S+')
)
local count = 0
local function legacy(language, suffix)
  local destination = rt.join(temp, language .. (suffix or ''))
  local modern = project.plan({
    language = language,
    name = 'outset',
    standard = language == 'c' and 17 or nil,
    modules = false,
  }, destination)
  local old = { root = modern.root, spec = modern.spec, files = {}, expected = {} }
  local function prior(text)
    return text:gsub('RIVET', 'OUTSET'):gsub('Rivet', 'Outset'):gsub('rivet', 'outset')
  end
  for path, content in pairs(modern.files) do
    old.files[prior(path)], old.expected[prior(path)] = prior(content), false
  end
  old.spec = json.decode(old.files['.outset.json'])
  project.apply(destination, old)
  rt.write(
    rt.join(destination, '.outset.local.json'),
    '{"args":["engine.outset"],"env":{"OUTSET_CUSTOM":"keep"}}\n'
  )
  return modern.root
end
for _, language in ipairs({ 'cpp', 'c', 'python', 'rust', 'swift' }) do
  local directory = legacy(language)
  local before = rt.read(rt.join(directory, '.outset.json'))
  local plan = migration.plan(directory)
  assert(not rt.exists(rt.join(directory, '.rivet.json')), 'Migration preview wrote files')
  assert(project.root(directory) == directory)
  project.apply(directory, plan)
  assert(not rt.exists(rt.join(directory, '.outset.json')))
  local spec = project.load(directory)
  assert(spec.name == 'outset', 'Application name was changed')
  assert(
    rt.read(rt.join(directory, '.rivet.local.json')):find('OUTSET_CUSTOM', 1, true),
    'User settings changed'
  )
  local found_backup = false
  for path, content in pairs(plan.files) do
    if path:match('^%.rivet%-recovery/.*/%.outset%.json$') then
      assert(content == before)
      found_backup = true
    end
  end
  assert(found_backup, 'Original manifest was not backed up')
  project.apply(directory, project.file_plan(directory, { name = 'extra', kind = 'source' }))
  if language == 'cpp' or language == 'c' then
    local tasks = require('rivet.tasks')
    local workflow = tasks.plan(directory, 'debug', nil, { task = 'test' })
    for _, step in ipairs(tasks.sequence('test', workflow)) do
      if step == 'configure' and workflow.prepare then
        workflow.prepare()
      end
      local argv, cwd = tasks.command(directory, workflow, step)
      local result = rt.run(argv, { cwd = cwd })
      assert(result.code == 0, result.stdout .. result.stderr)
    end
  end
  count = count + 1
  print(
    'ok - '
      .. language
      .. ' migration preserves identity, backs up metadata, and allows later file additions'
  )
end
local directory = legacy('cpp', '-identifiers')
local path = 'src/core/core.cpp'
local source = assert(rt.read(rt.join(directory, path)))
  .. '\n// Preserve engine.outset and OUTSET_CUSTOM in application code.\n'
rt.write(rt.join(directory, path), source)
local plan = migration.plan(directory)
assert(not plan.files[path], 'Migration rewrote unrelated application identifiers')
rt.write(rt.join(directory, '.outset.json'), '{}\n')
assert(not pcall(project.apply, directory, plan), 'Stale migration applied')
assert(not rt.exists(rt.join(directory, '.rivet.json')))
count = count + 1
directory = legacy('python', '-collision')
rt.write(rt.join(directory, '.rivet.local.json'), 'Keep this file\n')
assert(not pcall(migration.plan, directory), 'Existing destination was overwritten')
assert(rt.read(rt.join(directory, '.rivet.local.json')) == 'Keep this file\n')
count = count + 1
local link = rt.join(temp, 'rivet-link')
assert(rt.run({ 'ln', '-s', rt.join(rt.absolute(root), 'bin/rivet'), link }).code == 0)
local result = rt.run({ link, '--version' }, { cwd = temp })
assert(result.code == 0 and result.stdout:find('Rivet.nvim', 1, true), result.stderr)
count = count + 1
result = rt.run({ rt.join(rt.absolute(root), 'bin/outset'), '--version' }, { cwd = temp })
assert(result.code == 0 and result.stdout:find('Rivet.nvim', 1, true), result.stderr)
assert(result.stderr:find('outset is deprecated', 1, true), 'Missing outset deprecation notice')
count = count + 1
print(count .. ' migration/launcher checks passed; fixtures: ' .. temp)
