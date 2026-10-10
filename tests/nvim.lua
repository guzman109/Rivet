local temporary_root = assert(vim.uv.fs_realpath(vim.uv.os_tmpdir()))
-- nvim --headless -u NONE -i NONE -l tests/nvim.lua
local script = debug.getinfo(1, 'S').source:sub(2)
local root = script:match('^(.*)/tests/nvim%.lua$') or '.'
vim.opt.runtimepath:prepend(root)
local state_home = vim.fn.tempname()
vim.env.XDG_STATE_HOME = state_home
local ui = require('rivet.ui')
local chosen
local panel = ui.select_preview('Test', {
  { id = 'first', label = 'First', description = 'Description', preview = 'alpha\nbeta' },
  { id = 'second', label = 'Second', preview = 'gamma\ndelta' },
}, function(value)
  chosen = value.id
end)
assert(#vim.api.nvim_buf_get_lines(panel.preview, 0, -1, false) == 6, 'Preview newlines were lost')
vim.api.nvim_win_set_cursor(panel.windows[1], { 2, 0 })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = panel.list })
assert(
  vim.api.nvim_buf_get_lines(panel.preview, 0, 1, false)[1] == '# Second',
  'Cursor preview did not update'
)
vim.o.columns = 60
vim.api.nvim_exec_autocmds('VimResized', {})
assert(vim.api.nvim_win_get_config(panel.windows[1]).width == 54)
local keymaps = vim.api.nvim_buf_get_keymap(panel.list, 'n')
for _, key in ipairs(keymaps) do
  if key.lhs == '<CR>' then
    key.callback()
  end
end
assert(chosen == 'second', 'Enter did not accept selected item')
assert(not vim.api.nvim_buf_is_valid(panel.list), 'List buffer leaked')
assert(not vim.api.nvim_buf_is_valid(panel.preview), 'Preview buffer leaked')
local applied = false
panel = ui.review('/tmp/test', { files = { ['main.cpp'] = 'line1\nline2\n' } }, function()
  applied = true
end)
assert(not applied, 'Review applied without approval')
for _, key in ipairs(vim.api.nvim_buf_get_keymap(panel.list, 'n')) do
  if key.lhs == 'q' then
    key.callback()
  end
end
assert(not applied, 'Cancel applied changes')
panel = ui.review('/tmp/test', { files = { ['main.cpp'] = 'line1\nline2\n' } }, function()
  applied = true
end)
for _, key in ipairs(vim.api.nvim_buf_get_keymap(panel.list, 'n')) do
  if key.lhs == 'c' then
    key.callback()
  end
end
assert(applied, 'Create key did not apply changes')
-- Test the wizard, including emitted arguments, without filesystem mutation.
local input_values = {
  'sandbox',
  temporary_root .. '/rivet-ui-project',
  (vim.fn.exepath('clang++') ~= '' and vim.fn.exepath('clang++') or '/usr/bin/c++'),
}
local input_index = 0
vim.ui.input = function(_, callback)
  input_index = input_index + 1
  callback(input_values[input_index])
end
vim.ui.select = function(items, _, callback)
  callback(items[1])
end
local select_preview = ui.select_preview
ui.select_preview = function(_, items, callback)
  callback(items[1])
end
local received, created, reviewed
package.loaded['rivet.project'] = {
  plan = function(spec, root)
    received = spec
    return { spec = spec, files = { ['main.cpp'] = 'int main() {}' } }
  end,
  load = function()
    return { language = 'cpp' }
  end,
  apply = function(root, plan)
    created = root
  end,
}
package.loaded['rivet.project'].inspect = package.loaded['rivet.project'].load

ui.review = function(root, plan, apply)
  reviewed = { root = root, plan = plan }
  assert(not created)
  apply()
end
require('rivet').setup()
require('rivet').new()
assert(received.name == 'sandbox' and received.modules == true and received.standard == 26)
assert(received.std_modules == false, 'Standard-library modules must remain opt-in')
assert(received.generator == 'Ninja' and received.header_guard == 'pragma')
assert(reviewed.root == temporary_root .. '/rivet-ui-project' and created == reviewed.root)
assert(vim.fn.exists(':RivetNew') == 2 and vim.fn.exists(':RivetTask') == 2)

