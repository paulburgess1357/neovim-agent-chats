-- What the agents report about themselves through their own hooks.
--
-- A hook appends one line per event to
--
--   <dir>/<agent>/<session id>.log      {"t":1763650000.123,"e":"Stop",...}
--
-- (scripts/agent-chats-hook.sh for agents with command hooks, a plugin file
-- for opencode). This module folds such a log into the state of the chat's
-- turn: working, waiting for you, done or aborted.
--
-- Nothing here deletes or rewrites a log, so any number of Neovim instances
-- can read the same ones; each keeps its own position. Only whole lines are
-- read, so a line caught half written is picked up on the next look.
--
-- A provider says what its events mean with one small table (`hooks.events`,
-- see types.lua): event name -> signal. The signals:
--
--   working    a turn began
--   active     the turn is running
--   waiting    the agent asked you something (a permission, a question)
--   resolved   a request was answered, or a tool finished
--   done       the turn finished
--   idle       the session is idle: done, unless the turn was interrupted
--   aborted    the turn was interrupted
--   start      the session started or resumed: forget what was known
--   ended      the session closed

local config = require('agent-chats.config')
local fs = require('agent-chats.util.fs')

local M = {}

---@class agent_chats.Reported
---@field turn agent_chats.Turn?  The turn state the events add up to.
---@field at number               Epoch seconds of the last event that says so.
---@field waiting_for string?     What the oldest open request is about.
---@field pid integer?            The agent's process, as last reported.
---@field pid_at number?
---@field ended boolean?          The session said it closed.
---@field path string?            The transcript file the agent named.
---@field cwd string?
---@field count integer           Events read so far.

--- Where hooks write. The same place for every Neovim (it does not follow
--- $NVIM_APPNAME), because the agents know nothing about Neovim.
---@return string
function M.dir()
  local opt = config.get().hooks.dir
  if type(opt) == 'string' and opt ~= '' then
    return (vim.fs.normalize(opt))
  end
  local env = vim.env.AGENT_CHATS_EVENTS_DIR
  if env and env ~= '' then
    return (vim.fs.normalize(env))
  end
  local state = vim.env.XDG_STATE_HOME
  if not state or state == '' then
    state = fs.home .. '/.local/state'
  end
  return vim.fs.normalize(state) .. '/agent-chats/events'
end

--- Where a hook writes when its command names no folder: what the script
--- works out from the environment, taken to be the same as Neovim's.
---@return string
function M.unset_dir()
  local env = vim.env.AGENT_CHATS_EVENTS_DIR
  if env and env ~= '' then
    return (vim.fs.normalize(env))
  end
  local state = vim.env.XDG_STATE_HOME
  if not state or state == '' then
    state = fs.home .. '/.local/state'
  end
  return vim.fs.normalize(state) .. '/agent-chats/events'
end

local function safe_id(id)
  return type(id) == 'string' and id ~= '' and not id:find('[^%w_%-]')
end

--- The log of one session.
---@return string?
function M.path(agent, id)
  if not safe_id(agent) or not safe_id(id) then
    return nil
  end
  return ('%s/%s/%s.log'):format(M.dir(), agent, id)
end

-----------------------------------------------------------------------------
-- Folding events into a turn state
-----------------------------------------------------------------------------

local function fresh()
  return { offset = 0, pending = {}, count = 0, at = 0 }
end

-- A request is filed under the id the agent gave it; else under the
-- subagent that made it; else under the main agent when it names a tool. A
-- bare notice ("something needs you") stands alone and is taken back by
-- whatever is answered next.
local function key_of(ev)
  return ev.req or ev.agent or (ev.tool and '' or '*')
end

local function describe(ev)
  if type(ev.tool) == 'string' and ev.tool ~= '' then
    return 'permission to use ' .. ev.tool
  end
  return nil
end

-- How long after an interrupt a tool that was cut short may still report
-- its end without that counting as the turn going on.
local AFTERMATH = 3

