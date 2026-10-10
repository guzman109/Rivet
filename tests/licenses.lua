-- Offline license generation and filesystem protection for every built-in provider.
local root = (debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/licenses%.lua$') or '.')
package.path = root .. '/lua/?.lua;' .. package.path
local model = require('rivet.model')
local rt = require('rivet.runtime')
local project = require('rivet.project')
local licenses = require('rivet.licenses')
local temporary = assert(
  rt.run({ 'mktemp', '-d', rt.join(os.getenv('TMPDIR') or '/tmp', 'rivet-licenses.XXXXXX') }).stdout
    :match('%S+')
)
local passed = 0
local function test(name, fn)
  fn()
  passed = passed + 1
  print('ok - ' .. name)
end
local function rejects(fn)
  assert(not pcall(fn), 'Expected rejection')
end
for _, language in ipairs({ 'cpp', 'c', 'python', 'rust', 'swift' }) do
  test(language .. ' generates each full license without changing the supplied options', function()
    for _, choice in ipairs(licenses.choices) do
      local opts = {
        language = language,
        name = 'sample',
        license = choice.id,
        license_holder = 'Ada %1 & Team',
        license_year = '2026',
      }
      local plan = model.plan(opts)
      assert(opts.license == choice.id and opts.license_holder == 'Ada %1 & Team')
      if choice.id == 'none' then
        assert(plan.files.LICENSE == nil and plan.files.NOTICE == nil)
      else
        assert(#plan.files.LICENSE > 1000 and plan.spec.license.id == choice.id)
        if choice.id == 'MIT' or choice.id == 'BSD-3-Clause' then
          assert(plan.files.LICENSE:find('2026 Ada %1 & Team', 1, true))
          assert(not plan.files.LICENSE:find('<year>', 1, true))
        else
          assert(
            plan.files.LICENSE == require('rivet.license_texts')[choice.id],
            'Canonical license was changed'
          )
          assert(plan.files.NOTICE:find('SPDX-License-Identifier: ' .. choice.id, 1, true))
        end
        if language == 'python' then
          assert(plan.files['pyproject.toml']:find('license = "' .. choice.id .. '"', 1, true))
        elseif language == 'rust' then
          assert(plan.files['Cargo.toml']:find('license = "' .. choice.id .. '"', 1, true))
        end
      end
    end
  end)
end
test('Rust workspace members carry their distributable license files', function()
  local p = model.plan({
    language = 'rust',
    name = 'sample',
    kind = 'workspace',
    license = 'Apache-2.0',
    license_holder = 'Ada',
  })
  assert(p.files['crates/sample/LICENSE'] == p.files.LICENSE)
  assert(p.files['crates/sample/NOTICE'] == p.files.NOTICE)
end)
test('invalid or missing legal fields fail before writing', function()
  for _, opts in ipairs({
    { license = 'MIT' },
    { license = 'made-up', license_holder = 'Ada' },
    { license = 'MIT', license_holder = 'Ada\nInjected' },
    { license = 'MIT', license_holder = 'Ada', license_year = 'now' },
    { license = 'MIT', license_holder = '   ' },
  }) do
    rejects(function()
      model.plan(opts)
    end)
  end
end)
test(
  'selected license fills empty header fields and preserves explicit per-file choices',
  function()
    local opts = {
      license = 'MIT',
      license_holder = 'Ada',
      license_year = '2026',
      comment_header = { style = 'compact' },
    }
    local p = model.plan(opts)
    assert(p.spec.comment_header.license == 'MIT' and p.spec.comment_header.copyright == '2026 Ada')
    assert(opts.comment_header.license == nil)
    opts.comment_header.license = 'BSD-3-Clause'
    assert(model.plan(opts).spec.comment_header.license == 'BSD-3-Clause')
  end
)
test('license is written atomically and survives adding sources', function()
  local destination = rt.join(temporary, 'licensed')
  local p = project.plan(
    {
      name = 'sample',
      language = 'python',
      license = 'MIT',
      license_holder = 'Ada',
      license_year = '2026',
    },
    destination
  )
  assert(not rt.exists(destination), 'Preview wrote files')
  project.apply(destination, p)
  local before = assert(rt.read(rt.join(destination, 'LICENSE')))
  project.apply(destination, project.file_plan(destination, { name = 'extra' }))
  assert(rt.read(rt.join(destination, 'LICENSE')) == before)
  assert(project.load(destination).license.holder == 'Ada')
end)
test('existing license and notice files are never replaced', function()
  for _, path in ipairs({ 'LICENSE', 'NOTICE' }) do
    local destination = rt.join(temporary, 'collision_' .. path)
    rt.mkdir(destination)
    rt.write(rt.join(destination, path), 'Existing legal terms\n')
    rejects(function()
      project.plan(
        { language = 'python', license = 'Apache-2.0', license_holder = 'Ada' },
        destination
      )
    end)
    assert(rt.read(rt.join(destination, path)) == 'Existing legal terms\n')
    assert(not rt.exists(rt.join(destination, 'pyproject.toml')))
  end
end)
test('No license yet preserves an existing license without claiming ownership', function()
  local destination = rt.join(temporary, 'existing')
  rt.mkdir(destination)
  rt.write(rt.join(destination, 'LICENSE'), 'Keep these terms\n')
  project.apply(destination, project.plan({ language = 'python', license = 'none' }, destination))
  assert(rt.read(rt.join(destination, 'LICENSE')) == 'Keep these terms\n')
end)
test('CLI current-folder creation infers the name, creates Git and a complete license', function()
  local destination = rt.join(temporary, 'current_folder')
  rt.mkdir(destination)
  local command = {
    rt.join(rt.absolute(root), 'bin/rivet'),
    'new',
    '.',
    '--language',
    'python',
    '--license',
    'MIT',
    '--license-holder',
    'Ada Lovelace',
    '--git',
    'true',
  }
  local result = rt.run(command, { cwd = destination })
  assert(result.code == 0, result.stdout .. result.stderr)
  assert(project.load(destination).name == 'current_folder')
  assert(rt.read(rt.join(destination, 'LICENSE')):find('Ada Lovelace', 1, true))
  assert(rt.is_dir(rt.join(destination, '.git')) and rt.read(rt.join(destination, '.gitignore')))
end)
test('CLI preview includes the full license and writes nothing', function()
  local destination = rt.join(temporary, 'preview')
  local result = rt.run({
    rt.join(rt.absolute(root), 'bin/rivet'),
    'new',
    destination,
    '--language',
    'python',
    '--license',
    'GPL-3.0-only',
    '--license-holder',
    'Ada',
    '--preview',
  })
  assert(result.code == 0, result.stderr)
  assert(
    result.stdout:find('END OF TERMS AND CONDITIONS', 1, true)
      and result.stdout:find('version 3 only', 1, true)
  )
  assert(not rt.exists(destination))
end)
print(string.format('%d license checks passed; fixtures: %s', passed, temporary))
