-- Preset, target, and task commands, plus the workflow runner they share.
local context = require('rivet.context')
local ui = require('rivet.ui')
local protected = context.protected
local choose = context.choose
local current_root = context.current_root
local M = {}

local function run_workflow(root, name, preset, target_name, done)
  if ui.is_running(root) then
    return ui.notify('A task is already running for this project.', vim.log.levels.WARN)
  end
  local state = require('rivet.task_state').load(root)
  local tasks = require('rivet.tasks').plan(
    root,
    preset,
    target_name,
    vim.tbl_extend('force', state, { task = name })
  )
  assert(tasks[name], 'Unavailable task: ' .. name)
  state.preset, state.last_task = preset, name
  if target_name then
    state.target = target_name
  end
  require('rivet.task_state').save(root, state)
  local qfid = ui.new_quickfix(root, name .. ' (' .. preset .. ')')
  local workflow, index = require('rivet.tasks').sequence(name, tasks), 0
  local run_next
  run_next = protected(function()
    index = index + 1
    local step = workflow[index]
    if not step then
      if done then
        done()
      end
      return
    end
    if step == 'configure' and tasks.prepare then
      tasks.prepare()
    end
    local argv, cwd = require('rivet.tasks').command(root, tasks, step)
    local spec = require('rivet.project').inspect(root)
    local provider = require('rivet.model').provider(spec)
    local diagnostic_service = (provider.services or {}).diagnostics
      and require('rivet.tasks').service(spec, 'diagnostics')
    local parser = diagnostic_service and diagnostic_service.parse
    local renderer = diagnostic_service and diagnostic_service.render
    if diagnostic_service and diagnostic_service.render_for then
      renderer = diagnostic_service.render_for(argv)
    end
    ui.run(
      root,
      argv,
      step .. ' (' .. preset .. ')',
      protected(function(ok, process)
        if not ok then
          return
        end
        if tasks.after_step then
          tasks.after_step(step, process)
        end
        if step == 'configure' and tasks.after_configure then
          local success, message = tasks.after_configure()
          if not success and message then
            ui.notify(message, vim.log.levels.WARN)
          end
        end
        run_next()
      end),
      {
        quickfix_id = qfid,
        cwd = cwd,
        diagnostic_cwd = step == 'configure' and root
          or (tasks.context and tasks.context.binaryDir or root),
        diagnostics = parser,
        render_line = renderer,
      }
    )
  end)
  run_next()
end

