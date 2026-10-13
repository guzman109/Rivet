-- Compatibility for existing editor setup calls, removed in Rivet 0.3.0.
-- New configuration uses require('rivet').
if rawget(_G, 'vim') and vim.deprecate then
  vim.deprecate("require('outset')", "require('rivet')", '0.3.0', 'rivet.nvim', false)
end
return require('rivet')
