-- Process inspection: is a pid alive, what is its parent, where does it run.
--
-- Linux answers all of it from /proc with a few small reads. Elsewhere one
-- `ps` lists every process and is reused for a moment, because a refresh
-- asks about many processes and each `ps` is a process of its own; `lsof`
-- says where a process runs, and is remembered for longer.

local uv = vim.uv
local fs = require('agent-chats.util.fs')
local async = require('agent-chats.util.async')

local M = {}

M.has_procfs = uv.os_uname().sysname == 'Linux' and fs.is_dir('/proc/self')

--- Whether a process with this pid exists.
---@param pid integer?
function M.alive(pid)
  if type(pid) ~= 'number' or pid <= 0 then
    return false
  end
  local ok, _, name = uv.kill(pid, 0)
  return ok == 0 or name == 'EPERM'
end

--- `/proc/<pid>/stat` essentials (Linux only).
---@return { comm: string, ppid: integer, start: integer }?
function M.stat(pid)
  if not M.has_procfs then
    return nil
  end
  local raw = fs.read_small('/proc/' .. pid .. '/stat', 1024)
  if not raw then
    return nil
  end
  -- The command name is parenthesised and may itself contain spaces or
  -- parentheses, so match up to the last ')'.
  local comm, rest = raw:match('^%d+ %((.*)%) (.*)$')
  if not rest then
    return nil
  end
  local f = vim.split(rest, ' ', { plain = true })
  -- `rest` starts at field 3 (state): ppid is field 4, starttime field 22.
  return { comm = comm, ppid = tonumber(f[2]) or 0, start = tonumber(f[20]) or 0 }
end

--- Seconds in `ps -o etime=` output: `[[dd-]hh:]mm:ss`.
---@return number?
function M.parse_etime(s)
  s = vim.trim(s or '')
  local days, rest = s:match('^(%d+)%-(.+)$')
  local parts = vim.split(rest or s, ':', { plain = true })
  if #parts < 2 or #parts > 3 then
    return nil
  end
  local secs = 0
  for _, part in ipairs(parts) do
    local n = tonumber(part)
    if not n then
      return nil
    end
    secs = secs * 60 + n
  end
  return secs + (tonumber(days) or 0) * 86400
end

-- The process table without /proc: pid -> { ppid, args, born }.
local snapshot = { at = 0, rows = nil }
local SNAPSHOT_MS = 2000

---@return table<integer, { ppid: integer, args: string, born: number? }>
local function processes()
  if snapshot.rows and uv.now() - snapshot.at < SNAPSHOT_MS then
    return snapshot.rows
  end
  local res = async.system({ 'ps', '-axo', 'pid=,ppid=,etime=,args=' })
  local rows, now = {}, os.time()
  if res.code == 0 and res.stdout then
    for line in res.stdout:gmatch('[^\n]+') do
      local pid, ppid, etime, args = line:match('^%s*(%d+)%s+(%d+)%s+(%S+)%s+(.-)%s*$')
      if pid then
        local elapsed = M.parse_etime(etime)
        rows[tonumber(pid)] =
          { ppid = tonumber(ppid), args = args, born = elapsed and (now - elapsed) or nil }
      end
    end
  end
  snapshot = { at = uv.now(), rows = rows }
  return rows
end

--- Parent pid, or nil when unknown.
---@return integer?
function M.parent(pid)
  if M.has_procfs then
    local st = M.stat(pid)
    return st and st.ppid or nil
  end
  local row = processes()[pid]
  return row and row.ppid or nil
end

--- Argument list of a process (best effort outside Linux: split on spaces).
---@return string[]?
function M.argv(pid)
  if M.has_procfs then
    local raw = fs.read_small('/proc/' .. pid .. '/cmdline', 16384)
    if not raw or raw == '' then
      return nil
    end
    return vim.split(raw, '\0', { plain = true, trimempty = true })
  end
  local row = processes()[pid]
  return row and vim.split(row.args, ' ', { plain = true, trimempty = true }) or nil
end

-- pid -> { at, cwd }. `lsof` is slow, and an agent does not move about.
local cwds = {}
local CWD_MS = 30000

--- Working directory of a process.
---@return string?
function M.cwd(pid)
  if M.has_procfs then
    return uv.fs_readlink('/proc/' .. pid .. '/cwd')
  end
  local hit = cwds[pid]
  if hit and uv.now() - hit.at < CWD_MS then
    return hit.cwd
  end
  local res = async.system({ 'lsof', '-a', '-d', 'cwd', '-p', tostring(pid), '-Fn' })
  local cwd
  if res.code == 0 and res.stdout then
    cwd = res.stdout:match('\nn([^\n]+)') or res.stdout:match('^n([^\n]+)')
  end
  cwds[pid] = { at = uv.now(), cwd = cwd }
  return cwd
end

