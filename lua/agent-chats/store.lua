-- The chat index: every chat of every enabled agent, kept current.
--
-- A refresh asks each provider what is on disk and which processes are
-- running, re-parses only what changed, works out each chat's board status
-- and tells listeners what moved. Full refreshes rescan the folders for new
-- chats; the quick ones in between only re-stat chats that are running or
-- recently active. Everything runs time-sliced (util/async), so the editor
-- stays responsive however many chats there are.
--
-- What a chat is doing can be known three ways, and a provider supplies any
-- of them (see types.lua):
--
--   hooks    events the agent pushes through its own hook system
--   query    an official interface that can be asked (a CLI, an API)
--   live     files and processes, plus the transcript itself
--
-- The first two are first-hand: the agent saying what it is doing. When
-- several speak, the most recent one is believed. Hooks say nothing when a
-- turn is interrupted, so a transcript that has moved on since their last
-- word corrects them. With no first-hand report the transcript decides.

local uv = vim.uv
local async = require('agent-chats.util.async')
local config = require('agent-chats.config')
local events = require('agent-chats.events')
local fs = require('agent-chats.util.fs')
local proc = require('agent-chats.util.proc')
local providers = require('agent-chats.providers')
local state = require('agent-chats.state')
local status = require('agent-chats.status')

local M = {}

---@type table<string, agent_chats.Chat>
M.chats = {}
M.initialized = false
-- Chats left unread from disk because they are older than board.max_age_days.
M.older = 0
-- Ignore board.max_age_days (the board's "show all").
M.show_all = false

local by_provider = {} ---@type table<string, table<string, agent_chats.Chat>>
local unparsed = {} ---@type table<string, { mtime: number, size: integer, old: boolean? }>
local older_by = {} ---@type table<string, integer>
local pathless = {} ---@type table<string, boolean>
local subagents = {} ---@type table<string, agent_chats.Chat[]>
local children = {} ---@type table<string, agent_chats.Chat[]>
local prev_status = {} ---@type table<string, string>
local listeners = {} ---@type (fun(event: table))[]
local reported = {} ---@type table<string, boolean>
-- Chat key -> the process its hook named, once that process was seen alive.
local seen_alive = {} ---@type table<string, integer>

local started_at = os.time()
-- Chat key -> when its turn last ended, as of the last status pass.
local ended_at = {} ---@type table<string, number>
-- The shared state as of the last refresh (see `state.foreign_changes`).
local seen_foreign = 0
local running, waiters, queued = false, {}, nil
local timer
local last_full = 0
local fast = false
local cache_loaded, cache_dirty = false, false

-- Fields that describe the running process, not the transcript: they are
-- carried across re-parses and never written to the cache.
local RUNTIME = {
  'live',
  'pid',
  'turn_live',
  'exact',
  'source',
  'answered',
  'done_at',
  'said_at',
  'waiting_for',
  'name',
  'name_explicit',
  'kind',
  'term',
  'status',
  'inferred',
  'through',
  'misses',
}

local function report(where, err)
  local msg = ('agent-chats: %s: %s'):format(where, tostring(err))
  if reported[msg] then
    return
  end
  reported[msg] = true
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.WARN)
  end)
end

local counts_cache

local function emit(event)
  counts_cache = nil
  for _, fn in ipairs(listeners) do
    local ok, err = pcall(fn, event)
    if not ok then
      report('listener', err)
    end
  end
end