---@param st table
---@param ev table              A decoded log line.
---@param signal string
---@param what string?          What a request is about.
local function fold(st, ev, signal, what)
  local t = ev.t
  if signal ~= 'ended' then
    st.ended = false
  end
  -- A subagent's model call or finished tool says nothing about the turn
  -- of the chat itself, except that this subagent is no longer waiting.
  if (signal == 'working' or signal == 'active') and ev.agent then
    signal = 'resolved'
  end

  -- `st.at` dates the turn itself (running, done, aborted): it moves only
  -- when the chat's own agent says something. Requests are dated on their
  -- own, so that one coming and going never makes an old state look new.
  if signal == 'working' then
    st.pending, st.base, st.at = {}, 'working', t
  elseif signal == 'active' then
    st.base, st.at = 'working', t
  elseif signal == 'resolved' then
    local key = key_of(ev)
    local had = st.pending[key] ~= nil
    st.pending[key] = nil
    if ev.agent then
      -- A bare notice is taken back with the request it was about. A
      -- subagent that had none open, finishing some tool, answers nothing.
      if had or not ev.tool then
        st.pending['*'] = nil
      end
    else
      st.pending['*'] = nil
      if st.base == 'aborted' and t - st.at <= AFTERMATH then
        -- The tool the interrupt cut short, reporting in.
        return
      end
      st.base, st.at = 'working', t
    end
  elseif signal == 'waiting' then
    st.pending[key_of(ev)] = { t = t, what = what or describe(ev) }
    if st.base == nil then
      st.at = t
    end
  elseif signal == 'done' or signal == 'aborted' then
    st.pending, st.base, st.at = {}, signal, t
  elseif signal == 'idle' then
    -- A report of the state the session is in, not of something that just
    -- happened: it ends a running turn, and leaves a finished one dated as
    -- it was.
    st.pending = {}
    if st.base == 'working' then
      st.base, st.at = 'done', t
    end
  elseif signal == 'start' then
    st.pending, st.base, st.at = {}, nil, t
  elseif signal == 'ended' then
    st.pending, st.base, st.at, st.ended = {}, nil, t, true
  end
end

--- The signal a provider's table gives an event, and what a request is about.
---@param events table<string, string|fun(ev: table): string?, string?>
---@return string? signal, string? what
local function classify(events, ev)
  local rule = events[ev.e]
  if type(rule) == 'function' then
    local ok, signal, what = pcall(rule, ev)
    if ok and type(signal) == 'string' then
      return signal, type(what) == 'string' and what or nil
    end
    return nil
  end
  return type(rule) == 'string' and rule or nil
end

---@param st table
---@param line string
---@param events table
local function take(st, line, events)
  local ev = fs.decode(line)
  if type(ev) ~= 'table' or type(ev.e) ~= 'string' or type(ev.t) ~= 'number' then
    return
  end
  st.count = st.count + 1
  st.last_t = ev.t
  if type(ev.pid) == 'number' then
    st.pid, st.pid_at = ev.pid, ev.t
  end
  if type(ev.path) == 'string' and ev.path ~= '' then
    st.path = ev.path
  end
  if type(ev.cwd) == 'string' and ev.cwd ~= '' then
    st.cwd = ev.cwd
  end
  local signal, what = classify(events, ev)
  if signal then
    fold(st, ev, signal, what)
  end
end

