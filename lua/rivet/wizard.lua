-- Shared editor questionnaire: provider data, reversible navigation, one final review.
local M = {}
function M.run(values, steps, finish)
  local ui = require('rivet.ui')
  local index, history = 1, {}
  local show, back
  local function safe(fn)
    return function(...)
      local ok, err = pcall(fn, ...)
      if not ok then
        ui.notify(tostring(err), vim.log.levels.ERROR)
        show()
      end
    end
  end
  back = function()
    index = table.remove(history) or 1
    show()
  end
  show = function()
    local step = steps[index]
    if not step then
      return finish(back)
    end
    if step.when and not step.when(values) then
      index = index + 1
      return show()
    end
    local function next_step()
      history[#history + 1] = index
      index = index + 1
      show()
    end
    if step.run then
      return step.run(next_step, back)
    end
    local function accept(value, item)
      if step.validate then
        step.validate(value, values)
      end
      values[step.key] = value
      if step.apply then
        step.apply(values, item or value)
      end
      next_step()
    end
    if step.input then
      local default = values[step.key]
      if default == nil then
        default = type(step.default) == 'function' and step.default(values) or step.default
      end
      return ui.input(
        step.title .. ': (:back to return) ',
        default or '',
        safe(function(value)
          if value == ':back' then
            return back()
          end
          accept(value)
        end)
      )
    end
    local items = vim.deepcopy(type(step.items) == 'function' and step.items(values) or step.items)
    assert(#items > 0, 'No choices available for ' .. step.title)
    -- Keep a remembered/profile value first, without changing provider defaults.
    for i, item in ipairs(items) do
      local id = item.id
      if id == nil then
        id = item.name
      end
      if id == values[step.key] then
        table.insert(items, 1, table.remove(items, i))
        break
      end
    end
    return ui.select_preview(
      step.title,
      items,
      safe(function(item)
        local id = item.id
        if id == nil then
          id = item.name
        end
        accept(id, item)
      end),
      { back = #history > 0 and back or nil }
    )
  end
  show()
end
return M
