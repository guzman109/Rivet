local temporary_root = assert(vim.uv.fs_realpath(vim.uv.os_tmpdir()))
-- nvim --headless -u NONE -i NONE -l tests/nvim_process.lua
local script = debug.getinfo(1, 'S').source:sub(2)
local root = script:match('^(.*)/tests/nvim_process%.lua$') or '.'
vim.opt.runtimepath:prepend(root)
local ui = require('rivet.ui')
local function press(buf, lhs)
  for _, key in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if key.lhs:lower() == lhs:lower() then
      key.callback()
      return
    end
  end
  error('Missing output key: ' .. lhs)
end
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
local first_output = vim.api.nvim_get_current_buf()
done = false
ui.run(temporary_root, { '/bin/echo', 'second output' }, 'second', function(ok)
  assert(ok)
  done = true
end)
assert(vim.wait(3000, function()
  return done
end))
assert(#vim.api.nvim_list_wins() == count, 'task windows accumulated')
assert(not vim.api.nvim_buf_is_valid(first_output), 'obsolete task output accumulated')
local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(text:find('second output', 1, true) and text:find('Exit status: 0', 1, true))
assert(
  text:find('Press q or Enter to close · :Rivet output reopen', 1, true),
  'Completion lacks close hints'
)
local completed_output = vim.api.nvim_get_current_buf()
press(completed_output, '<CR>')
assert(vim.api.nvim_buf_is_valid(completed_output) and #vim.fn.win_findbuf(completed_output) == 0)
assert(ui.show_output(temporary_root) == completed_output, 'Enter erased completed task output')
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
assert(
  table
    .concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    :find('Press q or Enter to close', 1, true),
  'Launch failure lacks close hints'
)

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
assert(
  table
    .concat(vim.api.nvim_buf_get_lines(output, 0, -1, false), '\n')
    :find('Ctrl-C stop · q close view · :Rivet output reopen', 1, true),
  'Running output lacks close and cancellation hints'
)
local streaming_window = vim.api.nvim_get_current_win()
press(output, '<CR>')
assert(vim.api.nvim_win_is_valid(streaming_window), 'Enter closed running task output')
assert(vim.api.nvim_win_get_buf(streaming_window) == output and ui.is_running(temporary_root))
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

-- Each project retains its output while the shared view follows another task.
-- Closing that view must still allow reopening and cancelling either project.
local projects = vim.fn.tempname()
local project_a, project_b = projects .. '/a', projects .. '/b'
vim.fn.mkdir(project_a, 'p')
vim.fn.mkdir(project_b, 'p')
local a_done, b_done
ui.run(
  project_a,
  {
    '/bin/sh',
    '-c',
    "printf 'project a early\\n'; sleep 0.3; printf 'project-a.cpp:9: warning: a warning\\nproject a done\\n'",
  },
  'project a',
  function(ok)
    assert(ok, 'another project interrupted project a')
    a_done = true
  end,
  { close_on_success = true }
)
local a_output = vim.api.nvim_get_current_buf()
local a_qfid = vim.fn.getqflist({ id = 0 }).id
assert(vim.wait(1000, function()
  return table
    .concat(vim.api.nvim_buf_get_lines(a_output, 0, -1, false), '\n')
    :find('project a early', 1, true)
end))
ui.run(
  project_b,
  {
    '/bin/sh',
    '-c',
    "printf 'project b early\\nproject-b.cpp:11: error: b error\\n'; sleep 5",
  },
  'project b',
  function(ok)
    assert(not ok, 'hidden project b was not cancelled')
    b_done = true
  end
)
local b_output = vim.api.nvim_get_current_buf()
local b_window = vim.api.nvim_get_current_win()
local b_qfid = vim.fn.getqflist({ id = 0 }).id
assert(vim.api.nvim_buf_is_valid(a_output), 'another project wiped running output')
assert(vim.wait(1000, function()
  return table
    .concat(vim.api.nvim_buf_get_lines(b_output, 0, -1, false), '\n')
    :find('project b early', 1, true)
end))
assert(vim.wait(3000, function()
  return a_done
end))
assert(
  vim.api.nvim_win_is_valid(b_window) and vim.api.nvim_win_get_buf(b_window) == b_output,
  'Hidden successful task closed another project output'
)
press(b_output, 'q')
assert(
  vim.api.nvim_buf_is_valid(b_output) and #vim.fn.win_findbuf(b_output) == 0,
  'q erased task output'
)
assert(ui.is_running(project_b), 'q stopped the task')
assert(ui.show_output(project_a) == a_output, 'project a output could not be reopened')
text = table.concat(vim.api.nvim_buf_get_lines(a_output, 0, -1, false), '\n')
assert(text:find('project a done\nExit status: 0', 1, true), 'hidden output stopped streaming')
assert(vim.fn.getqflist({ id = b_qfid, items = 0 }).items[1].lnum == 11)
assert(vim.fn.getqflist({ id = a_qfid, items = 0 }).items[1].lnum == 9)
assert(
  vim.fn.getqflist({ id = 0 }).id == b_qfid,
  'another project replaced the selected quickfix list'
)
assert(ui.stop(project_b), 'hidden task could not be cancelled')
assert(not ui.stop(project_b), 'task accepted cancellation twice')
assert(vim.wait(3000, function()
  return b_done
end))
assert(ui.show_output(project_b) == b_output, 'closed project output could not be reopened')
text = table.concat(vim.api.nvim_buf_get_lines(b_output, 0, -1, false), '\n')
assert(text:find('project b early', 1, true) and text:find('Stopped (signal ', 1, true))
assert(not ui.stop(project_b), 'completed task accepted cancellation')
local replacement_done
ui.run(project_a, { '/bin/echo', 'replacement' }, 'project a replacement', function(ok)
  assert(ok)
  replacement_done = true
end)
assert(not vim.api.nvim_buf_is_valid(a_output), 'completed project output accumulated')
assert(vim.api.nvim_buf_is_valid(b_output), 'replacing project a output erased project b output')
assert(vim.wait(3000, function()
  return replacement_done
end))
vim.fn.delete(projects, 'rf')

done = false
process = ui.run(temporary_root, { '/bin/sleep', '5' }, 'cancel', function(ok)
  assert(not ok)
  done = true
end, { close_on_success = true })
local cancelled_output = vim.api.nvim_get_current_buf()
press(cancelled_output, '<C-c>')
assert(
  vim.wait(3000, function()
    return done
  end),
  'Ctrl-C did not stop the task'
)
assert(#vim.fn.win_findbuf(cancelled_output) > 0, 'Cancellation closed failed output')

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

-- Provider presentation errors must not strand a completed task or lose raw output.
for _, hook in ipairs({ 'render_line', 'diagnostics' }) do
  done = false
  local calls, notifications = 0, #errors
  local options = {}
  options[hook] = function()
    calls = calls + 1
    error('broken provider ' .. hook)
  end
  ui.run(
    temporary_root,
    { '/usr/bin/printf', 'first output\nsecond output\n' },
    'provider error',
    function(ok, result)
      assert(ok and result.stdout == 'first output\nsecond output\n')
      done = true
    end,
    options
  )
  assert(
    vim.wait(3000, function()
      return done
    end),
    'Provider error interrupted task completion'
  )
  assert(not ui.is_running(temporary_root), 'Provider error stranded running state')
  assert(calls == 1 and #errors == notifications + 1, 'Provider failure was reported repeatedly')
  text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  assert(text:find('first output\nsecond output\nExit status: 0', 1, true))
end
done = false
ui.run(temporary_root, { '/bin/echo', 'malformed diagnostic' }, 'invalid diagnostic', function(ok)
  assert(ok)
  done = true
end, {
  diagnostics = function()
    return { filename = 'source.c', lnum = {}, text = 'invalid provider line number' }
  end,
})
assert(vim.wait(3000, function()
  return done
end))
assert(not ui.is_running(temporary_root))
text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(text:find('malformed diagnostic\nExit status: 0', 1, true), 'Quickfix error lost output')

-- Cargo's build JSON ends before the launched application's arbitrary output.
local cargo = vim.fn.exepath('cargo')
if cargo ~= '' then
  local fixture = vim.fn.tempname()
  vim.fn.mkdir(fixture .. '/src', 'p')
  vim.fn.writefile({
    '[package]',
    'name = "rivet_output_fixture"',
    'version = "0.1.0"',
    'edition = "2021"',
  }, fixture .. '/Cargo.toml')
  local artifact = '{"reason":"compiler-artifact","target":{"name":"USER"}}'
  local message = '{"reason":"compiler-message","message":{"message":"USER",'
    .. '"spans":[{"is_primary":true,"file_name":"fake.rs","line_start":2,"column_start":1}]}}'
  vim.fn.writefile({
    'fn main() {',
    '    let unused = 1;',
    '    println!("{}", r#"' .. artifact .. '"#);',
    '    println!("{}", r#"' .. message .. '"#);',
    '    eprintln!("{}", r#"' .. artifact .. '"#);',
    '}',
  }, fixture .. '/src/main.rs')
  local argv = {
    'env',
    'CARGO_HOME=' .. fixture .. '/cargo-home',
    'CARGO_TARGET_DIR=' .. fixture .. '/target',
    cargo,
    'run',
    '--offline',
    '--message-format=json',
    '--',
  }
  local diagnostics = require('rivet.native_diagnostics')
  done = false
  ui.run(fixture, argv, 'Cargo application output', function(ok, result)
    assert(ok, result.stderr)
    done = true
  end, { diagnostics = diagnostics.parse_for(argv), render_line = diagnostics.render_for(argv) })
  assert(
    vim.wait(30000, function()
      return done
    end),
    'Offline Cargo fixture did not complete'
  )
  text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  assert(text:find('Build finished', 1, true) and text:find('Built rivet_output_fixture', 1, true))
  assert(text:find(artifact, 1, true) and text:find(message, 1, true), 'Application JSON changed')
  assert(not text:find('Built USER', 1, true), 'Application artifact was decoded as Cargo output')
  local compiler_warning = false
  for _, item in ipairs(vim.fn.getqflist()) do
    local path = vim.api.nvim_buf_get_name(item.bufnr)
    assert(not path:match('/fake%.rs$'), 'Application JSON became a compiler diagnostic')
    compiler_warning = compiler_warning or path:match('/src/main%.rs$') ~= nil
  end
  assert(compiler_warning, 'Real Cargo compiler warning was lost')
  vim.fn.delete(fixture, 'rf')
end

-- Automatic close keeps output accessible and preserves the user's editor focus.
done = false
ui.run(
  temporary_root,
  { '/bin/echo', 'successful automatic close' },
  'automatic close',
  function(ok)
    assert(ok)
    done = true
  end,
  { close_on_success = true }
)
local automatic_output = vim.api.nvim_get_current_buf()
local automatic_window = vim.api.nvim_get_current_win()
local editor_window
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if win ~= automatic_window then
    editor_window = win
    break
  end
end
assert(editor_window, 'No editor window for focus regression')
vim.api.nvim_set_current_win(editor_window)
local editor_buffer = vim.api.nvim_get_current_buf()
assert(vim.wait(3000, function()
  return done
end))
assert(
  not vim.api.nvim_win_is_valid(automatic_window),
  'Successful output did not close automatically'
)
assert(
  vim.api.nvim_get_current_win() == editor_window
    and vim.api.nvim_get_current_buf() == editor_buffer
)
assert(ui.show_output(temporary_root) == automatic_output, 'Automatic close erased task output')

done = false
ui.run(temporary_root, { '/bin/sh', '-c', 'exit 3' }, 'failed automatic close', function(ok)
  assert(not ok)
  done = true
end, { close_on_success = true })
local failed_output = vim.api.nvim_get_current_buf()
assert(vim.wait(3000, function()
  return done
end))
assert(#vim.fn.win_findbuf(failed_output) > 0, 'Failure output closed automatically')
local failed_window = vim.api.nvim_get_current_win()
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if win ~= failed_window then
    vim.api.nvim_win_close(win, true)
  end
end
press(failed_output, 'q')
assert(vim.api.nvim_get_current_buf() ~= failed_output, 'q left output in the last window')
assert(ui.show_output(temporary_root) == failed_output)
press(failed_output, '<CR>')
assert(vim.api.nvim_get_current_buf() ~= failed_output, 'Enter left output in the last window')

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
press(vim.api.nvim_get_current_buf(), '<C-c>')
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
