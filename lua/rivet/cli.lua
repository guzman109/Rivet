local M = {}
local rt = require('rivet.runtime')
local project = require('rivet.project')
local term = require('rivet.terminal')
local reference = require('rivet.cli_reference')
local function parse(args)
  local positional, opts, i = {}, {}, 2
  local allowed = reference.allowed()
  while i <= #args do
    local arg = args[i]
    if arg == '-h' then
      opts.help = true
    elseif arg:sub(1, 2) == '--' then
      local key = arg:sub(3):gsub('-', '_')
      assert(allowed[key], 'Unknown option: --' .. arg:sub(3))
      if key == 'preview' or key == 'interactive' or key == 'help' or key == 'build' then
        opts[key] = true
      else
        i = i + 1
        assert(args[i] and args[i]:sub(1, 2) ~= '--', 'Missing value for --' .. key)
        opts[key] = args[i]
      end
    else
      positional[#positional + 1] = arg
    end
    i = i + 1
  end
  for _, key in ipairs({ 'modules', 'std_modules', 'git' }) do
    if opts[key] ~= nil then
      assert(
        opts[key] == 'true' or opts[key] == 'false',
        '--' .. key:gsub('_', '-') .. ' must be true or false'
      )
      opts[key] = opts[key] == 'true'
    end
  end
  if opts.standard then
    opts.standard = assert(tonumber(opts.standard), 'Invalid standard')
  end
  return positional, opts
end
local function show_notes(plan)
  for _, note in ipairs(plan.notes or {}) do
    term.message('warning', 'Note:', note)
  end
end
local function show(plan)
  local paths = {}
  for path in pairs(plan.files) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  term.heading('Preview · ' .. plan.spec.name)
  term.row('Project:', plan.root)
  term.row('Files:', tostring(#paths))
  show_notes(plan)
  if plan.git then
    term.message('muted', plan.git.summary)
  end
  for _, path in ipairs(paths) do
    term.heading('--- ' .. path .. ' ---')
    if path == '.rivet.json' then
      term.message('muted', '(project manifest)')
    else
      io.write(plan.files[path] or '(remove file)\n')
    end
  end
end
local function choose(prompt, items)
  term.heading(prompt)
  for i, item in ipairs(items) do
    term.row(i .. '. ' .. item.label, item.description or '')
    if item.preview then
      print(type(item.preview) == 'table' and table.concat(item.preview, '\n') or item.preview)
    end
  end
  term.prompt('Choice [1] › ')
  local reply = io.read('*l')
  assert(reply, 'Cancelled')
  local index = reply == '' and 1 or tonumber(reply)
  assert(index and items[index], 'Invalid choice')
  return items[index].id
end
local function interactive(opts)
  local licenses = require('rivet.licenses')
  if not opts.license then
    opts.license = choose('Project license', licenses.choices)
  end
  if opts.license ~= 'none' then
    if not opts.license_holder then
      term.prompt('Copyright holder (person or organization) › ')
      opts.license_holder = licenses.holder(assert(io.read('*l'), 'Cancelled'))
    end
    if not opts.license_year then
      term.prompt('Copyright year [' .. os.date('%Y') .. '] › ')
      local year = assert(io.read('*l'), 'Cancelled')
      opts.license_year = licenses.year(year ~= '' and year or nil)
    end
    local files =
      licenses.files(licenses.normalize(opts.license, opts.license_holder, opts.license_year))
    choose('Review project license', {
      {
        id = true,
        label = 'Use ' .. opts.license,
        preview = files.LICENSE .. (files.NOTICE and '\n--- NOTICE ---\n' .. files.NOTICE or ''),
      },
    })
  end
  if opts.git == nil then
    opts.git = choose('Git repository', {
      {
        id = false,
        label = 'Skip Git initialization',
        description = 'Generate the language-specific .gitignore only.',
      },
      {
        id = true,
        label = 'Initialize Git',
        description = 'Reuse an existing repository when present. No staging or commits.',
      },
    })
  end
  for _, step in
    ipairs(require('rivet.model').questions('new', opts, { tools = rt.detect_tools() }))
  do
    local before = opts[step.key]
    local visible = not step.when or step.when(opts)
    assert(
      before == nil or before == opts[step.key],
      'The selected choices conflict with --' .. step.key:gsub('_', '-')
    )
    if visible and opts[step.key] == nil then
      if step.input then
        term.prompt(step.title .. ' [' .. (step.default or '') .. '] › ')
        local value = assert(io.read('*l'), 'Cancelled')
        opts[step.key] = value ~= '' and value or step.default
      else
        opts[step.key] = choose(step.title, step.items)
      end
    end
  end
end
local function run_task(root, name, preset, target_name, options)
  options = options or {}
  options.task = name
  local tasks = require('rivet.tasks').plan(root, preset, target_name, options)
  for _, step in ipairs(require('rivet.tasks').sequence(name, tasks)) do
    if step == 'configure' and tasks.prepare then
      tasks.prepare()
    end
    local argv, cwd = require('rivet.tasks').command(root, tasks, step)
    assert(argv, 'Project has no runnable executable')
    local display = {}
    for _, argument in ipairs(argv) do
      display[#display + 1] = argument:find('[%s;]') and rt.quote(argument) or argument
    end
    term.heading(step:sub(1, 1):upper() .. step:sub(2))
    term.message('command', '›', table.concat(display, ' '))
    local result = rt.run(argv, { cwd = cwd or root })
    io.write(result.stdout)
    io.stderr:write(result.stderr)
    if result.code ~= 0 then
      term.message('error', 'Failed', step .. ' exited with status ' .. result.code)
      return result.code
    end
    if tasks.after_step then
      tasks.after_step(step, result)
    end
    if step == 'configure' and tasks.after_configure then
      local ok, message = tasks.after_configure()
      if not ok and message then
        io.stderr:write(message .. '\n')
      end
    end
  end
  term.message('success', 'Done', name .. ' completed')
  return 0
end
function M.main(args)
  local command = args[1]
  if command == '--version' then
    term.message('accent', 'Rivet.nvim', require('rivet.version'))
    return 0
  end
  if not command or command == '--help' or command == '-h' or command == 'help' then
    reference.help(args[2])
    return 0
  end
  local pos, opts = parse(args)
  if opts.help then
    reference.help(command)
    return 0
  end
  if command == 'completions' then
    assert(#pos == 1, 'Usage: rivet completions fish|bash|zsh')
    io.write(require('rivet.completions').generate(pos[1]))
    return 0
  end
  assert(not opts.build or command == 'new', '--build is only available with rivet new')
  assert(opts.git == nil or command == 'new', '--git is only available with rivet new')
  assert(
    command == 'new' or not (opts.license or opts.license_holder or opts.license_year),
    'License options are only available with rivet new'
  )
  if command == 'migrate' then
    local root = opts.root and rt.absolute(opts.root) or assert(project.root(), 'No project found')
    local plan = require('rivet.migration').plan(root)
    if opts.preview then
      show(plan)
    else
      project.apply(root, plan)
      term.message('success', 'Migrated project:', root)
    end
    return 0
  end
  if command == 'doctor' then
    local root = opts.root and rt.absolute(opts.root) or project.root(rt.cwd())
    local doctor = root and require('rivet.tasks').service(project.inspect(root), 'doctor')
      or require('rivet.doctor')
    local exit = 0
    for _, entry in ipairs(doctor.inspect(root, opts.preset, { build_preset = opts.build_preset })) do
      term.message(
        ({ error = 'error', warning = 'warning', warn = 'warning', ok = 'success' })[entry.level]
          or 'muted',
        entry.level:upper() .. ':',
        entry.message
      )
      if entry.level == 'error' then
        exit = 1
      end
    end
    return exit
  end
  if command == 'styles' or command == 'layouts' then
    for _, item in ipairs(require('rivet.catalog')[command]) do
      term.heading(item.id .. ' · ' .. item.label)
      print(item.description)
      if item.preview then
        print(type(item.preview) == 'table' and table.concat(item.preview, '\n') or item.preview)
      end
    end
    return 0
  end
  if command == 'config' and not pos[2] then
    local config = require('rivet.tool_config')
    if not pos[1] then
      for _, tool in ipairs(config.tools()) do
        term.heading(tool.id)
        print(tool.description)
        term.row('File:', tool.path)
        term.row('Reference:', tool.url)
      end
    else
      local tool = config.tool(pos[1])
      term.heading(tool.label)
      print(tool.description)
      term.row('File:', tool.path)
      term.row('Reference:', tool.url)
      for _, entry in ipairs(config.catalog(tool.id)) do
        term.heading(entry.key .. ' (' .. entry.type .. ')')
        print(entry.description)
        if entry.default then
          print('  Default: ' .. entry.default)
        end
        for _, choice in ipairs(entry.choices or {}) do
          print('  ' .. choice.id .. ' — ' .. (choice.description or choice.label))
        end
      end
    end
    return 0
  end
  if command == 'new' then
    local root = assert(pos[1] or opts.root, 'Usage: rivet new ROOT')
    local preview, interactive_mode, build, preset =
      opts.preview, opts.interactive, opts.build, opts.preset
    opts.root, opts.preview, opts.interactive, opts.build, opts.preset = nil, nil, nil, nil, nil
    opts.name = opts.name
      or require('rivet.model').default_name(
        rt.absolute(root):match('([^/]+)$') or 'project',
        opts.language
      )
    if interactive_mode then
      interactive(opts)
    end
    if build then
      assert(preset == nil or preset == 'debug' or preset == 'release', 'Choose debug or release')
    end
    if not opts.language or opts.language == 'cpp' then
      opts.compiler = opts.compiler or rt.detect_tools().clangxx
    end
    local plan = project.plan(opts, root)
    if preview or interactive_mode then
      show(plan)
    end
    if preview then
      return 0
    end
    if interactive_mode then
      term.prompt('\nCreate project? [y/N] › ')
      if io.read('*l') ~= 'y' then
        term.message('muted', 'Cancelled')
        return 0
      end
    end
    project.apply(plan.root, plan)
    term.message('success', 'Created', plan.root)
    if build then
      return run_task(plan.root, 'build', preset)
    end
    if plan.spec.std_modules then
      print(
        'Run rivet build --root '
          .. rt.quote(plan.root)
          .. ' to verify import std support and generate module interfaces for the compiler and clangd.'
      )
    end
    return 0
  end
  local root = opts.root and rt.absolute(opts.root) or project.root(rt.cwd())
  assert(root, 'No Rivet project found; use --root PATH or rivet new ROOT')
  if command == 'config' then
    assert(#pos == 3, 'Usage: rivet config TOOL [KEY VALUE] [--preview]')
    local plan = require('rivet.tool_config').plan(root, pos[1], pos[2], pos[3])
    if opts.preview then
      show(plan)
    else
      project.apply(root, plan)
      term.message('success', 'Updated', require('rivet.tool_config').tool(pos[1]).path)
      show_notes(plan)
    end
    return 0
  end
  if command == 'upgrade' then
    assert(#pos == 0, 'Usage: rivet upgrade [--root PATH] [--preview]')
    local plan = require('rivet.upgrade').plan(root)
    if opts.preview then
      show(plan)
    else
      project.apply(root, plan)
      term.message('success', 'Upgraded supplementary templates:', root)
      show_notes(plan)
    end
    return 0
  end
  if command == 'move' or command == 'remove' or command == 'module-rename' then
    local plan = project.lifecycle_plan(root, {
      action = command == 'module-rename' and 'module' or command,
      from = pos[1] or opts.from,
      to = pos[2] or opts.to,
    })
    if opts.preview then
      show(plan)
    else
      project.apply(root, plan)
      term.message('success', 'Updated', root)
    end
    return 0
  end
  if command == 'repair' then
    local plan = project.repair_plan(root, assert(pos[1], 'Managed file path required'))
    if opts.preview then
      show(plan)
    else
      project.apply(root, plan)
      term.message('success', 'Restored', 'Generated file restored; edited backup saved')
    end
    return 0
  end
  if command == 'targets' then
    for _, target in ipairs(require('rivet.tasks').targets(root, opts.preset, opts)) do
      term.row(target.name, target.type)
    end
    return 0
  end
  if command == 'file' or command == 'target' or command == 'dependency' then
    opts.name = assert(pos[1], 'Missing name')
    if command == 'dependency' then
      opts.tag = opts.tag or opts.version
    end
    local planner = ({
      file = project.file_plan,
      target = project.target_plan,
      dependency = project.dependency_plan,
    })[command]
    local plan = planner(root, opts)
    if opts.preview then
      show(plan)
    else
      project.apply(root, plan)
      term.message('success', 'Updated', root)
    end
    return 0
  end
  if command == 'cache' then
    local cmake = require('rivet.tasks').adapter(root)
    assert(cmake.cache, 'This provider has no CMake cache editor')
    local entries = cmake.cache(root, opts.preset)
    assert(#entries > 0, 'No cache yet; run rivet configure first')
    if pos[1] then
      local entry
      for _, e in ipairs(entries) do
        if e.name == pos[1] then
          entry = e
        end
      end
      assert(entry, 'Unknown cache variable: ' .. pos[1])
      local argv = cmake.set_cache(root, opts.preset, entry, assert(pos[2], 'Missing cache value'))
      local tasks = require('rivet.tasks').plan(
        root,
        opts.preset,
        nil,
        { task = 'configure', build_preset = opts.build_preset }
      )
      if tasks.prepare then
        tasks.prepare()
      end
      local r = rt.run(argv, { cwd = root })
      if r.code == 0 and tasks.after_configure then
        local ok, message = tasks.after_configure()
        if not ok and message then
          io.stderr:write(message .. '\n')
        end
      end
      io.write(r.stdout)
      io.stderr:write(r.stderr)
      return r.code
    end
    for _, e in ipairs(entries) do
      term.heading(e.name .. ':' .. e.type .. '=' .. e.value)
      print('  ' .. e.help)
    end
    return 0
  end
  return run_task(root, command, opts.preset, opts.target, opts)
end
return M
