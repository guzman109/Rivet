-- Runtime services are registered by providers, never loaded from manifest module paths.
local M = {}
---Service modules differ by provider (for example CMake versus native task adapters).
---@param spec table A spec, or at least { language = ... }
---@param name string
---@return any
function M.service(spec, name)
  local service = (require('rivet.model').provider(spec).services or {})[name]
  assert(service, 'The ' .. (spec.language or 'cpp') .. ' provider does not support ' .. name)
  return type(service) == 'string' and require(service) or service
end
function M.adapter(root)
  return M.service(require('rivet.project').inspect(root), 'tasks')
end
function M.targets(root, preset, options)
  local adapter = M.adapter(root)
  if adapter.targets then
    return adapter.targets(root, preset, options)
  end
  return require('rivet.project').inspect(root).targets or {}
end
function M.plan(root, preset, target, options)
  local plan = M.adapter(root).tasks(root, preset, target, options)
  plan.options = require('rivet.task_options').load(root)
  if plan.options.jobs and plan.context and plan.build then
    for i = #plan.build, 1, -1 do
      if plan.build[i] == '--parallel' then
        if tonumber(plan.build[i + 1]) then
          table.remove(plan.build, i + 1)
        end
        table.remove(plan.build, i)
      end
    end
    plan.build[#plan.build + 1] = '--parallel'
    plan.build[#plan.build + 1] = tostring(plan.options.jobs)
  end
  for _, key in ipairs({ 'benchmark', 'profile', 'submit', 'status', 'cancel' }) do
    if plan.options[key] then
      plan[key] = plan.options[key]
    end
  end
  return plan
end
function M.sequence(name, plan)
  if plan and plan.sequences and plan.sequences[name] then
    return plan.sequences[name]
  end
  return assert(
    ({
      configure = { 'configure' },
      build = { 'configure', 'build' },
      check = { 'configure', 'check' },
      test = { 'configure', 'build', 'test' },
      run = { 'configure', 'build', 'run' },
      format = { 'configure', 'format' },
      lint = { 'lint' },
      benchmark = { 'configure', 'build', 'benchmark' },
      profile = { 'configure', 'build', 'profile' },
      submit = { 'submit' },
      status = { 'status' },
      cancel = { 'cancel' },
      package = { 'package' },
      xcode = { 'xcode' },
    })[name],
    'Unknown task: ' .. tostring(name)
  )
end
function M.command(root, plan, step)
  local argv = plan[step]
  if step == 'run' or step == 'benchmark' or step == 'profile' then
    argv = plan.run_command and plan.run_command() or plan.run
  end
  if plan.commands and plan.commands[step] then
    argv = plan.commands[step]()
  end
  local executable
  if (step == 'profile' or step == 'benchmark') and plan.options[step] then
    executable = plan.executable and plan.executable() or false
  end
  return require('rivet.task_options').command(root, argv, plan.options, step, executable)
end
function M.names(root)
  local names = (M.adapter(root).names and M.adapter(root).names(root))
    or M.adapter(root).task_names
    or { 'configure', 'build', 'test', 'run', 'format' }
  local result = {}
  for _, name in ipairs(names) do
    result[#result + 1] = name
  end
  local options = require('rivet.task_options').load(root)
  for _, key in ipairs({ 'benchmark', 'profile', 'submit', 'status', 'cancel' }) do
    if options[key] then
      result[#result + 1] = key
    end
  end
  return result
end
return M
