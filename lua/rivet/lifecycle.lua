-- Pure, reviewed changes to registered files. Module identity is a separate operation.
local M = {}
local function copy(v)
  if type(v) ~= 'table' then
    return v
  end
  local o = {}
  for k, x in pairs(v) do
    o[k] = copy(x)
  end
  return o
end
local function escaped(v)
  return (v:gsub('([^%w])', '%%%1'))
end
-- Mask comments and literals without changing offsets. Never refactor prose or string contents.
local function mask(text)
  local out, i = {}, 1
  while i <= #text do
    local rest = text:sub(i)
    local raw_start, raw_end, delimiter = rest:find('^u8R"([^%s%(]*)%(')
    if not raw_start then
      raw_start, raw_end, delimiter = rest:find('^[uUL]?R"([^%s%(]*)%(')
    end
    ---@type integer?
    local n = 1
    if rest:sub(1, 2) == '//' then
      n = (rest:find('\n', 1, true) or (#rest + 1)) - 1
    elseif rest:sub(1, 2) == '/*' then
      n = (rest:find('*/', 3, true) or (#rest - 1)) + 1
    elseif raw_start then
      local stop = rest:find(')' .. delimiter .. '"', raw_end + 1, true)
      n = stop and stop + #delimiter + 1 or #rest
    elseif rest:match('^%d') or rest:match('^%.%d') then
      -- Consume a preprocessing number, including C++ digit separators and
      -- exponent signs, before treating an apostrophe as a character literal.
      n = 1
      while n <= #rest do
        local c = rest:sub(n, n)
        if
          c:match('[%w_.]')
          or c == "'" and rest:sub(n + 1, n + 1):match('[%w_]')
          or c:match('[+-]') and rest:sub(n - 1, n - 1):match('[eEpP]')
        then
          n = n + 1
        else
          break
        end
      end
      n = n - 1
    elseif rest:sub(1, 1) == '"' or rest:sub(1, 1) == "'" then
      local quote = rest:sub(1, 1)
      n = 2
      while n <= #rest do
        if rest:sub(n, n) == '\\' then
          n = n + 2
        elseif rest:sub(n, n) == quote then
          break
        else
          n = n + 1
        end
      end
    else
      out[#out + 1] = text:sub(i, i)
      i = i + 1
      n = nil
    end
    if n then
      out[#out + 1] = text:sub(i, i + n - 1):gsub('[^\n]', ' ')
      i = i + n
    end
  end
  return table.concat(out)
end
function M.module_references(text, old, new)
  local clean, edits = mask(text), {}
  for a, token, b in clean:gmatch('()%f[%a_](module)%s+()') do
    edits[#edits + 1] = { a, token, b }
  end
  for a, token, b in clean:gmatch('()%f[%a_](import)%s+()') do
    edits[#edits + 1] = { a, token, b }
  end
  table.sort(edits, function(a, b)
    return a[3] > b[3]
  end)
  local count = 0
  for _, edit in ipairs(edits) do
    local at = edit[3]
    if clean:sub(at, at + #old - 1) == old and clean:sub(at + #old):match('^%s*;') then
      text = text:sub(1, at - 1) .. new .. text:sub(at + #old)
      count = count + 1
    end
  end
  return text, count
end
function M.plan(existing, opts, contents, render)
  local spec = copy(existing)
  local result = {
    spec = spec,
    files = {},
    replace = {},
    original = contents,
    managed = { ['cmake/RivetTargets.cmake'] = true },
  }
  local registered = {}
  for _, t in ipairs(spec.targets or {}) do
    for _, field in ipairs({ 'sources', 'headers', 'modules' }) do
      for _, path in ipairs(t[field] or {}) do
        registered[path] = not t.external or nil
      end
    end
  end
  local function replace(path, value)
    assert(contents[path] ~= nil, 'Registered file is missing: ' .. path)
    result.files[path], result.replace[path] = value, true
  end
  if opts.action == 'module' then
    local old, new =
      assert(opts.from, 'Module name required'), assert(opts.to, 'New module name required')
    assert(spec.module_names[old], 'Unknown module: ' .. old)
    assert(not spec.module_names[new], 'Module already exists: ' .. new)
    spec.module_names[new], spec.module_names[old] = spec.module_names[old], nil
    for path in pairs(registered) do
      if contents[path] then
        local text, n = M.module_references(contents[path], old, new)
        if n > 0 then
          replace(path, text)
        end
      end
    end
    assert(next(result.files), 'No module declarations found; reconcile the manifest first')
  else
    assert(opts.action == 'move' or opts.action == 'remove', 'Choose move or remove')
    local old, new = assert(opts.from, 'File path required'), opts.to
    assert(
      registered[old],
      'Only registered source, header, or module files can be changed; shader rules must be edited explicitly with their paths'
    )
    if opts.action == 'move' then
      require('rivet.runtime').safe_relative(assert(new, 'Destination path required'))
      assert(new:match('^[%w_./%-]+$'), 'Use letters, digits, _, -, /, or . in source paths')
      assert(
        new:match('%.([^%.]+)$') == old:match('%.([^%.]+)$'),
        'Keep the file extension when moving a registered file'
      )
      for _, path in ipairs(spec.files) do
        assert(path:lower() ~= new:lower(), 'Destination already registered: ' .. new)
      end
      result.files[new] = assert(contents[old], 'Source file is missing')
      result.moves = { [old] = new }
    end
    for name, entry in pairs(spec.module_names or {}) do
      if entry.path == old then
        if new then
          entry.path = new
        else
          for path in pairs(registered) do
            if path ~= old and contents[path] then
              local _, count = M.module_references(contents[path], name, name)
              assert(
                count == 0,
                'Module is still imported or implemented in '
                  .. path
                  .. '; remove those references explicitly first'
              )
            end
          end
          spec.module_names[name] = nil
        end
      end
    end
    -- Includes need semantic resolution; leave them visible to the reviewer rather than guessing.
    -- Module identity is unaffected by a path change.
    for _, target in ipairs(spec.targets or {}) do
      for _, field in ipairs({ 'sources', 'headers', 'modules' }) do
        for i = #(target[field] or {}), 1, -1 do
          if target[field][i] == old then
            if new then
              target[field][i] = new
            else
              table.remove(target[field], i)
            end
          end
        end
      end
    end
    for i = #spec.files, 1, -1 do
      if spec.files[i] == old then
        table.remove(spec.files, i)
      end
    end
    if new then
      spec.files[#spec.files + 1] = new
    end
    replace(old, false)
    result.notes = {
      'File paths change; C++ identifiers and #include references remain yours to update. Module/import renames use the separate module action.',
    }
  end
  for _, target in ipairs(spec.targets or {}) do
    assert(
      #(target.sources or {}) + #(target.modules or {}) > 0,
      'Cannot leave target '
        .. target.name
        .. ' without a compiled source; remove or restructure that target explicitly'
    )
  end
  table.sort(spec.files)
  result.files['cmake/RivetTargets.cmake'] = render(spec)
  return result
end
return M
