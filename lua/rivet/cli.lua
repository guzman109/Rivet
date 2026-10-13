local M = {}
local rt = require('rivet.runtime')
local project = require('rivet.project')
local function help()
  print([[
Rivet — Neovim-first project tools (macOS/Linux)

rivet new ROOT [--name NAME] [--interactive] [--preview] [--build]
  --language cpp|c|python|rust|swift
  --profile general|cpu|openmp|mpi|cuda|metal|webgpu|vulkan|opengl
  --cuda-standard 17|20|23 --cuda-architectures native|all-major|80;90
  --manager python|uv --edition 2021|2024
  --standard 17|20|23|26 (C++), 11|17|23 (C)
  --modules true|false --std-modules true|false
  --module-layout single|split
  --style LLVM|Google|Chromium|Mozilla|WebKit|Microsoft|GNU
  --layout feature|library|flat --kind app|library (Rust also: workspace)
  --header-guard pragma|ifndef
  --generator Ninja|"Unix Makefiles" --compiler /path/to/clang++
  --git true|false
  --license none|MIT|Apache-2.0|BSD-3-Clause|GPL-3.0-only
  --license-holder "Ada Lovelace" --license-year 2026
rivet file NAME [--target NAME] [--preview]
  C++ --kind source|header|pair|class|module|module_impl|c_source|c_header
  Other providers use their native source template.
rivet target NAME --kind app|library
rivet dependency NAME --repository owner/repo --tag PIN --target lib::lib --link-to NAME
rivet move FROM TO [--preview]
rivet remove PATH [--preview]
rivet module-rename FROM TO [--preview]
rivet repair MANAGED_FILE [--preview]
rivet migrate [--root PATH] [--preview]
rivet --version
rivet targets
rivet configure|build|check|test|run|format|lint|package|xcode [--preset NAME] [--target APP]
  --build-preset NAME --test-preset NAME --build-target TARGET
rivet cache [KEY VALUE] [--preset NAME]
rivet doctor [--root PATH] [--preset NAME]
rivet styles|layouts

All project commands accept --root PATH (default: nearest supported project).
Existing CMake/Cargo/Python/SwiftPM projects do not need an Rivet manifest for tasks.
Only manifest-owned projects support generated file mutations.
Runtime argv/env/cwd and optional benchmark/profile/submit/status/cancel hooks live
in .rivet.local.json. Hooks run only when explicitly selected.
File/target/dependency commands accept --preview to inspect without writing.
New defaults: C++26, named modules, standard-library headers, feature layout,
Ninja, LLVM style. --std-modules true opts into import std independently of
--modules; CMake verifies actual toolchain support and errors if unavailable.
Use new . to create in the current folder; the folder supplies the default name.
C++ names are normalized to identifiers; --name overrides the inferred name.
--git true initializes Git after creation or reuses the enclosing repository.
Git initialization is opt-in; no files are staged or committed. Language-specific ignore rules
are always generated, before existing .gitignore rules so user exceptions win.
new --build runs the provider's Build workflow (Debug unless --preset is set).
After configure, .clangd follows the selected compilation database via
.cache/rivet. Custom .clangd files are preserved.
If configure/build fails, generated files remain available for correction.
The first import std build generates module interfaces used by the compiler
and clangd. --preview never writes or builds, including with --build.
CMake Build configures first; Test/Run configure and build. Native providers
use their ecosystem tasks. C++ projects also include optional justfile recipes.
No packages are downloaded by scaffolding. CPM downloads only during configure
after a dependency is explicitly added. No runtime LuaRocks dependencies.
]])
end
local function parse(args)
  local positional, opts, i = {}, {}, 2
  local allowed = {
    preview = true,
    interactive = true,
    build = true,
    help = true,
    modules = true,
    std_modules = true,
    module_layout = true,
    build_preset = true,
    test_preset = true,
    build_target = true,
    style = true,
    layout = true,
    kind = true,
    header_guard = true,
    generator = true,
    compiler = true,
    standard = true,
    name = true,
    root = true,
    target = true,
    module = true,
    repository = true,
    tag = true,
    version = true,
    link_to = true,
    preset = true,
    language = true,
    git = true,
    from = true,
    to = true,
    profile = true,
    cuda_standard = true,
    cuda_architectures = true,
    manager = true,
    edition = true,
    license = true,
    license_holder = true,
    license_year = true,
  }
  while i <= #args do
    local arg = args[i]
    if arg:sub(1, 2) == '--' then
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
local function show(plan)
  local paths = {}
  for path in pairs(plan.files) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  print('Project: ' .. plan.root)
  print('Name: ' .. plan.spec.name)
  if plan.git then
    print(plan.git.summary)
  end
  for _, path in ipairs(paths) do
    print('\n--- ' .. path .. ' ---')
    if path == '.rivet.json' then
      print('(project manifest)')
    else
      io.write(plan.files[path] or '(remove file)\n')
    end
  end
