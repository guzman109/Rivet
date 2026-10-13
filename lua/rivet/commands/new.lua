-- :RivetNew project creation wizard.
local context = require('rivet.context')
local protected = context.protected
local choose = context.choose
local review = context.review
local tasks = require('rivet.commands.tasks')
local M = {}

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
  local profiles = vim.tbl_extend('force', preferences.profiles, context.config.profiles)
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
          return runtime.join(context.config.projects_dir or vim.fn.getcwd(), spec.name)
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
          local identity = context.config.identity or preferences.identity
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
                  tasks.run_workflow(root, 'build', 'debug')
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

return M