---@param st table
---@param mtime number
---@return agent_chats.Reported
local function report(st, mtime)
  local turn = st.base
  local at = st.at
  local waiting_for, since, latest
  for _, p in pairs(st.pending) do
    if not since or p.t < since then
      since, waiting_for = p.t, p.what
    end
    if not latest or p.t > latest then
      latest = p.t
    end
  end
  if since then
    -- Waiting is as old as its newest request: what else the chat did since
    -- says nothing about whether you have answered.
    turn, at = 'waiting', latest
  end
  -- A time in whole seconds was cut short by up to a second. When it is the
  -- log's last line, the file's own time says when it was really written.
  if at == st.last_t and at % 1 == 0 and mtime > at and mtime < at + 2 then
    at = mtime
  end
  return {
    turn = turn,
    at = at,
    waiting_for = waiting_for,
    pid = st.pid,
    pid_at = st.pid_at,
    ended = st.ended or nil,
    path = st.path,
    cwd = st.cwd,
    count = st.count,
  }
end

-----------------------------------------------------------------------------
-- Reading logs
-----------------------------------------------------------------------------

-- Per log path: how far it has been read and what that added up to.
local cache = {}

--- What the hooks of `agent` have reported about session `id`, or nil when
--- they have reported nothing.
---@param agent string
---@param events table<string, string|fun(ev: table): string?, string?>
---@param id string
---@return agent_chats.Reported?
function M.get(agent, events, id)
  local path = M.path(agent, id)
  if not path then
    return nil
  end
  local stat = fs.stat(path)
  if not stat or stat.type ~= 'file' then
    cache[path] = nil
    return nil
  end
  local st = cache[path]
  if not st or stat.size < st.offset or st.events ~= events then
    -- New, or replaced by a shorter file, or to be read by other rules.
    st = fresh()
    st.events = events
    cache[path] = st
  end
  if stat.size > st.offset then
    local data = fs.read_range(path, st.offset, stat.size - st.offset)
    if data then
      local consumed = fs.each_line(data, function(line)
        take(st, line, events)
      end)
      st.offset = st.offset + consumed
    end
  end
  if st.count == 0 then
    return nil
  end
  return report(st, stat.mtime)
end

--- Ids of the sessions of `agent` whose hooks wrote something since `since`.
---@param agent string
---@param since number  Epoch seconds.
---@return string[]
function M.recent(agent, since)
  local out = {}
  if not safe_id(agent) then
    return out
  end
  local dir = M.dir() .. '/' .. agent
  for _, e in ipairs(fs.scandir(dir)) do
    local id = e.type == 'file' and e.name:match('^([%w_%-]+)%.log$')
    if id then
      local stat = fs.stat(dir .. '/' .. e.name)
      if stat and stat.mtime >= since then
        out[#out + 1] = id
      end
    end
  end
  return out
end

--- How many sessions of `agent` have a log, and when the newest was written.
---@return integer count, number? newest
function M.summary(agent)
  local count, newest = 0, nil
  if not safe_id(agent) then
    return count, newest
  end
  local dir = M.dir() .. '/' .. agent
  for _, e in ipairs(fs.scandir(dir)) do
    if e.type == 'file' and e.name:match('%.log$') then
      local stat = fs.stat(dir .. '/' .. e.name)
      if stat then
        count = count + 1
        if not newest or stat.mtime > newest then
          newest = stat.mtime
        end
      end
    end
  end
  return count, newest
end

--- Delete every log of `agent` (its hooks were removed: what the logs say
--- would only go stale).
---@return integer removed
function M.clear(agent)
  local removed = 0
  if not safe_id(agent) then
    return removed
  end
  local dir = M.dir() .. '/' .. agent
  for _, e in ipairs(fs.scandir(dir)) do
    if e.type == 'file' and e.name:match('%.log$') then
      local path = dir .. '/' .. e.name
      if vim.uv.fs_unlink(path) then
        removed = removed + 1
      end
      cache[path] = nil
    end
  end
  return removed
end

--- Forget what has been read (tests).
function M.reset()
  cache = {}
end

-- For tests: fold a list of events without a file.
---@param events table
---@param list table[]
---@return agent_chats.Reported
function M._fold(events, list)
  local st = fresh()
  for _, ev in ipairs(list) do
    take(st, vim.json.encode(ev), events)
  end
  return report(st, 0)
end

return M
