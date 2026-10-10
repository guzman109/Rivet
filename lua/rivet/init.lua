local M = {}
local config = { projects_dir = nil, default_preset = 'debug', profiles = {} }
local ui = require('rivet.ui')
local active_root

local function protected(fn)
  return function(...)
    local ok, result = pcall(fn, ...)
    if not ok then
      ui.notify(tostring(result), vim.log.levels.ERROR)
    end
    return ok and result or nil
  end
end

local function input(prompt, default, callback)
  ui.input(prompt, default, protected(callback))
end

local function choose(prompt, items, callback)
  ui.choose(prompt, items, protected(callback))
end

local function current_root()
  local project = require('rivet.project')
  local output_root = vim.b.rivet_root
  if vim.bo.buftype == 'quickfix' then
    local context = vim.fn.getqflist({ context = 0 }).context
    if type(context) == 'table' and context.rivet then
      output_root = context.root
    end
  end
  local path = vim.api.nvim_buf_get_name(0)
  if path == '' or path:match('^%w+://') then
    path = vim.fn.getcwd()
  else
    path = vim.fn.fnamemodify(path, ':h')
  end
  local root = output_root or project.root(path) or project.root(vim.fn.getcwd()) or active_root
  assert(
    root,
    'No supported project found. Run :RivetNew or open CMakeLists.txt, pyproject.toml, Cargo.toml, or Package.swift.'
  )
  active_root = root
  return root
end

local function review(root, plan, after_apply, back)
  return ui.review(
    root,
    plan,
    protected(function()
      require('rivet.project').apply(root, plan)
      active_root = plan.root or root
      ui.notify('Project files saved in ' .. root)
      if after_apply then
        after_apply(active_root, plan.spec)
      end
    end),
    { back = back }
  )
end

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

local style_sample = [[#include <algorithm>
#include <vector>

namespace simulation {
class ParticleSystem {
public:
  explicit ParticleSystem(int count) : positions_(count, 0.0f) {}
  void step(float delta) {
    for (auto &position : positions_) {
      if (position < 100.0f) { position += delta; }
    }
  }
private:
  std::vector<float> positions_;
};
} // namespace simulation
]]

local function style_items()
  local catalog = require('rivet.catalog')
  local tools = require('rivet.runtime').detect_tools()
  local items = vim.deepcopy(catalog.styles)
  for _, item in ipairs(items) do
    local style = item.id
    local fallback = item.preview
    local cached
    item.preview = function()
      if cached then
        return cached
      end
      if tools.clang_format then
        local result = vim
          .system({ tools.clang_format, '--style=' .. style }, {
            text = true,
            stdin = catalog.style_sample or style_sample,
          })
          :wait(2000)
        if result.code == 0 then
          cached = 'Actual clang-format output (' .. style .. '):\n\n' .. result.stdout
          return cached
        end
      end
      return 'Install clang-format to preview this style using your installed formatter.\n\n'
        .. (fallback or style_sample)
    end
  end
  return items
end

