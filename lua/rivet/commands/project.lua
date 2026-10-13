-- Commands that review changes to an existing project and local preferences.
local context = require('rivet.context')
local ui = require('rivet.ui')
local protected = context.protected
local input = context.input
local choose = context.choose
local current_root = context.current_root
local review = context.review
local M = {}

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
    context.config.identity or preferences.load().identity,
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

function M.migrate()
  local root = assert(require('rivet.project').root(), 'Open an Outset project first')
  review(root, require('rivet.migration').plan(root))
end

return M
