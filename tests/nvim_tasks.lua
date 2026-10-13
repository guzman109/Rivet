-- nvim --headless -u NONE -i NONE -l tests/nvim_tasks.lua
local root = (debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/nvim_tasks%.lua$') or '.')
vim.opt.runtimepath:prepend(root)
local temporary = vim.fn.tempname()
vim.env.XDG_STATE_HOME = temporary
local project_a, project_b = temporary .. '/project-a', temporary .. '/project-b'
local project_root = project_a
local targets = {
  { name = 'engine', type = 'executable' },
  { name = 'viewer', type = 'executable' },
  { name = 'engine_test', type = 'executable', test = true },
}
package.loaded['rivet.project'] = {
  root = function()
    return project_root
  end,
  load = function()
    return { targets = targets }
  end,
}
package.loaded['rivet.project'].inspect = package.loaded['rivet.project'].load

local requested, runs, choices = {}, {}, {}
package.loaded['rivet.cmake'] = {
  presets = function(_, kind)
    if kind ~= 'configure' then
      return {}
    end
    return { { name = 'debug' }, { name = 'release' } }
  end,
  tasks = function(path, preset, target)
    requested[#requested + 1] = { root = path, preset = preset, target = target }
    local out = {}
    for _, name in ipairs({ 'configure', 'build', 'test', 'run', 'format' }) do
      out[name] = { name }
    end
    return out
  end,
}
local ui = require('rivet.ui')
local choose_release, choose_first, fail_step
ui.choose = function(prompt, items, callback)
  choices[#choices + 1] = prompt
  if prompt:find('preset', 1, true) then
    for _, item in ipairs(items) do
      if item.name == (choose_release and 'release' or 'debug') then
        return callback(item)
      end
    end
  end
  assert(#items == 2, 'test executables appeared in run target selection')
  callback(items[choose_first and 1 or 2])
end
ui.run = function(path, argv, title, callback, opts)
  runs[#runs + 1] = {
    name = argv[1],
    qfid = opts.quickfix_id,
    close_on_success = opts.close_on_success,
  }
  callback(argv[1] ~= fail_step)
end
local rivet = require('rivet')
rivet.setup()
rivet.task('run')
assert(#choices == 2 and #runs == 3)
assert(requested[1].target == 'viewer' and requested[1].preset == 'debug')
assert(runs[1].qfid == runs[2].qfid and runs[2].qfid == runs[3].qfid)
assert(
  not runs[1].close_on_success and not runs[2].close_on_success and not runs[3].close_on_success
)
package.loaded['rivet.task_state'] = nil -- Simulate a fresh editor's state reader.
rivet.task('repeat')
assert(#choices == 2 and #runs == 6 and requested[2].target == 'viewer')
choose_release = true
rivet.preset()
rivet.task('build')
assert(#choices == 3 and requested[3].preset == 'release' and #runs == 8)
rivet.task('repeat')
assert(#choices == 3 and #runs == 10 and runs[10].name == 'build')
choose_first = true
rivet.run_target()
rivet.task('run')
assert(#choices == 4 and requested[5].target == 'engine')
targets[1].name = 'replacement'
rivet.task('run')
assert(#choices == 5 and requested[6].target == 'replacement', 'removed target was reused')
fail_step = 'configure'
local count = #runs
rivet.task('test')
assert(#runs == count + 1, 'workflow continued after configure failed')
project_root = project_b
rivet.task('build')
assert(#choices == 6, 'preset leaked between projects')
local state = require('rivet.task_state').load(project_a)
assert(state.preset == 'release' and state.target == 'replacement' and state.last_task == 'test')
project_root = project_a
vim.b.rivet_root = project_b
rivet.task('repeat')
assert(
  requested[#requested].root == project_b,
  'task output resolved to a different project in the editor cwd'
)
local output_root, stopped_root
ui.show_output = function(path)
  output_root = path
  return 42
end
ui.stop = function(path)
  stopped_root = path
  return true
end
local commands = require('rivet.commands.tasks')
assert(
  commands.output() == 42 and output_root == project_b,
  'output command lost the buffer project'
)
commands.stop()
assert(stopped_root == project_b, 'stop command lost the buffer project')
vim.b.rivet_root = nil
fail_step = nil
require('rivet.context').config.task_output = 'close-on-success'
local start = #runs
commands.run_workflow(project_a, 'run', 'release', 'replacement')
assert(#runs == start + 3)
assert(not runs[start + 1].close_on_success and not runs[start + 2].close_on_success)
assert(runs[start + 3].close_on_success, 'Final workflow output did not receive close-on-success')
local before_choices, before_runs = #choices, #runs
ui.is_running = function()
  return true
end
local id = vim.fn.getqflist({ id = 0 }).id
rivet.task('run')
assert(
  #choices == before_choices and #runs == before_runs and vim.fn.getqflist({ id = 0 }).id == id,
  'busy task changed choices or cleared quickfix'
)
vim.fn.delete(temporary, 'rf')
print('Remembered task choices and workflow checks passed')
vim.cmd('qa!')
