-- opencode.
--
--   chats     <data>/opencode.db   one SQLite database: `session`, `message`
--             and `part` tables, the last two holding JSON
--   running   no registry: processes named `opencode` are matched to a
--             session by `-s <id>` on their command line, else by folder
--
-- <data> is $XDG_DATA_HOME/opencode or ~/.local/share/opencode. The database
-- is read through the system SQLite library; without it, through opencode's
-- own `opencode db "<sql>" --format json`.
--
-- What a session is doing right now (busy, idle, asking for a permission)
-- is not in the database. opencode says it through its plugin events when
-- the plugin shipped here is installed (see `M.hooks`).

local async = require('agent-chats.util.async')
local common = require('agent-chats.providers.common')
local config = require('agent-chats.config')
local fs = require('agent-chats.util.fs')
local proc = require('agent-chats.util.proc')
local sqlite = require('agent-chats.util.sqlite')
local text = require('agent-chats.util.text')

---@type agent_chats.Provider
local M = { name = 'opencode', label = 'opencode' }

function M.home()
  local opt = config.provider('opencode').home
  if type(opt) ~= 'string' or opt == '' then
    local xdg = vim.env.XDG_DATA_HOME
    if xdg and xdg ~= '' then
      return vim.fs.normalize(xdg) .. '/opencode'
    end
  end
  return common.home('opencode', nil, '.local/share/opencode')
end

local function db_path()
  return M.home() .. '/opencode.db'
end

function M.available()
  return fs.is_file(db_path())
end

-----------------------------------------------------------------------------
-- Reading the database
-----------------------------------------------------------------------------

---@alias agent_chats.opencode.Query fun(sql: string, params: any[]?): table[]?, string?

--- When set, every statement goes through this function (tests).
---@type agent_chats.opencode.Query?
M._query = nil

local function literal(v)
  if type(v) == 'number' then
    return v == math.floor(v) and ('%d'):format(v) or tostring(v)
  end
  if v == nil or v == vim.NIL then
    return 'NULL'
  end
  return "'" .. tostring(v):gsub("'", "''") .. "'"
end

-- `sql` with each `?` replaced by its parameter as a literal: the command
-- line takes a statement, not bindings.
local function inline(sql, params)
  local i = 0
  return (sql:gsub('%?', function()
    i = i + 1
    return literal(params and params[i])
  end))
end

--- Run a statement through `opencode db`. A process per statement, so only
--- used where the SQLite library is missing.
---@type agent_chats.opencode.Query
function M._cli_query(sql, params)
  local home = M.home()
  if fs.basename(home) ~= 'opencode' then
    return nil, 'opencode db cannot be pointed at ' .. home
  end
  local res = async.system(
    { config.provider('opencode').cmd[1], 'db', inline(sql, params), '--format', 'json' },
    { env = { XDG_DATA_HOME = vim.fs.dirname(home) }, timeout = 15000 }
  )
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or '')
  end
  local rows = fs.decode(res.stdout)
  if type(rows) ~= 'table' then
    return nil, 'unreadable output from opencode db'
  end
  return rows
end

local function noop() end

-- A function that runs statements, one that releases what it holds, and
-- whether statements run on the editor's own thread.
local function connect()
  if M._query then
    return M._query, noop, false
  end
  if not fs.is_file(db_path()) then
    return nil, noop, false
  end
  if sqlite.available() then
    -- Read-only, and opened per use: the agent writes to this file (WAL)
    -- and nothing is held between refreshes.
    local db = sqlite.open(db_path())
    if not db then
      return nil, noop, false
    end
    return function(sql, params)
      return db:query(sql, params)
    end,
      function()
        db:close()
      end,
      true
  end
  return M._cli_query, noop, false
end

--- Run `fn(query, blocking)` against the database. nil when it cannot be read.
local function with_db(fn)
  local query, close, blocking = connect()
  if not query then
    return nil
  end
  local ok, a, b = xpcall(fn, debug.traceback, query, blocking)
  close()
  if not ok then
    error(a, 0)
  end
  return a, b
end

local function marks(n)
  return (('?,'):rep(n):sub(1, -2))
end

local function secs(ms)
  return type(ms) == 'number' and ms / 1000 or nil
end

