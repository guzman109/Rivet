local M = {}
-- vim.text.diff is Neovim 0.12+; vim.diff remains for 0.11.
---@diagnostic disable-next-line: deprecated
M.diff = vim.text.diff or vim.diff
local output_window
local running = {}
local task_outputs = {}
local running_footer = 'Ctrl-C stop · q close view · :Rivet output reopen'
local completed_footer = 'Press q or Enter to close · :Rivet output reopen'

local function lines(value)
  if type(value) == 'table' then
    return value
  end
  return vim.split(value or '', '\n', { plain = true })
end

function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = 'Rivet' })
end

function M.input(prompt, default, callback)
  vim.ui.input({ prompt = prompt, default = default or '' }, function(value)
    if value ~= nil then
      callback(value)
    end
  end)
end

function M.choose(prompt, items, callback)
  vim.ui.select(items, {
    prompt = prompt,
    format_item = function(item)
      return type(item) == 'table' and (item.label or item.name or item.id) or item
    end,
  }, function(item)
    if item ~= nil then
      callback(item)
    end
  end)
end

local function scratch(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype or 'markdown'
  return buf
end

local function replace(buf, content)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines(content))
  vim.bo[buf].modifiable = false
end

-- The list retains focus while its adjacent preview follows the cursor. Tab
-- moves into the preview so long examples and complete file diffs can scroll.
function M.select_preview(title, items, callback, opts)
  opts = opts or {}
  if #items == 0 then
    return M.notify('No choices are available.')
  end
  if vim.o.columns < 32 or vim.o.lines < 10 then
    return M.notify(
      'Enlarge Neovim to at least 32 columns and 10 rows to show previews.',
      vim.log.levels.WARN
    )
  end
  local list_buf, preview_buf = scratch(), scratch()
  local list_win, preview_win, group
  local closed, selected = false, 1
  local previous_win = vim.api.nvim_get_current_win()
  local function close()
    if closed then
      return
    end
    closed = true
    if group then
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end
    for _, win in ipairs({ list_win, preview_win }) do
      if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    for _, buf in ipairs({ list_buf, preview_buf }) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    if vim.api.nvim_win_is_valid(previous_win) then
      pcall(vim.api.nvim_set_current_win, previous_win)
    end
  end
  local function preview()
    local item = items[selected]
    local body = item.preview
    if type(body) == 'function' then
      local ok, result = pcall(body, item)
      body = ok and result or ('Preview unavailable: ' .. tostring(result))
    end
    local content = { '# ' .. (item.label or item.id or item.name), '' }
    if item.description and item.description ~= '' then
      vim.list_extend(content, lines(item.description))
      content[#content + 1] = ''
    end
    vim.list_extend(content, lines(body))
    replace(preview_buf, content)
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_set_cursor(preview_win, { 1, 0 })
    end
  end
  local function geometry()
    local columns, rows = vim.o.columns, vim.o.lines
    local width = math.max(20, math.min(128, columns - 6))
    local height = math.max(4, math.min(38, rows - 7))
    local row, col =
      math.max(0, math.floor((rows - height - 2) / 2) - 1),
      math.max(0, math.floor((columns - width) / 2))
    local a, b
    if columns >= 80 then
      local left_width = math.min(38, math.floor(width * 0.34))
      a = { row = row, col = col, width = left_width, height = height }
      b = { row = row, col = col + left_width + 2, width = width - left_width - 2, height = height }
    else
      local list_height = math.min(#items + 1, math.max(3, math.floor(height * 0.4)))
      a = { row = row, col = col, width = width, height = list_height }
      b = {
        row = row + list_height + 2,
        col = col,
        width = width,
        height = math.max(2, height - list_height - 2),
      }
    end
    for _, config in ipairs({ a, b }) do
      config.relative = 'editor'
      config.style = 'minimal'
      config.border = 'rounded'
    end
    a.title = ' ' .. title .. ' '
    a.title_pos = 'center'
    a.footer = (opts.review and ' c apply · q cancel ' or ' Enter select · q cancel ')
      .. (opts.back and '· Backspace back ' or '')
    b.title = ' Preview '
    b.footer = ' Tab switch pane · j/k scroll '
    return a, b
  end
  local labels = {}
  for _, item in ipairs(items) do
    labels[#labels + 1] = ' ' .. (item.label or item.id or item.name)
  end
  replace(list_buf, labels)
  local a, b = geometry()
  list_win = vim.api.nvim_open_win(list_buf, true, a)
  preview_win = vim.api.nvim_open_win(preview_buf, false, b)
  vim.wo[list_win].cursorline = true
  vim.wo[list_win].wrap = false
  vim.wo[preview_win].wrap = true
  vim.wo[preview_win].linebreak = true
  preview()
  local function accept()
    local item = items[selected]
    close()
    if callback then
      callback(item)
    end
  end
  local function switch()
    local dest = vim.api.nvim_get_current_win() == list_win and preview_win or list_win
    if vim.api.nvim_win_is_valid(dest) then
      vim.api.nvim_set_current_win(dest)
    end
  end
  for _, buf in ipairs({ list_buf, preview_buf }) do
    if opts.back then
      vim.keymap.set('n', '<BS>', function()
        close()
        opts.back()
      end, { buffer = buf, nowait = true })
    end
    vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true, desc = 'Cancel Rivet' })
    vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true })
    vim.keymap.set('n', '<Tab>', switch, { buffer = buf, nowait = true })
    if opts.review then
      vim.keymap.set(
        'n',
        'c',
        accept,
        { buffer = buf, nowait = true, desc = 'Create or apply reviewed files' }
      )
      vim.keymap.set('n', '<C-s>', accept, { buffer = buf, nowait = true })
      vim.keymap.set('n', '<CR>', switch, { buffer = buf, nowait = true })
    else
      vim.keymap.set('n', '<CR>', accept, { buffer = buf, nowait = true, desc = 'Select choice' })
    end
  end
  group = vim.api.nvim_create_augroup('RivetPreview' .. list_buf, { clear = true })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = list_buf,
    callback = function()
      if closed or not vim.api.nvim_win_is_valid(list_win) then
        return
      end
      local next_row = vim.api.nvim_win_get_cursor(list_win)[1]
      if next_row ~= selected then
        selected = next_row
        preview()
      end
    end,
  })
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if closed then
        return
      end
      if vim.o.columns < 32 or vim.o.lines < 10 then
        close()
        return M.notify(
          'Preview closed because the window is too small. Enlarge Neovim and run the command again.',
          vim.log.levels.WARN
        )
      end
      local left, right = geometry()
      vim.api.nvim_win_set_config(list_win, left)
      vim.api.nvim_win_set_config(preview_win, right)
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(event)
      if tonumber(event.match) == list_win or tonumber(event.match) == preview_win then
        close()
      end
    end,
  })
  return {
    close = close,
    list = list_buf,
    preview = preview_buf,
    windows = { list_win, preview_win },
  }
