-- JSON as text: where each value sits in a file, so a few lines can be added
-- to or taken out of someone's settings without rewriting the rest. Key
-- order, indentation and comments all stay exactly as they were.
--
-- `scan` reads strict JSON and also the comments (`//`, `/* */`) some agents
-- allow in their settings.

local M = {}

---@class agent_chats.JsonNode
---@field kind "object"|"array"|"string"|"scalar"
---@field s integer            First byte of the value.
---@field e integer            Last byte of the value.
---@field members { key: string, s: integer, e: integer, value: agent_chats.JsonNode }[]?  Object members; `s`..`e` spans key to value.
---@field items agent_chats.JsonNode[]?  Array items.

local BYTE = string.byte

--- Position of the next byte that is neither blank nor inside a comment.
---@return integer? pos nil for a comment that never ends.
local function skip(text, i)
  while true do
    local c = BYTE(text, i)
    if c == 32 or c == 9 or c == 10 or c == 13 then
      i = i + 1
    elseif c == 47 then
      local n = BYTE(text, i + 1)
      if n == 47 then
        local nl = text:find('\n', i, true)
        i = nl and nl + 1 or #text + 1
      elseif n == 42 then
        local close = text:find('*/', i + 2, true)
        if not close then
          return nil
        end
        i = close + 2
      else
        return i
      end
    else
      return i
    end
  end
end

--- Last byte of the string that starts at `i`.
local function string_end(text, i)
  local j = i + 1
  while true do
    local c = BYTE(text, j)
    if not c then
      return nil
    elseif c == 92 then
      j = j + 2
    elseif c == 34 then
      return j
    else
      j = j + 1
    end
  end
end

local function line_of(text, pos)
  local _, n = text:sub(1, pos):gsub('\n', '')
  return n + 1
end

local value

