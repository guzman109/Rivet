local repo = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/nvim_compiler%.lua$') or '.'
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(repo, ':p'))
vim.o.swapfile = false
local rt, project = require('rivet.runtime'), require('rivet.project')
local temporary = vim.fn.tempname()
vim.env.XDG_STATE_HOME = temporary
local root = temporary .. '/project'
project.apply(root, project.plan({ name = 'picker', standard = 20, modules = false }, root))
root = assert(vim.uv.fs_realpath(root))
vim.cmd.cd(vim.fn.fnameescape(root))
local ui, compilers = require('rivet.ui'), require('rivet.compilers')
local prompt, notices = nil, {}
ui.select_preview = function(title, items, callback, options)
  prompt = { title = title, items = items, callback = callback, options = options }
end
ui.notify = function(message)
  notices[#notices + 1] = message
end
compilers.discover = function()
  local compiler = compilers.inspect(assert(rt.detect_tools().clangxx))
  return { compiler }
end
require('rivet').setup({})
vim.cmd.RivetCompiler()
assert(prompt.title == 'C++ compiler' and #prompt.items == 2)
prompt.callback(prompt.items[1])
assert(prompt.options.review)
assert(not rt.read(root .. '/CMakeUserPresets.json'), 'Picker bypassed review')
prompt.callback(prompt.items[1])
assert(rt.read(root .. '/CMakeUserPresets.json'))
assert(require('rivet.task_state').load(root).preset == 'debug')
assert(
  require('rivet.cmake').context(root, 'debug', { tasks = true }).build_preset == 'local-debug'
)
assert(notices[#notices]:find('Compiler selected', 1, true))
vim.fn.delete(temporary, 'rf')
print('ok - compiler picker reviews and applies local presets')
