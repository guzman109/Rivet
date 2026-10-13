-- Small dependency-free JSON codec shared by Lua, LuaJIT, and Neovim.
local M = {}
M.null = setmetatable({}, {
  __tostring = function()
    return 'null'
  end,
})
local array_mt = {}
function M.array(t)
  return setmetatable(t or {}, array_mt)
end
local escapes = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}
local function quote(s)
  return '"'
    .. s:gsub('[%z\1-\31\\"]', function(c)
      return escapes[c] or string.format('\\u%04x', c:byte())
    end)
    .. '"'
end
function M.encode(value)
  local active = {}
  local function enc(v, depth)
    if v == M.null then
      return 'null'
    end
    local t = type(v)
    if t == 'nil' then
      return 'null'
    end
    if t == 'boolean' then
      return tostring(v)
    end
    if t == 'string' then
      return quote(v)
    end
    if t == 'number' then
      assert(v == v and math.abs(v) ~= math.huge, 'Non-finite JSON number')
      return tostring(v)
    end
    assert(t == 'table' and not active[v], 'Invalid or cyclic JSON value')
    active[v] = true
    local is_array = getmetatable(v) == array_mt or #v > 0
    local parts, keys = {}, {}
    for k in pairs(v) do
      keys[#keys + 1] = k
    end
    if is_array then
      assert(#keys == #v, 'Sparse JSON array')
      for i = 1, #v do
        parts[#parts + 1] = enc(v[i], depth + 1)
      end
    else
      table.sort(keys)
      for _, k in ipairs(keys) do
        assert(type(k) == 'string', 'JSON object keys must be strings')
        parts[#parts + 1] = quote(k) .. ': ' .. enc(v[k], depth + 1)
      end
    end
    active[v] = nil
    local a, b = is_array and '[' or '{', is_array and ']' or '}'
    if #parts == 0 then
      return a .. b
    end
    local indent = string.rep('  ', depth + 1)
    return a
      .. '\n'
      .. indent
      .. table.concat(parts, ',\n' .. indent)
      .. '\n'
      .. string.rep('  ', depth)
      .. b
  end
  return enc(value, 0) .. '\n'
end
local function utf8(n)
  if n < 128 then
    return string.char(n)
  end
  if n < 2048 then
    return string.char(192 + math.floor(n / 64), 128 + n % 64)
  end
  if n < 65536 then
    return string.char(224 + math.floor(n / 4096), 128 + math.floor(n / 64) % 64, 128 + n % 64)
  end
  return string.char(
    240 + math.floor(n / 262144),
    128 + math.floor(n / 4096) % 64,
    128 + math.floor(n / 64) % 64,
    128 + n % 64
  )
end
---@param s string
---@return any
function M.decode(s)
  local i, parse = 1, nil
  local function ws()
    local _, e = s:find('^[ \t\r\n]*', i)
    i = (e or i - 1) + 1
  end
  local function fail(message)
    error(message .. ' at JSON byte ' .. i, 0)
  end
  local function str()
    i = i + 1
    local out = {}
    while i <= #s do
      local c = s:sub(i, i)
      i = i + 1
      if c == '"' then
        return table.concat(out)
      end
      if c == '\\' then
        local e = s:sub(i, i)
        i = i + 1
        local map = {
          ['"'] = '"',
          ['\\'] = '\\',
          ['/'] = '/',
          b = '\b',
          f = '\f',
          n = '\n',
          r = '\r',
          t = '\t',
        }
        if e == 'u' then
          local hex = s:sub(i, i + 3)
          if not hex:match('^%x%x%x%x$') then
            fail('Invalid Unicode escape')
          end
          local n = tonumber(hex, 16)
          i = i + 4
          if n >= 0xD800 and n <= 0xDBFF then
            local tail = s:sub(i, i + 5)
            if not tail:match('^\\u%x%x%x%x$') then
              fail('Missing Unicode low surrogate')
            end
            local low = tonumber(tail:sub(3), 16)
            if low < 0xDC00 or low > 0xDFFF then
              fail('Invalid Unicode low surrogate')
            end
            n = 0x10000 + (n - 0xD800) * 1024 + low - 0xDC00
            i = i + 6
          elseif n >= 0xDC00 and n <= 0xDFFF then
            fail('Unpaired Unicode surrogate')
          end
          out[#out + 1] = utf8(n)
        elseif map[e] then
          out[#out + 1] = map[e]
        else
          fail('Invalid string escape')
        end
      elseif c:byte() < 32 then
        fail('Control character in string')
      else
        out[#out + 1] = c
      end
    end
    fail('Unclosed string')
  end
  parse = function(depth)
    if depth > 100 then
      fail('JSON nesting too deep')
    end
    ws()
    local c = s:sub(i, i)
    if c == '"' then
      return str()
    end
    if c == '{' or c == '[' then
      local arr = c == '['
      local out = arr and M.array() or {}
      i = i + 1
      ws()
      local closing = arr and ']' or '}'
      if s:sub(i, i) == closing then
        i = i + 1
        return out
      end
      while true do
        local key
        if not arr then
          ws()
          if s:sub(i, i) ~= '"' then
            fail('Expected object key')
          end
          key = str()
          ws()
          if s:sub(i, i) ~= ':' then
            fail('Expected colon')
          end
          i = i + 1
        end
        local v = parse(depth + 1)
        if arr then
          out[#out + 1] = v
        else
          if out[key] ~= nil then
            fail('Duplicate key')
          end
          out[key] = v
        end
        ws()
        local sep = s:sub(i, i)
        i = i + 1
        if sep == closing then
          return out
        end
        if sep ~= ',' then
          fail('Expected comma or closing delimiter')
        end
      end
    end
    for word, value in pairs({ ['true'] = true, ['false'] = false, ['null'] = M.null }) do
      if s:sub(i, i + #word - 1) == word then
        i = i + #word
        return value
      end
    end
    local token = s:sub(i):match('^-?%d+%.?%d*[eE]?[+-]?%d*')
    if token then
      if token:match('^-?0%d') or token:match('%.$') or token:match('[eE][+-]?$') then
        fail('Invalid number')
      end
      local n = tonumber(token)
      if not n or n ~= n or math.abs(n) == math.huge then
        fail('Invalid number')
      end
      i = i + #token
      return n
    end
    fail('Expected JSON value')
  end
  assert(type(s) == 'string', 'JSON input must be text')
  local out = parse(0)
  ws()
  if i <= #s then
    fail('Trailing input')
  end
  return out
end
return M
