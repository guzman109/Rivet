local M = {}
local context = require('rivet.context')

-- Public functions live in rivet.commands.*; they load on first use.
local exports = {
  new = 'new',
  cmake = 'cmake',
  preset = 'tasks',
  build_preset = 'tasks',
  test_preset = 'tasks',
  build_target = 'tasks',
  statusline = 'tasks',
  status = 'tasks',
  run_target = 'tasks',
  task = 'tasks',
  file = 'project',
  target = 'project',
  dependency = 'project',
  profile = 'project',
  identity = 'project',
  files = 'project',
  module_rename = 'project',
  repair = 'project',
  run_options = 'project',
  doctor = 'project',
  header = 'project',
  header_defaults = 'project',
  migrate = 'project',
}
setmetatable(M, {
  __index = function(_, name)
    local module = exports[name]
    return module and require('rivet.commands.' .. module)[name]
  end,
})

-- { :Rivet subcommand, :RivetX command, function, description }
local commands = {
  { 'new', 'RivetNew', 'new', 'Create a project with previews' },
  { 'file', 'RivetFile', 'file', 'Add a file from a language template' },
  { 'files', 'RivetFiles', 'files', 'Review a registered file move or removal' },
  { 'header', 'RivetHeader', 'header', 'Preview and edit the current file comment header' },
  {
    'header-defaults',
    'RivetHeaderDefaults',
    'header_defaults',
    'Change comment headers for future project files',
  },
  { 'target', 'RivetTarget', 'target', 'Add a CMake target' },
  { 'dependency', 'RivetDependency', 'dependency', 'Add a pinned CPM dependency' },
  { 'cmake', 'RivetCMake', 'cmake', 'Edit project CMake cache options' },
  { 'preset', 'RivetPreset', 'preset', 'Change the remembered configure preset' },
  { 'build-preset', 'RivetBuildPreset', 'build_preset', 'Choose an associated build preset' },
  { 'test-preset', 'RivetTestPreset', 'test_preset', 'Choose an associated test preset' },
  { 'build-target', 'RivetBuildTarget', 'build_target', 'Choose the target to build' },
  { 'status', 'RivetStatus', 'status', 'Show active preset and target choices' },
  { 'run-target', 'RivetRunTarget', 'run_target', 'Change the remembered application target' },
  {
    'run-options',
    'RivetRunOptions',
    'run_options',
    'Review local task arguments, environment, and hooks',
  },
  { 'profile', 'RivetProfile', 'profile', 'Save reusable project choices locally' },
  { 'identity', 'RivetIdentity', 'identity', 'Preview and save a local header identity' },
  {
    'module-rename',
    'RivetModuleRename',
    'module_rename',
    'Review module declarations and imports under a new identity',
  },
  {
    'repair',
    'RivetRepair',
    'repair',
    'Review restoring a generated file while backing up local edits',
  },
  { 'migrate', 'RivetMigrate', 'migrate', 'Review migrating an Outset project to Rivet' },
  { 'doctor', 'RivetDoctor', 'doctor', 'Check project toolchain availability' },
}
local task_names = { 'repeat', 'configure', 'build', 'test', 'run', 'format' }

local function run(name, ...)
  return context.protected(M[name])(...)
end

local function dispatch(args)
  local subcommand, rest = args.args:match('^%s*(%S*)%s*(.-)%s*$')
  if subcommand == 'task' then
    return run('task', rest)
  end
  for _, command in ipairs(commands) do
    if command[1] == subcommand then
      return run(command[3])
    end
  end
  require('rivet.ui').notify(
    subcommand == '' and 'Usage: :Rivet {subcommand}. Press Tab to list subcommands.'
      or ('Unknown Rivet subcommand: ' .. subcommand),
    vim.log.levels.ERROR
  )
end

local function complete(lead, line)
  local words = vim.split(line:sub(1, #line - #lead), '%s+', { trimempty = true })
  local choices = {}
  if #words == 1 then
    choices[1] = 'task'
    for _, command in ipairs(commands) do
      choices[#choices + 1] = command[1]
    end
  elseif #words == 2 and words[2] == 'task' then
    choices = task_names
  end
  return vim.tbl_filter(function(choice)
    return vim.startswith(choice, lead)
  end, choices)
end

local registered = false
local function register()
  for _, command in ipairs(commands) do
    vim.api.nvim_create_user_command(command[2], function()
      run(command[3])
    end, { desc = command[4], force = true })
  end
  vim.api.nvim_create_user_command('RivetTask', function(args)
    run('task', args.args)
  end, {
    desc = 'Run a project build task',
    nargs = '?',
    force = true,
    complete = function()
      return task_names
    end,
  })
  vim.api.nvim_create_user_command('Rivet', dispatch, {
    desc = 'Run a Rivet subcommand',
    nargs = '*',
    force = true,
    complete = complete,
  })
end

-- plugin/rivet.lua calls setup() at startup and plugin managers may call it
-- again with options; options merge and commands are registered once.
---@param opts? rivet.Config
function M.setup(opts)
  context.config = vim.tbl_deep_extend('force', context.config, opts or {})
  if not registered then
    register()
    registered = true
  end
end

return M
