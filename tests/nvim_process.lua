local temporary_root = assert(vim.uv.fs_realpath(vim.uv.os_tmpdir()))
-- nvim --headless -u NONE -i NONE -l tests/nvim_process.lua
local script = debug.getinfo(1, 'S').source:sub(2)
local root = script:match('^(.*)/tests/nvim_process%.lua$') or '.'
vim.opt.runtimepath:prepend(root)
local ui = require('rivet.ui')
local done
ui.run(temporary_root, { '/bin/echo', 'task output' }, 'smoke', function(ok, result)
  assert(ok and result.stdout == 'task output\n')
  done = true
end)
assert(
  vim.wait(3000, function()
    return done
  end),
  'process did not finish'
)
local count = #vim.api.nvim_list_wins()
done = false
ui.run(temporary_root, { '/bin/echo', 'second output' }, 'second', function(ok)
  assert(ok)
  done = true
end)
assert(vim.wait(3000, function()
  return done
end))
assert(#vim.api.nvim_list_wins() == count, 'task windows accumulated')
local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(text:find('second output', 1, true) and text:find('Exit status: 0', 1, true))
local errors = {}
ui.notify = function(message)
  errors[#errors + 1] = message
end
done = false
ui.run(temporary_root, { '/no/such/program' }, 'missing', function(ok)
  assert(not ok)
  done = true
end)
assert(vim.wait(3000, function()
  return done
end))
assert(#errors > 0)

-- Output is visible before completion, including chunks without a newline.
done = false
local process = ui.run(
  temporary_root,
  {
    '/bin/sh',
    '-c',
    "printf 'early'; sleep 0.5; printf ' output\\n'; printf 'src/a file.cpp:12:3: er' >&2; sleep 0.3; printf 'ror: broken\\ntrailing' >&2; exit 1",
  },
  'stream',
  function(ok, result)
    assert(not ok and result.stdout == 'early output\n')
    assert(result.stderr == 'src/a file.cpp:12:3: error: broken\ntrailing')
    done = true
  end
)
local output = vim.api.nvim_get_current_buf()
local qfid = vim.fn.getqflist({ id = 0 }).id
assert(
  vim.wait(400, function()
    return table
      .concat(vim.api.nvim_buf_get_lines(output, 4, -1, false), '\n')
      :find('early', 1, true) ~= nil
  end),
  'output did not stream before process exit'
)
assert(not done, 'streaming check ran only after exit')
local rejected
ui.run(temporary_root, { '/bin/echo', 'overlap' }, 'overlap', function(ok)
  rejected = not ok
end)
assert(rejected, 'overlapping project task was accepted')
vim.fn.setqflist({}, ' ', { title = 'Unrelated list', items = {} })
local unrelated = vim.fn.getqflist({ id = 0 }).id
assert(vim.wait(3000, function()
  return done
end))
assert(
  vim.fn.getqflist({ id = 0 }).id == unrelated,
  'background task replaced the selected quickfix list'
)
local items = vim.fn.getqflist({ id = qfid, items = 0 }).items
assert(#items == 1 and items[1].lnum == 12 and items[1].col == 3 and items[1].type == 'E')
assert(
  vim.api.nvim_buf_get_name(items[1].bufnr) == temporary_root .. '/src/a file.cpp',
  'diagnostic used the editor cwd'
)
text = table.concat(vim.api.nvim_buf_get_lines(output, 0, -1, false), '\n')
assert(text:find('early output\n', 1, true) and text:find('trailing\nExit status: 1', 1, true))

-- Relative compiler paths are resolved from the build directory. Reusing a list
-- across configure/build/run retains diagnostics from earlier workflow steps.
done = false
ui.run(
  temporary_root,
  { '/bin/echo', '../../src/main.cpp:7: warning: check this' },
  'relative',
  function(ok)
    assert(ok)
    done = true
  end,
  { quickfix_id = qfid, diagnostic_cwd = temporary_root .. '/build/debug' }
)
assert(vim.wait(3000, function()
  return done
end))
items = vim.fn.getqflist({ id = qfid, items = 0 }).items
assert(
  #items == 2 and vim.api.nvim_buf_get_name(items[2].bufnr) == temporary_root .. '/src/main.cpp'
)

done = false
process = ui.run(temporary_root, { '/bin/sleep', '5' }, 'cancel', function(ok)
  assert(not ok)
  done = true
end)
for _, key in ipairs(vim.api.nvim_buf_get_keymap(0, 'n')) do
  if key.lhs == '<C-C>' or key.lhs == '<C-c>' then
    key.callback()
  end
end
assert(
  vim.wait(3000, function()
    return done
  end),
  'Ctrl-C did not stop the task'
)

done = false
ui.run(
  temporary_root,
  { '/bin/sh', '-c', "sleep 0.1; printf 'after close\\n'" },
  'closed',
  function(ok)
    assert(ok)
    done = true
  end
)
vim.api.nvim_buf_delete(0, { force = true })
assert(
  vim.wait(3000, function()
    return done
  end),
  'closing output interrupted completion'
)
done = false
local argument = 'first line\nsecond line'
ui.run(temporary_root, { '/usr/bin/printf', '%s', argument }, 'multiline argv', function(ok, result)
  assert(ok and result.stdout == argument, 'Argument boundaries changed')
  done = true
end)
assert(
  vim.wait(3000, function()
    return done
  end),
  'Multiline argv did not finish'
)
text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(text:find('first line\nsecond line', 1, true), 'Multiline output missing')

-- A TERM-resistant child must die even after the immediate parent exits.
local pidfile = vim.fn.tempname()
local python = vim.fn.exepath('python3')
assert(python ~= '', 'python3 is needed for the process-tree regression')
local child = 'import os, signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open('
  .. string.format('%q', pidfile)
  .. ', "w").write(str(os.getpid())); time.sleep(8)'
local parent =
  'import subprocess, sys, time; subprocess.Popen([sys.executable, "-c", sys.argv[1]]); time.sleep(8)'
done = false
ui.run(temporary_root, { python, '-c', parent, child }, 'cancel children', function(ok)
  assert(not ok)
  done = true
end)
assert(vim.wait(3000, function()
  return vim.fn.filereadable(pidfile) == 1
end))
local pid = tonumber(vim.fn.readfile(pidfile)[1])
assert(pid and vim.uv.kill(pid, 0) == 0, 'Child did not start')
for _, key in ipairs(vim.api.nvim_buf_get_keymap(0, 'n')) do
  if key.lhs:lower() == '<c-c>' then
    key.callback()
  end
end
assert(
  vim.wait(4000, function()
    local dead = vim.uv.kill(pid, 0) == nil
    -- Minimal container PID 1 may leave a killed orphan unreaped. A zombie is
    -- terminated; it cannot execute or hold resources used by the build.
    local stat = io.open('/proc/' .. pid .. '/stat', 'r')
    if stat then
      local value = stat:read('*a')
      stat:close()
      dead = dead or value:match('%) Z ') ~= nil
    end
    return done and dead
  end),
  'Child survived Ctrl-C'
)
vim.fn.delete(pidfile)
print('UI async process checks passed')
vim.cmd('qa!')
