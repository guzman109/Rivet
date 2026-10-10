local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/nvim_license%.lua$') or '.'
vim.opt.runtimepath:prepend(root)
local temp = vim.fn.tempname()
vim.env.XDG_STATE_HOME = temp .. '-state'
local ui = require('rivet.ui')
local reviewed, saw_preview
ui.notify = function(message)
  error(message)
end
ui.choose = function(prompt, items, callback)
  if prompt:match('^Project language') then
    return callback('python')
  end
  callback(items[1])
end
ui.input = function(prompt, default, callback)
  if prompt:match('^Copyright holder') then
    return callback('Ada Lovelace')
  end
  if prompt:match('^Project directory') then
    return callback(temp)
  end
  callback(default)
end
ui.select_preview = function(title, items, callback)
  if title == 'Project license' then
    for _, item in ipairs(items) do
      if item.id == 'Apache-2.0' then
        return callback(item)
      end
    end
  end
  if title == 'Review project license' then
    assert(items[1].preview:find('TERMS AND CONDITIONS', 1, true))
    assert(items[1].preview:find('Ada Lovelace', 1, true))
    saw_preview = true
  end
  callback(items[1])
end
ui.review = function(destination, plan)
  reviewed = true
  assert(saw_preview and plan.spec.language == 'python')
  assert(plan.files.LICENSE and plan.files.NOTICE:find('Ada Lovelace', 1, true))
  assert(plan.spec.license.id == 'Apache-2.0')
  assert(vim.fn.isdirectory(destination) == 0, 'Wizard applied before confirmation')
end
require('rivet').new()
assert(reviewed, 'License wizard did not reach final review')
vim.fn.delete(temp .. '-state', 'rf')
print('License wizard identity, full-text preview, and final review passed')
vim.cmd('qa!')
