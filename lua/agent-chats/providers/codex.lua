-- Codex CLI.
--
--   chats     <home>/sessions/<y>/<m>/<d>/rollout-<local start time>-<session id>.jsonl
--   titles    <home>/session_index.jsonl   `{id, thread_name, updated_at}`; the last line for an id wins
--   running   nothing on disk: `live` matches codex processes to chats
--
-- <home> is $CODEX_HOME or ~/.codex.
--
-- A rollout is a log of `{timestamp, type, payload}` envelopes. Two
-- generations of it exist, and one file holds both when an old chat is
-- resumed by a newer Codex:
--
--   events   the conversation is `event_msg` user_message / agent_message;
--            tool calls are `response_item` *_call / *_output pairs
--   items    the conversation, tool calls included, is `event_msg`
--            item_completed; the response_item records are still written
--            and say the same thing a second time
--
-- Turn boundaries are the same in both: task_started, task_complete,
-- turn_aborted. Codex records nothing when it stops to ask for approval, so
-- "needs you" comes from its hooks when they are installed (see `M.hooks`)
-- and is otherwise the stall guess (status.lua) on an outstanding tool call.

local async = require('agent-chats.util.async')
local common = require('agent-chats.providers.common')
local config = require('agent-chats.config')
local fs = require('agent-chats.util.fs')
local proc = require('agent-chats.util.proc')
local text = require('agent-chats.util.text')
local time = require('agent-chats.util.time')

---@type agent_chats.Provider
local M = { name = 'codex', label = 'Codex' }

function M.home()
  return common.home('codex', 'CODEX_HOME', '.codex')
end

function M.available()
  return fs.is_dir(M.home() .. '/sessions')
end

-----------------------------------------------------------------------------
-- Reading records
-----------------------------------------------------------------------------

-- The envelope type and the payload type open every line, so its first
-- bytes say whether it is worth decoding. These are not: token counts, the
-- environment snapshot, encrypted reasoning, settings echoes, tool listings.
local NOISE = {
  token_count = true,
  token_usage_record = true,
  world_state = true,
  reasoning = true,
  thread_settings_applied = true,
  additional_tools = true,
}

--- Envelope type and payload type of a raw line, without decoding it.
local function line_types(line)
  local a, b
  for t in line:sub(1, 200):gmatch('"type":"([%w_]+)"') do
    if not a then
      a = t
    else
      b = t
      break
    end
  end
  return a, b
end

local function skip(line)
  local a, b = line_types(line)
  return (a ~= nil and NOISE[a] == true) or (b ~= nil and NOISE[b] == true)
end

local function payload(r)
  return type(r.payload) == 'table' and r.payload or {}
end

local function str(v)
  if type(v) == 'string' and v ~= '' then
    return v
  end
end