function M.new()
  local runtime, model = require('rivet.runtime'), require('rivet.model')
  local preferences = require('rivet.preferences').load()
  local profiles = vim.tbl_extend('force', preferences.profiles, config.profiles)
  local function start(options)
    local spec = vim.deepcopy(options or { language = 'cpp' })
    spec.language = spec.language or 'cpp'
    local provider = model.provider(spec)
    local tools = runtime.detect_tools()
    local function choose_back(prompt, items, callback, back)
      local choices = vim.list_extend(vim.deepcopy(items), { '← Back' })
      choose(prompt, choices, function(value)
        if value == '← Back' then
          return back()
        end
        callback(value)
      end)
    end
    local steps = {
      {
        run = function(next_step, back)
          choose_back('Create project in: ', { 'New folder', 'Current folder' }, function(value)
            spec._current_folder = value == 'Current folder'
            if spec._current_folder then
              spec._destination = runtime.absolute(vim.fn.getcwd())
            end
            next_step()
          end, back)
        end,
      },
      {
        key = 'name',
        title = 'Project name',
        input = true,
        default = function()
          return spec._current_folder
              and model.default_name(spec._destination:match('[^/]+$') or 'project', spec.language)
            or ('hello_' .. spec.language)
        end,
        validate = function(value)
          model.normalize({ language = spec.language, name = value })
        end,
      },
      {
        key = '_destination',
        title = 'Project directory',
        input = true,
        when = function()
          if spec._current_folder then
            return false
          end
          return true
        end,
        default = function()
          return runtime.join(config.projects_dir or vim.fn.getcwd(), spec.name)
        end,
        validate = function(value)
          assert(value ~= '', 'A project directory is required')
        end,
      },
      {
        run = function(next_step, back)
          choose_back(
            'Git repository: ',
            { 'Skip Git initialization', 'Initialize Git (reuse an existing repository)' },
            function(value)
              spec.git = value ~= 'Skip Git initialization'
              next_step()
            end,
            back
          )
        end,
      },
      {
        when = function()
          return provider.services and provider.services.headers
        end,
        run = function(next_step, back)
          local items = { 'No header', 'Personalize and preview styles' }
          local identity = config.identity or preferences.identity
          if identity then
            table.insert(items, 1, 'Use saved identity and preview styles')
          end
          choose_back('File comment headers: ', items, function(value)
            if value == 'No header' then
              spec.comment_header = nil
              return next_step()
            end
            local initial =
              vim.deepcopy(spec.comment_header or (value:match('^Use saved') and identity) or {})
            if spec.license and spec.license ~= 'none' then
              initial.license = spec.license
              initial.copyright = spec.license_year .. ' ' .. spec.license_holder
            end
            require('rivet.header_ui').configure(initial, {
              filename = ({
                python = 'main.py',
                rust = 'main.rs',
                swift = 'main.swift',
                c = 'main.c',
              })[spec.language] or 'main.cpp',
              project = spec.name,
              language = spec.language,
            }, function(header)
              spec.comment_header = header
              next_step()
            end, { back = back })
          end, back)
        end,
      },
    }
    -- License selection precedes comment-header personalization.
    local license_steps = require('rivet.licenses').questions(spec)
    for index, step in ipairs(license_steps) do
      table.insert(steps, 4 + index, step)
    end
    vim.list_extend(steps, model.questions('new', spec, { tools = tools, styles = style_items() }))
    require('rivet.wizard').run(
      spec,
      steps,
      protected(function(back)
        local destination = runtime.absolute(spec._destination)
        local options = vim.deepcopy(spec)
        options._destination, options._current_folder, options._license_review = nil, nil, nil
        review(
          destination,
          require('rivet.project').plan(options, destination),
          function(root, created)
            if not created.std_modules then
              return
            end
            choose(
              'Check import std support and build Debug interfaces for clangd? Files remain if it fails.',
              { 'Configure and build Debug now', 'Later (:RivetTask build)' },
              function(value)
                if value == 'Configure and build Debug now' then
                  run_workflow(root, 'build', 'debug')
                end
              end
            )
          end,
          back
        )
      end)
    )
  end
  local function select_language()
    local languages = model.list_languages()
    table.sort(languages, function(a, b)
      if a == 'cpp' then
        return true
      elseif b == 'cpp' then
        return false
      else
        return a < b
      end
    end)
    if #languages == 1 then
      return start({ language = languages[1] })
    end
    choose('Project language: ', languages, function(language)
      start({ language = language })
    end)
  end
  local choices = { { label = 'New choices' } }
  for name, options in pairs(profiles) do
    choices[#choices + 1] = { label = name, options = options }
  end
  table.sort(choices, function(a, b)
    if not a.options then
      return true
    end
    if not b.options then
      return false
    end
    return a.label < b.label
  end)
  if #choices == 1 then
    return select_language()
  end
  choose('Project profile: ', choices, function(item)
    if item.options then
      start(item.options)
    else
      select_language()
    end
  end)
end

local function mutation(kind)
  local root = current_root()
  local project, model = require('rivet.project'), require('rivet.model')
  local spec, options = project.load(root), {}
  require('rivet.wizard').run(
    options,
    model.questions(kind, spec),
    protected(function(back)
      if options.link_to == '' then
        options.link_to = nil
      end
      review(root, project[kind .. '_plan'](root, options), nil, back)
    end)
  )
end
function M.file()
  mutation('file')
end
function M.target()
  mutation('target')
end
function M.dependency()
  mutation('dependency')
end

function M.profile()
  local spec = require('rivet.project').load(current_root())
  input('Save project choices as profile: ', spec.name, function(name)
    assert(name:match('%S') and not name:find('[%z\r\n]'), 'A profile name is required')
    local preferences = require('rivet.preferences')
    local options = require('rivet.model').profile(spec)
    ui.select_preview('Save local project profile', {
      {
        label = name,
        preview = vim.inspect(options)
          .. '\n\nReusable choices only. Destination, compiler paths, Git actions, and identity are not saved in profiles.',
      },
    }, function()
      local value = preferences.load()
      value.profiles[name] = options
      preferences.save(value)
      ui.notify('Saved project profile: ' .. name)
    end, { review = true })
  end)
end

function M.identity()
  local preferences = require('rivet.preferences')
  require('rivet.header_ui').configure(
    config.identity or preferences.load().identity,
    { filename = 'example.cpp', project = 'example' },
    function(identity)
      ui.select_preview('Save local header identity', {
        {
          label = 'Identity and header style',
          preview = require('rivet.headers').render(
            identity,
            { filename = 'example.cpp', project = 'example' }
          ) .. '\nSaved locally for future wizards. Existing projects stay as they are.',
        },
      }, function()
        local value = preferences.load()
        value.identity = identity
        preferences.save(value)
        ui.notify('Saved local header identity')
      end, { review = true })
    end
  )
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
  local preferred = state.preset or config.default_preset
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
  local root = vim.b.rivet_root or active_root
  if not root then
    return ''
  end
  local state = require('rivet.task_state').load(root)
  local parts = { 'Rivet', state.preset or config.default_preset }
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

function M.files()
  local root = current_root()
  local spec = require('rivet.project').load(root)
  local entries = {}
  for _, t in ipairs(spec.targets or {}) do
    for _, field in ipairs({ 'sources', 'headers', 'modules' }) do
      for _, path in ipairs(t[field] or {}) do
        entries[#entries + 1] = { name = path }
      end
    end
  end
  choose('Registered file: ', entries, function(item)
    choose('File operation: ', { 'Move / rename file', 'Remove file' }, function(action)
      local function plan(destination)
        review(
          root,
          require('rivet.project').lifecycle_plan(
            root,
            { action = destination and 'move' or 'remove', from = item.name, to = destination }
          )
        )
      end
      if action == 'Remove file' then
        return plan()
      end
      input(
        'New project-relative path (includes/identifiers need separate edits): ',
        item.name,
        plan
      )
    end)
  end)
end
function M.module_rename()
  local root = current_root()
  local spec = require('rivet.project').load(root)
  local names = {}
  for name in pairs(spec.module_names or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  choose('Module identity to refactor: ', names, function(old)
    input('New module name (review declarations and imports): ', old, function(new)
      review(
        root,
        require('rivet.project').lifecycle_plan(root, { action = 'module', from = old, to = new })
      )
    end)
  end)
end
function M.repair()
  local root = current_root()
  local project = require('rivet.project')
  local spec = project.load(root)
  local paths = {}
  for path in pairs(spec.generated or {}) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  choose('Restore a generated file and back up your edited copy: ', paths, function(path)
    review(root, project.repair_plan(root, path))
  end)
end
function M.run_options()
  local root = current_root()
  local settings = require('rivet.task_options')
  local values = settings.load(root)
  input(
    'Local task options (JSON: args, env, cwd, jobs, ranks, threads, launcher, profiler/cluster hooks): ',
    vim.json.encode(values),
    function(text)
      review(root, settings.plan(root, vim.json.decode(text)))
    end
  )
end

local function configure_cache(root, preset, done)
  if ui.is_running(root) then
    return ui.notify('A task is already running for this project.', vim.log.levels.WARN)
  end
  local state = require('rivet.task_state').load(root)
  local task = require('rivet.tasks').plan(
    root,
    preset,
    nil,
    vim.tbl_extend('force', state, { task = 'configure' })
  )
  if task.prepare then
    task.prepare()
  end
  ui.run(
    root,
    task.configure,
    'configure (' .. preset .. ')',
    protected(function(ok)
      if not ok then
        return
      end
      if task.after_configure then
        local synced, message = task.after_configure()
        if not synced and message then
          ui.notify(message, vim.log.levels.WARN)
        end
      end
      done()
    end)
  )
end

local function cache_editor(root, preset, advanced)
  local cmake = require('rivet.tasks').adapter(root)
  assert(cmake.cache, 'This provider has no CMake cache editor')
  local cache = cmake.cache(root, preset)
  if #cache == 0 then
    choose('No CMake cache. Configure this project now?', { 'Configure', 'Cancel' }, function(value)
      if value == 'Configure' then
        configure_cache(root, preset, function()
          cache_editor(root, preset, advanced)
        end)
      end
    end)
    return
  end
  local items = {
    {
      id = '__advanced',
      label = advanced and 'Hide advanced entries' or 'Show advanced entries',
      preview = 'CMake cache values are project configuration options.\n\nSelect a value to edit it. BOOL values offer ON/OFF; other values use a text prompt or the choices provided by CMake.\n\nEdits are saved as local CMakeUserPresets.json overrides and reconfigure the selected build.\n\nAdvanced entries include compiler and toolchain details. Prefer choosing a fresh build directory when changing compilers or generators.',
    },
  }
  for _, entry in ipairs(cache) do
    if entry.type ~= 'INTERNAL' and entry.type ~= 'STATIC' and (advanced or not entry.advanced) then
      items[#items + 1] = {
        id = entry.name,
        label = entry.name .. ' = ' .. entry.value,
        entry = entry,
        description = entry.help or 'No description was supplied by this CMake project.',
        preview = 'Name: '
          .. entry.name
          .. '\nType: '
          .. entry.type
          .. '\nValue: '
          .. entry.value
          .. '\n\n'
          .. (entry.advanced and 'Advanced configuration option.\n\n' or '')
          .. 'Press Enter to edit. Changes reconfigure this project.\nPress q to leave the cache editor.',
      }
    end
  end
  table.sort(items, function(a, b)
    if a.id == '__advanced' then
      return true
    end
    if b.id == '__advanced' then
      return false
    end
    return a.id < b.id
  end)
  ui.select_preview(
    'CMake cache · ' .. preset,
    items,
    protected(function(item)
      if item.id == '__advanced' then
        return cache_editor(root, preset, not advanced)
      end
      local entry = item.entry
      local function save(value)
        assert(not ui.is_running(root), 'Wait for the current task before changing its cache')
        cmake.set_cache(root, preset, entry, value)
        configure_cache(root, preset, function()
          cache_editor(root, preset, advanced)
        end)
      end
      if entry.type == 'BOOL' then
        choose(entry.name .. ': ', { 'ON', 'OFF' }, save)
      elseif entry.choices and #entry.choices > 0 then
        choose(entry.name .. ': ', entry.choices, save)
      else
        input(entry.name .. ' (' .. entry.type .. '): ', entry.value, save)
      end
    end)
  )
end

function M.cmake()
  local root = current_root()
  preset_picker(root, function(preset)
    cache_editor(root, preset, false)
  end)
end

function M.doctor()
  local ok, root = pcall(current_root)
  require('rivet.health').root = ok and root or nil
  vim.cmd('checkhealth rivet')
end

function M.header()
  local root = current_root()
  require('rivet.header_ui').edit(
    root,
    require('rivet.project').load(root),
    vim.api.nvim_get_current_buf()
  )
end

function M.header_defaults()
  local root = current_root()
  local project = require('rivet.project')
  local spec = project.load(root)
  require('rivet.header_ui').configure(
    spec.comment_header,
    { filename = 'example.cpp', project = spec.name, language = spec.language },
    protected(function(value)
      review(root, project.header_plan(root, value))
    end)
  )
end

function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})
  local commands = {
    RivetMigrate = {
      function()
        local root = assert(require('rivet.project').root(), 'Open an Outset project first')
        review(root, require('rivet.migration').plan(root))
      end,
      'Review migrating an Outset project to Rivet',
    },
    RivetNew = { M.new, 'Create a project with previews' },
    RivetProfile = { M.profile, 'Save reusable project choices locally' },
    RivetIdentity = { M.identity, 'Preview and save a local header identity' },
    RivetFile = { M.file, 'Add a file from a language template' },
    RivetFiles = { M.files, 'Review a registered file move or removal' },
    RivetModuleRename = {
      M.module_rename,
      'Review module declarations and imports under a new identity',
    },
    RivetRepair = { M.repair, 'Review restoring a generated file while backing up local edits' },
    RivetRunOptions = { M.run_options, 'Review local task arguments, environment, and hooks' },
    RivetHeader = { M.header, 'Preview and edit the current file comment header' },
    RivetHeaderDefaults = { M.header_defaults, 'Change comment headers for future project files' },
    RivetTarget = { M.target, 'Add a CMake target' },
    RivetDependency = { M.dependency, 'Add a pinned CPM dependency' },
    RivetCMake = { M.cmake, 'Edit project CMake cache options' },
    RivetPreset = { M.preset, 'Change the remembered configure preset' },
    RivetBuildPreset = { M.build_preset, 'Choose an associated build preset' },
    RivetTestPreset = { M.test_preset, 'Choose an associated test preset' },
    RivetBuildTarget = { M.build_target, 'Choose the target to build' },
    RivetStatus = { M.status, 'Show active preset and target choices' },
    RivetRunTarget = { M.run_target, 'Change the remembered application target' },
    RivetDoctor = { M.doctor, 'Check project toolchain availability' },
  }
  for name, command in pairs(commands) do
    vim.api.nvim_create_user_command(
      name,
      protected(command[1]),
      { desc = command[2], force = true }
    )
  end
  vim.api.nvim_create_user_command('RivetTask', function(args)
    protected(M.task)(args.args)
  end, {
    desc = 'Run a project build task',
    nargs = '?',
    force = true,
    complete = function()
      return { 'repeat', 'configure', 'build', 'test', 'run', 'format' }
    end,
  })
end

return M