local function preset_picker(root, callback, force)
  local adapter = require('rivet.tasks').adapter(root)
  local state = require('rivet.task_state').load(root)
  local entries = adapter.presets(root, 'configure')
  assert(#entries > 0, 'No configure presets are available on this host')
  if not force then
    for _, item in ipairs(entries) do
      if item.name == state.preset then
        return callback(item.name)
      end
    end
  end
  local preferred = state.preset or context.config.default_preset
  table.sort(entries, function(a, b)
    if a.name == preferred then
      return true
    end
    if b.name == preferred then
      return false
    end
    return a.name < b.name
  end)
  choose('Configure preset: ', entries, function(item)
    local saved = require('rivet.task_state').load(root)
    if saved.preset ~= item.name then
      saved.build_preset, saved.test_preset, saved.build_target = nil, nil, nil
    end
    saved.preset = item.name
    require('rivet.task_state').save(root, saved)
    callback(item.name)
  end)
end
function M.preset()
  local root = current_root()
  preset_picker(root, function(value)
    ui.notify('Configure preset: ' .. value)
  end, true)
end
local function associated_picker(root, kind, force, callback)
  preset_picker(root, function(configure)
    local state = require('rivet.task_state').load(root)
    local entries = require('rivet.tasks').adapter(root).presets(root, kind, configure)
    if not force then
      for _, item in ipairs(entries) do
        if item.name == state[kind .. '_preset'] then
          return callback()
        end
      end
      if #entries <= 1 then
        state[kind .. '_preset'] = entries[1] and entries[1].name or ''
        require('rivet.task_state').save(root, state)
        return callback()
      end
    end
    if #entries == 0 then
      entries = { { name = '', label = 'Use configure preset build directory' } }
    end
    choose(kind .. ' preset: ', entries, function(item)
      state[kind .. '_preset'] = item.name
      require('rivet.task_state').save(root, state)
      callback()
    end)
  end)
end
function M.build_preset()
  associated_picker(current_root(), 'build', true, function()
    ui.notify('Build preset saved')
  end)
end
function M.test_preset()
  associated_picker(current_root(), 'test', true, function()
    ui.notify('Test preset saved')
  end)
end
function M.build_target()
  local root = current_root()
  local entries = { { name = '', label = 'Preset default targets / all' } }
  for _, target in
    ipairs(
      require('rivet.tasks').targets(
        root,
        require('rivet.task_state').load(root).preset,
        require('rivet.task_state').load(root)
      )
    )
  do
    entries[#entries + 1] = target
  end
  choose('Build target: ', entries, function(item)
    local state = require('rivet.task_state').load(root)
    state.build_target = item.name
    require('rivet.task_state').save(root, state)
    ui.notify('Build target: ' .. (item.name ~= '' and item.name or 'preset default'))
  end)
end
function M.statusline()
  local root = vim.b.rivet_root or context.active_root
  if not root then
    return ''
  end
  local state = require('rivet.task_state').load(root)
  local parts = { 'Rivet', state.preset or context.config.default_preset }
  if state.build_preset and state.build_preset ~= '' then
    parts[#parts + 1] = 'build:' .. state.build_preset
  end
  if state.test_preset and state.test_preset ~= '' then
    parts[#parts + 1] = 'test:' .. state.test_preset
  end
  if state.build_target and state.build_target ~= '' then
    parts[#parts + 1] = 'target:' .. state.build_target
  end
  if state.target then
    parts[#parts + 1] = 'run:' .. state.target
  end
  return table.concat(parts, ' · ')
end
function M.status()
  current_root()
  ui.notify(M.statusline())
end

local function run_target(root, force, callback)
  local runnable = {}
  local state = require('rivet.task_state').load(root)
  for _, target in
    ipairs(
      require('rivet.tasks').targets(
        root,
        require('rivet.task_state').load(root).preset,
        require('rivet.task_state').load(root)
      )
    )
  do
    if target.type == 'executable' and not target.test then
      runnable[#runnable + 1] = target
    end
  end
  if #runnable == 0 then
    return ui.notify(
      'This project has no application target. Add one with :RivetTarget, or run :RivetTask test.'
    )
  end
  local function select(target)
    local saved = require('rivet.task_state').load(root)
    saved.target = target.name
    require('rivet.task_state').save(root, saved)
    callback(target.name)
  end
  if not force then
    for _, target in ipairs(runnable) do
      if target.name == state.target then
        return select(target)
      end
    end
  end
  if #runnable == 1 then
    return select(runnable[1])
  end
  choose('Application target to run: ', runnable, select)
end

function M.run_target()
  run_target(current_root(), true, function(value)
    ui.notify('Application target: ' .. value)
  end)
end

function M.task(task_name)
  local root = current_root()
  if ui.is_running(root) then
    return ui.notify('A task is already running for this project.', vim.log.levels.WARN)
  end
  local function execute(name)
    if name == 'repeat' then
      name = require('rivet.task_state').load(root).last_task
    end
    assert(name, 'No previous task; choose a task first')
    preset_picker(root, function(preset)
      local function launch(target)
        run_workflow(root, name, preset, target)
      end
      local function selected()
        if name == 'run' or name == 'benchmark' or name == 'profile' then
          local ok = pcall(
            require('rivet.tasks').targets,
            root,
            preset,
            require('rivet.task_state').load(root)
          )
          if
            not ok
            and require('rivet.project').inspect(root).external
            and require('rivet.tasks').adapter(root) == require('rivet.cmake')
          then
            return run_workflow(root, 'configure', preset, nil, function()
              run_target(root, false, launch)
            end)
          end
          run_target(root, false, launch)
        else
          launch()
        end
      end
      if require('rivet.tasks').adapter(root) ~= require('rivet.cmake') or name == 'configure' then
        return selected()
      end
      associated_picker(root, 'build', false, function()
        if name == 'test' then
          associated_picker(root, 'test', false, selected)
        else
          selected()
        end
      end)
    end)
  end
  if task_name and task_name ~= '' then
    return execute(task_name)
  end
  local choices = require('rivet.tasks').names(root)
  if require('rivet.task_state').load(root).last_task then
    table.insert(choices, 1, 'repeat')
  end
  choose('Project task · ' .. M.statusline(), choices, execute)
end
M.run_workflow = run_workflow
M.preset_picker = preset_picker

return M
