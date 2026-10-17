local M = {}
function M.compiler()
  local context, ui = require('rivet.context'), require('rivet.ui')
  local compilers = require('rivet.compilers')
  local root = context.current_root()
  assert(not ui.is_running(root), 'Wait for the current task before switching compilers')
  local function select(path)
    context.review(root, compilers.plan(root, path), function()
      local state = require('rivet.task_state')
      local saved = state.load(root)
      saved.preset = 'debug'
      saved.build_preset, saved.test_preset, saved.build_target = nil, nil, nil
      state.save(root, saved)
      ui.notify('Compiler selected. Run :RivetTask build to configure and build it.')
    end)
  end
  local items = compilers.discover()
  items[#items + 1] = {
    label = 'Enter compiler path…',
    manual = true,
    preview = 'Select a C++ compiler executable outside the discovered locations.',
  }
  ui.select_preview(
    'C++ compiler',
    items,
    context.protected(function(item)
      if item.manual then
        context.input('C++ compiler path: ', '', select)
      else
        select(item.path)
      end
    end)
  )
end
return M
