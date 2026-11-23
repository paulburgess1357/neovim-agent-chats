-- Text shaping for one-line rows and previews.

local M = {}

-- The cells a text takes, by the text alone. (`strdisplaywidth()` answers
-- for the window the cursor is in, with its wrapping and its indent of
-- wrapped lines: rows drawn while the cursor was in a conversation came
-- out narrower than the list they were drawn for.)
local strwidth = vim.api.nvim_strwidth

--- The first line of `s` that says something; nil when none does. What a
--- prompt of several lines is called by: its first line, not the start of
--- its second run on behind it.
---@param s string?
---@return string?
function M.first_line(s)
  if type(s) ~= 'string' then
    return nil
  end
  for line in s:sub(1, 4096):gmatch('[^\r\n]+') do
    if line:find('%S') then
      return vim.trim(line)
    end
  end
  return nil
end

--- Collapse `s` to a single clean line, at most `max` cells wide (when given).
---@param s string?
---@param max integer?
---@return string
function M.oneline(s, max)
  if type(s) ~= 'string' or s == '' then
    return ''
  end
  -- A prompt can be megabytes of pasted text; only its start can be shown.
  if #s > 4096 then
    s = s:sub(1, 4096)
  end
  s = s:gsub('[%c]+', ' '):gsub('%s+', ' ')
  s = vim.trim(s)
  if max then
    s = M.truncate(s, max)
  end
  return s
end

--- Cut `s` to `width` display cells, ending in an ellipsis when cut.
---@param s string
---@param width integer
---@return string
function M.truncate(s, width)
  if width <= 0 then
    return ''
  end
  if strwidth(s) <= width then
    return s
  end
  -- (The ellipsis is two cells where 'ambiwidth' is "double".)
  local dots = strwidth('…')
  if width <= dots then
    return width == dots and '…' or ''
  end
  local n = math.min(vim.fn.strchars(s), width - dots)
  local out = vim.fn.strcharpart(s, 0, n)
  while n > 0 and strwidth(out) > width - dots do
    n = n - 1
    out = vim.fn.strcharpart(s, 0, n)
  end
  return out .. '…'
end

--- Cut `s` to `width` display cells from the left, keeping its end: for a
--- path, whose last parts say the most.
---@param s string
---@param width integer
---@return string
function M.truncate_left(s, width)
  if width <= 0 then
    return ''
  end
  if strwidth(s) <= width then
    return s
  end
  local dots = strwidth('…')
  if width <= dots then
    return width == dots and '…' or ''
  end
  local total = vim.fn.strchars(s)
  local n = math.min(total, width - dots)
  local out = vim.fn.strcharpart(s, total - n)
  while n > 0 and strwidth(out) > width - dots do
    n = n - 1
    out = vim.fn.strcharpart(s, total - n)
  end
  return '…' .. out
end

--- Truncate, then pad on the right to exactly `width` cells.
function M.fit(s, width)
  if width <= 0 then
    return ''
  end
  s = M.truncate(s, width)
  return s .. string.rep(' ', width - strwidth(s))
end

--- Pad on the left to `width` cells (right-aligned column).
function M.rfit(s, width)
  if width <= 0 then
    return ''
  end
  s = M.truncate(s, width)
  return string.rep(' ', width - strwidth(s)) .. s
end

M.width = strwidth

--- Lines of `s`, without trailing blank lines.
---@param s string?
---@return string[]
function M.lines(s)
  if type(s) ~= 'string' or s == '' then
    return {}
  end
  local out = vim.split(s:gsub('\r\n?', '\n'), '\n', { plain = true })
  while #out > 0 and out[#out]:match('^%s*$') do
    out[#out] = nil
  end
  return out
end

--- The first `n` lines of `s`, plus how many were left out.
---@return string[] lines, integer omitted
function M.head_lines(s, n)
  local lines = M.lines(s)
  if #lines <= n then
    return lines, 0
  end
  local out = {}
  for i = 1, n do
    out[i] = lines[i]
  end
  return out, #lines - n
end

--- Keep at most `max` bytes of `s`, cutting on a UTF-8 boundary.
function M.clip(s, max)
  if type(s) ~= 'string' or #s <= max then
    return s
  end
  local cut = max
  -- Step back off continuation bytes (10xxxxxx).
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return s:sub(1, cut)
end

--- Keep the last `max` bytes of `s`, cutting on a UTF-8 boundary.
function M.clip_tail(s, max)
  if type(s) ~= 'string' or #s <= max then
    return s
  end
  local start = #s - max + 1
  while start <= #s do
    local b = s:byte(start)
    if b < 0x80 or b >= 0xC0 then
      break
    end
    start = start + 1
  end
  return s:sub(start)
end

--- `s` broken into lines of at most `width` cells, at spaces.
---@param s string
---@param width integer
---@return string[]
function M.wrap(s, width)
  width = math.max(width, 10)
  local out, line = {}, ''
  for word in s:gmatch('%S+') do
    if line == '' then
      line = word
    elseif strwidth(line) + 1 + strwidth(word) <= width then
      line = line .. ' ' .. word
    else
      out[#out + 1] = line
      line = word
    end
  end
  if line ~= '' then
    out[#out + 1] = line
  end
  return out
end

--- `a`, `a and b`, `a, b and c`.
---@param items string[]
function M.list(items)
  local n = #items
  if n <= 1 then
    return items[1] or ''
  end
  return table.concat(items, ', ', 1, n - 1) .. ' and ' .. items[n]
end

--- A random version-4 UUID.
function M.uuid()
  local bytes = vim.uv.random(16)
  local b = { bytes:byte(1, 16) }
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  return ('%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x'):format(unpack(b))
end

M.UUID = '%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x'

--- A shell command line for an argument list, for display and for pasting.
---@param argv string[]
function M.cmdline(argv)
  local out = {}
  for i, a in ipairs(argv) do
    out[i] = a:match('^[%w%-%._/=:@%%+,]+$') and a or vim.fn.shellescape(a)
  end
  return table.concat(out, ' ')
end

--- Case-insensitive plain-text match unless the needle has an uppercase letter.
---@return fun(haystack: string): integer?, integer?
function M.matcher(needle)
  local smart = needle:match('%u') ~= nil
  local n = smart and needle or needle:lower()
  return function(haystack)
    if type(haystack) ~= 'string' then
      return nil
    end
    return (smart and haystack or haystack:lower()):find(n, 1, true)
  end
end

return M
