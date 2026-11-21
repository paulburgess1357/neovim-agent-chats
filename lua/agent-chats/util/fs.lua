-- File helpers. Everything here is synchronous and cheap; callers that walk
-- many files call `async.tick()` between them.

local uv = vim.uv

local M = {}

M.home = uv.os_homedir() or vim.env.HOME or ''

---@param path string
---@return { mtime: number, size: integer, type: string }?
function M.stat(path)
  local st = uv.fs_stat(path)
  if not st then
    return nil
  end
  return { mtime = st.mtime.sec + st.mtime.nsec / 1e9, size = st.size, type = st.type }
end

function M.exists(path)
  return uv.fs_stat(path) ~= nil
end

function M.is_dir(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == 'directory'
end

function M.is_file(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == 'file'
end

--- Entries of a directory as `{ name, type }`. Empty when it cannot be read.
---@param path string
---@return { name: string, type: string }[]
function M.scandir(path)
  local out = {}
  local handle = uv.fs_scandir(path)
  if not handle then
    return out
  end
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if not typ or typ == 'unknown' or typ == 'link' then
      local st = uv.fs_stat(path .. '/' .. name)
      typ = st and st.type or 'unknown'
    end
    out[#out + 1] = { name = name, type = typ }
  end
  return out
end

--- Read `len` bytes at `offset`.
---@return string?
function M.read_range(path, offset, len)
  local fd = uv.fs_open(path, 'r', 292)
  if not fd then
    return nil
  end
  local data = uv.fs_read(fd, len, offset)
  uv.fs_close(fd)
  return data
end

--- The whole of a regular file, or nil when it is not there or cannot be
--- read. The size is taken from the file once it is open: another process
--- may replace it between a look and the open, and a size from the look
--- would then cut the new file short.
---@return string?
function M.read_file(path)
  local fd = uv.fs_open(path, 'r', 292)
  if not fd then
    return nil
  end
  local st = uv.fs_fstat(fd)
  if not st or st.type ~= 'file' then
    uv.fs_close(fd)
    return nil
  end
  local data = st.size == 0 and '' or uv.fs_read(fd, st.size, 0)
  uv.fs_close(fd)
  return data
end

--- What is at `path`: "file" (readable), "missing", or a reason it cannot
--- be used: "unreadable", "not a file", "dangling link". For callers that
--- must not take "cannot read" for "not there".
---@return "file"|"missing"|"unreadable"|"not a file"|"dangling link"
function M.kind(path)
  local st = uv.fs_stat(path)
  if not st then
    return uv.fs_lstat(path) and 'dangling link' or 'missing'
  end
  if st.type ~= 'file' then
    return 'not a file'
  end
  local fd = uv.fs_open(path, 'r', 292)
  if not fd then
    return 'unreadable'
  end
  uv.fs_close(fd)
  return 'file'
end

--- Read a file whose size is not known up front (procfs reports 0).
---@return string?
function M.read_small(path, max)
  return M.read_range(path, 0, max or 65536)
end

--- Decode JSON, mapping `null` to nil. Returns nil on malformed input.
function M.decode(text)
  if not text or text == '' then
    return nil
  end
  local ok, val = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if ok then
    return val
  end
  return nil
end

function M.read_json(path)
  return M.decode(M.read_file(path))
end

--- Call `fn(line)` for every complete (newline-terminated) line of `data`.
--- Returns the number of bytes consumed, so a caller reading a growing file
--- can resume at `offset + consumed` and never see half a line.
---@param data string
---@param fn fun(line: string)
---@return integer consumed
function M.each_line(data, fn)
  local pos, len = 1, #data
  local find, sub = string.find, string.sub
  while pos <= len do
    local nl = find(data, '\n', pos, true)
    if not nl then
      break
    end
    if nl > pos then
      fn(sub(data, pos, nl - 1))
    end
    pos = nl + 1
  end
  return pos - 1
end

---@class agent_chats.JsonlOpts
---@field skip (fun(line: string): boolean)? Raw-line filter applied before decoding.
---@field size integer? File size, when the caller already knows it.

local function decode_lines(data, opts, drop_first, keep_last)
  local out = {}
  local skip = opts and opts.skip
  local first = true
  local consumed = M.each_line(data, function(line)
    if first and drop_first then
      first = false
      return
    end
    first = false
    if skip and skip(line) then
      return
    end
    local rec = M.decode(line)
    if type(rec) == 'table' then
      out[#out + 1] = rec
    end
  end)
  -- A last line with no newline yet: complete in a finished file, partial in
  -- one still being written. It is kept only if it decodes.
  if keep_last and consumed < #data and not (first and drop_first) then
    local line = string.sub(data, consumed + 1)
    if not (skip and skip(line)) then
      local rec = M.decode(line)
      if type(rec) == 'table' then
        out[#out + 1] = rec
      end
    end
  end
  return out
end

--- Records decoded from the first `bytes` of a JSONL file.
---@return table[] records, boolean whole Whether the whole file was read.
function M.jsonl_head(path, bytes, opts)
  local size = opts and opts.size or (M.stat(path) or {}).size
  if not size then
    return {}, false
  end
  local whole = size <= bytes
  local data = M.read_range(path, 0, math.min(size, bytes))
  if not data then
    return {}, false
  end
  return decode_lines(data, opts, false, whole), whole
end

--- Records decoded from the last `bytes` of a JSONL file.
---@return table[] records, boolean whole Whether the whole file was read.
function M.jsonl_tail(path, bytes, opts)
  local size = opts and opts.size or (M.stat(path) or {}).size
  if not size then
    return {}, false
  end
  local whole = size <= bytes
  local offset = whole and 0 or size - bytes
  local data = M.read_range(path, offset, size - offset)
  if not data then
    return {}, false
  end
  -- Unless the read began at the start of the file, its first line is a
  -- fragment of a longer one.
  return decode_lines(data, opts, not whole, true), whole
end

--- Create a folder and the ones above it. `mode` (default 0755) is given
--- to those that had to be made.
---@param dir string
---@param mode integer?
function M.mkdirp(dir, mode)
  if not M.is_dir(dir) then
    pcall(vim.fn.mkdir, dir, 'p', mode or 493)
  end
end

--- Write `data` to `path` so readers never see a half-written file.
---@param path string
---@param data string
---@param mode integer?  Permission bits of the file (default 0644).
---@return boolean ok
function M.write_atomic(path, data, mode)
  M.mkdirp(vim.fs.dirname(path))
  local tmp = ('%s.%d.tmp'):format(path, uv.os_getpid())
  local fd = uv.fs_open(tmp, 'w', mode or 420)
  if not fd then
    return false
  end
  local written = uv.fs_write(fd, data, 0)
  uv.fs_close(fd)
  local ok = written == #data
  if ok and mode then
    -- Exactly these bits, whatever the umask made of them.
    uv.fs_chmod(tmp, mode)
  end
  if not ok then
    uv.fs_unlink(tmp)
    return false
  end
  if uv.fs_rename(tmp, path) ~= true then
    uv.fs_unlink(tmp)
    return false
  end
  return true
end

--- `~/x` for paths under the home directory.
function M.tilde(path)
  if not path or path == '' then
    return ''
  end
  if M.home ~= '' and path:sub(1, #M.home) == M.home then
    local rest = path:sub(#M.home + 1)
    if rest == '' or rest:sub(1, 1) == '/' then
      return '~' .. rest
    end
  end
  return path
end

--- Last path component.
function M.basename(path)
  if not path or path == '' then
    return ''
  end
  return (path:gsub('/+$', ''):match('([^/]+)$')) or path
end

return M
