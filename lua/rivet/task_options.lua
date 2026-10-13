local rt, json = require('rivet.runtime'), require('rivet.json')
local M = {}
local function array(value, label)
  assert(type(value) == 'table', label .. ' must be an argv array')
  for k, v in pairs(value) do
    assert(
      type(k) == 'number' and k >= 1 and k <= #value and type(v) == 'string' and not v:find('%z'),
      label .. ' must contain strings'
    )
  end
end
function M.validate(value)
  assert(type(value) == 'table', 'Task options must be an object')
  local allowed = {
    args = true,
    env = true,
    cwd = true,
    jobs = true,
    ranks = true,
    threads = true,
    gpus = true,
    launcher = true,
    benchmark = true,
    profile = true,
    submit = true,
    status = true,
    cancel = true,
    job_id = true,
    python = true,
    lua = true,
    python_module = true,
    test_runner = true,
  }
  for key in pairs(value) do
    assert(allowed[key], 'Unknown task option: ' .. tostring(key))
  end
  for _, key in ipairs({ 'args', 'launcher', 'benchmark', 'profile', 'submit', 'status', 'cancel' }) do
    if value[key] then
      array(value[key], key)
    end
  end
  for _, key in ipairs({ 'jobs', 'ranks', 'threads', 'gpus' }) do
    if value[key] then
      assert(
        type(value[key]) == 'number' and value[key] >= 1 and value[key] % 1 == 0,
        key .. ' must be a positive integer'
      )
    end
  end
  for _, key in ipairs({ 'cwd', 'job_id', 'python', 'lua', 'python_module', 'test_runner' }) do
    if value[key] then
      assert(type(value[key]) == 'string' and not value[key]:find('[%z\r\n]'), 'Invalid ' .. key)
    end
  end
  if value.test_runner then
    assert(
      value.test_runner == 'unittest' or value.test_runner == 'pytest',
      'Choose unittest or pytest'
    )
  end
  if value.cwd and value.cwd ~= '.' then
    rt.safe_relative(value.cwd)
  end
  if value.env then
    assert(type(value.env) == 'table', 'env must be an object')
    for k, v in pairs(value.env) do
      assert(
        type(k) == 'string'
          and k:match('^[A-Za-z_][A-Za-z0-9_]*$')
          and type(v) == 'string'
          and not v:find('%z'),
        'Invalid environment entry'
      )
    end
  end
  return value
end
function M.load(root)
  local text = rt.read(rt.confined(root, '.rivet.local.json'))
  return M.validate(text and json.decode(text) or {})
end
function M.plan(root, value)
  local spec = require('rivet.project').inspect(root)
  return {
    root = require('rivet.project').canonical(root),
    spec = spec,
    files = { ['.rivet.local.json'] = json.encode(M.validate(value)) },
    expected = {
      ['.rivet.local.json'] = rt.read(rt.confined(root, '.rivet.local.json')) or false,
    },
  }
end
function M.command(root, command, options, task, resolved_executable)
  options = options or M.load(root)
  local result = {}
  local executable = resolved_executable == false and nil
    or resolved_executable
    or (command and command[1])
  if resolved_executable == false then
    executable = nil
  end
  local vars = {
    root = root,
    executable = executable,
    ranks = tostring(options.ranks or 1),
    threads = tostring(options.threads or 1),
    gpus = tostring(options.gpus or 1),
    job_id = options.job_id,
  }
  local hook = options[task]
  local function expand(s)
    return (
      s:gsub('{([%w_]+)}', function(key)
        return assert(vars[key], 'Set ' .. key .. ' before running this hook')
      end)
    )
  end
  if hook then
    assert(#hook > 0, 'Empty ' .. task .. ' command')
    for _, arg in ipairs(hook) do
      result[#result + 1] = expand(arg)
    end
  else
    if task == 'run' and options.launcher then
      for _, arg in ipairs(options.launcher) do
        result[#result + 1] = expand(arg)
      end
    end
    for _, arg in ipairs(assert(command, 'Task unavailable: ' .. task)) do
      result[#result + 1] = arg
    end
  end
  if task == 'run' or task == 'profile' or task == 'benchmark' then
    for _, arg in ipairs(options.args or {}) do
      result[#result + 1] = arg
    end
  end
  local env = {}
  for k, v in pairs(options.env or {}) do
    env[k] = v
  end
  if options.threads then
    env.OMP_NUM_THREADS = tostring(options.threads)
  end
  -- GPU count is a scheduler/launcher parameter, not an automatic device selection.
  if options.jobs then
    env.CMAKE_BUILD_PARALLEL_LEVEL = tostring(options.jobs)
  end
  return require('rivet.presets').environment_command(result, env),
    (
      (task == 'run' or task == 'profile' or task == 'benchmark')
        and options.cwd
        and options.cwd ~= '.'
        and rt.confined(root, options.cwd)
      or root
    )
end
return M
