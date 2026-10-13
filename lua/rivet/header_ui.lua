local M = {}
local ui = require('rivet.ui')
local headers = require('rivet.headers')

local function safe(fn)
  return function(...)
    local ok, result = pcall(fn, ...)
    if not ok then
      ui.notify(tostring(result), vim.log.levels.ERROR)
    end
    return ok and result or nil
  end
end

-- Collect details before showing the styles, so every preview is personalized.
function M.configure(defaults, context, callback, opts)
  opts = opts or {}
  local headers = context.language
      and require('rivet.tasks').service({ language = context.language }, 'headers')
    or headers
  local values = vim.deepcopy(defaults or { created = 'today' })
  local index = 0
  local next_field
  next_field = safe(function()
    index = index + 1
    local item = headers.fields[index]
    if item then
      return ui.input(
        (item.prompt or item.label) .. ' (optional; :back to return): ',
        values[item.key] or '',
        safe(function(value)
          if value == ':back' then
            if index == 1 and opts.back then
              return opts.back()
            end
            index = math.max(0, index - 2)
            return next_field()
          end
          values[item.key] = value
          -- Validate each answer before advancing. The license is checked after style selection.
          headers.normalize(vim.tbl_extend('force', values, { style = 'none' }))
          next_field()
        end)
      )
    end
    local items = {}
    for _, style in ipairs(headers.styles) do
      if style.id ~= 'spdx' or (values.license and values.license:match('%S')) then
        local choice = vim.deepcopy(style)
        local config = vim.tbl_extend('force', values, { style = style.id })
        choice.preview = headers.render(config, context)
          .. (context.body or (headers.example or {}).body or '')
        choice.config = headers.normalize(config)
        if style.id == values.style then
          table.insert(items, 1, choice)
        else
          items[#items + 1] = choice
        end
      end
    end
    ui.select_preview(
      'File comment header',
      items,
      safe(function(choice)
        callback(choice.config)
      end),
      {
        back = function()
          index = #headers.fields - 1
          next_field()
        end,
      }
    )
  end)
  next_field()
end

function M.edit(root, spec, buf)
  local headers = require('rivet.tasks').service(spec, 'headers')
  assert(vim.bo[buf].buftype == '' and vim.bo[buf].modifiable, 'Open an editable source file first')
  local path = vim.api.nvim_buf_get_name(buf)
  assert(
    path ~= '' and headers.accepts(path, vim.bo[buf].filetype),
    'This file is not supported by the provider comment-header editor'
  )
  assert(
    require('rivet.project').root(vim.fn.fnamemodify(path, ':h')) == root,
    'The current file must be inside this Rivet project'
  )
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local before = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n'
  local prefix = headers.preamble and headers.preamble(before) or ''
  local editable = before:sub(#prefix + 1)
  local leading = headers.leading(editable)
  local defaults =
    vim.tbl_extend('force', spec.comment_header or { created = 'today' }, headers.extract(editable))
  local function configure(replace_leading)
    local body = editable:sub(replace_leading and leading + 1 or 1)
    M.configure(
      defaults,
      { filename = path, project = spec.name, language = spec.language, body = body },
      function(config)
        local after = prefix
          .. headers.render(config, { filename = path, project = spec.name })
          .. body
        ui.select_preview(
          'Review file header',
          {
            {
              label = 'Changes',
              preview = (vim.text.diff or vim.diff)(
                before,
                after,
                { result_type = 'unified', ctxlen = 3 }
              ),
            },
            { label = 'Complete file', preview = after },
          },
          safe(function()
            assert(
              vim.api.nvim_buf_is_valid(buf)
                and vim.api.nvim_buf_get_changedtick(buf) == tick
                and vim.api.nvim_buf_get_name(buf) == path,
              'The buffer changed after preview. Run :RivetHeader again'
            )
            local result = vim.split(after:gsub('\n$', ''), '\n', { plain = true })
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, result)
            ui.notify('Header updated in the buffer. Save with :write, or undo with u.')
          end),
          { review = true }
        )
      end
    )
  end
  if leading > 0 then
    ui.choose(
      'Existing leading comment: ',
      {
        'Replace it (review changes before applying)',
        'Keep it and prepend a header',
      },
      safe(function(choice)
        configure(choice:match('^Replace') ~= nil)
      end)
    )
  else
    configure(false)
  end
end

return M
