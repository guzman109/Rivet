local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/file_templates%.lua$') or '.'
package.path = root .. '/lua/?.lua;' .. package.path
local model, project, rt =
  require('rivet.model'), require('rivet.project'), require('rivet.runtime')
local templates = require('rivet.file_templates')
local temporary = assert(rt.run({ 'mktemp', '-d', '/tmp/rivet-files.XXXXXX' }).stdout:match('%S+'))
local passed = 0
local function test(name, fn)
  fn()
  passed = passed + 1
  print('ok - ' .. name)
end
local function rejects(fn)
  assert(not pcall(fn), 'Expected rejection')
end
local ok, err = pcall(function()
  test('file inference and unsafe paths', function()
    assert(templates.infer('one.cppm') == 'cpp' and templates.infer('one.lua') == 'lua')
    local cc =
      model.add_file(model.plan({ name = 'host', modules = false }).spec, { name = 'src/extra.cc' })
    assert(cc.files['src/extra.cpp'])
    for _, path in ipairs({ '../escape.lua', '/escape.py', 'dir/../escape.rs' }) do
      rejects(function()
        templates.plan({ name = 'test' }, { name = path }, 'lua')
      end)
    end
  end)
  test('template previews show the configured header and final files use real names', function()
    local spec = model.plan({
      name = 'host',
      modules = true,
      comment_header = { style = 'doc', author = 'Ada', description = 'Host interfaces' },
    }).spec
    local steps = model.questions('file', spec)
    for _, item in ipairs(steps[1].items) do
      assert(
        item.preview:find('@file example.', 1, true) and item.preview:find('@author Ada', 1, true),
        'Missing preview header'
      )
    end
    local plan =
      model.add_file(spec, { name = 'src/render', kind = 'module_pair', module = 'host.render' })
    assert(plan.files['src/render.cppm']:find('@file render.cppm', 1, true))
    assert(plan.files['src/render.cpp']:find('@file render.cpp', 1, true))
  end)
  test('foreign source files preserve host targets', function()
    local spec = model.plan({
      name = 'host',
      modules = false,
      comment_header = { style = 'compact', author = 'Ada' },
    }).spec
    local original = require('rivet.json').encode(spec.targets)
    for _, language in ipairs({ 'python', 'rust', 'swift', 'lua', 'text' }) do
      local plan = model.add_file(spec, {
        name = 'tools/helper',
        language = language,
        kind = language == 'lua' and 'script' or 'source',
      })
      assert(require('rivet.json').encode(plan.spec.targets) == original)
      assert(next(plan.files) and next(plan.spec.file_languages))
      assert(not plan.files['cmake/RivetTargets.cmake'])
      if language ~= 'text' then
        local headers = require('rivet.tasks').service({ language = language }, 'headers')
        for path, body in pairs(plan.files) do
          local header = headers.render(spec.comment_header, { filename = path, project = 'host' })
          assert(body:sub(1, #header) == header and header:find('Ada', 1, true))
        end
      end
    end
  end)
  test('every built-in file wizard previews its language header', function()
    for _, language in ipairs(model.list_languages()) do
      local spec = model.plan({
        language = language,
        name = 'sample',
        comment_header = { style = 'compact', author = 'Ada' },
      }).spec
      local steps = model.questions('file', spec)
      assert(steps[1].key == 'kind' and steps[1].items[1].preview:find('Ada', 1, true), language)
    end
  end)
  test('C++ documentation headers adapt to Python line-comment headers', function()
    local spec = model.plan({
      name = 'host',
      comment_header = { style = 'doc', author = 'Ada' },
    }).spec
    local steps =
      templates.with_header_previews(templates.questions(spec, 'python'), spec, 'python')
    assert(steps[1].items[1].preview:find('# Author: Ada', 1, true))
    local plan = model.add_file(spec, { name = 'scripts/helper', language = 'python' })
    assert(plan.files['scripts/helper.py']:find('# Author: Ada', 1, true))
    assert(plan.spec.comment_header.style == 'doc', 'Foreign file changed project defaults')
  end)
  test('preview decoration preserves lazy functions and line tables', function()
    local spec = { name = 'sample', comment_header = { style = 'compact', author = 'Ada' } }
    local calls = 0
    local steps = {
      {
        key = 'kind',
        items = function(values)
          return {
            { id = 'header', label = 'Header', preview = { '#pragma once', values.name } },
            {
              id = 'source',
              label = 'Source',
              preview = function(item)
                calls = calls + 1
                return { '// ' .. item.label, 'int value = 42;' }
              end,
            },
            { id = 'pair', description = { 'Two files', 'One review' } },
            { id = 'module' },
          }
        end,
      },
    }
    local decorated = templates.with_header_previews(steps, spec, 'cpp')
    local items = decorated[1].items({ name = 'specific' })
    assert(calls == 0 and items[1].preview:find('#pragma once\nspecific', 1, true))
    assert(items[2].preview(items[2]):find('// Source\nint value = 42;', 1, true))
    assert(calls == 1 and items[2].preview(items[2]):find('Ada', 1, true))
    assert(items[3].preview:find('Two files\nOne review', 1, true))
    assert(items[4].preview:find('module', 1, true))
    assert(type(steps[1].items({ name = 'original' })[1].preview) == 'table')
  end)
  test('C pairs register both files in C++ host', function()
    local plan = model.add_file(
      model.plan({ name = 'host', modules = false }).spec,
      { language = 'c', name = 'ffi/answer', kind = 'pair', target = 'host_core' }
    )
    assert(plan.files['ffi/answer.c']:find('#include "answer.h"', 1, true))
    assert(plan.files['ffi/answer.h']:find('extern "C"', 1, true))
    assert(plan.files['cmake/RivetTargets.cmake']:find('enable_language(C)', 1, true))
  end)
  test('legacy mixed C aliases remain supported', function()
    local spec = model.plan({ name = 'host', modules = false }).spec
    for _, choice in ipairs({
      { name = 'one.c', kind = 'c_source' },
      { name = 'one.h', kind = 'c_header' },
      { name = 'one', language = 'c', kind = 'c_pair' },
    }) do
      assert(next(model.add_file(spec, choice).files))
    end
  end)
  test('module pair shares owning target and declaration', function()
    local plan = model.add_file(
      model.plan({ name = 'host', standard = 20 }).spec,
      { name = 'src/answer', kind = 'module_pair', module = 'host.answer', target = 'host_core' }
    )
    assert(plan.files['src/answer.cppm']:find('export module host.answer;', 1, true))
    assert(plan.files['src/answer.cpp']:find('module host.answer;', 1, true))
    assert(plan.spec.module_names['host.answer'].target == 'host_core')
    rejects(function()
      model.add_file(plan.spec, { name = 'other', kind = 'module_pair', module = 'host.answer' })
    end)
  end)
  test('external file preview creates no manifest and refuses overwrites', function()
    local folder = rt.join(temporary, 'external')
    rt.mkdir(folder)
    local plan = project.file_plan(folder, { name = 'src/helper', language = 'python' })
    assert(not plan.files['.rivet.json'] and not rt.exists(rt.join(folder, 'src/helper.py')))
    project.apply(plan.root, plan)
    assert(
      rt.read(rt.join(folder, 'src/helper.py')) and not rt.exists(rt.join(folder, '.rivet.json'))
    )
    rejects(function()
      project.file_plan(folder, { name = 'src/helper', language = 'python' })
    end)
  end)
  test('loose files can be moved and removed without host build changes', function()
    local folder = rt.join(temporary, 'managed')
    rt.mkdir(folder)
    project.apply(folder, project.plan({ name = 'host', modules = false }, folder))
    local initial = rt.read(rt.join(folder, 'cmake/RivetTargets.cmake'))
    project.apply(
      folder,
      project.file_plan(folder, { name = 'tools/helper', language = 'lua', kind = 'script' })
    )
    project.apply(
      folder,
      project.lifecycle_plan(
        folder,
        { action = 'move', from = 'tools/helper.lua', to = 'scripts/helper.lua' }
      )
    )
    assert(
      not rt.exists(rt.join(folder, 'tools/helper.lua'))
        and rt.read(rt.join(folder, 'scripts/helper.lua'))
    )
    project.apply(
      folder,
      project.lifecycle_plan(folder, { action = 'remove', from = 'scripts/helper.lua' })
    )
    assert(not rt.exists(rt.join(folder, 'scripts/helper.lua')))
    assert(rt.read(rt.join(folder, 'cmake/RivetTargets.cmake')) == initial)
  end)
  test('supplementary snapshots contain no generated source code', function()
    local folder = rt.join(temporary, 'snapshots')
    rt.mkdir(folder)
    local plan = project.plan({ name = 'host', modules = false }, folder)
    assert(plan.spec.rivet_version and plan.spec.template_baselines['.clang-format'])
    assert(not plan.spec.template_baselines['src/host_core/host.cpp'])
    project.apply(plan.root, plan)
    local upgrade = require('rivet.upgrade').plan(folder)
    assert(not upgrade.files['src/host_core/host.cpp'])
  end)
end)
rt.run({ 'rm', '-rf', temporary })
assert(ok, err)
print(passed .. ' file template tests passed')