-- The initial build must use the newly created root, even while another project
-- is open, and each asynchronous step must wait for the previous one to succeed.
local std_choice, build_choice, build_failure = false, 2, false
local runs, task_roots = {}, {}
package.loaded['rivet.project'].root = function()
  return '/wrong/open/project'
end
package.loaded['rivet.cmake'] = {
  tasks = function(project_root, preset)
    task_roots[#task_roots + 1] = project_root
    assert(project_root == created, 'Initial build used the open project instead of created root')
    assert(preset == 'debug', 'Initial build should generate Debug editor artifacts')
    return { configure = { 'mock-cmake', 'configure' }, build = { 'mock-cmake', 'build' } }
  end,
}
ui.select_preview = function(title, items, callback)
  if title == 'Standard library' then
    callback(items[std_choice and 2 or 1])
  elseif title == 'C++ interface' then
    callback(items[2])
  else
    callback(items[1])
  end
end
vim.ui.select = function(items, opts, callback)
  if opts.prompt:find('Check import std', 1, true) then
    callback(items[build_choice])
  else
    callback(items[1])
  end
end
ui.run = function(project_root, argv, title, callback)
  assert(created and reviewed, 'A build began before project review was accepted')
  runs[#runs + 1] = { root = project_root, step = argv[2] }
  vim.schedule(function()
    callback(not (build_failure and argv[2] == 'configure'))
  end)
end
local function run_std_wizard(suffix, choice, failure)
  input_index, received, created, reviewed = 0, nil, nil, nil
  input_values[2] = temporary_root .. '/rivet-ui-' .. suffix
  std_choice, build_choice, build_failure = true, choice, failure or false
  runs, task_roots = {}, {}
  require('rivet').new()
  assert(
    received.std_modules and not received.modules,
    'std choice should be independent of project modules'
  )
  assert(received.generator == 'Ninja', 'import std should force Ninja for header projects too')
end
run_std_wizard('std-later', 2)
assert(#runs == 0 and #task_roots == 0, 'Declining initial build still ran a task')
run_std_wizard('std-now', 1)
assert(#runs == 1 and runs[1].step == 'configure', 'Build ran before configure completed')
assert(
  vim.wait(1000, function()
    return #runs == 2
  end),
  'Initial async build did not run'
)
assert(runs[2].step == 'build' and runs[2].root == created)
local remembered = require('rivet.task_state').load(created)
assert(remembered.last_task == 'build' and remembered.preset == 'debug')
run_std_wizard('std-configure-failure', 1, true)
vim.wait(50, function()
  return false
end)
assert(#runs == 1 and runs[1].step == 'configure', 'Build continued after configure failed')

-- Current-folder creation uses the folder's name even with a configured parent.
local original_cwd = vim.fn.getcwd()
local current_directory = vim.fn.tempname() .. '/123 My-Engine'
vim.fn.mkdir(current_directory, 'p')
vim.api.nvim_set_current_dir(current_directory)
require('rivet').setup({ projects_dir = '/not/the/current/folder' })
received, created, reviewed = nil, nil, nil
local name_prompted = false
vim.ui.select = function(items, options, callback)
  callback(
    items[options.prompt:match('^Create project in:') and 2 or options.prompt:match(
      '^Git repository:'
    ) and 2 or 1]
  )
end
ui.select_preview = function(_, items, callback)
  callback(items[1])
end
vim.ui.input = function(options, callback)
  assert(not options.prompt:match('^Project directory:'), 'Current folder asked for another folder')
  if options.prompt:match('^Project name:') then
    name_prompted = true
    assert(options.default == 'project_123_My_Engine', 'Folder name was not inferred safely')
  end
  callback(options.default)
end
require('rivet').new()
assert(name_prompted and received.name == 'project_123_My_Engine' and received.git)
assert(
  reviewed.root == vim.fn.getcwd() and created == reviewed.root,
  'Current folder created a nested directory'
)
vim.api.nvim_set_current_dir(original_cwd)
vim.fn.delete(vim.fn.fnamemodify(current_directory, ':h'), 'rf')

-- Canceling the first text input must not plan or write anything.
received, created = nil, nil
vim.ui.input = function(_, callback)
  callback(nil)
end
require('rivet').new()
assert(not received and not created)
print('UI smoke checks passed')
vim.fn.delete(state_home, 'rf')
vim.cmd('qa!')
