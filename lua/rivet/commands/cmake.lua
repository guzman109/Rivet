-- :RivetCMake cache editor.
local context = require('rivet.context')
local ui = require('rivet.ui')
local protected = context.protected
local input = context.input
local choose = context.choose
local current_root = context.current_root
local tasks = require('rivet.commands.tasks')
local M = {}

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
  tasks.preset_picker(root, function(preset)
    cache_editor(root, preset, false)
  end)
end

return M