--- Text of a content list (`[{type, text}]`), images as a marker.
local function content_text(content)
  if type(content) == 'string' then
    return content
  end
  if type(content) ~= 'table' then
    return nil
  end
  local parts = {}
  for _, c in ipairs(content) do
    if type(c) == 'table' then
      if type(c.text) == 'string' then
        parts[#parts + 1] = c.text
      elseif type(c.type) == 'string' and c.type:lower():find('image', 1, true) then
        parts[#parts + 1] = '[image]'
      end
    elseif type(c) == 'string' then
      parts[#parts + 1] = c
    end
  end
  return table.concat(parts, '\n')
end

--- What the user typed, from the record that states it outright.
local function explicit_prompt(r, p)
  if r.type ~= 'event_msg' then
    return nil
  end
  local s
  if p.type == 'user_message' then
    s = type(p.message) == 'string' and p.message or ''
    local images = (type(p.images) == 'table' and #p.images or 0)
      + (type(p.local_images) == 'table' and #p.local_images or 0)
    for _ = 1, images do
      s = s .. '\n[image]'
    end
  elseif
    p.type == 'item_completed'
    and type(p.item) == 'table'
    and p.item.type == 'UserMessage'
  then
    s = content_text(p.item.content)
  end
  s = s and vim.trim(s)
  return s ~= '' and s or nil
end

--- The same from the model's input, for a rollout with neither record:
--- only text that is not context Codex injected itself.
local function raw_prompt(r, p)
  if r.type ~= 'response_item' or p.type ~= 'message' or p.role ~= 'user' then
    return nil
  end
  local s = vim.trim(content_text(p.content) or '')
  if s == '' or s:sub(1, 1) == '<' or s:find('^# AGENTS%.md instructions') then
    return nil
  end
  return s
end

local function reply_text(r, p)
  if r.type ~= 'event_msg' then
    return nil
  end
  local s
  if p.type == 'agent_message' then
    s = str(p.message)
  elseif
    p.type == 'item_completed'
    and type(p.item) == 'table'
    and p.item.type == 'AgentMessage'
  then
    s = content_text(p.item.content)
  end
  if s and vim.trim(s) ~= '' then
    return s
  end
end

local function is_call(p)
  return type(p.call_id) == 'string' and type(p.type) == 'string' and p.type:sub(-5) == '_call'
end

local function is_output(p)
  return type(p.call_id) == 'string' and type(p.type) == 'string' and p.type:sub(-7) == '_output'
end

--- Name and view of a `response_item` tool call.
---@return string name, agent_chats.ToolView view
local function call_view(p)
  local name = p.name or (p.type:gsub('_call$', ''))
  local input = p.arguments or p.input or p.action
  if p.type == 'custom_tool_call' and type(input) == 'string' then
    -- Custom tools take free text: `apply_patch` a patch, `exec` a script.
    if input:find('^%s*%*%*%* Begin Patch') then
      local files = {}
      for file in input:gmatch('%*%*%* %a+ File: ([^\n]+)') do
        files[#files + 1] = fs.tilde(vim.trim(file))
      end
      return name, { summary = table.concat(files, ', '), input = input, lang = 'diff' }
    end
    local first = vim.trim(input):match('^[^\n]*') or ''
    return name,
      {
        summary = text.oneline(first, 120),
        input = input,
        lang = name == 'exec' and 'javascript' or nil,
      }
  end
  return name, common.tool(name, input)
end

--- Text of a tool output, and whether it reports failure.
local function output_text(p)
  local v = p.output
  if v == nil and type(p.tools) == 'table' then
    local names = {}
    for _, t in ipairs(p.tools) do
      if type(t) == 'table' and type(t.name) == 'string' then
        names[#names + 1] = t.name
      end
    end
    return table.concat(names, '\n'), false
  end
  if type(v) == 'string' and v:sub(1, 1) == '{' then
    -- Older shell output: `{"output": "...", "metadata": {"exit_code": 0}}`.
    local d = fs.decode(v)
    if type(d) == 'table' and type(d.output) == 'string' then
      local code = type(d.metadata) == 'table' and d.metadata.exit_code
      return d.output, type(code) == 'number' and code ~= 0
    end
  end
  return common.result_text(v), false
end

-- Function calls that are the agent asking you something.
local ASKS = { request_user_input = true, request_user_input_async = true }

local TURN_EVENTS = { task_started = true, task_complete = true, turn_aborted = true }

-----------------------------------------------------------------------------
-- Titles
-----------------------------------------------------------------------------

local index = { names = {} }

--- id -> thread name, from the session index (cached until the file changes).
local function titles()
  local path = M.home() .. '/session_index.jsonl'
  local st = fs.stat(path)
  if not st then
    index = { names = {} }
    return index.names
  end
  if index.path == path and index.mtime == st.mtime and index.size == st.size then
    return index.names
  end
  local names = {}
  local function take(line)
    local r = fs.decode(line)
    if type(r) == 'table' and type(r.id) == 'string' and str(r.thread_name) then
      names[r.id] = r.thread_name
    end
  end
  local data = fs.read_file(path) or ''
  local consumed = fs.each_line(data, take)
  if consumed < #data then
    take(data:sub(consumed + 1))
  end
  index = { path = path, mtime = st.mtime, size = st.size, names = names }
  return names
end

--- A chat's title is kept in the session index, not in its rollout, so
--- renaming a chat touches nothing the index of chats looks at. This is
--- what changes instead: the chat is read again when it does.
function M.rev(id)
  return titles()[id]
end

-----------------------------------------------------------------------------
-- Discovery and parsing
-----------------------------------------------------------------------------

local ROLLOUT = '^rollout%-.*%-(' .. text.UUID .. ')%.jsonl$'

local function subdirs(dir)
  local out = {}
  for _, e in ipairs(fs.scandir(dir)) do
    if e.type == 'directory' then
      out[#out + 1] = e.name
    end
  end
  table.sort(out, function(a, b)
    return a > b
  end)
  return out
end

--- Calls `fn(dir)` for every day directory, newest first; stops when it returns true.
local function each_day(fn)
  local root = M.home() .. '/sessions'
  for _, y in ipairs(subdirs(root)) do
    for _, m in ipairs(subdirs(root .. '/' .. y)) do
      for _, d in ipairs(subdirs(root .. '/' .. y .. '/' .. m)) do
        if fn(('%s/%s/%s/%s'):format(root, y, m, d)) then
          return
        end
      end
    end
  end
end

function M.discover()
  local by_id = {}
  each_day(function(dir)
    for _, f in ipairs(fs.scandir(dir)) do
      local id = f.type == 'file' and f.name:match(ROLLOUT)
      if id then
        local path = dir .. '/' .. f.name
        local st = fs.stat(path)
        -- One id in two files should not happen; the newer one wins if it does.
        if st and st.size > 0 and (not by_id[id] or by_id[id].mtime < st.mtime) then
          by_id[id] = { id = id, path = path, mtime = st.mtime, size = st.size }
        end
      end
    end
    async.tick()
  end)
  local out = {}
  for _, entry in pairs(by_id) do
    out[#out + 1] = entry
  end
  return out
end

--- Where the rollout of a running session is.
function M.locate(id)
  local found
  each_day(function(dir)
    for _, f in ipairs(fs.scandir(dir)) do
      if f.type == 'file' and f.name:match(ROLLOUT) == id then
        local path = dir .. '/' .. f.name
        local st = fs.stat(path)
        if st and st.size > 0 then
          found = { id = id, path = path, mtime = st.mtime, size = st.size }
          return true
        end
      end
    end
  end)
  return found
end

local function head_enough(records)
  local meta, prompt = false, false
  for _, r in ipairs(records) do
    if r.type == 'session_meta' then
      meta = true
    elseif explicit_prompt(r, payload(r)) then
      prompt = true
    end
    if meta and prompt then
      return true
    end
  end
  return false
end

local function has_turn(records)
  for _, r in ipairs(records) do
    if r.type == 'event_msg' and TURN_EVENTS[payload(r).type] then
      return true
    end
  end
  return false
end

--- The thread that started this one, when it is a subagent: a thread an
--- agent spawned to hand part of its work to. Its session_meta says so
--- (`source.subagent`), and names the thread that did.
---
--- Not a fork (`forked_from_id` alone): a chat you forked yourself is a
--- chat of its own.
---@return string? parent, string? name  The id of that thread, and what Codex calls this one: "Beauvoir: onboarding".
local function spawned_by(p)
  local sub = type(p.source) == 'table' and p.source.subagent or nil
  if sub == nil and p.thread_source ~= 'subagent' then
    return nil
  end
  local spawn = type(sub) == 'table' and type(sub.thread_spawn) == 'table' and sub.thread_spawn
    or {}
  local parent = str(spawn.parent_thread_id) or str(p.parent_thread_id)
  if parent == p.id then
    parent = nil
  end
  -- The name Codex gave the agent, and what it was spawned for (the last
  -- part of its path: "/root/onboarding").
  local nick = str(spawn.agent_nickname) or str(p.agent_nickname)
  local path = str(spawn.agent_path) or str(p.agent_path)
  local task = path and path:match('([^/]+)/*$') or nil
  if task == 'root' then
    task = nil
  end
  return parent, (nick and task) and (nick .. ': ' .. task) or nick or task
end

--- Returns whether the rollout's session_meta was among the records.
local function scan_head(records, out)
  local meta = false
  local raw
  for _, r in ipairs(records) do
    local p = payload(r)
    if r.type == 'session_meta' then
      -- (The first one: a subagent's rollout begins with its own, and has
      -- that of the thread it was spawned from after it.)
      if not meta then
        meta = true
        out.cwd = str(p.cwd)
        out.created = time.parse_iso(p.timestamp) or time.parse_iso(r.timestamp)
        if type(p.source) == 'string' then
          out.origin = p.source
        elseif type(p.source) == 'table' then
          out.origin = (next(p.source))
        end
        -- (Its name is its title until the session index has one for it.)
        out.parent_id, out.title = spawned_by(p)
        if type(p.git) == 'table' then
          out.branch = str(p.git.branch)
        end
      end
    elseif not out.first_prompt then
      local s = explicit_prompt(r, p)
      if s then
        out.first_prompt = text.clip(s, common.PROMPT_BYTES)
      elseif not raw then
        raw = raw_prompt(r, p)
      end
    end
    if meta and out.first_prompt then
      break
    end
  end
  if not out.first_prompt and raw then
    out.first_prompt = text.clip(raw, common.PROMPT_BYTES)
  end
  return meta
end

local function scan_tail(records, out, whole)
  local pending = {} -- call_id -> { name, view }
  local pending_n = 0
  local last_id
  local raw_prompt_text, raw_reply
  local said_prompt, said_reply = false, false
  local active = false

  local function clear_pending()
    pending, pending_n, last_id = {}, 0, nil
  end

  for _, r in ipairs(records) do
    local p = payload(r)
    local ts = time.parse_iso(r.timestamp)
    if ts and r.type ~= 'session_meta' then
      out.updated = ts
    end
    if r.type == 'event_msg' then
      local k = p.type
      if k == 'task_started' then
        clear_pending()
        out.turn, out.turn_at, out.turn_began = 'working', ts, ts
      elseif k == 'task_complete' then
        clear_pending()
        out.turn, out.turn_at = 'done', ts
        if str(p.last_agent_message) and vim.trim(p.last_agent_message) ~= '' then
          out.last_reply = text.clip(p.last_agent_message, common.REPLY_BYTES)
          said_reply = true
        end
      elseif k == 'turn_aborted' then
        clear_pending()
        out.turn, out.turn_at = 'aborted', ts
      elseif k == 'error' then
        clear_pending()
        out.turn, out.turn_at = 'done', ts
      else
        local prompt = explicit_prompt(r, p)
        if prompt then
          out.last_prompt = text.clip(prompt, common.PROMPT_BYTES)
          said_prompt = true
          active = true
          -- Its task_started may lie before the part of the file read.
          if out.turn ~= 'working' then
            out.turn, out.turn_at, out.turn_began = 'working', ts, ts
          end
        else
          local reply = reply_text(r, p)
          if reply then
            out.last_reply = text.clip(reply, common.REPLY_BYTES)
            said_reply = true
            active = true
          end
        end
      end
    elseif r.type == 'response_item' then
      active = true
      if is_output(p) then
        if pending[p.call_id] then
          pending[p.call_id] = nil
          pending_n = pending_n - 1
        end
      elseif is_call(p) then
        if not pending[p.call_id] then
          pending_n = pending_n + 1
        end
        local name, view = call_view(p)
        pending[p.call_id] = { name = name, view = view }
        last_id = p.call_id
      elseif p.type == 'message' then
        if p.role == 'user' then
          raw_prompt_text = raw_prompt(r, p) or raw_prompt_text
        elseif p.role == 'assistant' then
          local s = content_text(p.content)
          if s and vim.trim(s) ~= '' then
            raw_reply = s
          end
        end
      end
    elseif r.type == 'turn_context' then
      out.model = str(p.model) or out.model
    end
  end

  if not said_prompt and raw_prompt_text then
    out.last_prompt = text.clip(raw_prompt_text, common.PROMPT_BYTES)
  end
  if not said_reply and raw_reply then
    out.last_reply = text.clip(raw_reply, common.REPLY_BYTES)
  end
  -- Activity with no turn boundary in reach: a turn longer than the read.
  if out.turn == 'unknown' and active and not whole then
    out.turn = 'working'
  end
  if pending_n > 0 and out.turn == 'working' then
    out.pending_tool = true
    local tool = (last_id and pending[last_id]) or select(2, next(pending))
    out.activity = common.activity(tool.name or 'tool', tool.view)
    for _, t in pairs(pending) do
      if ASKS[t.name] then
        out.asking = true
      end
    end
  end
end

function M.parse(entry, prev)
  local out = { turn = 'unknown' }
  local carried = common.carried(prev, entry)
  local head, head_whole
  local has_meta = carried ~= nil
  if carried then
    out = vim.tbl_extend('force', out, carried)
  else
    head, head_whole = common.head(entry.path, entry.size, { skip = skip, enough = head_enough })
    has_meta = scan_head(head, out)
  end
  local tail, tail_whole = head, true
  if not head_whole then
    tail, tail_whole = common.tail(entry.path, entry.size, { skip = skip, enough = has_turn })
  end
  scan_tail(tail, out, tail_whole)
  -- A subagent has no title in the session index, and its rollout begins
  -- with the conversation it was spawned from: by its first prompt it would
  -- be called what the chat that spawned it is called. It goes by the name
  -- Codex gave it, which the head says (and which is kept when only the
  -- tail was read).
  local spawned
  if out.parent_id then
    spawned = out.title or (prev and prev.path == entry.path and prev.title) or 'subagent'
  end
  out.title = titles()[entry.id] or spawned
  if prev and prev.path == entry.path then
    -- The branch comes from the head; the rest may lie before the tail.
    out.branch = out.branch or prev.branch
    out.last_prompt = out.last_prompt or prev.last_prompt
    out.last_reply = out.last_reply or prev.last_reply
    out.model = out.model or prev.model
  end
  if not has_meta and not out.first_prompt and not out.last_prompt and not out.last_reply then
    return nil
  end
  out.updated = out.updated or entry.mtime
  out.created = out.created or out.updated
  return out
end

-----------------------------------------------------------------------------
-- Running processes
-----------------------------------------------------------------------------

-- Subcommands that hold no conversation (`codex app-server`, `codex mcp`, ...).
local NOT_CHAT = {}
for _, name in ipairs({
  'app-server',
  'exec-server',
  'mcp',
  'mcp-server',
  'login',
  'logout',
  'plugin',
  'completion',
  'update',
  'doctor',
  'sandbox',
  'debug',
  'apply',
  'a',
  'archive',
  'unarchive',
  'delete',
  'migrate-rollouts',
  'migrate-nfs-db',
  'cloud',
  'features',
  'help',
  'remote-control',
  'agents',
  'queue',
}) do
  NOT_CHAT[name] = true
end

-- Options that take a value, so the word after them is not the subcommand.
local VALUE_OPTS = {}
for _, name in ipairs({
  '-c',
  '--config',
  '-m',
  '--model',
  '-p',
  '--profile',
  '-s',
  '--sandbox',
  '-a',
  '--ask-for-approval',
  '-C',
  '--cd',
  '-i',
  '--image',
  '--enable',
  '--disable',
  '--remote',
  '--remote-auth-token-env',
  '--local-provider',
  '--add-dir',
}) do
  VALUE_OPTS[name] = true
end

--- Arguments after the codex executable, or nil when argv is not codex itself
--- (a sandbox helper running under its name, for one).
local function codex_args(argv)
  for i = 1, math.min(3, #argv) do
    if (fs.basename(argv[i]):gsub('%.[%w]+$', '')) == 'codex' then
      return vim.list_slice(argv, i + 1)
    end
  end
end

local function is_chat(args)
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '--' then
      return true
    elseif a:sub(1, 1) == '-' then
      if VALUE_OPTS[a] then
        i = i + 1
      end
    else
      return not NOT_CHAT[a]
    end
    i = i + 1
  end
  return true
end

-- `codex resume <id>` names the chat. (`codex fork <id>` names the chat it
-- copies, not the new one it writes, so it is left to the other matches.)
local function resumed_id(args)
  for i, a in ipairs(args) do
    if a == 'resume' and args[i + 1] and args[i + 1]:match('^' .. text.UUID .. '$') then
      return args[i + 1]
    end
  end
end

M._parse_etime = proc.parse_etime

--- Epoch seconds in a rollout's file name (local time).
local function file_start(path)
  local y, mo, d, h, mi, s = fs.basename(path)
    :match('^rollout%-(%d+)%-(%d+)%-(%d+)T(%d+)%-(%d+)%-(%d+)%-')
  if not y then
    return nil
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
end

-- Codex keeps no record of running sessions, so each codex process is
-- matched to a chat by the best evidence there is:
--   0. the process a session's own hook ran under, when hooks are installed
--   1. a rollout it holds open (Linux)
--   2. `resume <id>` on its command line
--   3. a rollout named for the second it started, in its working directory
--   4. the chat last written in its working directory since it started
---@param chats table<string, agent_chats.Chat>?
---@param reported table<string, agent_chats.Reported>?
function M.live(chats, reported)
  local out = {}
  chats = chats or {}
  local found, by_pid = {}, {}
  for _, p in ipairs(proc.find({ codex = true })) do
    local args = codex_args(p.argv or {})
    if args and is_chat(args) then
      p.args = args
      found[#found + 1] = p
      by_pid[p.pid] = p
    end
  end
  if #found == 0 then
    return out
  end
  -- A launcher and the binary it runs are both "codex": deepest first, and
  -- whatever a process claims, its launchers do not claim something else.
  for _, p in ipairs(found) do
    local depth, cur = 0, p.ppid
    while cur and by_pid[cur] and depth < 16 do
      depth = depth + 1
      cur = by_pid[cur].ppid
    end
    p.depth = depth
  end
  table.sort(found, function(a, b)
    if a.depth ~= b.depth then
      return a.depth > b.depth
    end
    return a.pid < b.pid
  end)

  local by_path = {}
  for id, chat in pairs(chats) do
    if chat.path then
      by_path[chat.path] = chat.id or id
    end
  end
  local sessions = M.home() .. '/sessions/'
  local spoken = {}

  local function claim_launchers(p)
    local cur = p.ppid
    while cur and by_pid[cur] and not spoken[cur] do
      spoken[cur] = true
      cur = by_pid[cur].ppid
    end
  end

  -- One process can hold several sessions (a chat and the agents it
  -- spawned), so a process is never used up by one match: a hook, and each
  -- rollout it holds open, names a session of its own.
  for id, said in pairs(reported or {}) do
    local p = said.pid and not said.ended and by_pid[said.pid] or nil
    if p and chats[id] then
      -- A process younger than the event that named it took over the number.
      local born = proc.start_time(p.pid)
      if not (born and said.pid_at and born > said.pid_at + 2) then
        out[id] = { pid = p.pid, cwd = proc.cwd(p.pid) }
        p.matched = true
        claim_launchers(p)
      end
    end
  end

  for _, p in ipairs(found) do
    if not spoken[p.pid] then
      local cwd = proc.cwd(p.pid)
      for _, path in ipairs(proc.open_paths(p.pid)) do
        local id = by_path[path]
          or (path:sub(1, #sessions) == sessions and fs.basename(path):match(ROLLOUT) or nil)
        if id then
          out[id] = out[id] or { pid = p.pid, cwd = cwd }
          p.matched = true
        end
      end
      local started
      if not p.matched then
        -- Nothing names its session outright: go by the command line, then
        -- by time and place. These find one session per process.
        local id = resumed_id(p.args)
        if not id then
          started = proc.start_time(p.pid)
          local best, best_diff, recent, recent_at
          for key, chat in pairs(chats) do
            local cid = chat.id or key
            if not out[cid] and chat.path and (not cwd or not chat.cwd or chat.cwd == cwd) then
              local fstart = started and file_start(chat.path)
              local diff = fstart and math.abs(fstart - started)
              if diff and diff <= 5 and (not best_diff or diff < best_diff) then
                best, best_diff = cid, diff
              end
              local at = chat.updated or chat.mtime or 0
              if cwd and chat.cwd == cwd and started and at >= started - 5 then
                if not recent_at or at > recent_at then
                  recent, recent_at = cid, at
                end
              end
            end
          end
          id = best or recent
        end
        if id then
          out[id] = out[id] or { pid = p.pid, cwd = cwd, started = started }
          p.matched = true
        end
      end
      if p.matched then
        claim_launchers(p)
      end
    end
  end
  return out
end

-----------------------------------------------------------------------------
-- Hooks
-----------------------------------------------------------------------------

-- Codex writes nothing to the rollout when it stops to ask for approval,
-- so its hooks are the only way to know it is blocked on you. They also
-- say when a turn is interrupted, and under which process a session runs.
M.hooks = {
  events = {
    SessionStart = function(ev)
      return (ev.src == 'startup' or ev.src == 'resume') and 'start' or nil
    end,
    SessionEnd = 'ended',
    UserPromptSubmit = 'working',
    PermissionRequest = 'waiting',
    PostToolUse = 'resolved',
    SubagentStop = 'resolved',
    Stop = 'done',
    Interrupt = 'aborted',
  },
  process = { codex = true },
  -- Newer versions of Codex keep `codex app-server` running as a daemon
  -- that holds the sessions of every terminal, and a session's hooks run
  -- under it. That process being alive says nothing about a chat being
  -- open anywhere: only a process that is itself a chat does.
  holds = function(pid)
    local args = codex_args(proc.argv(pid) or {})
    return args ~= nil and is_chat(args)
  end,
  config = function()
    return {
      kind = 'json',
      path = M.home() .. '/hooks.json',
      events = {
        'SessionStart',
        'SessionEnd',
        'UserPromptSubmit',
        'PermissionRequest',
        'PostToolUse',
        'SubagentStop',
        'Stop',
        'Interrupt',
      },
      timeout = 10,
      -- Codex gives these two a second of its own and allows no more than three.
      timeouts = { SessionEnd = false, Interrupt = false },
      note = 'Codex runs a hook only after you have trusted it. It asks the next time it starts ("Hooks need review"); /hooks in a running session does the same.',
    }
  end,
}

-----------------------------------------------------------------------------
-- Transcript
-----------------------------------------------------------------------------

local ADDED_BYTES = 16000

--- Push a message unless it repeats the one before it.
local function say(out, role, s, ts)
  s = s and vim.trim(s) or ''
  if s == '' then
    return
  end
  local last = out[#out]
  if last and last.role == role and last.text == s then
    return
  end
  out[#out + 1] = { role = role, text = s, time = ts }
end

local function prefixed(body, prefix)
  local lines = {}
  for _, l in ipairs(text.lines(text.clip(body or '', ADDED_BYTES))) do
    lines[#lines + 1] = prefix .. l
  end
  return table.concat(lines, '\n')
end

local function item_messages(item, out, ts)
  local t = item.type
  if t == 'UserMessage' then
    say(out, 'user', content_text(item.content), ts)
  elseif t == 'AgentMessage' then
    say(out, 'assistant', content_text(item.content), ts)
  elseif t == 'Reasoning' then
    say(out, 'thinking', content_text(item.summary_text), ts)
  elseif t == 'CommandExecution' then
    local view = common.tool('shell', { command = item.command })
    out[#out + 1] = {
      role = 'tool',
      id = item.id,
      name = 'shell',
      summary = view.summary,
      input = view.input,
      lang = view.lang,
      time = ts,
    }
    local body = str(item.aggregated_output) or str(item.formatted_output) or str(item.stdout) or ''
    local code = item.exit_code
    local failed = item.status == 'failed' or (type(code) == 'number' and code ~= 0)
    if type(code) == 'number' and code ~= 0 then
      body = (body ~= '' and (body:gsub('\n+$', '') .. '\n') or '') .. ('exit code %d'):format(code)
    end
    out[#out + 1] = { role = 'tool_result', id = item.id, text = body, error = failed, time = ts }
  elseif t == 'FileChange' then
    local paths = {}
    for path in pairs(type(item.changes) == 'table' and item.changes or {}) do
      paths[#paths + 1] = path
    end
    table.sort(paths)
    local files, parts = {}, {}
    for _, path in ipairs(paths) do
      local change = item.changes[path]
      files[#files + 1] = fs.tilde(path)
      if type(change) == 'table' then
        if change.type == 'add' then
          parts[#parts + 1] = '--- /dev/null\n+++ ' .. path .. '\n' .. prefixed(change.content, '+')
        elseif change.type == 'delete' then
          parts[#parts + 1] = '--- ' .. path .. '\n+++ /dev/null\n' .. prefixed(change.content, '-')
        else
          parts[#parts + 1] = ('--- %s\n+++ %s\n%s'):format(
            path,
            str(change.move_path) or path,
            (tostring(change.unified_diff or ''):gsub('\n+$', ''))
          )
        end
      end
    end
    out[#out + 1] = {
      role = 'tool',
      id = item.id,
      name = 'apply_patch',
      summary = table.concat(files, ', '),
      input = table.concat(parts, '\n'),
      lang = 'diff',
      time = ts,
    }
    if item.status and item.status ~= 'completed' then
      local note = vim.trim(tostring(item.status) .. '\n' .. (str(item.stderr) or ''))
      out[#out + 1] = { role = 'tool_result', id = item.id, text = note, error = true, time = ts }
    end
  elseif t == 'McpToolCall' then
    local name = (str(item.server) and (item.server .. '.') or '') .. (str(item.tool) or 'tool')
    local view = common.tool(name, item.arguments)
    out[#out + 1] = {
      role = 'tool',
      id = item.id,
      name = name,
      summary = view.summary,
      input = view.input,
      lang = view.lang,
      time = ts,
    }
    local res = item.result
    out[#out + 1] = {
      role = 'tool_result',
      id = item.id,
      text = type(res) == 'table' and common.result_text(res.content or res) or '',
      error = item.status == 'failed' or (type(res) == 'table' and res.isError == true),
      time = ts,
    }
  elseif t == 'Extension' then
    out[#out + 1] = {
      role = 'tool',
      id = item.id,
      name = str(item.kind) or 'extension',
      summary = text.oneline(item.query, 120),
      time = ts,
    }
    local lines = {}
    for _, res in ipairs(type(item.results) == 'table' and item.results or {}) do
      if type(res) == 'table' and (res.title or res.url) then
        lines[#lines + 1] = ('%s  %s'):format(tostring(res.title or ''), tostring(res.url or ''))
      end
    end
    if #lines > 0 then
      out[#out + 1] =
        { role = 'tool_result', id = item.id, text = table.concat(lines, '\n'), time = ts }
    end
  elseif t == 'ImageView' then
    out[#out + 1] =
      { role = 'tool', id = item.id, name = 'view_image', summary = fs.tilde(item.path), time = ts }
  end
end

--- `items`: the file has reached its item_completed part.
local function convert(r, out, items)
  local p = payload(r)
  local ts = time.parse_iso(r.timestamp)
  if r.type == 'compacted' then
    say(out, 'system', 'Earlier conversation was compacted here.', ts)
  elseif r.type == 'event_msg' then
    local k = p.type
    if k == 'turn_aborted' then
      local why = str(p.reason)
      say(
        out,
        'system',
        why == 'interrupted' and 'Interrupted by user.'
          or ('Turn aborted' .. (why and (': ' .. why) or '') .. '.'),
        ts
      )
    elseif k == 'error' then
      say(out, 'system', 'Error: ' .. tostring(p.message or 'unknown'), ts)
    elseif k == 'thread_rolled_back' then
      say(out, 'system', ('Rolled back %s turn(s).'):format(tostring(p.num_turns or '?')), ts)
    elseif k == 'item_completed' then
      if type(p.item) == 'table' then
        item_messages(p.item, out, ts)
      end
    elseif not items then
      if k == 'user_message' then
        say(out, 'user', explicit_prompt(r, p), ts)
      elseif k == 'agent_message' then
        say(out, 'assistant', str(p.message), ts)
      elseif k == 'agent_reasoning' then
        say(out, 'thinking', str(p.text), ts)
      end
    end
  elseif r.type == 'response_item' and not items then
    if is_output(p) then
      local body, failed = output_text(p)
      out[#out + 1] =
        { role = 'tool_result', id = p.call_id, text = body, error = failed, time = ts }
    elseif is_call(p) then
      local name, view = call_view(p)
      out[#out + 1] = {
        role = 'tool',
        id = p.call_id,
        name = name,
        summary = view.summary,
        input = view.input,
        lang = view.lang,
        time = ts,
      }
    end
  end
end

--- The cursor is `{ offset, items }`: where to read on from, and whether the
--- file has switched to item records by then.
function M.messages(chat, opts)
  local cursor = opts and opts.cursor
  local offset, items = 0, false
  if type(cursor) == 'table' then
    offset, items = cursor.offset or 0, cursor.items == true
  end
  local out = {}
  local st = chat.path and fs.stat(chat.path)
  if not st then
    return out, cursor
  end
  -- Shorter than what was read before: read it from the top, and say so.
  local restarted = false
  if st.size < offset then
    offset, items, restarted = 0, false, true
  end
  if st.size == offset then
    return out, { offset = offset, items = items }, restarted
  end
  local data = fs.read_range(chat.path, offset, st.size - offset)
  if not data then
    return out, { offset = offset, items = items }, restarted
  end
  local n = 0
  local consumed = fs.each_line(data, function(line)
    n = n + 1
    if n % 100 == 0 then
      async.tick()
    end
    local a, b = line_types(line)
    if (a and NOISE[a]) or (b and NOISE[b]) or (items and a == 'response_item') then
      return
    end
    local r = fs.decode(line)
    if type(r) ~= 'table' then
      return
    end
    if not items and r.type == 'event_msg' and payload(r).type == 'item_completed' then
      items = true
    end
    convert(r, out, items)
  end)
  return out, { offset = offset + consumed, items = items }, restarted
end

-----------------------------------------------------------------------------
-- Commands
-----------------------------------------------------------------------------

-- A prompt that the program could take for an option or a command of its
-- own is kept from that (see `common.arg`).
local arg = common.arg

function M.resume_cmd(chat)
  return common.cmd('codex', 'resume', chat.id)
end

function M.new_cmd(opts)
  local args = {}
  if opts.prompt and opts.prompt ~= '' then
    args[#args + 1] = arg(opts.prompt)
  end
  return common.cmd('codex', args)
end

function M.headless_cmd(chat, prompt)
  return common.cmd(
    'codex',
    'exec',
    'resume',
    config.provider('codex').headless_args,
    chat.id,
    arg(prompt)
  )
end

function M.resume_prompt_cmd(chat, prompt)
  return common.cmd('codex', 'resume', chat.id, arg(prompt))
end

return M
