-- Invoked as a script by the selected Lua runtime. Compile without executing.
local failed = false
for _, path in ipairs(arg or {}) do
  local chunk, message = loadfile(path)
  if not chunk then
    io.stderr:write(tostring(message) .. '\n')
    failed = true
  end
end
if failed then
  os.exit(1)
end