end

function M.review(root, plan, apply, opts)
  local paths = vim.tbl_keys(plan.files)
  table.sort(paths)
  local summary = { 'Project: ' .. root }
  if plan.spec then
    summary[#summary + 1] = 'Name: ' .. plan.spec.name
  end
  if plan.git then
    summary[#summary + 1] = plan.git.summary
  end
  summary[#summary + 1] = ''
  summary[#summary + 1] = 'Files to create, update, or remove:'
  summary[#summary + 1] = ''
  for _, path in ipairs(paths) do
    summary[#summary + 1] = '  ' .. (plan.files[path] == false and 'REMOVE ' or '') .. path
  end
  for _, note in ipairs(plan.notes or {}) do
    summary[#summary + 1] = note
  end
  summary[#summary + 1] = ''
  summary[#summary + 1] = 'Browse every file using j/k. Tab enters the preview for scrolling.'
  summary[#summary + 1] = 'Press c to create/apply these changes, or q to cancel.'
  local items = { { label = 'Overview / file tree', preview = summary } }
  for _, path in ipairs(paths) do
    local before = plan.expected and plan.expected[path]
    local body = plan.files[path] or ''
    if type(before) == 'string' then
      body = 'Changes:\n\n'
        .. M.diff(before, body, { result_type = 'unified', ctxlen = 3 })
        .. (plan.files[path] == false and '\nFile will be removed.\n' or '\nComplete resulting file:\n\n')
        .. body
    end
    items[#items + 1] = { label = path, preview = body }
  end
  return M.select_preview('Review project changes', items, function()
    apply()
  end, vim.tbl_extend('force', opts or {}, { review = true }))
end

local function show_output(buf)
  if output_window and vim.api.nvim_win_is_valid(output_window) then
    vim.api.nvim_win_set_buf(output_window, buf)
  else
    vim.cmd('botright 14split')
    output_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(output_window, buf)
  end
  vim.api.nvim_set_current_win(output_window)
end

local function close_view(win, buf)
  local closed = pcall(vim.api.nvim_win_close, win, true)
  if not closed and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
    -- Neovim cannot close its last window. Return it to an editor buffer while
    -- keeping the task buffer hidden and available to reopen.
    local alternate = vim.fn.bufnr('#')
    if
      alternate < 0
      or alternate == buf
      or not vim.api.nvim_buf_is_valid(alternate)
      or vim.api.nvim_buf_get_name(alternate):match('^rivet://')
    then
      alternate = vim.api.nvim_create_buf(true, false)
    end
    vim.api.nvim_win_set_buf(win, alternate)
  end
end

local function close_output(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    close_view(win, buf)
  end
end

function M.output(title, content, opts)
  opts = opts or {}
  local buf = scratch('text')
  local previous = opts.root and task_outputs[opts.root]
  if opts.root then
    -- Another project's task can replace the shared window while this buffer
    -- continues receiving output. Keep the latest output available to reopen.
    vim.bo[buf].bufhidden = 'hide'
    vim.b[buf].rivet_root = opts.root
    task_outputs[opts.root] = buf
  end
  show_output(buf)
  if previous and not running[opts.root] and vim.api.nvim_buf_is_valid(previous) then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  pcall(vim.api.nvim_buf_set_name, buf, 'rivet://' .. title:gsub('%s+', '-') .. '/' .. buf)
  replace(buf, content)
  vim.keymap.set('n', 'q', function()
    close_output(buf)
  end, { buffer = buf, desc = 'Close output' })
  return buf
end

function M.show_output(root)
  local buf = task_outputs[root]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    task_outputs[root] = nil
    M.notify('No task output is available for this project.', vim.log.levels.WARN)
    return
  end
  show_output(buf)
  return buf
end

function M.is_running(root)
  return running[root] ~= nil
end

function M.stop(root)
  local token = running[root]
  if not token or token.cancelled or not token.stop then
    return false
  end
  token.cancelled = true
  token.stop()
  return true
end

function M.new_quickfix(root, title)
  vim.fn.setqflist(
    {},
    ' ',
    { title = 'Rivet: ' .. title, context = { rivet = true, root = root }, items = {} }
  )
  return vim.fn.getqflist({ id = 0 }).id
end

local function clean_output(line)
  return line:gsub('\27%[[%d;]*[mK]', ''):gsub('\r', '')
end

function M.run(root, argv, title, callback, opts)
  opts = opts or {}
  if type(argv) ~= 'table' or #argv == 0 then
    M.notify('No command is available for ' .. title, vim.log.levels.ERROR)
    if callback then
      callback(false)
    end
    return
  end
  if running[root] then
    M.notify('A task is already running for this project.', vim.log.levels.WARN)
    if callback then
      callback(false)
    end
    return
  end
  local shown = {}
  for _, argument in ipairs(argv) do
    -- Keep the heading on one buffer line without changing the actual argv.
    shown[#shown + 1] = vim.fn.shellescape(argument):gsub('\n', '\\n'):gsub('\r', '\\r')
  end
  local heading = { title, root, '$ ' .. table.concat(shown, ' '), '' }
  local buf = M.output(
    title,
    vim.list_extend(vim.deepcopy(heading), { 'Running…', running_footer }),
    { root = root }
  )
  vim.api.nvim_win_set_cursor(output_window, { #heading + 2, 0 })
  local qfid = opts.quickfix_id or M.new_quickfix(root, title)
  local token = {}
  running[root] = token
  local streams = { stdout = { raw = {}, partial = '' }, stderr = { raw = {}, partial = '' } }
  local queue, scheduled, finished, emitted = {}, false, false, 0
  vim.keymap.set('n', '<CR>', function()
    if finished then
      close_output(buf)
    end
  end, { buffer = buf, desc = 'Close completed task output' })
  local function flush(final)
    scheduled = false
    local completed, diagnostics = {}, {}
    local function emit(line)
      line = clean_output(line)
      local displayed = line
      if opts.render_line then
        displayed = opts.render_line(line)
      end
      if displayed then
        for _, part in ipairs(vim.split(displayed:gsub('\n$', ''), '\n', { plain = true })) do
          completed[#completed + 1] = part
        end
      end
      local parser = opts.diagnostics or require('rivet.diagnostics').parse
      local item = parser(line, opts.diagnostic_cwd or root)
      if item then
        if item.filename then
          item.filename = vim.fs.normalize(item.filename)
        end
        diagnostics[#diagnostics + 1] = item
      end
    end
    for _, event in ipairs(queue) do
      local stream = streams[event.name]
      stream.partial = stream.partial .. event.data
      while true do
        local newline = stream.partial:find('\n', 1, true)
        if not newline then
          break
        end
        emit(stream.partial:sub(1, newline - 1))
        stream.partial = stream.partial:sub(newline + 1)
      end
    end
    queue = {}
    if final then
      for _, name in ipairs({ 'stdout', 'stderr' }) do
        if streams[name].partial ~= '' then
          emit(streams[name].partial)
        end
        streams[name].partial = ''
      end
    end
    if #diagnostics > 0 then
      -- Update our own list, even if the user or another project changed lists.
      vim.fn.setqflist({}, 'a', { id = qfid, items = diagnostics })
    end
    if vim.api.nvim_buf_is_valid(buf) then
      local follow = {}
      local count = vim.api.nvim_buf_line_count(buf)
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if vim.api.nvim_win_get_cursor(win)[1] >= count - 1 then
          follow[#follow + 1] = win
        end
      end
      local output = vim.deepcopy(completed)
      for _, name in ipairs({ 'stdout', 'stderr' }) do
        if streams[name].partial ~= '' then
          output[#output + 1] = clean_output(streams[name].partial)
        end
      end
      local status = final and ('Exit status: ' .. final.code) or 'Running…'
      if final and (token.cancelled or (final.signal or 0) ~= 0) then
        status = 'Stopped (signal ' .. (final.signal or 0) .. ', exit ' .. final.code .. ')'
      end
      output[#output + 1] = status
      output[#output + 1] = final and completed_footer or running_footer
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, #heading + emitted, -1, false, output)
      vim.bo[buf].modifiable = false
      for _, win in ipairs(follow) do
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
      end
    end
    emitted = emitted + #completed
  end
  local function receive(name)
    return function(err, data)
      if data then
        streams[name].raw[#streams[name].raw + 1] = data
        queue[#queue + 1] = { name = name, data = data }
      end
      if err then
        queue[#queue + 1] = { name = name, data = '[' .. name .. ': ' .. tostring(err) .. ']\n' }
      end
      if not scheduled then
        scheduled = true
        vim.schedule(function()
          if not finished then
            flush()
          end
        end)
      end
    end
  end
  local ok, result = pcall(vim.system, argv, {
    cwd = opts.cwd or root,
    -- libuv creates a new session/process group on POSIX. Cancellation must
    -- reach the compiler, build tool, and application children as well.
    detach = true,
    text = true,
    stdout = receive('stdout'),
    stderr = receive('stderr'),
  }, function(process)
    vim.schedule(function()
      finished = true
      flush(process)
      running[root] = nil
      process.stdout = table.concat(streams.stdout.raw)
      process.stderr = table.concat(streams.stderr.raw)
      local success = process.code == 0 and (process.signal or 0) == 0 and not token.cancelled
      if token.cancelled then
        M.notify(title .. ' stopped.', vim.log.levels.WARN)
      elseif not success then
        M.notify(
          title
            .. ' failed (exit '
            .. process.code
            .. '). See output; :copen shows compiler diagnostics.',
          vim.log.levels.ERROR
        )
      end
      if
        success
        and opts.close_on_success
        and output_window
        and vim.api.nvim_win_is_valid(output_window)
        and vim.api.nvim_win_get_buf(output_window) == buf
      then
        close_view(output_window, buf)
      end
      if callback then
        callback(success, process)
      end
    end)
  end)
  if not ok then
    finished = true
    running[root] = nil
    replace(buf, vim.list_extend(heading, { tostring(result), completed_footer }))
    M.notify(tostring(result), vim.log.levels.ERROR)
    if callback then
      callback(false)
    end
    return
  end
  token.stop = function()
    if vim.fn.has('win32') == 1 then
      vim.system({ 'taskkill', '/PID', tostring(result.pid), '/T', '/F' })
    else
      vim.uv.kill(-result.pid, 15)
      -- A child can ignore TERM or outlive its parent and keep output pipes
      -- open. The group remains ours until its last process has exited.
      vim.defer_fn(function()
        vim.uv.kill(-result.pid, 9)
      end, 1000)
    end
  end
  vim.keymap.set('n', '<C-c>', function()
    if running[root] == token then
      M.stop(root)
    end
  end, { buffer = buf, desc = 'Stop the running project task' })
  return result
end

return M
