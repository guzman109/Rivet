local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/nvim_files%.lua$') or '.'
root = vim.fn.fnamemodify(root, ':p')
vim.opt.runtimepath:prepend(root)
local project, ui = require('rivet.project'), require('rivet.ui')
local temporary = vim.fn.tempname()
vim.fn.mkdir(temporary, 'p')
project.apply(
  project.canonical(temporary),
  project.plan({ name = 'host', modules = true, standard = 20 }, temporary)
)
vim.cmd.cd(temporary)
local context = require('rivet.context')
local preview, step = nil, 0
context.review = function(_, plan)
  preview = plan
end
ui.notify = function(message, level)
  if level == vim.log.levels.ERROR then
    error(message)
  end
end
local function create(language, kind, name)
  step, preview = 0, nil
  ui.select_preview = function(title, items, callback)
    step = step + 1
    local desired = title == 'New file language' and language
      or title == 'Target' and 'host_core'
      or kind
    if title:find('target') then
      desired = 'host_core'
    end
    for _, item in ipairs(items) do
      if (item.id or item.name) == desired then
        return callback(item)
      end
    end
    error('Missing choice ' .. tostring(desired) .. ' in ' .. title)
  end
  ui.input = function(title, _, callback)
    callback(title:find('module name') and 'host.answer' or name)
  end
  package.loaded['rivet.commands.project'] = nil
  require('rivet.commands.project').file()
  assert(preview, 'File wizard did not reach review')
  return preview
end
local pair = create('cpp', 'module_pair', 'src/answer')
assert(pair.files['src/answer.cppm'] and pair.files['src/answer.cpp'])
local lua = create('lua', 'script', 'scripts/helper')
assert(lua.files['scripts/helper.lua'] and not lua.files['CMakeLists.txt'])
local c = create('c', 'pair', 'src/answer')
assert(c.files['src/answer.c'] and c.files['src/answer.h'])
assert(not vim.uv.fs_stat(temporary .. '/scripts/helper.lua'), 'Review created files')
local unrelated = vim.fn.tempname()
vim.fn.mkdir(unrelated, 'p')
vim.cmd.cd(unrelated)
vim.bo.buftype = 'nofile'
vim.b.rivet_root = project.canonical(temporary)
local output_plan = create('lua', 'script', 'scripts/from_output')
assert(
  output_plan.root == project.canonical(temporary),
  'File creation ignored task output project context'
)
vim.b.rivet_root = nil
vim.fn.delete(unrelated, 'rf')
vim.fn.delete(temporary, 'rf')
print('Neovim file language and pair wizard tests passed')