--- Subscribe to index events:
---   { type = 'update' }                              something changed
---   { type = 'transition', chat, from, to, fresh }   a chat changed status
---@param fn fun(event: table)
---@return fun() unsubscribe
function M.on(fn)
  listeners[#listeners + 1] = fn
  return function()
    for i, f in ipairs(listeners) do
      if f == fn then
        table.remove(listeners, i)
        break
      end
    end
  end
end

-----------------------------------------------------------------------------
-- Cache of parsed chats, so the board is populated the moment it opens
-----------------------------------------------------------------------------

local CACHE_VERSION = 1

local function cache_path()
  local opt = config.get().cache_file
  if opt == false then
    return nil
  end
  return opt or (vim.fn.stdpath('cache') .. '/agent-chats/index.json')
end

local function load_cache()
  cache_loaded = true
  local path = cache_path()
  local raw = path and fs.read_json(path)
  if type(raw) ~= 'table' or raw.version ~= CACHE_VERSION or type(raw.chats) ~= 'table' then
    return
  end
  for key, chat in pairs(raw.chats) do
    if
      type(chat) == 'table'
      and chat.key == key
      and type(chat.provider) == 'string'
      and type(chat.id) == 'string'
      and not M.chats[key]
    then
      chat.turn_file = chat.turn_file or 'unknown'
      chat.turn = chat.turn_file
      -- Until the first refresh settles it.
      chat.status = 'ended'
      M.chats[key] = chat
      by_provider[chat.provider] = by_provider[chat.provider] or {}
      by_provider[chat.provider][chat.id] = chat
    end
  end
end

local function save_cache()
  local path = cache_path()
  if not path or not cache_dirty then
    return
  end
  cache_dirty = false
  local out = {}
  for key, chat in pairs(M.chats) do
    if not chat.stub and not chat.subagent then
      local copy = {}
      for k, v in pairs(chat) do
        copy[k] = v
      end
      for _, f in ipairs(RUNTIME) do
        copy[f] = nil
      end
      copy.turn = nil
      out[key] = copy
    end
  end
  local ok, json = pcall(vim.json.encode, { version = CACHE_VERSION, chats = out })
  if ok then
    fs.write_atomic(path, json)
  end
end

-----------------------------------------------------------------------------
-- One provider
-----------------------------------------------------------------------------

local function drop(chat)
  M.chats[chat.key] = nil
  subagents[chat.key] = nil
  prev_status[chat.key] = nil
  ended_at[chat.key] = nil
  seen_alive[chat.key] = nil
  local mine = by_provider[chat.provider]
  if mine then
    mine[chat.id] = nil
  end
  cache_dirty = true
end

---@return agent_chats.Chat?
local function apply_entry(p, entry, prev)
  local key = p.name .. ':' .. entry.id
  local ok, parsed = pcall(p.parse, entry, (prev and not prev.stub) and prev or nil)
  if not ok then
    report(p.name .. ' parse', parsed)
    parsed = nil
  end
  if type(parsed) ~= 'table' then
    unparsed[key] = { mtime = entry.mtime, size = entry.size, rev = entry.rev }
    return nil
  end
  unparsed[key] = nil
  local chat = parsed
  chat.key, chat.provider, chat.id = key, p.name, entry.id
  chat.path, chat.mtime, chat.size, chat.data = entry.path, entry.mtime, entry.size, entry.data
  chat.rev = entry.rev
  chat.turn_file = parsed.turn or 'unknown'
  chat.updated = chat.updated or entry.mtime
  chat.created = chat.created or chat.updated
  if chat.parent_id then
    chat.parent = p.name .. ':' .. chat.parent_id
  end
  if prev then
    for _, f in ipairs(RUNTIME) do
      chat[f] = prev[f]
    end
    chat.subs_at = prev.subs_at
  end
  chat.status = chat.status or 'ended'
  by_provider[p.name][entry.id] = chat
  M.chats[key] = chat
  cache_dirty = true
  return chat
end

-- A turn the hooks call running has, within this long, left something in
-- the transcript (its prompt at the least).
local STRAY_SECS = 20
-- A prompt is written within moments of the hook that announces it.
local STALE_SECS = 5

--- The most recent thing the agent itself said about the chat's turn: from
--- its files (`info`, a registry), from being asked (`asked`), or through
--- its hooks (`reported`). nil when it said nothing that still holds.
---@param chat agent_chats.Chat
---@param info agent_chats.Live?
---@param asked agent_chats.Live?
---@param reported agent_chats.Reported?
---@return { turn: agent_chats.Turn, at: number, source: string, waiting_for: string? }?
local function first_hand(chat, info, asked, reported, now)
  local best
  local function claim(turn, at, source, waiting_for)
    if turn and (not best or at > best.at) then
      best = { turn = turn, at = at, source = source, waiting_for = waiting_for }
    end
  end
  if info then
    claim(info.turn, info.turn_at or now, 'registry', info.waiting_for)
  end
  if asked then
    claim(asked.turn, asked.turn_at or now, 'query', asked.waiting_for)
  end
  if reported then
    claim(reported.turn, reported.at, 'hooks', reported.waiting_for)
  end
  if not best then
    return nil
  end
  if best.source == 'hooks' then
    -- Hooks are silent when a turn is interrupted or a request is refused,
    -- so what they last said can outlive its truth. The transcript records
    -- both: when it shows the turn over after the hooks last spoke, it is
    -- right. So it is when it shows work after they called the turn over
    -- (a turn they did not see start). Work written during a turn they
    -- call running, or while a request is open, is no news: the first is
    -- what running means, the second can be another part of the chat.
    local file = chat.turn_file
    local at = math.max(chat.turn_at or 0, file == 'working' and chat.updated or 0)
    if file and file ~= 'unknown' then
      local file_over = file == 'done' or file == 'aborted'
      local hooks_over = best.turn == 'done' or best.turn == 'aborted'
      if at > best.at then
        if file_over or hooks_over then
          return nil
        end
      elseif
        best.turn == 'working'
        and file_over
        and now - best.at > STRAY_SECS
        and (chat.updated or 0) <= best.at
      then
        -- "Running", say the hooks, yet the transcript shows the turn over
        -- and nothing written since: a real turn would have left a trace
        -- by now. A stray event (a tool reporting in late, a model call
        -- made behind the scenes), not a turn.
        return nil
      end
      -- The turn the transcript shows began well after the hooks last
      -- spoke: they stopped reporting some turn ago, and what they said
      -- then is about that one.
      if file == 'working' and not hooks_over and (chat.turn_began or 0) > best.at + STALE_SECS then
        return nil
      end
    end
  elseif best.turn == 'waiting' and not best.waiting_for then
    best.waiting_for = reported and reported.turn == 'waiting' and reported.waiting_for or nil
  end
  return best
end

--- Fold what is known about the running process into the chat.
---@param chat agent_chats.Chat
---@param info agent_chats.Live?         From files and processes.
---@param asked agent_chats.Live?        From the agent's query interface.
---@param reported agent_chats.Reported? From the agent's hooks.
---@param known boolean                  Whether anything could tell if it is running.
---@return boolean changed
local function apply_live(chat, info, asked, reported, known, now)
  local function signature()
    -- `said_at` too: a turn that started and ended between two looks
    -- leaves everything else as it was, and is still news.
    return ('%s|%s|%s|%s|%s|%s|%s|%s'):format(
      tostring(chat.live),
      tostring(chat.pid),
      tostring(chat.turn_live),
      tostring(chat.waiting_for),
      tostring(chat.name),
      tostring(chat.source),
      tostring(chat.answered),
      tostring(chat.said_at)
    )
  end
  local before = signature()
  local process = info or asked
  local missed = false
  if not known then
    chat.live, chat.pid, chat.kind = nil, nil, nil
  elseif process then
    chat.live, chat.misses = true, 0
    chat.pid = process.pid or (asked and asked.pid) or nil
    chat.name = process.name or (asked and asked.name) or nil
    chat.name_explicit = process.name_explicit or (asked and asked.name_explicit) or nil
    chat.kind = process.kind or (asked and asked.kind) or nil
    chat.cwd = chat.cwd or process.cwd or (asked and asked.cwd) or nil
  elseif chat.live and (chat.misses or 0) < 1 then
    -- One missed look (a registry file caught mid-rewrite) is not an exit.
    chat.misses = (chat.misses or 0) + 1
    missed = true
  else
    chat.live, chat.pid, chat.kind = false, nil, nil
  end

  local said
  local answered
  if missed then
    -- Keep what was known for this one round.
    if chat.exact then
      said = { turn = chat.turn_live, source = chat.source, waiting_for = chat.waiting_for }
      answered = chat.answered
    end
  elseif chat.live ~= false and (process or reported) then
    said = first_hand(chat, info, asked, reported, now)
  end
  -- Hooks report a request, not its answer: a tool you approved runs on in
  -- silence. Where the chat's terminal is in this Neovim the answer can be
  -- seen being typed, and the request is taken as settled from then on.
  if said and said.source == 'hooks' and said.turn == 'waiting' and said.at and chat.term then
    local term = package.loaded['agent-chats.term']
    local typed = term and term.typed_at(chat.term)
    if typed and typed > said.at then
      said = { turn = 'working', at = typed, source = 'hooks' }
      answered = true
    end
  end
  chat.answered = answered
  -- A hook says when a turn ended, often before the transcript is written:
  -- that is the moment it became yours to read. (A registry's "idle since"
  -- is not: it also moves when you run a command of the agent's own.)
  if said and said.source == 'hooks' and said.turn == 'done' and said.at then
    chat.done_at = said.at
  elseif not missed then
    chat.done_at = nil
  end
  if not missed then
    -- When the agent itself last spoke of its turn, where it said when. (A
    -- report with no time of its own counts as made now, and so says
    -- nothing about when the turn changed.)
    local stamped
    if said and said.source == 'hooks' then
      stamped = said.at
    elseif said and said.source == 'registry' then
      stamped = info and info.turn_at
    elseif said and said.source == 'query' then
      stamped = asked and asked.turn_at
    end
    chat.said_at = stamped or nil
  end
  chat.turn_live = said and said.turn or nil
  chat.exact = said ~= nil
  chat.source = said and said.source or 'transcript'
  chat.waiting_for = said and said.waiting_for or nil
  chat.turn = chat.turn_live or chat.turn_file or 'unknown'
  -- "Not busy any more" is all an agent says when a turn stops; the
  -- transcript knows whether it finished or was interrupted.
  if
    chat.turn == 'done'
    and chat.turn_file == 'aborted'
    and said
    and said.at
    and (chat.turn_at or 0) >= said.at - 5
  then
    chat.turn = 'aborted'
  end
  return before ~= signature()
end

-- File times read back from the JSON cache lose a little precision. `rev`
-- stands for whatever a provider keeps about the chat outside its transcript.
local function same(chat, entry)
  local a, b = chat.mtime or 0, entry.mtime
  -- A provider may give its times in whole seconds while the quick look
  -- reads the file's own, with fractions: the same second is the same.
  if a % 1 == 0 or b % 1 == 0 then
    a, b = math.floor(a), math.floor(b)
  end
  return chat.size == entry.size and math.abs(a - b) < 0.002 and chat.rev == entry.rev
end

local function hot(chat, now)
  return chat.live
    or chat.status == 'attention'
    or chat.status == 'working'
    or now - (chat.updated or 0) < 900
end

local function refresh_subagents(p, chat, now)
  local stamp = chat.mtime
  local wanted = chat.live or subagents[chat.key] ~= nil or now - (chat.updated or 0) < 86400
  if not wanted or (chat.subs_at == stamp and not chat.live) then
    return false
  end
  chat.subs_at = stamp
  local ok, subs = pcall(p.subagents, chat)
  if not ok then
    report(p.name .. ' subagents', subs)
    return false
  end
  local function signature(list)
    local parts = {}
    for _, sub in ipairs(list or {}) do
      parts[#parts + 1] = sub.key .. '=' .. tostring(sub.status)
    end
    return table.concat(parts, ',')
  end
  local before = signature(subagents[chat.key])
  for _, sub in ipairs(subs) do
    sub.status = (sub.turn == 'working' and sub.live) and 'working' or 'ended'
  end
  subagents[chat.key] = #subs > 0 and subs or nil
  return before ~= signature(subs)
end

-- Sessions whose hooks wrote something lately, per provider: they are looked
-- at on every refresh, whatever else is known about them.
local reporting = {} ---@type table<string, table<string, boolean>>
-- Chat id -> the id its hook log goes by, where the two differ.
local aliases = {} ---@type table<string, table<string, string>>
-- The last answer of each provider's query interface.
local answers = {} ---@type table<string, { at: number, result: table? }>

--- The rules a provider's hook events are read by. nil when it has no hooks
--- or they are switched off.
local function hook_rules(p)
  local rules = type(p.hooks) == 'table' and p.hooks.events or nil
  if type(rules) ~= 'table' or config.get().hooks.enabled == false then
    return nil
  end
  return rules
end

--- A log under an id no chat has: the agent may name its sessions one way
--- and its transcripts another. The transcript the log names settles it.
local function adopt_strays(p, rules, mine)
  local name = p.name
  local alias = aliases[name] or {}
  aliases[name] = alias
  local by_path
  for id in pairs(reporting[name] or {}) do
    if not mine[id] then
      local r = events.get(name, rules, id)
      if r and r.path then
        if not by_path then
          by_path = {}
          for cid, chat in pairs(mine) do
            if chat.path then
              by_path[chat.path] = cid
            end
          end
        end
        local cid = by_path[r.path]
        if cid then
          alias[cid] = id
        end
      end
    end
  end
end

--- Ask the provider's query interface, no more often than it wants.
---@return table<string, agent_chats.Live>?
local function ask(p, mine)
  if type(p.query) ~= 'function' then
    return nil
  end
  local hit = answers[p.name]
  if hit and uv.now() - hit.at < (p.query_interval or 10000) then
    return hit.result
  end
  -- Marked first: the call may take a while, and a failure is not retried
  -- any sooner than an answer would be.
  hit = { at = uv.now(), result = hit and hit.result or nil }
  answers[p.name] = hit
  local ok, res = pcall(p.query, mine)
  if not ok then
    report(p.name .. ' query', res)
    res = nil
  end
  hit.at, hit.result = uv.now(), type(res) == 'table' and res or nil
  return hit.result
end

--- Whether `pid`, which a hook named at `at`, is still that agent's process.
local function still_running(p, pid, at)
  if not proc.alive(pid) then
    return false
  end
  local born = proc.start_time(pid)
  if born and at and born > at + 2 then
    -- Younger than the event that named it: the number went to another process.
    return false
  end
  local names = type(p.hooks) == 'table' and p.hooks.process or nil
  return proc.is(pid, names or { [p.name] = true })
end

---@return boolean changed
local function refresh_provider(p, full, now, cutoff)
  local name = p.name
  local mine = by_provider[name] or {}
  by_provider[name] = mine
  local changed = false

  if not p.available() then
    for _, chat in pairs(mine) do
      drop(chat)
      changed = true
    end
    older_by[name] = 0
    return changed
  end

  local first_load = next(mine) == nil

  -- The three sources, most direct first.
  local rules = hook_rules(p)
  if rules and (full or not reporting[name]) then
    -- A day back: a request can sit unanswered overnight, and its chat must
    -- still be looked at when this Neovim starts in the morning.
    local ids = {}
    for _, id in ipairs(events.recent(name, now - 86400)) do
      ids[id] = true
    end
    reporting[name] = ids
  end
  local alias = aliases[name] or {}
  local heard = {} ---@type table<string, agent_chats.Reported|false>
  --- What the hooks have reported about a chat (read once per refresh).
  ---@return agent_chats.Reported?
  local function reported(id)
    if not rules then
      return nil
    end
    local r = heard[id]
    if r == nil then
      r = events.get(name, rules, alias[id] or id) or false
      heard[id] = r
    end
    return r or nil
  end
  -- For the chats already known, ahead of looking at processes: a hook
  -- names the process its session runs under.
  local hints = {}
  if rules then
    for id, chat in pairs(mine) do
      if not chat.subagent and (reporting[name][id] or alias[id] or hot(chat, now)) then
        hints[id] = reported(id)
      end
    end
  end
  local asked = ask(p, mine)
  ---@type table<string, agent_chats.Live>?
  local live
  if p.live then
    local ok, res = pcall(p.live, mine, hints)
    if ok then
      live = res
    else
      report(name .. ' live', res)
    end
  end
  -- Every session known to be running, whoever said so.
  ---@type table<string, agent_chats.Live>?
  local running
  if live or asked then
    running = {}
    for id, info in pairs(asked or {}) do
      running[id] = info
    end
    for id, info in pairs(live or {}) do
      running[id] = info
    end
  end

  if full or pathless[name] then
    local entries = p.discover()
    local present, older = {}, 0
    for _, e in ipairs(entries) do
      present[e.id] = true
      if not e.path then
        pathless[name] = true
      end
      if p.rev then
        e.rev = p.rev(e.id)
      end
      local key = name .. ':' .. e.id
      local chat = mine[e.id]
      local skip = unparsed[key]
      local old = cutoff ~= nil
        and e.mtime < cutoff
        and not (running and running[e.id])
        and not state.pinned(key)
      if old then
        -- Past board.max_age_days: not read, and no longer listed if it was.
        if chat and not chat.stub then
          drop(chat)
          changed = true
        end
        unparsed[key] = { mtime = e.mtime, size = e.size, rev = e.rev, old = true }
        older = older + 1
      elseif chat and not chat.stub and same(chat, e) then
        -- Unchanged since it was parsed.
      elseif skip and same(skip, e) and not skip.old then
        -- Known to hold no conversation.
      elseif apply_entry(p, e, chat) then
        changed = true
      elseif chat then
        drop(chat)
        changed = true
      end
      async.tick()
    end
    for _, chat in pairs(mine) do
      if not present[chat.id] and not chat.stub then
        drop(chat)
        changed = true
      end
    end
    older_by[name] = older
  else
    for id, chat in pairs(mine) do
      if chat.path and not chat.stub and ((running and running[id]) or hot(chat, now)) then
        local st = fs.stat(chat.path)
        if not st then
          drop(chat)
          changed = true
        else
          local entry = {
            id = id,
            path = chat.path,
            mtime = st.mtime,
            size = st.size,
            data = chat.data,
            rev = p.rev and p.rev(id) or nil,
          }
          if not same(chat, entry) and apply_entry(p, entry, chat) then
            changed = true
          end
        end
      end
    end
  end

  if rules and full then
    adopt_strays(p, rules, mine)
    alias = aliases[name] or alias
  end

  -- The very first look at processes had no chats to match them to (an
  -- agent without a registry is matched by folder, by time, by which chat
  -- started which). Now that they are read, look once more.
  if first_load and p.live and next(mine) ~= nil then
    if rules then
      for id, chat in pairs(mine) do
        if not chat.subagent and (reporting[name][id] or alias[id] or hot(chat, now)) then
          hints[id] = reported(id)
        end
      end
    end
    local ok, res = pcall(p.live, mine, hints)
    if ok and res then
      live = res
      running = running or {}
      for id, info in pairs(res) do
        running[id] = info
      end
    elseif not ok then
      report(name .. ' live', res)
    end
  end

  -- Sessions that are running but not in the index yet: one whose
  -- transcript we have not seen, or one that has not been sent a prompt.
  for id, info in pairs(running or {}) do
    local chat = mine[id]
    if not chat or chat.stub then
      local entry = p.locate and p.locate(id, info) or nil
      if entry and p.rev then
        entry.rev = p.rev(id)
      end
      local made = entry and apply_entry(p, entry, chat) or nil
      if made then
        changed = true
      elseif not chat then
        local at = info.started or now
        mine[id] = {
          key = name .. ':' .. id,
          provider = name,
          id = id,
          stub = true,
          cwd = info.cwd,
          created = at,
          updated = at,
          mtime = 0,
          size = 0,
          turn_file = 'unknown',
          status = 'idle',
        }
        M.chats[mine[id].key] = mine[id]
        changed = true
      end
    end
  end

  -- A process that files and queries have assigned to a session is not
  -- some other session's, whatever an old hook event says.
  local taken = {}
  for _, info in pairs(running or {}) do
    if info.pid then
      taken[info.pid] = true
    end
  end

  for _, chat in pairs(mine) do
    local id = chat.id
    local info = live and live[id] or nil
    local answer = asked and asked[id] or nil
    local said
    if
      rules
      and not chat.subagent
      and (reporting[name][id] or alias[id] or info or answer or hot(chat, now))
    then
      said = reported(id)
    end
    local known = running ~= nil
    if not info and not answer and said then
      if said.ended then
        -- It said it closed, and nothing has it open.
        known = true
      elseif said.pid and not taken[said.pid] then
        if still_running(p, said.pid, said.pid_at) then
          -- Nothing else lists this session, but the process its hook ran
          -- under is still there.
          info, known = { pid = said.pid, cwd = said.cwd }, true
          seen_alive[chat.key] = said.pid
        elseif seen_alive[chat.key] == said.pid then
          -- It was there, and now it is gone: so is the session. (A pid
          -- never seen alive proves nothing; it may have been a shell the
          -- hook ran under.)
          known = true
        end
      end
    end
    if apply_live(chat, info, answer, said, known, now) then
      changed = true
    end
    if chat.stub and not chat.live then
      drop(chat)
      changed = true
    elseif p.subagents and not chat.stub and refresh_subagents(p, chat, now) then
      changed = true
    end
  end
  return changed
end

--- Terminals of this Neovim whose agent has started no session yet: a new
--- chat that has not been sent a prompt, for an agent that writes nothing
--- until then. Each gets a row all the same. Without one, going back to
--- the list would leave a running terminal that nothing leads to.
---@return boolean changed
local function list_unstarted(term)
  local want = {}
  for buf, t in pairs(term.terms) do
    if t.owned and t.unstarted and t.provider and vim.api.nvim_buf_is_valid(buf) then
      want[t.key] = buf
    end
  end
  local changed = false
  for _, chat in pairs(M.chats) do
    if chat.unstarted then
      local buf = want[chat.key]
      if not buf then
        -- Its session has shown up (the terminal is that chat's now), or
        -- the terminal is gone.
        drop(chat)
        changed = true
      elseif chat.term ~= buf then
        chat.term, changed = buf, true
      end
    end
  end
  for key, buf in pairs(want) do
    if not M.chats[key] then
      local t = term.terms[buf]
      M.chats[key] = {
        key = key,
        provider = t.provider,
        id = key:match(':(.*)$'),
        stub = true,
        unstarted = true,
        cwd = t.cwd,
        created = t.started,
        updated = t.started,
        mtime = 0,
        size = 0,
        turn = 'unknown',
        turn_file = 'unknown',
        live = true,
        term = buf,
        source = 'transcript',
        status = 'idle',
      }
      changed = true
    end
  end
  return changed
end

-----------------------------------------------------------------------------
-- A whole refresh
-----------------------------------------------------------------------------

local function reindex_children()
  children = {}
  for _, chat in pairs(M.chats) do
    if chat.parent and M.chats[chat.parent] then
      local list = children[chat.parent] or {}
      list[#list + 1] = chat
      children[chat.parent] = list
    end
  end
  for _, list in pairs(children) do
    table.sort(list, function(a, b)
      return (a.created or 0) < (b.created or 0)
    end)
  end
end

-- Statuses a read mark can move a chat between. Anything else is news from
-- the agent.
local MARKED = { done = true, idle = true, ended = true }

--- Recompute every chat's board status. Returns the transitions.
---
--- `quiet`: the user changed a read mark or a pin; nothing happened to any
--- chat. Only what a read mark can cause is applied then. A refresh may be
--- half done at that moment, with a chat's new turn already read: that
--- change is left for the refresh to find and announce.
local function restatus(now, quiet)
  local cfg = config.get().status
  local term = package.loaded['agent-chats.term']
  local transitions, changed = {}, false
  local decided = {} ---@type table<string, { [1]: agent_chats.Status, [2]: boolean, [3]: string? }>
  for key, chat in pairs(M.chats) do
    local st, inferred = status.derive(chat, state.seen(key), now, cfg)
    -- Finishing while you are looking at its terminal is not "unread".
    if st == 'done' and term and chat.term and term.is_focused(chat.term) then
      state.mark_seen(key)
      st = chat.live and 'idle' or 'ended'
    end
    if quiet and chat.status ~= st and not (MARKED[st] and MARKED[chat.status or 'ended']) then
      st, inferred = chat.status, chat.inferred or false
    end
    decided[key] = { st, inferred }
  end
  -- A chat started by another is listed under it, out of sight until
  -- unfolded: when it is the one waiting for you, every chat above it says
  -- so. In a fixed order, so that two waiting at once always name the same.
  local waiting = {}
  for key, chat in pairs(M.chats) do
    if chat.parent and decided[key][1] == 'attention' then
      waiting[#waiting + 1] = key
    end
  end
  table.sort(waiting)
  for _, key in ipairs(waiting) do
    local up, hops = M.chats[key].parent, 0
    while up and decided[up] and hops < 16 do
      if decided[up][1] ~= 'attention' then
        decided[up] = { 'attention', decided[key][2], key }
      end
      up, hops = M.chats[up] and M.chats[up].parent or nil, hops + 1
    end
  end
  for key, chat in pairs(M.chats) do
    local st, inferred, through = unpack(decided[key], 1, 3)
    if chat.status ~= st or (chat.inferred or false) ~= inferred or chat.through ~= through then
      changed = true
    end
    chat.status, chat.inferred, chat.through = st, inferred or nil, through
    local before = prev_status[key]
    -- When its turn last ended, as far as is known now, and as of the last
    -- time this was worked out.
    local ended = math.max(chat.turn_at or chat.updated or 0, chat.done_at or 0)
    local known = ended_at[key]
    ended_at[key] = ended
    if before ~= st then
      prev_status[key] = st
      if M.initialized then
        -- Something that happened while we were watching, as opposed to an
        -- old chat coming into view.
        local fresh = not quiet and (ended >= started_at - 2 or before ~= nil)
        if st == 'done' then
          -- "Done, unread" is news when a turn has ended that had not
          -- before, whoever notices it (a key pressed while a refresh is
          -- half-way included). Marking a chat unread ends no turn.
          if known == nil then
            fresh = not quiet and ended >= started_at - 2
          else
            fresh = ended > known
          end
        end
        transitions[#transitions + 1] = {
          type = 'transition',
          chat = chat,
          from = before,
          to = st,
          fresh = fresh,
        }
      end
    end
  end
  return transitions, changed
end

local function do_refresh(full)
  local cfg = config.get()
  local now = os.time()
  proc.share(true)
  if not cache_loaded then
    load_cache()
  end
  full = full or not M.initialized
  local cutoff
  if not M.show_all and (cfg.board.max_age_days or 0) > 0 then
    cutoff = now - cfg.board.max_age_days * 86400
  end

  local changed = false
  -- Read marks, pins, labels and names are shared with other Neovims. A
  -- change made there is nothing that happened to a chat: it is taken in
  -- without announcing anything, and the rows are drawn again.
  local shared = {}
  local foreign = state.foreign_changes()
  if foreign ~= seen_foreign then
    if M.initialized then
      shared = restatus(now, true)
      changed = true
    end
    seen_foreign = foreign
  end
  local enabled = {}
  for _, p in ipairs(providers.enabled()) do
    enabled[p.name] = true
    local ok, res = pcall(refresh_provider, p, full, now, cutoff)
    if ok then
      changed = changed or res
    else
      report(p.name, res)
    end
    async.tick()
  end
  for name, mine in pairs(by_provider) do
    if not enabled[name] then
      for _, chat in pairs(mine) do
        drop(chat)
        changed = true
      end
      older_by[name] = nil
    end
  end

  M.older = 0
  for _, n in pairs(older_by) do
    M.older = M.older + n
  end
  reindex_children()

  -- Which terminal of this Neovim hosts which chat.
  local ok_term, term = pcall(require, 'agent-chats.term')
  if ok_term then
    if term.attach(M.chats) then
      changed = true
    end
    -- After the look above: a terminal that got its chat just now is done
    -- with its stand-in.
    if list_unstarted(term) then
      changed = true
    end
  end
  proc.share(false)

  local transitions, status_changed = restatus(os.time())
  changed = changed or status_changed
  local first = not M.initialized
  M.initialized = true
  if full then
    last_full = uv.now()
    save_cache()
  end
  if changed or first or #transitions > 0 then
    emit({ type = 'update' })
    pcall(vim.api.nvim_exec_autocmds, 'User', { pattern = 'AgentChatsUpdate', modeline = false })
  end
  for _, tr in ipairs(shared) do
    emit(tr)
  end
  for _, tr in ipairs(transitions) do
    emit(tr)
  end
end

--- Refresh in the background. `opts.full` rescans for new chats.
---@param opts { full: boolean? }?
---@param cb fun()?
function M.refresh(opts, cb)
  local full = opts and opts.full or false
  if cb then
    waiters[#waiters + 1] = cb
  end
  if running then
    queued = queued or full
    return
  end
  running = true
  async.run(function()
    do_refresh(full)
  end, function(ok, err)
    running = false
    if not ok then
      report('refresh', err)
    end
    local done = waiters
    waiters = {}
    for _, fn in ipairs(done) do
      pcall(fn)
    end
    if queued ~= nil then
      local again = queued
      queued = nil
      M.refresh({ full = again })
    end
  end)
end

--- Call `cb` once the index has been loaded for the first time: now, when
--- it has been. (Anything that goes through every chat must not start on
--- half of them.)
---@param cb fun()
function M.when_ready(cb)
  if M.initialized then
    return cb()
  end
  if running then
    waiters[#waiters + 1] = cb
  else
    M.refresh({ full = true }, cb)
  end
end

--- Refresh now and return when it is done (tests, and first use).
---@param opts { full: boolean? }?
function M.refresh_sync(opts)
  if running then
    vim.wait(5000, function()
      return not running
    end, 5)
  end
  do_refresh(not opts or opts.full ~= false)
end

--- The agent that ran `key` in a terminal of this Neovim has exited: the
--- chat is over now, not at the next look. (Until then it would read as
--- "running, but not here".)
function M.exited(key)
  local chat = M.chats[key]
  if not chat then
    return
  end
  chat.live, chat.pid, chat.term, chat.kind = false, nil, nil, nil
  chat.turn_live, chat.exact, chat.waiting_for, chat.answered = nil, false, nil, nil
  chat.said_at = nil
  chat.source = 'transcript'
  chat.turn = chat.turn_file or 'unknown'
  seen_alive[key] = nil
  if chat.stub then
    drop(chat)
  end
  if M.initialized then
    local transitions = restatus(os.time())
    emit({ type = 'update' })
    for _, tr in ipairs(transitions) do
      emit(tr)
    end
  end
end

--- Recompute statuses after a change to the saved state (read marks, ...).
function M.touch()
  if not M.initialized then
    return
  end
  -- The user changed a read mark or a pin: nothing happened to the chat.
  local transitions = restatus(os.time(), true)
  emit({ type = 'update' })
  for _, tr in ipairs(transitions) do
    emit(tr)
  end
end

-----------------------------------------------------------------------------
-- Watching
-----------------------------------------------------------------------------

--- How long after the last look for new chats the next one is due (ms).
--- A chat was just started here and its session has not shown up yet: it
--- is looked for every few seconds, not at the usual leisurely pace, or
--- its row would say "(no prompt yet)" for up to half a minute.
---@return number
function M._scan_due()
  local cfg = config.get().watch
  for _, chat in pairs(M.chats) do
    if chat.unstarted then
      return math.min(cfg.scan_interval, 3000)
    end
  end
  return cfg.scan_interval
end

local function arm()
  if not timer then
    return
  end
  local cfg = config.get().watch
  timer:start(
    fast and cfg.interval or cfg.background_interval,
    0,
    vim.schedule_wrap(function()
      if not timer then
        return
      end
      M.refresh({ full = uv.now() - last_full >= M._scan_due() }, arm)
    end)
  )
end

--- Start refreshing on a timer.
function M.start()
  if timer then
    return
  end
  timer = uv.new_timer()
  M.refresh({ full = true }, arm)
end

function M.stop()
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    timer = nil
  end
end

function M.is_watching()
  return timer ~= nil
end

--- Check more often (while the board is on screen).
function M.set_fast(value)
  if fast == value then
    return
  end
  fast = value
  if timer and not running then
    arm()
  end
end

--- Include chats older than board.max_age_days.
function M.set_show_all(value)
  if M.show_all ~= value then
    M.show_all = value
    M.refresh({ full = true })
  end
end

-----------------------------------------------------------------------------
-- Reading the index
-----------------------------------------------------------------------------

---@return agent_chats.Chat?
function M.get(key)
  if M.chats[key] then
    return M.chats[key]
  end
  -- A subagent listed under its parent.
  local parent = key:match('^(.-)/[^/]+$')
  for _, sub in ipairs(parent and subagents[parent] or {}) do
    if sub.key == key then
      return sub
    end
  end
end

--- Chats spawned by `key`: subagents and child sessions, oldest first.
---@return agent_chats.Chat[]
function M.children(key)
  local out = {}
  vim.list_extend(out, subagents[key] or {})
  vim.list_extend(out, children[key] or {})
  return out
end

--- Load a chat's subagents now (the board asks when a row is unfolded).
function M.load_children(chat)
  local p = providers.get(chat.provider)
  if p and p.subagents and not chat.stub and not subagents[chat.key] then
    local ok, subs = pcall(p.subagents, chat)
    if ok and #subs > 0 then
      for _, sub in ipairs(subs) do
        sub.status = (sub.turn == 'working' and sub.live) and 'working' or 'ended'
      end
      subagents[chat.key] = subs
    end
  end
  return M.children(chat.key)
end

--- Top-level chats. Archived ones only with `opts.archived`.
---@param opts { archived: boolean? }?
---@return agent_chats.Chat[]
function M.list(opts)
  local out = {}
  for key, chat in pairs(M.chats) do
    local nested = chat.parent and M.chats[chat.parent] ~= nil
    -- A session that never held a conversation (it only ran a command such
    -- as a login) is noise unless it is open right now.
    local empty = not chat.live
      and not chat.first_prompt
      and not chat.last_prompt
      and not chat.last_reply
      and not chat.title
    if not nested and not empty then
      if (opts and opts.archived) or not state.is_archived(key, chat.updated) then
        out[#out + 1] = chat
      end
    end
  end
  return out
end

--- How many chats are in each status (archived ones left out).
---@return table<agent_chats.Status, integer>
function M.counts()
  if counts_cache then
    return counts_cache
  end
  local c = { attention = 0, working = 0, done = 0, idle = 0, ended = 0 }
  for _, chat in ipairs(M.list()) do
    local st = chat.status or 'ended'
    c[st] = (c[st] or 0) + 1
  end
  if M.initialized then
    counts_cache = c
  end
  return c
end

--- Forget everything (tests).
function M.reset()
  M.stop()
  M.chats, M.initialized, M.older, M.show_all = {}, false, 0, false
  by_provider, unparsed, older_by, pathless = {}, {}, {}, {}
  subagents, children, prev_status, listeners, reported = {}, {}, {}, {}, {}
  running, waiters, queued, counts_cache = false, {}, nil, nil
  last_full, fast, cache_loaded, cache_dirty = 0, false, false, false
  reporting, aliases, answers, seen_alive = {}, {}, {}, {}
  started_at = os.time()
  ended_at = {}
  seen_foreign = 0
  events.reset()
end

--- Write the cache now (on exit).
function M.flush()
  cache_dirty = cache_dirty or M.initialized
  save_cache()
end

return M
