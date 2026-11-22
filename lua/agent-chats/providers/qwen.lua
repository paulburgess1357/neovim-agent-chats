-- Qwen Code.
--
--   chats     <runtime>/projects/<encoded cwd>/chats/<session id>.jsonl
--             <runtime>/projects/<encoded cwd>/chats/<session id>.runtime.json
--   running   <home>/sessions/<pid>.json   one per live process, naming the
--             session it has open
--
-- <home> is $QWEN_HOME or ~/.qwen; <runtime> is $QWEN_RUNTIME_DIR, or <home>
-- when that is unset. Qwen's registry says which session a process has open
-- but not whether it is busy. With its hooks installed (see `M.hooks`) it
-- reports that itself; without them the turn state comes from the
-- transcript and "needs you" is the board's quiet-tool-call guess.

local async = require('agent-chats.util.async')
local common = require('agent-chats.providers.common')
local config = require('agent-chats.config')
local fs = require('agent-chats.util.fs')
local proc = require('agent-chats.util.proc')
local text = require('agent-chats.util.text')
local time = require('agent-chats.util.time')

---@type agent_chats.Provider
local M = { name = 'qwen', label = 'Qwen', preassign_id = true }

function M.home()
  return common.home('qwen', 'QWEN_HOME', '.qwen')
end

-- Where the chats are. Qwen can keep them apart from the rest of its data;
-- a `home` set in the options speaks for both.
local function runtime()
  local opt = config.provider('qwen').home
  if type(opt) ~= 'string' or opt == '' then
    local env = vim.env.QWEN_RUNTIME_DIR
    if env and env ~= '' then
      return (vim.fs.normalize(env))
    end
  end
  return M.home()
end

function M.available()
  return fs.is_dir(runtime() .. '/projects')
end

-----------------------------------------------------------------------------
-- Reading records
-----------------------------------------------------------------------------

-- Every record opens with four fixed-width fields and then its `type`, so a
-- `system` record can be told from the raw line. Most of them are telemetry
-- of each API response and tool call, file-history and memory snapshots or
-- compressed history, some of it large; only these subtypes are wanted, plus
-- the request start / end events among the telemetry.
local KEEP = {
  custom_title = true,
  parent_session = true,
  session_source = true,
  slash_command = true,
  turn_result = true,
}

--- Whether a raw line can be dropped undecoded, and its system subtype.
---@return boolean drop, string? subtype
local function classify(line)
  local at = line:sub(1, 320):find('"type":"system"', 1, true)
  if not at then
    return false
  end
  local sub = line:match('"subtype":"([%w_]+)"', at)
  if not sub then
    return false
  end
  if sub == 'ui_telemetry' then
    return line:find('"event.name":"request_lifecycle"', at, true) == nil, sub
  end
  return not KEEP[sub], sub
end

local function skip(line)
  return (classify(line))
end

local function parts_of(r)
  local parts = type(r.message) == 'table' and r.message.parts
  return type(parts) == 'table' and parts or {}
end

local function payload_of(r)
  return type(r.systemPayload) == 'table' and r.systemPayload or {}
end

local function is_turn_record(r)
  return r.type == 'user' or r.type == 'assistant' or r.type == 'tool_result'
end

