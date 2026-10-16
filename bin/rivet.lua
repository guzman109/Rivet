#!/usr/bin/env lua
local script = arg[0]:gsub('\\', '/')
local root = (script:match('^(.*)/[^/]+$') or '.') .. '/..'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
local ok, result = pcall(function()
  return require('rivet.cli').main(arg)
end)
if not ok then
  require('rivet.terminal').error(result)
  os.exit(1)
end
os.exit(result or 0)
