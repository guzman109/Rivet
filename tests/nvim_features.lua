-- nvim --headless -u NONE -i NONE -l tests/nvim_features.lua
local repo = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/nvim_features%.lua$') or '.'
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(repo, ':p'))
local calls = {}
local function record(name)
  return function(value)
    calls[#calls + 1] = { name = name, value = value }
  end
end
package.loaded['rivet.commands.config'] = { config = record('config') }
package.loaded['rivet.commands.project'] = { upgrade = record('upgrade') }
package.loaded['rivet.commands.tasks'] = { output = record('output'), stop = record('stop') }
local rivet, context = require('rivet'), require('rivet.context')
assert(context.config.task_output == 'keep', 'Task output did not default to keep')
rivet.setup()
local commands = vim.api.nvim_get_commands({})
for _, name in ipairs({ 'RivetConfig', 'RivetUpgrade', 'RivetOutput', 'RivetStop' }) do
  assert(commands[name], 'Missing alias: ' .. name)
end
for _, name in ipairs({ 'config', 'upgrade', 'output', 'stop' }) do
  assert(type(rivet[name]) == 'function', 'Missing public export: ' .. name)
  vim.cmd('Rivet ' .. name)
  assert(calls[#calls].name == name, 'Unified command did not delegate: ' .. name)
  vim.cmd('Rivet' .. name:sub(1, 1):upper() .. name:sub(2))
  assert(calls[#calls].name == name, 'Alias did not delegate: ' .. name)
end
vim.cmd('Rivet config clang-format')
assert(calls[#calls].value == 'clang-format', 'Unified config lost its tool argument')
vim.cmd('RivetConfig clangd')
assert(calls[#calls].value == 'clangd', 'Config alias lost its tool argument')
rivet.config('clang-tidy')
assert(calls[#calls].value == 'clang-tidy', 'Public config lost its tool argument')
local subcommands = vim.fn.getcompletion('Rivet ', 'cmdline')
for _, name in ipairs({ 'config', 'upgrade', 'output', 'stop' }) do
  assert(vim.tbl_contains(subcommands, name), 'Missing subcommand completion: ' .. name)
end
assert(vim.deep_equal(vim.fn.getcompletion('Rivet config clang-t', 'cmdline'), { 'clang-tidy' }))
assert(vim.deep_equal(vim.fn.getcompletion('RivetConfig clang-f', 'cmdline'), { 'clang-format' }))
local current_root, task_module = context.current_root, package.loaded['rivet.tasks']
local active_root = context.active_root
context.current_root = function()
  context.active_root = 'lua-project'
  return 'lua-project'
end
package.loaded['rivet.tasks'] = {
  names = function(path)
    assert(path == 'lua-project')
    return { 'check', 'lint', 'build' }
  end,
}
assert(vim.deep_equal(vim.fn.getcompletion('Rivet task c', 'cmdline'), { 'check' }))
assert(vim.deep_equal(vim.fn.getcompletion('RivetTask l', 'cmdline'), { 'lint' }))
assert(not vim.tbl_contains(vim.fn.getcompletion('Rivet task ', 'cmdline'), 'run'))
assert(context.active_root == active_root, 'Task completion changed the active project')
context.current_root = function()
  error('No current project')
end
assert(vim.tbl_contains(vim.fn.getcompletion('RivetTask ', 'cmdline'), 'build'))
context.current_root, package.loaded['rivet.tasks'] = current_root, task_module
rivet.setup({ task_output = 'close-on-success', default_preset = 'release' })
assert(context.config.task_output == 'close-on-success')
local before = context.config
for _, invalid in ipairs({ 'close', false, 1 }) do
  local ok, err = pcall(rivet.setup, { task_output = invalid })
  assert(
    not ok and tostring(err):find('task_output must be', 1, true),
    'Invalid output mode was accepted'
  )
  assert(context.config == before, 'Invalid setup changed the active configuration')
end
rivet.setup({ task_output = 'keep' })
assert(context.config.task_output == 'keep' and context.config.default_preset == 'release')
print('New command exports, aliases, completions, and output configuration checks passed')
vim.cmd('qa!')