local function fail(text, pos, what)
  error(('line %d: %s'):format(line_of(text, math.min(pos, #text)), what), 0)
end

local function object(text, i)
  local node = { kind = 'object', s = i, members = {} }
  local pos = skip(text, i + 1)
  if not pos then
    fail(text, i, 'a comment is never closed')
  end
  if BYTE(text, pos) == 125 then
    node.e = pos
    return node
  end
  while true do
    if BYTE(text, pos) ~= 34 then
      fail(text, pos, 'expected a quoted key')
    end
    local ke = string_end(text, pos)
    if not ke then
      fail(text, pos, 'a string is never closed')
    end
    local ok, key = pcall(vim.json.decode, text:sub(pos, ke))
    if not ok or type(key) ~= 'string' then
      fail(text, pos, 'unreadable key')
    end
    local colon = skip(text, ke + 1)
    if not colon or BYTE(text, colon) ~= 58 then
      fail(text, ke, 'expected ":" after a key')
    end
    local vs = skip(text, colon + 1)
    if not vs then
      fail(text, colon, 'a comment is never closed')
    end
    local v = value(text, vs)
    node.members[#node.members + 1] = { key = key, s = pos, e = v.e, value = v }
    local nxt = skip(text, v.e + 1)
    local c = nxt and BYTE(text, nxt)
    if c == 44 then
      pos = skip(text, nxt + 1)
      if not pos then
        fail(text, nxt, 'a comment is never closed')
      end
    elseif c == 125 then
      node.e = nxt
      return node
    else
      fail(text, nxt or v.e, 'expected "," or "}"')
    end
  end
end

local function array(text, i)
  local node = { kind = 'array', s = i, items = {} }
  local pos = skip(text, i + 1)
  if not pos then
    fail(text, i, 'a comment is never closed')
  end
  if BYTE(text, pos) == 93 then
    node.e = pos
    return node
  end
  while true do
    local v = value(text, pos)
    node.items[#node.items + 1] = v
    local nxt = skip(text, v.e + 1)
    local c = nxt and BYTE(text, nxt)
    if c == 44 then
      pos = skip(text, nxt + 1)
      if not pos then
        fail(text, nxt, 'a comment is never closed')
      end
    elseif c == 93 then
      node.e = nxt
      return node
    else
      fail(text, nxt or v.e, 'expected "," or "]"')
    end
  end
end

value = function(text, i)
  local c = BYTE(text, i)
  if c == 123 then
    return object(text, i)
  elseif c == 91 then
    return array(text, i)
  elseif c == 34 then
    local e = string_end(text, i)
    if not e then
      fail(text, i, 'a string is never closed')
    end
    return { kind = 'string', s = i, e = e }
  end
  local _, e = text:find('^[%w%+%-%.]+', i)
  if not e then
    fail(text, i, c and ('unexpected "%s"'):format(string.char(c)) or 'the file ends early')
  end
  return { kind = 'scalar', s = i, e = e }
end

--- Read `text` into a tree of byte spans.
---@param text string
---@return agent_chats.JsonNode? root, string? err
function M.scan(text)
  local start = 1
  if text:sub(1, 3) == '\239\187\191' then
    start = 4
  end
  local ok, res = pcall(function()
    local i = skip(text, start)
    if not i then
      fail(text, start, 'a comment is never closed')
    end
    local root = value(text, i)
    local rest = skip(text, root.e + 1)
    if not rest then
      fail(text, root.e, 'a comment is never closed')
    end
    if rest <= #text then
      fail(text, rest, 'something follows the end of the document')
    end
    return root
  end)
  if not ok then
    return nil, tostring(res)
  end
  return res, nil
end

--- `text` with every comment blanked out, byte for byte, so positions hold.
---@param text string
---@return string
function M.strip_comments(text)
  local out, i, last = {}, 1, 1
  local n = #text
  while i <= n do
    local c = BYTE(text, i)
    if c == 34 then
      i = (string_end(text, i) or n) + 1
    elseif c == 47 and (BYTE(text, i + 1) == 47 or BYTE(text, i + 1) == 42) then
      local stop
      if BYTE(text, i + 1) == 47 then
        local nl = text:find('\n', i, true)
        stop = nl and nl - 1 or n
      else
        local close = text:find('*/', i + 2, true)
        stop = close and close + 1 or n
      end
      out[#out + 1] = text:sub(last, i - 1)
      out[#out + 1] = (text:sub(i, stop):gsub('[^\n]', ' '))
      i, last = stop + 1, stop + 1
    else
      i = i + 1
    end
  end
  out[#out + 1] = text:sub(last)
  return table.concat(out)
end

--- Decode `text`, comments allowed. `null` stays a value (`vim.NIL`), so a
--- key set to null is still seen.
---@return any value, string? err
function M.decode(text)
  if text:sub(1, 3) == '\239\187\191' then
    text = text:sub(4)
  end
  local ok, v = pcall(vim.json.decode, text)
  if ok then
    return v, nil
  end
  local ok2, v2 = pcall(vim.json.decode, M.strip_comments(text))
  if ok2 then
    return v2, nil
  end
  return nil, (tostring(v):gsub('^.-:%d+: ', ''))
end

--- The member of an object node with this key.
---@param node agent_chats.JsonNode?
---@return { key: string, s: integer, e: integer, value: agent_chats.JsonNode }?
function M.member(node, key)
  if not node or node.kind ~= 'object' then
    return nil
  end
  for _, m in ipairs(node.members) do
    if m.key == key then
      return m
    end
  end
  return nil
end

--- The decoded value of a node.
function M.value(text, node)
  local v = M.decode(text:sub(node.s, node.e))
  return v
end

--- The whitespace one level of nesting is indented by, and the line ending.
---@param text string
---@param root agent_chats.JsonNode
---@return string unit, string newline
function M.style(text, root)
  local newline = text:find('\r\n', 1, true) and '\r\n' or '\n'
  local first = root.kind == 'object' and root.members[1] or (root.items and root.items[1])
  if first then
    local lead = text:sub(root.s + 1, first.s - 1):match('\n([ \t]*)$')
    if lead and lead ~= '' then
      return lead, newline
    end
  end
  return '  ', newline
end

---@class agent_chats.JsonEdit
---@field s integer   First byte replaced (or the byte the text goes in front of).
---@field e integer   Last byte replaced; `s - 1` for an insertion.
---@field text string

--- Apply edits to `text`. They must not overlap.
---@param text string
---@param edits agent_chats.JsonEdit[]
---@return string
function M.apply(text, edits)
  table.sort(edits, function(a, b)
    return a.s > b.s
  end)
  for _, ed in ipairs(edits) do
    text = text:sub(1, ed.s - 1) .. ed.text .. text:sub(ed.e + 1)
  end
  return text
end

--- Position of the comma that follows `pos`, blanks and comments skipped.
local function comma_after(text, pos)
  local i = skip(text, pos)
  if i and BYTE(text, i) == 44 then
    return i
  end
  return nil
end

--- First byte of the line `pos` is on.
local function line_start(text, pos)
  local i = pos
  while i > 1 and BYTE(text, i - 1) ~= 10 do
    i = i - 1
  end
  return i
end

--- The newline that ends the line `pos` is on (the last byte of the text
--- when there is none).
local function line_end(text, pos)
  return text:find('\n', pos, true) or #text
end

--- Edits that remove some children of an object or array node, with the
--- commas that go with them and nothing else: a comment beside or between
--- them stays. `gone[i]` marks child `i`.
---@param text string
---@param node agent_chats.JsonNode
---@param gone table<integer, boolean>
---@return agent_chats.JsonEdit[]
function M.remove(text, node, gone)
  local kids = node.members or node.items
  local n = #kids
  local edits = {}
  local i = 1
  while i <= n do
    if gone[i] then
      local j = i
      while j < n and gone[j + 1] do
        j = j + 1
      end
      local s, e = kids[i].s, kids[j].e
      local whole_lines = true
      if j < n then
        -- Its own comma goes with it.
        e = comma_after(text, e + 1) or e
      elseif i > 1 then
        -- The last children: the comma that led up to them goes instead.
        local comma = comma_after(text, kids[i - 1].e + 1)
        if comma and text:sub(comma + 1, s - 1):match('^%s*$') then
          -- Nothing but blanks in between: one cut, from that comma on.
          s, whole_lines = comma, false
        elseif comma then
          edits[#edits + 1] = { s = comma, e = comma, text = '' }
        end
      end
      if whole_lines then
        -- Alone on its lines, the lines go with it; sharing a line, only
        -- the blanks that followed it do.
        local ls, le = line_start(text, s), line_end(text, e)
        if text:sub(ls, s - 1):match('^[ \t]*$') and text:sub(e + 1, le):match('^[ \t\r]*\n?$') then
          s, e = ls, le
        else
          local _, blanks = text:find('^[ \t]+', e + 1)
          e = blanks or e
        end
      end
      if i == 1 and j == n then
        -- Every child: when only blanks are left between the brackets,
        -- close them up.
        local rest = text:sub(node.s + 1, s - 1) .. text:sub(e + 1, node.e - 1)
        if rest:match('^%s*$') then
          return { { s = node.s + 1, e = node.e - 1, text = '' } }
        end
      end
      edits[#edits + 1] = { s = s, e = e, text = '' }
      i = j + 1
    else
      i = i + 1
    end
  end
  return edits
end

--- An edit that adds `piece` as the last child of an object or array node.
--- `piece` is the child's text (`"key": value` for an object); `pad` is the
--- indentation of the node's own line.
---@param text string
---@param node agent_chats.JsonNode
---@param piece string
---@param pad string
---@param unit string
---@param newline string
---@return agent_chats.JsonEdit
function M.append(text, node, piece, pad, unit, newline)
  local kids = node.members or node.items
  if #kids == 0 then
    local inner = text:sub(node.s + 1, node.e - 1)
    if inner:match('^%s*$') then
      return {
        s = node.s + 1,
        e = node.e - 1,
        text = newline .. pad .. unit .. piece .. newline .. pad,
      }
    end
    -- Something is written between the brackets (a comment). It stays
    -- where it is, and the new child goes on a line of its own after it.
    local last_nl = inner:match('.*()\n')
    if last_nl and inner:sub(last_nl + 1):match('^[ \t]*$') then
      local at = node.s + 1 + last_nl
      return { s = at, e = at - 1, text = pad .. unit .. piece .. newline }
    end
    return { s = node.e, e = node.e - 1, text = newline .. pad .. unit .. piece .. newline .. pad }
  end
  local last = kids[#kids]
  -- Written on one line: stay on it.
  if not text:sub(node.s, node.e):find('\n', 1, true) then
    return { s = last.e + 1, e = last.e, text = ', ' .. piece }
  end
  return { s = last.e + 1, e = last.e, text = ',' .. newline .. pad .. unit .. piece }
end

--- Every comment in `text`, in order.
---@param text string
---@return string[]
function M.comments(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local c = BYTE(text, i)
    if c == 34 then
      i = (string_end(text, i) or n) + 1
    elseif c == 47 and (BYTE(text, i + 1) == 47 or BYTE(text, i + 1) == 42) then
      local stop
      if BYTE(text, i + 1) == 47 then
        local nl = text:find('\n', i, true)
        stop = nl and nl - 1 or n
      else
        local close = text:find('*/', i + 2, true)
        stop = close and close + 1 or n
      end
      out[#out + 1] = (text:sub(i, stop):gsub('\r$', ''))
      i = stop + 1
    else
      i = i + 1
    end
  end
  return out
end

return M
