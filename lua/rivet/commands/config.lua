local context = require('rivet.context')
local ui = require('rivet.ui')
local config = require('rivet.tool_config')
local rt = require('rivet.runtime')
local M = {}
local function edit(root, tool)
  vim.cmd.edit(vim.fn.fnameescape(rt.confined(root, tool.path)))
  vim.bo.filetype = 'yaml'
  ui.notify(
    'Edit ' .. tool.path .. ' directly for arbitrary keys or advanced YAML. Reference: ' .. tool.url
  )
end
local function settings(root, tool)
  local items = {}
  local content = rt.read(rt.confined(root, tool.path)) or '(This file does not exist yet.)'
  for _, setting in ipairs(config.catalog(tool.id)) do
    local values = {}
    for _, choice in ipairs(setting.choices or {}) do
      values[#values + 1] = choice.label
    end
    items[#items + 1] = {
      label = setting.key,
      entry = setting,
      preview = setting.key
        .. '\n\n'
        .. setting.description
        .. '\n\nValue type: '
        .. setting.type
        .. (#values > 0 and '\n\nValues:\n' .. table.concat(values, '\n') or '')
        .. '\n\nCurrent '
        .. tool.path
        .. ':\n'
        .. content
        .. '\n\nReference: '
        .. tool.url,
    }
  end
  items[#items + 1] = {
    label = 'Open YAML · arbitrary keys and advanced configuration',
    manual = true,
    preview = 'Open '
      .. tool.path
      .. ' as an ordinary YAML buffer.\n\nUse this for settings outside the curated list, conditional fragments, aliases, and complex mappings. Your existing file is preserved; save manually when ready.\n\nReference: '
      .. tool.url
      .. '\n\n'
      .. content,
  }
  ui.select_preview(
    tool.label,
    items,
    context.protected(function(item)
      if item.manual then
        return edit(root, tool)
      end
      local entry = item.entry
      local function select_value(key)
        local function save(value)
          context.review(root, config.plan(root, tool.id, key, value))
        end
        if entry.choices then
          ui.select_preview(
            key,
            entry.choices,
            context.protected(function(choice)
              save(choice.id)
            end)
          )
        elseif entry.type == 'boolean' then
          context.choose(key .. ': ', {
            { id = 'true', label = 'true · enable' },
            { id = 'false', label = 'false · disable' },
          }, function(choice)
            save(choice.id)
          end)
        else
          local default = entry.default
          local ok, current = pcall(config.current, root, tool.id, key)
          if ok and current then
            if entry.type == 'string' and current:match("^'.*'$") then
              default = current:sub(2, -2):gsub("''", "'")
            elseif entry.type == 'string' and current:sub(1, 1) == '"' then
              local decoded, value = pcall(require('rivet.json').decode, current)
              if decoded and type(value) == 'string' then
                default = value
              end
            elseif entry.type ~= 'array' or current:sub(1, 1) == '[' then
              default = current
            end
          end
          context.input(key .. ' (' .. entry.type .. '): ', default, save)
        end
      end
      if entry.custom then
        context.input(
          'Exact check.option key: ',
          'readability-identifier-naming.VariableCase',
          function(key)
            select_value(entry.key .. '.' .. key)
          end
        )
      else
        select_value(entry.key)
      end
    end)
  )
end
function M.config(name)
  local root = context.current_root()
  if name and name ~= '' then
    return settings(root, config.tool(name))
  end
  local items = {}
  for _, tool in ipairs(config.tools()) do
    items[#items + 1] = {
      label = tool.label,
      tool = tool,
      preview = tool.description
        .. '\n\nFile: '
        .. tool.path
        .. '\n\nChoose a common key to see its meaning and values, then review the full diff before applying. Open YAML supports all other options.\n\nReference: '
        .. tool.url,
    }
  end
  ui.select_preview(
    'Project tool configuration',
    items,
    context.protected(function(item)
      settings(root, item.tool)
    end)
  )
end
return M
