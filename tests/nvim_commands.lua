-- nvim --headless -u NONE -i NONE -l tests/nvim_commands.lua
local script = debug.getinfo(1, 'S').source:sub(2)
local root = script:match('^(.*)/tests/nvim_commands%.lua$') or '.'
root = vim.fn.fnamemodify(root, ':p')
vim.opt.runtimepath:prepend(root)
vim.cmd('runtime plugin/rivet.lua')
local rivet = require('rivet')
local context = require('rivet.context')

-- A plugin manager calling setup() after plugin/ keeps both the merge and the commands.
rivet.setup({ default_preset = 'release', profiles = { quick = { language = 'c' } } })
rivet.setup({ projects_dir = '/tmp/rivet-projects' })
assert(context.config.default_preset == 'release', 'setup options were not merged')
assert(context.config.projects_dir == '/tmp/rivet-projects')
assert(context.config.profiles.quick.language == 'c', 'later setup dropped earlier options')

local commands = vim.api.nvim_get_commands({})
for _, name in ipairs({ 'Rivet', 'RivetNew', 'RivetTask', 'RivetMigrate', 'RivetDoctor' }) do
  assert(commands[name], 'missing command ' .. name)
end
for _, name in ipairs({
  'new',
  'cmake',
  'preset',
  'build_preset',
  'test_preset',
  'build_target',
  'statusline',
  'status',
  'run_target',
  'task',
  'file',
  'target',
  'dependency',
  'profile',
  'identity',
  'files',
  'module_rename',
  'repair',
  'run_options',
  'doctor',
  'header',
  'header_defaults',
  'migrate',
}) do
  assert(type(rivet[name]) == 'function', 'require("rivet").' .. name .. ' is not a function')
end
assert(rivet.no_such_function == nil)

local subcommands = vim.fn.getcompletion('Rivet ', 'cmdline')
assert(vim.tbl_contains(subcommands, 'new') and vim.tbl_contains(subcommands, 'build-preset'))
assert(vim.tbl_contains(subcommands, 'task'))
assert(vim.deep_equal(vim.fn.getcompletion('Rivet header-', 'cmdline'), { 'header-defaults' }))
assert(vim.tbl_contains(vim.fn.getcompletion('Rivet task ', 'cmdline'), 'build'))
assert(#vim.fn.getcompletion('Rivet status ', 'cmdline') == 0)

local messages = {}
require('rivet.ui').notify = function(message)
  messages[#messages + 1] = message
end
local empty = vim.fn.tempname()
vim.fn.mkdir(empty, 'p')
vim.cmd.cd(empty)
vim.cmd('Rivet bogus')
assert(messages[#messages]:find('Unknown Rivet subcommand: bogus', 1, true))
vim.cmd('Rivet')
assert(messages[#messages]:find('Usage: :Rivet', 1, true))
vim.cmd('Rivet status')
assert(messages[#messages]:find('No supported project found', 1, true), messages[#messages])
vim.cmd('Rivet task build')
assert(messages[#messages]:find('No supported project found', 1, true), messages[#messages])
vim.fn.delete(empty, 'rf')

print('Command registration checks passed')
vim.cmd('qa!')