end
local function choose(prompt, items)
  print('\n' .. prompt)
  for i, item in ipairs(items) do
    print(i .. '. ' .. item.label .. ' — ' .. (item.description or ''))
    if item.preview then
      print(type(item.preview) == 'table' and table.concat(item.preview, '\n') or item.preview)
    end
  end
  io.write('Choice [1]: ')
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
      io.write('Copyright holder (person or organization): ')
      opts.license_holder = licenses.holder(assert(io.read('*l'), 'Cancelled'))
    end
    if not opts.license_year then
      io.write('Copyright year [' .. os.date('%Y') .. ']: ')
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
        io.write(step.title .. ' [' .. (step.default or '') .. ']: ')
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
    print('> ' .. table.concat(argv, ' '))
    local result = rt.run(argv, { cwd = cwd or root })
    io.write(result.stdout)
    io.stderr:write(result.stderr)
    if result.code ~= 0 then
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
  return 0
end
function M.main(args)
  local command = args[1]
  if command == '--version' then
    print('Rivet.nvim ' .. require('rivet.version'))
    return 0
  end
  if not command or command == '--help' or command == 'help' then
    help()
    return 0
  end
  local pos, opts = parse(args)
  if opts.help then
    help()
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
      print('Migrated project: ' .. root)
    end
    return 0
  end
  if command == 'doctor' then
    local root = opts.root and rt.absolute(opts.root) or project.root(rt.cwd())
    local doctor = root and require('rivet.tasks').service(project.inspect(root), 'doctor')
      or require('rivet.doctor')
    local exit = 0
    for _, entry in ipairs(doctor.inspect(root, opts.preset, { build_preset = opts.build_preset })) do
      print(entry.level:upper() .. ': ' .. entry.message)
      if entry.level == 'error' then
        exit = 1
      end
    end
    return exit
  end
  if command == 'styles' or command == 'layouts' then
    for _, item in ipairs(require('rivet.catalog')[command]) do
      print(item.id .. ' — ' .. item.label .. '\n' .. item.description)
      if item.preview then
        print(type(item.preview) == 'table' and table.concat(item.preview, '\n') or item.preview)
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
      io.write('\nCreate project? [y/N]: ')
      if io.read('*l') ~= 'y' then
        print('Cancelled')
        return 0
      end
    end
    project.apply(plan.root, plan)
    print('Created ' .. plan.root)
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
      print('Updated ' .. root)
    end
    return 0
  end
  if command == 'repair' then
    local plan = project.repair_plan(root, assert(pos[1], 'Managed file path required'))
    if opts.preview then
      show(plan)
    else
      project.apply(root, plan)
      print('Restored generated file and saved edited backup')
    end
    return 0
  end
  if command == 'targets' then
    for _, target in ipairs(require('rivet.tasks').targets(root, opts.preset, opts)) do
      print(target.name .. ' (' .. target.type .. ')')
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
      print('Updated ' .. root)
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
      print(e.name .. ':' .. e.type .. '=' .. e.value .. '\n  ' .. e.help)
    end
    return 0
  end
  return run_task(root, command, opts.preset, opts.target, opts)
end
return M