--- Paths a process holds open (Linux only; empty elsewhere).
---@return string[]
function M.open_paths(pid)
  local out = {}
  if not M.has_procfs then
    return out
  end
  local dir = '/proc/' .. pid .. '/fd'
  for _, e in ipairs(fs.scandir(dir)) do
    local target = uv.fs_readlink(dir .. '/' .. e.name)
    if target and target:sub(1, 1) == '/' then
      out[#out + 1] = target
    end
  end
  return out
end

local boot_time, clk_tck

--- Epoch seconds a process started at (to the second outside Linux).
---@return number?
function M.start_time(pid)
  if not M.has_procfs then
    local row = processes()[pid]
    return row and row.born or nil
  end
  local st = M.stat(pid)
  if not st then
    return nil
  end
  if not boot_time then
    boot_time = tonumber((fs.read_small('/proc/stat', 16384) or ''):match('btime (%d+)'))
  end
  if not clk_tck then
    local res = async.system({ 'getconf', 'CLK_TCK' })
    clk_tck = tonumber(vim.trim(res.stdout or '')) or 100
  end
  if not boot_time then
    return nil
  end
  return boot_time + st.start / clk_tck
end

--- Pids from `pid` up to init, nearest first (not including `pid`).
---@return integer[]
function M.ancestors(pid, limit)
  local out, seen = {}, { [pid] = true }
  local cur = pid
  for _ = 1, limit or 32 do
    local parent = M.parent(cur)
    if not parent or parent <= 1 or seen[parent] then
      break
    end
    out[#out + 1] = parent
    seen[parent] = true
    cur = parent
  end
  return out
end

local function base(path)
  return (fs.basename(path or ''):gsub('%.[%w]+$', ''))
end

-- Every process, read from /proc once and shared by whoever asks during
-- the same refresh (each agent without a registry looks for its own).
-- Outside a refresh every question gets a fresh look.
local proc_rows
local sharing = false

---@return { pid: integer, ppid: integer, comm: string, argv: string[]? }[]
local function table_of_processes()
  if sharing and proc_rows then
    return proc_rows
  end
  local rows = {}
  for _, e in ipairs(fs.scandir('/proc')) do
    local pid = tonumber(e.name)
    if pid then
      local st = M.stat(pid)
      if st then
        rows[#rows + 1] = { pid = pid, ppid = st.ppid, comm = st.comm }
      end
      async.tick()
    end
  end
  proc_rows = rows
  return rows
end

--- A refresh begins (`true`) or ends (`false`). While one runs, the process
--- table is read once and shared; either way the next question after this
--- call gets a fresh look.
---@param on boolean
function M.share(on)
  sharing = on
  proc_rows, snapshot = nil, { at = 0, rows = nil }
end

-- Runtimes and shells that host an agent as a script: the agent's name is
-- then in the arguments, not the command name.
local HOSTS = {
  node = true,
  nodejs = true,
  bun = true,
  deno = true,
  sh = true,
  bash = true,
  zsh = true,
  dash = true,
  ksh = true,
}

--- Running processes that are one of `names` (a set of executable names).
---@param names table<string, boolean>
---@return { pid: integer, ppid: integer?, name: string, argv: string[] }[]
function M.find(names)
  local out = {}
  local function consider(pid, ppid, comm, argv_fn)
    local name = names[comm] and comm or nil
    local argv
    if not name and (HOSTS[comm] or comm == '') then
      argv = argv_fn() or {}
      for i = 1, math.min(3, #argv) do
        local b = base(argv[i])
        if names[b] then
          name = b
          break
        end
      end
    end
    if name then
      out[#out + 1] = { pid = pid, ppid = ppid, name = name, argv = argv or argv_fn() or {} }
    end
  end

  if M.has_procfs then
    for _, row in ipairs(table_of_processes()) do
      consider(row.pid, row.ppid, row.comm, function()
        -- Read once, however many agents ask about this process.
        if row.argv == nil then
          row.argv = M.argv(row.pid) or false
        end
        return row.argv or nil
      end)
    end
    return out
  end

  for pid, row in pairs(processes()) do
    local argv = vim.split(row.args, ' ', { plain = true, trimempty = true })
    consider(pid, row.ppid, base(argv[1]), function()
      return argv
    end)
  end
  return out
end

-- Programs that only run another: what they were given says what runs.
local RUNNERS = {
  node = true,
  bun = true,
  deno = true,
  python = true,
  sh = true,
  bash = true,
  zsh = true,
  dash = true,
  ksh = true,
  env = true,
}

--- Whether `path` names one of `names`. Two places count: the file itself
--- (`codex`, `codex.js`, `qwen-code`), and the package it lies in when it
--- is installed under `node_modules` (`.../node_modules/@qwen-code/
--- qwen-code/dist/cli/index.js`). A folder that merely has the name
--- (`~/src/codex/scripts/lint.sh`, `~/.claude/tools/x.sh`) does not.
local function names_it(path, names)
  local parts = vim.split(path, '/', { plain = true, trimempty = true })
  local function named(part)
    part = (part:gsub('^@', ''))
    local word = part:match('^%a[%w_]*')
    return names[part] or (word and names[word]) or false
  end
  if #parts > 0 and named(parts[#parts]) then
    return true
  end
  for i, part in ipairs(parts) do
    if part == 'node_modules' then
      -- The package, or its scope and then the package.
      if (parts[i + 1] and named(parts[i + 1])) or (parts[i + 2] and named(parts[i + 2])) then
        return true
      end
    end
  end
  return false
end

--- Whether process `pid` is one of the programs in `names`: by its own
--- name, or, for a program that only runs another (node, a shell), by the
--- script it was started with. What else is on its command line (a file a
--- tool was pointed at) says nothing about what it is.
---@param pid integer
---@param names table<string, boolean>
---@return boolean
function M.is(pid, names)
  local st = M.stat(pid)
  if st and names[st.comm] then
    return true
  end
  local argv = M.argv(pid)
  if not argv or not argv[1] then
    return false
  end
  if names_it(argv[1], names) then
    return true
  end
  local program = (argv[1]:match('[^/]+$') or ''):match('^%a+')
  if program and RUNNERS[program] then
    -- Which word is the script cannot be told for every runner (options
    -- that take a value, `bun run x`): any of the first few may be it.
    for i = 2, math.min(#argv, 8) do
      if argv[i]:sub(1, 1) ~= '-' and names_it(argv[i], names) then
        return true
      end
    end
  end
  return false
end

--- Forget what was looked up (tests).
function M.reset()
  M.share(false)
  cwds = {}
end

return M