--- Text of a `user` record, and whether you typed it.
---@return string? text, "prompt"|"system"|nil kind
local function user_text(r)
  -- What the client showed for the prompt, when it differs from what was
  -- sent (hook context, expanded file references).
  local s = payload_of(r).displayText
  if type(s) ~= 'string' or s == '' then
    local out = {}
    for _, p in ipairs(parts_of(r)) do
      if type(p) == 'table' then
        if type(p.text) == 'string' and not p.thought then
          out[#out + 1] = p.text
        elseif p.inlineData or p.fileData then
          out[#out + 1] = '[attachment]'
        end
      end
    end
    s = table.concat(out, '')
  end
  s = vim.trim(s)
  if s == '' then
    return nil
  end
  -- Goal runners, schedulers and subagents also speak in `user` records.
  if r.provenance ~= nil and r.provenance ~= 'real_user' then
    return s, 'system'
  end
  return s, 'prompt'
end

--- Reply text of an `assistant` record: its text parts that are not thoughts.
local function reply_text(r)
  local out = {}
  for _, p in ipairs(parts_of(r)) do
    if type(p) == 'table' and type(p.text) == 'string' and not p.thought then
      out[#out + 1] = p.text
    end
  end
  return table.concat(out, '')
end

--- Name and view of a function call. `tool_call` is a wrapper that invokes
--- another tool by name; the tool it names is the one worth showing.
---@return string name, agent_chats.ToolView view
local function call_view(fc)
  local name, args = fc.name or 'tool', fc.args
  if name == 'tool_call' and type(args) == 'table' and type(args.name) == 'string' then
    name, args = args.name, args.arguments
  end
  return name, common.tool(name, args)
end

--- A main-agent request start / end event, or nil. Requests of background
--- subagents (the memory extractor runs one after every turn) say nothing
--- about the turn.
local function lifecycle(r)
  if r.type ~= 'system' or r.subtype ~= 'ui_telemetry' then
    return nil
  end
  local ev = payload_of(r).uiEvent
  if type(ev) ~= 'table' or ev['event.name'] ~= 'request_lifecycle' or ev.subagentId ~= nil then
    return nil
  end
  return ev
end

-- Tool calls that are the agent asking you something.
local ASKS = { ask_user_question = true, exit_plan_mode = true }

-----------------------------------------------------------------------------
-- Discovery and parsing
-----------------------------------------------------------------------------

function M.discover()
  local out = {}
  local root = runtime() .. '/projects'
  for _, proj in ipairs(fs.scandir(root)) do
    if proj.type == 'directory' then
      local dir = root .. '/' .. proj.name .. '/chats'
      for _, f in ipairs(fs.scandir(dir)) do
        local id = f.type == 'file' and f.name:match('^(' .. text.UUID .. ')%.jsonl$')
        if id then
          local path = dir .. '/' .. f.name
          local st = fs.stat(path)
          if st and st.size > 0 then
            out[#out + 1] = { id = id, path = path, mtime = st.mtime, size = st.size }
          end
        end
      end
      async.tick()
    end
  end
  return out
end

local function has_prompt(records)
  for _, r in ipairs(records) do
    if r.type == 'user' then
      local s, kind = user_text(r)
      if s and kind == 'prompt' then
        return true
      end
    end
  end
  return false
end

local function has_turn(records)
  for _, r in ipairs(records) do
    if is_turn_record(r) then
      return true
    end
  end
  return false
end

---@return boolean conversation Whether the records hold any conversation.
local function scan_head(records, out)
  local conversation = false
  for _, r in ipairs(records) do
    if not out.cwd and type(r.cwd) == 'string' then
      out.cwd = r.cwd
    end
    if not out.created and r.timestamp then
      out.created = time.parse_iso(r.timestamp)
    end
    if r.type == 'system' then
      local payload = payload_of(r)
      if r.subtype == 'session_source' and type(payload.sourceType) == 'string' then
        out.origin = out.origin or payload.sourceType
      elseif r.subtype == 'parent_session' and type(payload.parentSessionId) == 'string' then
        out.parent_id = payload.parentSessionId
      elseif r.subtype == 'custom_title' and type(payload.customTitle) == 'string' then
        out.title = payload.customTitle ~= '' and payload.customTitle or out.title
      end
    elseif is_turn_record(r) then
      conversation = true
      if not out.first_prompt and r.type == 'user' then
        local s, kind = user_text(r)
        if s and kind == 'prompt' then
          out.first_prompt = text.clip(s, common.PROMPT_BYTES)
        end
      end
    end
  end
  return conversation
end

---@return boolean conversation Whether the records hold any conversation.
local function scan_tail(records, out)
  local pending = {} -- call id -> { name, view }
  local pending_n = 0
  local last_tool
  local open = {} -- execution id -> true, for main-agent requests in flight
  local open_n = 0
  local conversation = false

  local function clear_pending()
    pending, pending_n, last_tool = {}, 0, nil
  end

  local function seen(r, ts)
    conversation = true
    if ts then
      out.updated = ts
    end
    if type(r.gitBranch) == 'string' and r.gitBranch ~= '' then
      out.branch = r.gitBranch
    end
  end

  for _, r in ipairs(records) do
    local t = r.type
    local ts = time.parse_iso(r.timestamp)
    if t == 'user' then
      seen(r, ts)
      local s, kind = user_text(r)
      if s then
        if kind == 'prompt' then
          out.last_prompt = text.clip(s, common.PROMPT_BYTES)
        end
        -- A message typed while the agent works joins the turn in progress.
        if r.subtype ~= 'mid_turn_user_message' then
          clear_pending()
          out.turn_began = ts
        end
        out.turn, out.turn_at = 'working', ts
      end
    elseif t == 'assistant' then
      if r.provenance ~= 'subagent' then
        seen(r, ts)
        out.model = type(r.model) == 'string' and r.model or out.model
        local called = false
        for _, p in ipairs(parts_of(r)) do
          local fc = type(p) == 'table' and p.functionCall
          if type(fc) == 'table' then
            called = true
            local name, view = call_view(fc)
            -- Not every model numbers its calls.
            local id = fc.id or ('#' .. (pending_n + 1))
            if not pending[id] then
              pending_n = pending_n + 1
            end
            pending[id] = { name = name, view = view }
            last_tool = pending[id]
          end
        end
        local reply = reply_text(r)
        if vim.trim(reply) ~= '' then
          out.last_reply = text.clip(reply, common.REPLY_BYTES)
        end
        if called or pending_n > 0 or open_n > 0 then
          out.turn, out.turn_at = 'working', ts
        else
          out.turn, out.turn_at = 'done', ts
        end
      end
    elseif t == 'tool_result' then
      seen(r, ts)
      local had_id = false
      local function settle(id)
        if id == nil then
          return
        end
        had_id = true
        if pending[id] then
          pending[id] = nil
          pending_n = pending_n - 1
        end
      end
      for _, p in ipairs(parts_of(r)) do
        local fr = type(p) == 'table' and p.functionResponse
        if type(fr) == 'table' then
          settle(fr.id)
        end
      end
      settle(type(r.toolCallResult) == 'table' and r.toolCallResult.callId or nil)
      -- A result with no id cannot be matched to its call: take it as
      -- answering whatever was outstanding.
      if not had_id or pending_n <= 0 then
        clear_pending()
      end
      out.turn, out.turn_at = 'working', ts
    elseif t == 'system' then
      local payload = payload_of(r)
      if r.subtype == 'custom_title' then
        if type(payload.customTitle) == 'string' and payload.customTitle ~= '' then
          out.title = payload.customTitle
        end
      elseif r.subtype == 'parent_session' then
        if type(payload.parentSessionId) == 'string' then
          out.parent_id = payload.parentSessionId
        end
      elseif r.subtype == 'turn_result' then
        -- Written by `qwen serve` when it settles a turn.
        seen(r, ts)
        clear_pending()
        open, open_n = {}, 0
        out.turn, out.turn_at = payload.state == 'cancelled' and 'aborted' or 'done', ts
      else
        local ev = lifecycle(r)
        if ev then
          if ts then
            out.updated = ts
          end
          local id = ev.executionId or '?'
          if ev.phase == 'started' then
            if not open[id] then
              open[id] = true
              open_n = open_n + 1
            end
            out.turn, out.turn_at = 'working', ts
          elseif ev.phase == 'ended' then
            if open[id] then
              open[id] = nil
              open_n = open_n - 1
            end
            if ev.outcome == 'cancelled' or ev.outcome == 'interrupted' then
              clear_pending()
              out.turn, out.turn_at = 'aborted', ts
            elseif ev.outcome == 'error' then
              -- The request failed and nothing follows: your move, and worth
              -- a look.
              clear_pending()
              out.turn, out.turn_at = 'done', ts
            end
            -- After a success the assistant record that follows decides.
          end
        end
      end
    end
  end

  if pending_n > 0 and out.turn == 'working' then
    out.pending_tool = true
    local tool = last_tool or select(2, next(pending))
    if tool then
      out.activity = common.activity(tool.name or 'tool', tool.view)
      out.asking = ASKS[tool.name] or nil
    end
  end
  return conversation
end

function M.parse(entry, prev)
  local out = { turn = 'unknown' }
  local carried = common.carried(prev, entry)
  local conversation = carried ~= nil
  local head, head_whole
  if carried then
    out = vim.tbl_extend('force', out, carried)
  else
    head, head_whole = common.head(entry.path, entry.size, { skip = skip, enough = has_prompt })
    conversation = scan_head(head, out)
  end
  local tail = head_whole and head
    or common.tail(entry.path, entry.size, { skip = skip, enough = has_turn })
  conversation = scan_tail(tail, out) or conversation
  if prev and prev.path == entry.path then
    -- The tail may no longer reach back to these.
    out.title = out.title or prev.title
    out.last_prompt = out.last_prompt or prev.last_prompt
    out.last_reply = out.last_reply or prev.last_reply
    out.branch = out.branch or prev.branch
    out.model = out.model or prev.model
    out.parent_id = out.parent_id or prev.parent_id
  end
  if not conversation then
    -- Slash commands and bookkeeping only: nothing was ever said.
    return nil
  end
  out.updated = out.updated or entry.mtime
  out.created = out.created or out.updated
  return out
end

-----------------------------------------------------------------------------
-- Running processes
-----------------------------------------------------------------------------

local boot_id -- false when it cannot be read

local function current_boot()
  if boot_id == nil then
    local raw = fs.read_small('/proc/sys/kernel/random/boot_id', 128)
    boot_id = raw and vim.trim(raw) or false
    if boot_id == '' then
      boot_id = false
    end
  end
  return boot_id
end

-- A record outlives a crash, and its pid can then go to another process.
-- On Linux the record carries `<boot id>:<process start, in clock ticks>`
-- to tell; elsewhere Qwen writes no such token and a live pid is believed.
local function same_process(pid, token)
  if type(token) ~= 'string' then
    return true
  end
  local boot, ticks = token:match('^(.-):(%d+)$')
  if not boot then
    return true
  end
  local now_boot = current_boot()
  if now_boot and boot ~= now_boot then
    return false
  end
  local st = proc.stat(pid)
  if not st then
    return true
  end
  return st.start == tonumber(ticks)
end

--- The name Qwen gives a session nobody named: the folder's name and two
--- hex digits of the session id's hash.
local function derived_name(cwd, id)
  local base = fs.basename(cwd or '')
  -- Qwen keeps letters, marks and digits of any script; here every
  -- non-ASCII byte counts as one of them.
  base = base:gsub('[^%w%._%-\128-\255]+', '-'):gsub('^%-+', ''):gsub('%-+$', '')
  base = vim.fn.strcharpart(base, 0, 32)
  if base == '' then
    base = 'session'
  end
  return base .. '-' .. vim.fn.sha256(id):sub(1, 2)
end

-- `<chat>.runtime.json` per transcript path, re-read only when the
-- transcript changed: { mtime, size, pid?, cwd?, started? }.
local runtime_cache = {}

--- The process a chat's runtime file names, when it is still that process.
--- The file stays behind when the session ends, so a pid found dead (or
--- handed to a younger process) is forgotten until the transcript moves.
---@return { pid: integer, cwd: string?, started: number? }?
local function runtime_process(chat)
  local hit = runtime_cache[chat.path]
  if not hit or hit.mtime ~= chat.mtime or hit.size ~= chat.size then
    hit = { mtime = chat.mtime, size = chat.size }
    local rt = fs.read_json((chat.path:gsub('%.jsonl$', '.runtime.json')))
    if
      type(rt) == 'table'
      and rt.session_id == chat.id
      and type(rt.pid) == 'number'
      and (type(rt.hostname) ~= 'string' or rt.hostname == vim.uv.os_gethostname())
    then
      hit.pid = rt.pid
      hit.cwd = type(rt.work_dir) == 'string' and rt.work_dir or nil
      hit.started = time.epoch(rt.started_at)
    end
    runtime_cache[chat.path] = hit
  end
  if not hit.pid then
    return nil
  end
  local alive = proc.alive(hit.pid)
  if alive and hit.started then
    -- The process wrote the file, so it cannot be younger than it.
    local born = proc.start_time(hit.pid)
    if born and born > hit.started + 5 then
      alive = false
    end
  end
  if not alive then
    hit.pid = nil
    return nil
  end
  return hit
end

function M.live(chats)
  local out = {}
  local dir = M.home() .. '/sessions'
  for _, e in ipairs(fs.scandir(dir)) do
    -- `<pid>.json`, or `<pid>-<slot>.json` for a process with several sessions.
    local pid = tonumber(e.name:match('^(%d+)%.json$') or e.name:match('^(%d+)%-%x+%.json$'))
    if pid then
      local rec = fs.read_json(dir .. '/' .. e.name)
      if
        type(rec) == 'table'
        and type(rec.sessionId) == 'string'
        and (rec.pid == nil or rec.pid == pid)
        and proc.alive(pid)
        and same_process(pid, rec.procStart)
      then
        local cwd = type(rec.cwd) == 'string' and rec.cwd or nil
        local name = type(rec.name) == 'string' and rec.name ~= '' and rec.name or nil
        out[rec.sessionId] = {
          pid = pid,
          name = name,
          name_explicit = name ~= nil and name ~= derived_name(cwd, rec.sessionId),
          cwd = cwd,
          started = time.epoch(rec.startedAt),
          kind = type(rec.kind) == 'string' and rec.kind or nil,
        }
      end
    end
  end
  -- A session whose registration failed still leaves its runtime file.
  for id, chat in pairs(chats or {}) do
    if not out[id] and chat.path and not chat.subagent then
      local rt = runtime_process(chat)
      if rt then
        out[id] = { pid = rt.pid, cwd = rt.cwd, started = rt.started }
      end
    end
  end
  return out
end

-----------------------------------------------------------------------------
-- Asking Qwen itself
-----------------------------------------------------------------------------

--- What `qwen sessions ps --json` prints: one registry record per line.
---@return table[]? records  nil when the command is missing or fails.
local function cli_sessions()
  local exe = config.provider('qwen').cmd[1]
  if vim.fn.executable(exe) ~= 1 then
    return nil
  end
  local res = async.system(
    { exe, 'sessions', 'ps', '--json' },
    { env = { QWEN_HOME = M.home() }, timeout = 15000, stdin = false }
  )
  if res.code ~= 0 then
    return nil
  end
  local out = {}
  for line in (res.stdout or ''):gmatch('[^\n]+') do
    local rec = fs.decode(line)
    if type(rec) == 'table' and type(rec.sessionId) == 'string' then
      out[#out + 1] = rec
    end
  end
  return out
end

-- The official listing prints the records of the registry that `live`
-- reads. Reading them costs microseconds and the command a Node start, so
-- it is asked only when the registry is not where this reader looks for
-- it, as a newer Qwen may arrange; and by :checkhealth, to compare the two.
M.query_interval = 30000

function M.query()
  if fs.is_dir(M.home() .. '/sessions') then
    return nil
  end
  local records = cli_sessions()
  if not records then
    return nil
  end
  local out = {}
  for _, rec in ipairs(records) do
    local pid = tonumber(rec.pid)
    if pid and proc.alive(pid) then
      local name = type(rec.name) == 'string' and rec.name ~= '' and rec.name or nil
      out[rec.sessionId] = {
        pid = pid,
        name = name,
        cwd = type(rec.cwd) == 'string' and rec.cwd or nil,
        started = time.epoch(rec.startedAt),
        kind = type(rec.kind) == 'string' and rec.kind or nil,
      }
    end
  end
  return out
end

--- For :checkhealth: does Qwen's own listing agree with what is read here?
function M.check()
  local records = cli_sessions()
  if not records then
    return {}
  end
  local theirs, n_theirs = {}, 0
  for _, rec in ipairs(records) do
    if proc.alive(tonumber(rec.pid)) and not theirs[rec.sessionId] then
      theirs[rec.sessionId], n_theirs = true, n_theirs + 1
    end
  end
  local ours, n_ours, agree = M.live({}), 0, true
  for id in pairs(ours) do
    n_ours = n_ours + 1
    agree = agree and theirs[id] == true
  end
  if agree and n_ours == n_theirs then
    return {
      {
        level = 'ok',
        text = ('Qwen: `qwen sessions ps` and its session registry agree (%d running)'):format(
          n_ours
        ),
      },
    }
  end
  return {
    {
      level = 'warn',
      text = ('Qwen: `qwen sessions ps` lists %d running session%s, its registry as read here %d'):format(
        n_theirs,
        n_theirs == 1 and '' or 's',
        n_ours
      ),
      advice = {
        'This version of Qwen may keep its registry differently. Chats still list; which ones are running may be off.',
      },
    },
  }
end

-----------------------------------------------------------------------------
-- Hooks
-----------------------------------------------------------------------------

-- Qwen's hooks follow Claude Code's: the same event names and payload. They
-- are the only way to know that Qwen is blocked on you, since neither its
-- registry nor its transcript says so.
M.hooks = {
  events = {
    SessionStart = function(ev)
      return (ev.src == 'startup' or ev.src == 'resume') and 'start' or nil
    end,
    SessionEnd = 'ended',
    -- Sent before every model call of a turn, not only for what you typed.
    UserPromptSubmit = 'working',
    PermissionRequest = 'waiting',
    Notification = function(ev)
      if ev.type == 'permission_prompt' then
        return 'waiting', 'a permission prompt'
      end
      return nil
    end,
    PostToolUse = 'resolved',
    -- Qwen reports a tool cut short by an interrupt as a failed tool.
    PostToolUseFailure = function(ev)
      return ev.interrupt and 'aborted' or 'resolved'
    end,
    SubagentStop = 'resolved',
    Stop = 'done',
    StopFailure = 'done',
  },
  process = { qwen = true },
  config = function()
    return {
      kind = 'json',
      path = M.home() .. '/settings.json',
      events = {
        'SessionStart',
        'SessionEnd',
        'UserPromptSubmit',
        'PermissionRequest',
        'Notification',
        'PostToolUse',
        'PostToolUseFailure',
        'SubagentStop',
        'Stop',
        'StopFailure',
      },
      timeout = 10,
      note = 'Qwen Code reads its hooks when a session starts: restart the sessions that are running, or open /hooks in them once.',
    }
  end,
}

--- Where the transcript of a running session is, once it has one.
function M.locate(id, live)
  if not live.cwd then
    return nil
  end
  local path = ('%s/projects/%s/chats/%s.jsonl'):format(
    runtime(),
    (live.cwd:gsub('[^%w]', '-')),
    id
  )
  local st = fs.stat(path)
  if st and st.size > 0 then
    return { id = id, path = path, mtime = st.mtime, size = st.size }
  end
end

-----------------------------------------------------------------------------
-- Transcript
-----------------------------------------------------------------------------

--- Output of one function response: what the model was given back, else
--- what the client displayed for the call.
local function response_text(fr, tcr)
  local res = fr.response
  local s
  if type(res) == 'table' then
    if type(res.error) == 'string' then
      s = res.error
    elseif res.output ~= nil or res.content ~= nil or res.text ~= nil or res.result ~= nil then
      s = common.result_text(res)
    end
  elseif type(res) == 'string' then
    s = res
  end
  if (s == nil or s == '') and (fr.id == nil or fr.id == tcr.callId) then
    local shown = tcr.resultDisplay
    if type(shown) == 'string' then
      s = shown
    elseif type(shown) == 'table' and type(shown.fileDiff) == 'string' then
      s = shown.fileDiff
    end
  end
  if s == nil then
    s = res ~= nil and common.result_text(res) or ''
  end
  return s
end

local function convert(r, out)
  local t = r.type
  local ts = time.parse_iso(r.timestamp)
  if t == 'user' then
    local s, kind = user_text(r)
    if s then
      out[#out + 1] = { role = kind == 'prompt' and 'user' or 'system', text = s, time = ts }
    end
  elseif t == 'assistant' then
    -- Consecutive text parts are one reply; a thought or a call ends it.
    local reply = {}
    local function flush()
      local s = table.concat(reply, '')
      if vim.trim(s) ~= '' then
        out[#out + 1] = { role = 'assistant', text = s, time = ts }
      end
      reply = {}
    end
    for _, p in ipairs(parts_of(r)) do
      if type(p) == 'table' then
        if type(p.functionCall) == 'table' then
          flush()
          local name, view = call_view(p.functionCall)
          out[#out + 1] = {
            role = 'tool',
            id = p.functionCall.id,
            name = name,
            summary = view.summary,
            input = view.input,
            lang = view.lang,
            time = ts,
          }
        elseif type(p.text) == 'string' then
          if p.thought then
            flush()
            if p.text ~= '' then
              out[#out + 1] = { role = 'thinking', text = p.text, time = ts }
            end
          else
            reply[#reply + 1] = p.text
          end
        end
      end
    end
    flush()
  elseif t == 'tool_result' then
    local tcr = type(r.toolCallResult) == 'table' and r.toolCallResult or {}
    for _, p in ipairs(parts_of(r)) do
      local fr = type(p) == 'table' and p.functionResponse
      if type(fr) == 'table' then
        local failed = type(fr.response) == 'table' and fr.response.error ~= nil
        if fr.id == nil or fr.id == tcr.callId then
          failed = failed or tcr.status == 'error'
        end
        out[#out + 1] = {
          role = 'tool_result',
          id = fr.id or tcr.callId,
          text = response_text(fr, tcr),
          error = failed,
          time = ts,
        }
      end
    end
  elseif t == 'system' then
    local payload = payload_of(r)
    if r.subtype == 'slash_command' then
      if
        payload.phase == 'invocation'
        and not payload.hiddenInvocation
        and type(payload.rawCommand) == 'string'
        and payload.rawCommand ~= ''
      then
        out[#out + 1] = { role = 'user', text = payload.rawCommand, time = ts }
      end
    elseif r.subtype == 'turn_result' then
      if payload.state == 'cancelled' then
        out[#out + 1] = { role = 'system', text = 'Interrupted.', time = ts }
      elseif payload.state == 'error' then
        out[#out + 1] = { role = 'system', text = 'The request failed.', time = ts }
      end
    else
      local ev = lifecycle(r)
      if ev and ev.phase == 'ended' then
        if ev.outcome == 'cancelled' or ev.outcome == 'interrupted' then
          out[#out + 1] = { role = 'system', text = 'Interrupted by user.', time = ts }
        elseif ev.outcome == 'error' then
          out[#out + 1] = { role = 'system', text = 'The request failed.', time = ts }
        end
      end
    end
  end
end

function M.messages(chat, opts)
  local cursor = opts and opts.cursor or 0
  local out = {}
  local st = chat.path and fs.stat(chat.path)
  if not st then
    return out, cursor
  end
  -- Shorter than what was read before: the file was rewritten. Read it
  -- from the top, and say so, or the caller would add all of it to what
  -- it already has.
  local restarted = false
  if st.size < cursor then
    cursor, restarted = 0, true
  end
  if st.size == cursor then
    return out, cursor, restarted
  end
  local data = fs.read_range(chat.path, cursor, st.size - cursor)
  if not data then
    return out, cursor, restarted
  end
  local n = 0
  local consumed = fs.each_line(data, function(line)
    n = n + 1
    if n % 100 == 0 then
      async.tick()
    end
    local drop, sub = classify(line)
    if drop then
      -- Worth a line in the transcript, not worth decoding its payload.
      if sub == 'chat_compression' then
        out[#out + 1] = {
          role = 'system',
          text = 'Earlier conversation was compressed here.',
          time = time.parse_iso(line:match('"timestamp":"([^"]+)"')),
        }
      end
      return
    end
    local r = fs.decode(line)
    if type(r) == 'table' then
      convert(r, out)
    end
  end)
  return out, cursor + consumed, restarted
end

-----------------------------------------------------------------------------
-- Commands
-----------------------------------------------------------------------------

-- A prompt that the program could take for an option or a command of its
-- own is kept from that (see `common.arg`).
local arg = common.arg

function M.resume_cmd(chat)
  return common.cmd('qwen', '--resume', chat.id)
end

-- A positional prompt runs once and exits; `-i` runs it and stays open.
function M.new_cmd(opts)
  local args = {}
  if opts.id then
    vim.list_extend(args, { '--session-id', opts.id })
  end
  if opts.prompt and opts.prompt ~= '' then
    vim.list_extend(args, { '-i', arg(opts.prompt) })
  end
  return common.cmd('qwen', args)
end

function M.headless_cmd(chat, prompt)
  return common.cmd('qwen', '--resume', chat.id, config.provider('qwen').headless_args, arg(prompt))
end

function M.resume_prompt_cmd(chat, prompt)
  return common.cmd('qwen', '--resume', chat.id, '-i', arg(prompt))
end

return M