-----------------------------------------------------------------------------
-- Discovery
-----------------------------------------------------------------------------

-- What the last discover saw. An idle database then costs two stats, and a
-- busy one costs work only for the sessions that could have changed: those
-- whose row changed, those that gained rows, and those recently active or
-- mid-turn (parts are rewritten in place while a reply streams).
---@type { path: string, sig: string?, sessions: table<string, table>, part_max: integer, message_max: integer }?
local seen

local HOT_SECS = 3600
local CHUNK = 40

-- The process each session was last seen running in, and when each
-- process was last seen. A session whose process is gone, and which has
-- not moved since, is not taken for the chat of another process.
local owners = {} ---@type table<string, integer>
local seen_at = {} ---@type table<integer, integer>

function M._reset()
  seen = nil
  owners, seen_at = {}, {}
end

local function signature(path)
  local out = {}
  for i, p in ipairs({ path, path .. '-wal' }) do
    local st = fs.stat(p)
    -- A read can leave an empty write-ahead log behind; that is no change.
    if st and (i == 1 or st.size > 0) then
      out[i] = ('%.7f:%d'):format(st.mtime, st.size)
    else
      out[i] = '-'
    end
  end
  return table.concat(out, '|')
end

local function entries()
  local out = {}
  for _, s in pairs(seen and seen.sessions or {}) do
    out[#out + 1] = s.entry
  end
  return out
end

function M.discover()
  local path = db_path()
  if not M._query and not fs.is_file(path) then
    seen = nil
    return {}
  end
  if not seen or seen.path ~= path then
    seen = { path = path, sessions = {}, part_max = 0, message_max = 0 }
  end
  local state = seen
  local sig = signature(path)
  if state.sig and sig == state.sig and sig ~= '-|-' then
    return entries()
  end

  with_db(function(query, blocking)
    -- Sessions archived in opencode are left out, as in its own list.
    local rows = query([[
      select id, parent_id, directory, title, agent, model, time_created, time_updated,
        (select max(rowid) from part) as part_max,
        (select max(rowid) from message) as message_max
      from session where time_archived is null]])
    if not rows then
      return
    end
    local now = os.time()
    local by_id, need, wanted = {}, {}, {}
    local function want(id)
      if by_id[id] and not wanted[id] then
        wanted[id] = true
        need[#need + 1] = id
      end
    end
    local part_max, message_max = 0, 0
    for _, row in ipairs(rows) do
      part_max, message_max = row.part_max or 0, row.message_max or 0
      row.part_max, row.message_max = nil, nil
      row.sig = table.concat({
        tostring(row.time_updated or 0),
        row.title or '',
        row.directory or '',
        row.parent_id or '',
      }, '\0')
      by_id[row.id] = row
    end
    local shrank = part_max < state.part_max or message_max < state.message_max
    for id, row in pairs(by_id) do
      local s = state.sessions[id]
      if
        not s
        or shrank
        or s.sig ~= row.sig
        or s.turn == 'working'
        or now - s.entry.mtime < HOT_SECS
      then
        want(id)
      end
    end
    if state.sig and (part_max > state.part_max or message_max > state.message_max) then
      local grown = query(
        'select session_id from part where rowid > ? union select session_id from message where rowid > ?',
        { state.part_max, state.message_max }
      )
      if not grown then
        return
      end
      for _, r in ipairs(grown) do
        want(r.session_id)
      end
    end

    local fresh = {}
    for i = 1, #need, CHUNK do
      local ids = vim.list_slice(need, i, i + CHUNK - 1)
      local agg = query(
        ([[
        select 'part' as kind, session_id, max(time_updated) as updated, count(*) as n
          from part where session_id in (%s) group by session_id
        union all
        select 'message', session_id, max(time_updated), count(*)
          from message where session_id in (%s) group by session_id]]):format(
          marks(#ids),
          marks(#ids)
        ),
        vim.list_extend(vim.list_slice(ids), ids)
      )
      if not agg then
        return
      end
      for _, id in ipairs(ids) do
        fresh[id] = { updated = by_id[id].time_updated or by_id[id].time_created or 0, parts = 0 }
      end
      for _, r in ipairs(agg) do
        local f = fresh[r.session_id]
        if f then
          f.updated = math.max(f.updated, r.updated or 0)
          if r.kind == 'part' then
            f.parts = r.n or 0
          end
        end
      end
      if blocking then
        async.tick()
      end
    end

    local sessions = {}
    for id, row in pairs(by_id) do
      local old = state.sessions[id]
      local f = fresh[id]
      local sig_row = row.sig
      row.sig = nil
      if f then
        sessions[id] = {
          sig = sig_row,
          turn = old and old.turn,
          entry = { id = id, mtime = f.updated / 1000, size = f.parts, data = row },
        }
      else
        sessions[id] = old
      end
    end
    state.sessions = sessions
    state.part_max, state.message_max = part_max, message_max
    -- Taken before reading, so a write that landed meanwhile is seen next time.
    state.sig = sig
  end)
  return entries()
end

-----------------------------------------------------------------------------
-- Parsing
-----------------------------------------------------------------------------

-- Newest messages read for the state of the turn.
local WINDOW = 8
-- Larger rows (huge tool output) are not decoded for the board.
local MAX_DECODE = 1048576

local USER_LIKE = [[(data like '%"role":"user"%' or data like '%"role": "user"%')]]

-- Tool calls that are the agent asking you something.
local ASKS = { question = true }

-- Titles opencode gives a chat before it has thought of one.
local function title_of(title)
  if type(title) ~= 'string' or title == '' then
    return nil
  end
  if title:find('^New session %- %d%d%d%d%-') or title:find('^Child session %- %d%d%d%d%-') then
    return nil
  end
  return title
end

local function decode_message(row)
  local m = fs.decode(row.data)
  if type(m) ~= 'table' then
    m = {}
  end
  m.id = row.id
  m.created = row.time_created
  m.row_updated = row.time_updated
  return m
end

-- Decoded parts of the given messages, grouped by message, in order.
local function parts_of(query, ids, limit)
  local out = {}
  if #ids == 0 then
    return out
  end
  local rows = query(
    ('select message_id, id, time_created, data from part where message_id in (%s) order by message_id, id'):format(
      marks(#ids)
    ),
    ids
  )
  for _, r in ipairs(rows or {}) do
    if type(r.data) == 'string' and (not limit or #r.data <= limit) then
      local p = fs.decode(r.data)
      if type(p) == 'table' then
        p.created = r.time_created
        out[r.message_id] = out[r.message_id] or {}
        table.insert(out[r.message_id], p)
      end
    end
  end
  return out
end

-- What the user typed in a message: its text parts, minus what the harness added.
local function prompt_text(parts)
  local out, files = {}, {}
  for _, p in ipairs(parts or {}) do
    if p.type == 'text' and type(p.text) == 'string' and not p.synthetic and not p.ignored then
      out[#out + 1] = p.text
    elseif p.type == 'file' then
      files[#files + 1] = ('[file: %s]'):format(tostring(p.filename or p.url or '?'))
    end
  end
  local s = vim.trim(table.concat(out, '\n'))
  if s == '' then
    s = table.concat(files, ' ')
  end
  return s ~= '' and s or nil
end

local function reply_text(parts)
  local last
  for _, p in ipairs(parts or {}) do
    if p.type == 'text' and type(p.text) == 'string' and vim.trim(p.text) ~= '' then
      last = p.text
    end
  end
  return last
end

local function tool_view(p)
  local state = type(p.state) == 'table' and p.state or {}
  local view = common.tool(p.tool, state.input)
  if type(state.title) == 'string' and state.title ~= '' then
    view.summary = text.oneline(state.title, 120)
  end
  return view, state
end

local function model_of(row)
  local m = type(row.model) == 'string' and fs.decode(row.model) or nil
  return type(m) == 'table' and (m.id or m.modelID) or nil
end

function M.parse(entry, prev)
  local row = entry.data or {}
  local out = {
    turn = 'unknown',
    title = title_of(row.title),
    cwd = row.directory,
    parent_id = row.parent_id,
    created = secs(row.time_created),
    updated = entry.mtime,
    model = model_of(row),
  }
  local carried = common.carried(prev, entry)
  out.first_prompt = carried and carried.first_prompt or nil

  local read = with_db(function(query)
    local rows = query(
      'select id, time_created, time_updated, data from message where session_id = ? order by time_created desc, id desc limit ?',
      { entry.id, WINDOW }
    )
    if not rows then
      return false
    end
    if #rows == 0 then
      return true
    end
    local msgs, ids = {}, {}
    for i, r in ipairs(rows) do
      msgs[i] = decode_message(r)
      ids[i] = r.id
    end
    local parts = parts_of(query, ids, MAX_DECODE)

    local newest = msgs[1]
    local t = type(newest.time) == 'table' and newest.time or {}
    if newest.role == 'user' then
      out.turn, out.turn_at = 'working', secs(t.created or newest.created)
    elseif type(newest.error) == 'table' then
      out.turn = newest.error.name == 'MessageAbortedError' and 'aborted' or 'done'
      out.turn_at = secs(t.completed or newest.row_updated)
    elseif not t.completed or newest.finish == 'tool-calls' then
      out.turn, out.turn_at = 'working', secs(t.created or newest.created)
    else
      out.turn, out.turn_at = 'done', secs(t.completed)
    end

    for _, m in ipairs(msgs) do
      if m.role == 'assistant' then
        out.model = m.modelID or out.model
        break
      end
    end
    for _, m in ipairs(msgs) do
      if m.role == 'assistant' then
        local s = reply_text(parts[m.id])
        if s then
          out.last_reply = text.clip(s, common.REPLY_BYTES)
          break
        end
      end
    end

    -- The newest prompt; in a long turn it lies beyond the window.
    for _, m in ipairs(msgs) do
      if m.role == 'user' then
        out.turn_began = out.turn_began
          or secs((type(m.time) == 'table' and m.time.created) or m.created)
        local s = prompt_text(parts[m.id])
        if s then
          out.last_prompt = text.clip(s, common.PROMPT_BYTES)
          break
        end
      end
    end
    local function find_prompt(order)
      local found = query(
        ('select id from message where session_id = ? and %s order by time_created %s, id %s limit 3'):format(
          USER_LIKE,
          order,
          order
        ),
        { entry.id }
      )
      local fids = {}
      for i, r in ipairs(found or {}) do
        fids[i] = r.id
      end
      local fparts = parts_of(query, fids, MAX_DECODE)
      for _, id in ipairs(fids) do
        local s = prompt_text(fparts[id])
        if s then
          return text.clip(s, common.PROMPT_BYTES)
        end
      end
    end
    local whole = #rows < WINDOW
    if not out.last_prompt and not whole then
      out.last_prompt = find_prompt('desc')
    end
    if not out.first_prompt then
      if whole then
        for i = #msgs, 1, -1 do
          local s = msgs[i].role == 'user' and prompt_text(parts[msgs[i].id])
          if s then
            out.first_prompt = text.clip(s, common.PROMPT_BYTES)
            break
          end
        end
      else
        out.first_prompt = find_prompt('asc')
      end
    end

    if out.turn == 'working' and newest.role == 'assistant' then
      for _, p in ipairs(parts[newest.id] or {}) do
        local status = type(p.state) == 'table' and p.state.status
        if p.type == 'tool' and (status == 'pending' or status == 'running') then
          out.pending_tool = true
          out.activity = common.activity(p.tool or 'tool', (tool_view(p)))
          out.asking = ASKS[p.tool] or nil
        end
      end
    end
    return true
  end)

  if not read and prev then
    -- Unreadable just now: keep what was known.
    for _, k in ipairs({ 'turn', 'turn_at', 'last_prompt', 'last_reply', 'first_prompt', 'model' }) do
      out[k] = prev[k] or out[k]
    end
  end
  if seen and seen.sessions[entry.id] then
    seen.sessions[entry.id].turn = out.turn
  end
  return out
end

-----------------------------------------------------------------------------
-- Running processes
-----------------------------------------------------------------------------

-- Subcommands that are not a chat (for `attach`, the chat lives in a server).
local NOT_A_CHAT = {}
for _, c in ipairs({
  'serve',
  'web',
  'acp',
  'attach',
  'db',
  'session',
  'export',
  'import',
  'models',
  'auth',
  'providers',
  'mcp',
  'agent',
  'upgrade',
  'uninstall',
  'stats',
  'github',
  'pr',
  'plugin',
  'plug',
  'debug',
  'completion',
}) do
  NOT_A_CHAT[c] = true
end

-- Options that take a value, so the word after them is not a positional.
local TAKES_VALUE = {}
for _, o in ipairs({
  '--port',
  '--hostname',
  '--mdns-domain',
  '--cors',
  '-m',
  '--model',
  '--prompt',
  '--agent',
  '--log-level',
  '--format',
  '--title',
  '--command',
  '--attach',
  '--dir',
  '-f',
  '--file',
}) do
  TAKES_VALUE[o] = true
end

local function base(path)
  return (fs.basename(path or ''):gsub('%.[%w]+$', ''))
end

local function read_argv(argv)
  -- A runtime or shell may come before the word that names the program.
  local start = 2
  for i = 1, math.min(3, #argv) do
    if base(argv[i]) == 'opencode' then
      start = i + 1
      break
    end
  end
  local out = { fork = false, continue = false }
  local i = start
  while i <= #argv do
    local a = argv[i]
    local key, val = a:match('^(%-%-?[%w%-]+)=(.*)$')
    if key then
      if key == '--session' or key == '-s' then
        out.session = val
      elseif key == '--prompt' then
        out.prompt = val
      end
    elseif a == '-s' or a == '--session' then
      out.session = argv[i + 1]
      i = i + 1
    elseif a == '--prompt' then
      out.prompt = argv[i + 1]
      i = i + 1
    elseif a == '--fork' then
      out.fork = true
    elseif a == '-c' or a == '--continue' then
      out.continue = true
    elseif TAKES_VALUE[a] then
      i = i + 1
    elseif a:sub(1, 1) ~= '-' and not out.command then
      out.command = a
    end
    i = i + 1
  end
  return out
end

---@param chats table<string, agent_chats.Chat>?
---@param reported table<string, agent_chats.Reported>?
function M.live(chats, reported)
  local out = {}
  chats = chats or {}
  local procs = proc.find({ opencode = true })
  local pids = {}
  for _, p in ipairs(procs) do
    pids[p.pid] = true
  end
  table.sort(procs, function(a, b)
    return a.pid < b.pid
  end)

  local unplaced = {}
  for _, p in ipairs(procs) do
    -- A launcher and the binary it starts are one chat: the outer one counts.
    if not (p.ppid and pids[p.ppid]) then
      local args = read_argv(p.argv or {})
      if not (args.command and NOT_A_CHAT[args.command]) then
        local cwd = proc.cwd(p.pid)
        if args.session and args.session ~= '' and not args.fork then
          out[args.session] = out[args.session] or { pid = p.pid, cwd = cwd }
        else
          unplaced[#unplaced + 1] = { pid = p.pid, cwd = cwd, args = args }
        end
      end
    end
  end

  -- A session whose plugin events name one of these processes runs in it,
  -- unless that process is younger than the event. This is the agent
  -- saying so itself: it comes before any guess.
  local named = {} ---@type table<integer, boolean>
  for id, said in pairs(reported or {}) do
    if not out[id] and chats[id] and said.pid and pids[said.pid] and not said.ended then
      local born = proc.start_time(said.pid)
      if not (born and said.pid_at and born > said.pid_at + 2) then
        out[id] = { pid = said.pid, cwd = proc.cwd(said.pid) }
        named[said.pid] = true
      end
    end
  end

  -- No id on the command line and no word from the agent. What is left to
  -- go by is the folder, the time, and the prompt a process was started
  -- with. Two processes in one folder must never both be given the chat
  -- that moved last: the terminals of two chats would be crossed, and a
  -- reply typed into the wrong one.
  local now = os.time()
  local guessing = {}
  for _, u in ipairs(unplaced) do
    if not named[u.pid] then
      u.dirs = {}
      if u.cwd then
        u.dirs[u.cwd] = true
        local project = u.args.command
        if project and project ~= 'run' then
          local dir =
            vim.fs.normalize(project:sub(1, 1) == '/' and project or (u.cwd .. '/' .. project))
          if fs.is_dir(dir) then
            u.dirs[dir] = true
          end
        end
      end
      -- Where the start time is known (Linux), a chat last touched before
      -- the process began is not it, unless it was `--continue`d.
      u.started = not u.args.continue and proc.start_time(u.pid) or nil
      guessing[#guessing + 1] = u
    end
  end
  -- The newest first.
  table.sort(guessing, function(a, b)
    local sa, sb = a.started or 0, b.started or 0
    if sa ~= sb then
      return sa > sb
    end
    return a.pid > b.pid
  end)

  local function born(chat)
    return chat.created or chat.updated or chat.mtime or 0
  end
  local function moved(chat)
    return chat.updated or chat.mtime or 0
  end
  --- A session that ran in a process which is gone, and has not moved
  --- since: nobody's now.
  local function left_behind(id, chat)
    local pid = owners[id]
    return pid ~= nil and not pids[pid] and moved(chat) <= (seen_at[pid] or 0) + 10
  end
  --- A session in a folder of `u` that no process has been given.
  local function free(id, chat, u)
    return not out[id]
      and not chat.parent_id
      and chat.cwd ~= nil
      and u.dirs[chat.cwd] == true
      and not left_behind(id, chat)
  end
  local function born_in(u, chat)
    return u.started ~= nil and born(chat) >= u.started - 2
  end
  local function norm(s)
    return (vim.trim(s):gsub('%s+', ' ')):sub(1, 200)
  end

  -- A process started with a prompt made the chat that begins with that
  -- prompt and was born once the process was there. (Of two started with
  -- the same words, the older has the older chat.)
  local made_by = {} ---@type table<string, table>
  for i = #guessing, 1, -1 do
    local u = guessing[i]
    local want = u.args.prompt and not u.args.continue and norm(u.args.prompt) or ''
    if want ~= '' then
      local best
      for id, chat in pairs(chats) do
        if
          free(id, chat, u)
          and not made_by[id]
          and chat.first_prompt
          and norm(chat.first_prompt) == want
          and (not u.started or born_in(u, chat))
          and (not best or born(chat) < born(chats[best]))
        then
          best = id
        end
      end
      if best then
        u.own, made_by[best] = best, u
      end
    end
  end
  -- And it is still in that chat, unless a chat nobody is known to have
  -- made was born in its folder later: the process may have gone on to
  -- that one (`/new`).
  for _, u in ipairs(guessing) do
    if u.own then
      local doubt = false
      for id, chat in pairs(chats) do
        if
          id ~= u.own
          and not made_by[id]
          and free(id, chat, u)
          and born(chat) > born(chats[u.own])
        then
          doubt = true
          break
        end
      end
      if not doubt then
        out[u.own] = { pid = u.pid, cwd = u.cwd }
        u.placed = true
      end
    end
  end

  -- The rest is a guess.
  local rest = {}
  for _, u in ipairs(guessing) do
    -- (Started with a prompt a moment ago: its chat is about to appear,
    -- and no other is taken for it meanwhile.)
    local soon = u.args.prompt and not u.own and u.started and now - u.started < 20
    if not u.placed and not soon then
      rest[#rest + 1] = u
    end
  end
  --- The chat among `fits` that moved last.
  local function latest(u, fits)
    local best
    for id, chat in pairs(chats) do
      if
        free(id, chat, u)
        and (not made_by[id] or made_by[id] == u)
        and fits(chat)
        and (not best or moved(chat) > moved(chats[best]))
      then
        best = id
      end
    end
    return best
  end
  for _, u in ipairs(rest) do
    -- With another process to guess for in the same folder, nothing tells
    -- the two apart for certain. The guess is still made (the chat's row
    -- leads to a terminal, where what is on the screen settles it), and
    -- it is marked as one: nothing is typed into a terminal on a guess.
    local contested = false
    for _, v in ipairs(rest) do
      if v ~= u then
        for dir in pairs(u.dirs) do
          contested = contested or v.dirs[dir] == true
        end
      end
    end
    local function since_start(chat)
      return not u.started or moved(chat) >= u.started - 5
    end
    local id
    if contested then
      -- The chat it made itself, then one born while it ran, then one
      -- that has moved while it ran.
      id = (u.own and not out[u.own]) and u.own
        or latest(u, function(chat)
          return born_in(u, chat)
        end)
        or latest(u, since_start)
    else
      -- Alone in its folder: the chat there that moved last while it ran.
      id = latest(u, since_start)
    end
    if id then
      out[id] = { pid = u.pid, cwd = u.cwd, unsure = contested or nil }
    end
  end

  -- A subagent session runs inside its parent's process, for as long as it
  -- is at work: mid-turn by what the database holds, or waiting for you.
  local hosted = {}
  for id, chat in pairs(chats) do
    local busy = (chat.turn_file or chat.turn) == 'working' or chat.turn == 'waiting'
    if not out[id] and chat.parent_id and busy then
      local top, hops = chat.parent_id, 0
      while chats[top] and chats[top].parent_id and hops < 8 do
        top, hops = chats[top].parent_id, hops + 1
      end
      if out[top] then
        hosted[id] = { pid = out[top].pid, cwd = out[top].cwd }
      end
    end
  end
  for id, l in pairs(hosted) do
    out[id] = l
  end
  -- Remembered for the next look (see `left_behind`).
  for id, l in pairs(out) do
    if l.pid and not hosted[id] then
      owners[id] = l.pid
    end
  end
  for pid in pairs(pids) do
    seen_at[pid] = now
  end
  return out
end

-----------------------------------------------------------------------------
-- Hooks
-----------------------------------------------------------------------------

-- opencode has no hook commands; it has plugins: a file in its plugins
-- folder that is handed every event of a session. The one shipped with
-- this plugin (scripts/opencode-agent-chats.js) writes down the events that
-- say what a session is doing. Requests carry an id, so several can be
-- open at once and each is closed by its own answer.
local function config_dir()
  local opt = config.provider('opencode').config_dir
  if type(opt) == 'string' and opt ~= '' then
    return (vim.fs.normalize(opt))
  end
  for _, env in ipairs({ 'OPENCODE_CONFIG_DIR', 'XDG_CONFIG_HOME' }) do
    local dir = vim.env[env]
    if dir and dir ~= '' then
      return vim.fs.normalize(dir) .. (env == 'XDG_CONFIG_HOME' and '/opencode' or '')
    end
  end
  return fs.home .. '/.config/opencode'
end

M.hooks = {
  events = {
    ['session.status'] = function(ev)
      if ev.type == 'busy' or ev.type == 'retry' then
        return 'active'
      elseif ev.type == 'idle' then
        return 'idle'
      end
      return nil
    end,
    ['session.idle'] = 'idle',
    -- Interrupting a turn is reported as an error of this name; the
    -- session going idle afterwards does not make it a finished turn.
    ['session.error'] = function(ev)
      return ev.type == 'MessageAbortedError' and 'aborted' or nil
    end,
    ['permission.asked'] = 'waiting',
    ['permission.replied'] = 'resolved',
    ['question.asked'] = function()
      return 'waiting', 'an answer to its question'
    end,
    ['question.replied'] = 'resolved',
    ['question.rejected'] = 'resolved',
  },
  process = { opencode = true },
  config = function()
    return {
      kind = 'file',
      path = config_dir() .. '/plugins/agent-chats.js',
      source = 'opencode-agent-chats.js',
      note = 'opencode loads its plugins when it starts: restart the sessions that are running.',
    }
  end,
}

-----------------------------------------------------------------------------
-- Transcript
-----------------------------------------------------------------------------

function M.messages(chat)
  local out = {}
  local read = with_db(function(query)
    local rows = query(
      'select id, time_created, time_updated, data from message where session_id = ? order by time_created, id',
      { chat.id }
    )
    local prows = query(
      'select message_id, id, time_created, data from part where session_id = ? order by message_id, id',
      { chat.id }
    )
    if not rows or not prows then
      return false
    end
    local parts = {}
    for i, r in ipairs(prows) do
      local p = type(r.data) == 'string' and fs.decode(r.data)
      if type(p) == 'table' then
        p.created = r.time_created
        parts[r.message_id] = parts[r.message_id] or {}
        table.insert(parts[r.message_id], p)
      end
      if i % 200 == 0 then
        async.tick()
      end
    end
    for _, r in ipairs(rows) do
      local m = decode_message(r)
      local role = m.role == 'user' and 'user' or 'assistant'
      for _, p in ipairs(parts[m.id] or {}) do
        local ts = secs(p.created or m.created)
        if p.type == 'text' and type(p.text) == 'string' and vim.trim(p.text) ~= '' then
          if not p.ignored then
            out[#out + 1] = {
              role = (role == 'user' and p.synthetic) and 'system' or role,
              text = p.text,
              time = ts,
            }
          end
        elseif p.type == 'file' then
          out[#out + 1] = {
            role = role,
            text = ('[file: %s]'):format(tostring(p.filename or p.url or '?')),
            time = ts,
          }
        elseif p.type == 'reasoning' and type(p.text) == 'string' and p.text ~= '' then
          out[#out + 1] = { role = 'thinking', text = p.text, time = ts }
        elseif p.type == 'compaction' then
          out[#out + 1] =
            { role = 'system', text = 'Earlier conversation was compacted here.', time = ts }
        elseif p.type == 'tool' then
          local view, state = tool_view(p)
          out[#out + 1] = {
            role = 'tool',
            id = p.callID,
            name = p.tool,
            summary = view.summary,
            input = view.input,
            lang = view.lang,
            time = ts,
          }
          if state.status == 'completed' then
            out[#out + 1] = {
              role = 'tool_result',
              id = p.callID,
              text = common.result_text(state.output),
              time = ts,
            }
          elseif state.status == 'error' then
            out[#out + 1] = {
              role = 'tool_result',
              id = p.callID,
              text = common.result_text(state.error),
              error = true,
              time = ts,
            }
          end
        end
      end
      if type(m.error) == 'table' then
        local data = type(m.error.data) == 'table' and m.error.data or {}
        out[#out + 1] = {
          role = 'system',
          text = m.error.name == 'MessageAbortedError' and 'Interrupted by user.'
            or ('Error: ' .. tostring(data.message or m.error.name or 'unknown')),
          time = secs(m.row_updated or m.created),
        }
      end
    end
    return true
  end)
  if not read then
    -- Not "an empty conversation": a viewer would show that, and replace
    -- what it had with it.
    error("opencode's database could not be read just now", 0)
  end
  -- No cursor: parts are rewritten in place, so a viewer reloads in full.
  return out, nil
end

-----------------------------------------------------------------------------
-- Search
-----------------------------------------------------------------------------

local GREP_ROWS = 2000

function M.grep(query_text)
  if type(query_text) ~= 'string' or query_text == '' then
    return nil
  end
  -- The text as it sits inside the stored JSON, then with LIKE's wildcards
  -- made literal. LIKE ignores ASCII case, so this never narrows too far.
  local needle = vim.json.encode(query_text):sub(2, -2):gsub('\\/', '/')
  needle = needle:gsub('[\\%%_]', '\\%0')
  local pattern = '%' .. needle .. '%'
  return with_db(function(query, blocking)
    local out = {}
    local function add(rows)
      for _, r in ipairs(rows) do
        out[r.session_id] = true
      end
    end
    if not blocking then
      local rows =
        query("select distinct session_id from part where data like ? escape '\\'", { pattern })
      if not rows then
        return nil
      end
      add(rows)
      return out
    end
    -- On the editor's thread: scan in slices so a large database cannot stall it.
    local top = query('select max(rowid) as top from part')
    if not top then
      return nil
    end
    local max, from = top[1] and top[1].top or 0, 0
    while from < max do
      local rows = query(
        "select distinct session_id from part where rowid > ? and rowid <= ? and data like ? escape '\\'",
        { from, from + GREP_ROWS, pattern }
      )
      if not rows then
        return nil
      end
      add(rows)
      from = from + GREP_ROWS
      async.tick()
    end
    return out
  end)
end

-----------------------------------------------------------------------------
-- Commands
-----------------------------------------------------------------------------

-- A prompt that the program could take for an option or a command of its
-- own is kept from that (see `common.arg`).
local arg = common.arg

function M.resume_cmd(chat)
  return common.cmd('opencode', '-s', chat.id)
end

function M.new_cmd(opts)
  local args = {}
  if opts.prompt and opts.prompt ~= '' then
    vim.list_extend(args, { '--prompt', arg(opts.prompt) })
  end
  return common.cmd('opencode', args)
end

function M.headless_cmd(chat, prompt)
  return common.cmd(
    'opencode',
    'run',
    '-s',
    chat.id,
    config.provider('opencode').headless_args,
    arg(prompt)
  )
end

function M.resume_prompt_cmd(chat, prompt)
  return common.cmd('opencode', '-s', chat.id, '--prompt', arg(prompt))
end

return M
