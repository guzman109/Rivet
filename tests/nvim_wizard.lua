local temporary_root = assert(vim.uv.fs_realpath(vim.uv.os_tmpdir()))
-- Navigation, saved profiles, identity privacy, and non-C++ provider routing.
local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/nvim_wizard%.lua$') or '.'
vim.opt.runtimepath:prepend(root)
local temporary = vim.fn.tempname()
vim.env.XDG_STATE_HOME = temporary
local ui = require('rivet.ui')
local real_preview = ui.select_preview
local back = false
local panel = ui.select_preview('Back', { { id = 1, label = 'Choice' } }, function()
  error('Unexpected accept')
end, {
  back = function()
    back = true
  end,
})
for _, key in ipairs(vim.api.nvim_buf_get_keymap(panel.list, 'n')) do
  if key.lhs == '<BS>' then
    key.callback()
  end
end
assert(back and not vim.api.nvim_buf_is_valid(panel.list), 'Back did not close the panel')
local values, visits, finished = {}, {}, 0
ui.input = function(_, default, callback)
  visits[#visits + 1] = default
  callback(#visits == 1 and ':back' or 'Ada')
end
local picks = 0
ui.select_preview = function(_, items, callback)
  picks = picks + 1
  callback(items[picks == 1 and 1 or 2])
end
require('rivet.wizard').run(values, {
  {
    key = 'kind',
    title = 'Kind',
    items = { { id = 'a', label = 'A' }, { id = 'b', label = 'B' } },
  },
  { key = 'name', title = 'Name', input = true, default = 'sample' },
}, function()
  finished = finished + 1
end)
assert(picks == 2 and values.kind == 'b' and values.name == 'Ada' and finished == 1)
local preferences = require('rivet.preferences')
assert(preferences.load().identity == nil, 'Identity was inferred without opt-in')
preferences.save({
  profiles = { HPC = { language = 'cpp', standard = 20, modules = false } },
  identity = { style = 'compact', author = 'Ada Lovelace' },
})
local saved = preferences.load()
assert(saved.profiles.HPC.standard == 20 and saved.identity.author == 'Ada Lovelace')
local model = require('rivet.model')
local provider = { label = 'Fixture' }
provider.normalize = function(opts)
  assert(opts.language == 'fixture')
  return opts
end
provider.plan = function(opts)
  return { spec = opts, files = {} }
end
provider.add_file, provider.add_target, provider.add_dependency =
  provider.plan, provider.plan, provider.plan
provider.questions = function(kind)
  assert(kind == 'new')
  return {
    { key = 'flavor', title = 'Fixture flavor', items = { { id = 'custom', label = 'Custom' } } },
  }
end
provider.default_name = function()
  return 'hyphen-name'
end
provider.services = {
  tasks = {
    tasks = function(_, _, _, options)
      return { build = { 'fixture', options.mode } }
    end,
  },
}
model.register('fixture', provider)
local received
package.loaded['rivet.project'] = {
  root = function()
    return temporary_root .. '/fixture'
  end,
  load = function()
    return { language = 'fixture' }
  end,
  plan = function(spec, path)
    received = spec
    return { spec = spec, root = path, files = {} }
  end,
}
package.loaded['rivet.project'].inspect = package.loaded['rivet.project'].load

-- A configured profile exposes the provider questionnaire; no C++ compiler prompt is injected.
preferences.save({ profiles = { Fixture = { language = 'fixture' } } })
ui.choose = function(prompt, items, callback)
  if prompt:match('^Project profile') then
    return callback(items[2])
  end
  callback(items[prompt:match('^Create project') and 2 or 1])
end
ui.input = function(_, default, callback)
  callback(default)
end
ui.select_preview = function(_, items, callback)
  callback(items[1])
end
ui.review = function() end -- final review remains unapplied
require('rivet').new()
assert(
  received.language == 'fixture' and received.name == 'hyphen-name' and received.flavor == 'custom'
)
assert(received.compiler == nil and received.standard == nil)
local task = require('rivet.tasks').plan(temporary_root .. '/fixture', nil, nil, { mode = 'fast' })
assert(task.build[1] == 'fixture' and task.build[2] == 'fast')
ui.select_preview = real_preview
vim.fn.delete(temporary, 'rf')
print('Wizard navigation, opt-in preferences, and provider routing checks passed')
vim.cmd('qa!')
