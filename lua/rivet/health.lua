local M = {}
function M.check()
  vim.health.start('Rivet project tooling')
  if vim.fn.has('nvim-0.11') == 1 then
    vim.health.ok('Neovim 0.11 or newer')
  else
    vim.health.error('Neovim 0.11 or newer is required')
  end
  local project = require('rivet.project')
  local root = M.root or project.root(vim.fn.getcwd())
  local state = root and require('rivet.task_state').load(root) or {}
  local options = { build_preset = state.build_preset }
  for _, client in ipairs(vim.lsp.get_clients({ name = 'clangd' })) do
    if not root or client.config.root_dir == root then
      local cmd = client.config.cmd
      if type(cmd) == 'table' then
        options.clangd = require('rivet.runtime').executable(cmd[1])
        for _, arg in ipairs(cmd) do
          if arg == '--experimental-modules-support' then
            options.module_flag = true
          end
        end
      end
    end
  end
  local doctor = root and require('rivet.tasks').service(project.inspect(root), 'doctor')
    or require('rivet.doctor')
  for _, entry in ipairs(doctor.inspect(root, state.preset, options)) do
    vim.health[entry.level](entry.message)
  end
end
return M
