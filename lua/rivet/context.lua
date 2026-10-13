-- Editor state shared by the command modules: configuration, the active
-- project, and protected prompt/review helpers.
local ui = require('rivet.ui')
local M = {}
---@type rivet.Config
M.config = { projects_dir = nil, default_preset = 'debug', profiles = {} }
---@type string?
M.active_root = nil

function M.protected(fn)
  return function(...)
    local ok, result = pcall(fn, ...)
    if not ok then
      ui.notify(tostring(result), vim.log.levels.ERROR)
    end
    return ok and result or nil
  end
end

function M.input(prompt, default, callback)
  ui.input(prompt, default, M.protected(callback))
end

function M.choose(prompt, items, callback)
  ui.choose(prompt, items, M.protected(callback))
end

function M.current_root()
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
  local root = output_root or project.root(path) or project.root(vim.fn.getcwd()) or M.active_root
  assert(
    root,
    'No supported project found. Run :RivetNew or open CMakeLists.txt, pyproject.toml, Cargo.toml, or Package.swift.'
  )
  M.active_root = root
  return root
end

function M.review(root, plan, after_apply, back)
  return ui.review(
    root,
    plan,
    M.protected(function()
      require('rivet.project').apply(root, plan)
      M.active_root = plan.root or root
      ui.notify('Project files saved in ' .. root)
      if after_apply then
        after_apply(M.active_root, plan.spec)
      end
    end),
    { back = back }
  )
end

return M
