-- Claude Code.
--
--   chats       <home>/projects/<encoded cwd>/<session id>.jsonl
--   subagents   <home>/projects/<encoded cwd>/<session id>/subagents/agent-<id>.jsonl
--   running     <home>/sessions/<pid>.json   one per live process, with the
--               session it has open and a status: busy / idle / waiting
--
-- <home> is $CLAUDE_CONFIG_DIR or ~/.claude. The registry status is what
-- makes "needs you" exact for Claude with nothing installed; its hooks (see
-- `M.hooks`) say the same through a documented interface.

local async = require('agent-chats.util.async')
local common = require('agent-chats.providers.common')
local config = require('agent-chats.config')
local fs = require('agent-chats.util.fs')
local proc = require('agent-chats.util.proc')
local text = require('agent-chats.util.text')
local time = require('agent-chats.util.time')

---@type agent_chats.Provider
local M = { name = 'claude', label = 'Claude', preassign_id = true }

function M.home()
  return common.home('claude', 'CLAUDE_CONFIG_DIR', '.claude')
end

function M.available()
  return fs.is_dir(M.home() .. '/projects')
end

--- Whether Claude says itself what a session is doing, hooks or no hooks:
--- it does where it keeps a session registry.
function M.exact()
  return fs.is_dir(M.home() .. '/sessions')
end

-----------------------------------------------------------------------------
-- Reading records
-----------------------------------------------------------------------------

-- Conversation records start with `{"parentUuid":`. Everything that starts
-- with `{"type":` is bookkeeping (API request dumps, file-history snapshots,
-- mode markers, ...), some of it megabytes long, and only these are wanted.
local KEEP =
  { ['ai-title'] = true, ['custom-title'] = true, ['last-prompt'] = true, summary = true }

local function skip(line)
  if line:sub(1, 9) == '{"type":"' then
    local t = line:match('^{"type":"([%w%-_]+)"')
    return not (t and KEEP[t])
  end
  -- Context the harness attached to a turn (environment, tool listings).
  local at = line:find('"attachment":{', 1, true)
  return at ~= nil and at < 240
end

local INTERRUPTED = '[Request interrupted by user'

--- What a `user` record is, and its text.
---@return string? text, "prompt"|"command"|"interrupt"|"caveat"|"system"|nil kind
local function user_text(r, sidechain)
  if r.toolUseResult ~= nil or r.isCompactSummary then
    return nil
  end
  if r.isSidechain and not sidechain then
    return nil
  end
  if r.isMeta then
    -- Not something anyone said. One of them matters all the same: the
    -- note Claude writes before a command it ran itself (/exit, /model),
    -- which says that the command record after it starts no turn.
    local content = r.message and r.message.content
    if type(content) == 'string' and content:find('^%s*<local%-command%-caveat>') then
      return nil, 'caveat'
    end
    return nil
  end
  local content = r.message and r.message.content
  local parts
  if type(content) == 'string' then
    parts = { content }
  elseif type(content) == 'table' then
    parts = {}
    for _, b in ipairs(content) do
      if type(b) == 'table' then
        if b.type == 'tool_result' then
          return nil
        elseif b.type == 'text' and type(b.text) == 'string' then
          parts[#parts + 1] = b.text
        elseif b.type == 'image' then
          parts[#parts + 1] = '[image]'
        end
      end
    end
  else
    return nil
  end
  local s = vim.trim(table.concat(parts, '\n'))
  if s == '' then
    return nil
  end
  if s:sub(1, #INTERRUPTED) == INTERRUPTED then
    return s, 'interrupt'
  end
  if s:find('^<local%-command%-caveat>') then
    return nil, 'caveat'
  end
  if s:find('^<local%-command%-') or s:find('^<bash%-') or s:find('^<task%-notification>') then
    return nil
  end
  local cmd = s:match('^<command%-name>(.-)</command%-name>')
  if cmd then
    local args = s:match('<command%-args>(.-)</command%-args>') or ''
    return vim.trim(cmd .. ' ' .. args), 'command'
  end
  s = s:gsub('<system%-reminder>.-</system%-reminder>', ''):gsub('</?pasted_content[^>]*>', '')
  s = vim.trim(s)
  if s == '' then
    return nil
  end
  -- Turns the harness started on its own (a background task finishing, a
  -- message from another session) are turns, but not something you typed.
  if type(r.origin) == 'table' and r.origin.kind and r.origin.kind ~= 'human' then
    return s, 'system'
  end
  return s, 'prompt'
end

local function has_tool_result(r)
  if r.toolUseResult ~= nil then
    return true
  end
  local content = r.message and r.message.content
  if type(content) == 'table' then
    for _, b in ipairs(content) do
      if type(b) == 'table' and b.type == 'tool_result' then
        return true
      end
    end
  end
  return false
end

-- Tool calls that are the agent asking you something.
local ASKS = { AskUserQuestion = true, ExitPlanMode = true }

-----------------------------------------------------------------------------
-- Discovery and parsing
-----------------------------------------------------------------------------

function M.discover()
  local out = {}
  local root = M.home() .. '/projects'
  for _, proj in ipairs(fs.scandir(root)) do
    if proj.type == 'directory' then
      local dir = root .. '/' .. proj.name
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
    if r.type == 'user' or r.type == 'assistant' then
      return true
    end
  end
  return false
end

local function scan_head(records, out)
  for _, r in ipairs(records) do
    if not out.cwd and type(r.cwd) == 'string' then
      out.cwd = r.cwd
    end
    if not out.origin and type(r.entrypoint) == 'string' then
      out.origin = r.entrypoint
    end
    if not out.created and r.timestamp then
      out.created = time.parse_iso(r.timestamp)
    end
    if not out.first_prompt and r.type == 'user' then
      local s, kind = user_text(r)
      if s and kind == 'prompt' then
        out.first_prompt = text.clip(s, common.PROMPT_BYTES)
      end
    end
    if out.cwd and out.created and out.first_prompt then
      break
    end
  end
end

local function scan_tail(records, out)
  local pending = {} -- tool_use id -> { name, view }
  local pending_n = 0
  local last_tool
  local local_cmd = false
  local ai_title, custom_title, recorded_prompt

  local function clear_pending()
    pending, pending_n, last_tool = {}, 0, nil
  end

  for _, r in ipairs(records) do
    local t = r.type
    if t == 'ai-title' then
      ai_title = r.aiTitle or ai_title
    elseif t == 'custom-title' then
      custom_title = r.customTitle or custom_title
    elseif t == 'summary' then
      ai_title = ai_title or r.summary
    elseif t == 'last-prompt' then
      recorded_prompt = r.lastPrompt or recorded_prompt
    elseif not r.isSidechain and (t == 'user' or t == 'assistant' or t == 'system') then
      local ts = time.parse_iso(r.timestamp)
      if ts then
        out.updated = ts
      end
      if type(r.gitBranch) == 'string' and r.gitBranch ~= '' then
        out.branch = r.gitBranch
      end
      if t == 'user' then
        if has_tool_result(r) then
          local content = r.message and r.message.content
          if type(content) == 'table' then
            for _, b in ipairs(content) do
              if type(b) == 'table' and b.tool_use_id and pending[b.tool_use_id] then
                pending[b.tool_use_id] = nil
                pending_n = pending_n - 1
              end
            end
          end
          if pending_n <= 0 then
            clear_pending()
          end
          out.turn, out.turn_at = 'working', ts
        else
          local s, kind = user_text(r)
          if kind == 'caveat' then
            local_cmd = true
          elseif kind == 'interrupt' then
            clear_pending()
            out.turn, out.turn_at = 'aborted', ts
          elseif kind == 'command' then
            -- A command the client handled itself starts no turn.
            if not local_cmd then
              clear_pending()
              out.turn, out.turn_at, out.turn_began = 'working', ts, ts
            end
            local_cmd = false
          elseif s then
            if kind == 'prompt' then
              out.last_prompt = text.clip(s, common.PROMPT_BYTES)
              recorded_prompt = nil
            end
            clear_pending()
            out.turn, out.turn_at, out.turn_began = 'working', ts, ts
          end
        end
      elseif t == 'assistant' then
        local msg = r.message or {}
        out.model = msg.model or out.model
        for _, b in ipairs(type(msg.content) == 'table' and msg.content or {}) do
          if type(b) == 'table' then
            if b.type == 'text' and type(b.text) == 'string' and vim.trim(b.text) ~= '' then
              out.last_reply = text.clip(b.text, common.REPLY_BYTES)
            elseif b.type == 'tool_use' and b.id then
              if not pending[b.id] then
                pending_n = pending_n + 1
              end
              pending[b.id] = { name = b.name, view = common.tool(b.name, b.input) }
              last_tool = pending[b.id]
            end
          end
        end
        local stop = msg.stop_reason
        if stop == nil or stop == 'tool_use' or stop == 'pause_turn' then
          out.turn, out.turn_at = 'working', ts
        else
          clear_pending()
          out.turn, out.turn_at = 'done', ts
        end
      elseif r.subtype == 'turn_duration' then
        clear_pending()
        out.turn, out.turn_at = 'done', ts
      end
    end
  end

  out.title = custom_title or ai_title
  if recorded_prompt and not out.last_prompt then
    out.last_prompt = text.clip(recorded_prompt, common.PROMPT_BYTES)
  end
  if pending_n > 0 and out.turn == 'working' then
    out.pending_tool = true
    local tool = last_tool or select(2, next(pending))
    if tool then
      out.activity = common.activity(tool.name or 'tool', tool.view)
      out.asking = ASKS[tool.name] or nil
    end
  end
end

function M.parse(entry, prev)
  local out = { turn = 'unknown' }
  local carried = common.carried(prev, entry)
  local head, head_whole
  if carried then
    out = vim.tbl_extend('force', out, carried)
  else
    head, head_whole = common.head(entry.path, entry.size, { skip = skip, enough = has_prompt })
    scan_head(head, out)
  end
  local tail = head_whole and head
    or common.tail(entry.path, entry.size, { skip = skip, enough = has_turn })
  scan_tail(tail, out)
  if prev and prev.path == entry.path then
    -- The tail may no longer reach back to these.
    out.title = out.title or prev.title
    out.last_prompt = out.last_prompt or prev.last_prompt
    out.last_reply = out.last_reply or prev.last_reply
    out.branch = out.branch or prev.branch
    out.model = out.model or prev.model
  end
  if not out.cwd and not out.first_prompt and not out.last_prompt then
    -- Bookkeeping only: a session that never held a conversation.
    return nil
  end
  out.updated = out.updated or entry.mtime
  out.created = out.created or out.updated
  return out
end

-----------------------------------------------------------------------------
-- Running processes
-----------------------------------------------------------------------------

local TURN = { busy = 'working', shell = 'working', idle = 'done', waiting = 'waiting' }

-- A pid can be reused after a crash left its record behind; the record
-- carries the process start time (clock ticks since boot) to tell.
local function same_process(pid, rec)
  local want = tonumber(rec.procStart)
  local st = want and proc.stat(pid)
  if not st then
    return true
  end
  return st.start == want
end

-- Without a registry (a Claude Code that keeps none, or keeps it somewhere
-- else), the processes themselves are the evidence: the session named on a
-- command line, else the chat last written in a process's folder since it
-- started. Good enough to tell running from ended; the turn state then
-- comes from hooks or the transcript.
local function by_process(chats)
  local out, unplaced = {}, {}
  for _, p in ipairs(proc.find({ claude = true })) do
    local id
    for i, a in ipairs(p.argv) do
      local nxt = p.argv[i + 1]
      if
        (a == '--resume' or a == '-r' or a == '--session-id')
        and nxt
        and nxt:match('^' .. text.UUID .. '$')
      then
        id = nxt
      end
    end
    if id then
      out[id] = out[id] or { pid = p.pid, cwd = proc.cwd(p.pid) }
    else
      unplaced[#unplaced + 1] = p
    end
  end
  for _, p in ipairs(unplaced) do
    local cwd = proc.cwd(p.pid)
    local started = proc.start_time(p.pid)
    local best, best_at
    for id, chat in pairs(chats) do
      if cwd and chat.cwd == cwd and not out[chat.id or id] then
        local at = chat.updated or chat.mtime or 0
        if (not started or at >= started - 5) and (not best_at or at > best_at) then
          best, best_at = chat.id or id, at
        end
      end
    end
    if best then
      out[best] = { pid = p.pid, cwd = cwd }
    end
  end
  return out
end

function M.live(chats)
  local out = {}
  local dir = M.home() .. '/sessions'
  if not fs.is_dir(dir) then
    return by_process(chats or {})
  end
  for _, e in ipairs(fs.scandir(dir)) do
    local pid = tonumber(e.name:match('^(%d+)%.json$'))
    if pid then
      local rec = fs.read_json(dir .. '/' .. e.name)
      if
        type(rec) == 'table'
        and type(rec.sessionId) == 'string'
        and proc.alive(pid)
        and same_process(pid, rec)
      then
        out[rec.sessionId] = {
          pid = pid,
          turn = TURN[rec.status],
          name = type(rec.name) == 'string' and rec.name or nil,
          name_explicit = rec.nameSource ~= nil and rec.nameSource ~= 'derived',
          waiting_for = type(rec.waitingFor) == 'string' and rec.waitingFor or nil,
          cwd = type(rec.cwd) == 'string' and rec.cwd or nil,
          started = time.epoch(rec.startedAt),
          turn_at = time.epoch(rec.statusUpdatedAt),
          kind = rec.kind,
        }
      end
    end
  end
  return out
end

-----------------------------------------------------------------------------
-- Hooks
-----------------------------------------------------------------------------

-- Claude Code's hooks are a documented interface; the registry above is
-- not. With them installed (`:Chats hooks install claude`) a permission
-- prompt and the end of a turn are reported the moment they happen.
--
-- Two things no hook says: that you interrupted a turn, and that you
-- answered a prompt. The transcript records the first. The second shows up
-- when the tool finishes (PostToolUse), and at once in the registry, which
-- is why the two are used together.
M.hooks = {
  events = {
    -- A session picked up again starts clean; `compact` and `clear` happen
    -- inside a running one and change nothing.
    SessionStart = function(ev)
      return (ev.src == 'startup' or ev.src == 'resume') and 'start' or nil
    end,
    SessionEnd = 'ended',
    UserPromptSubmit = 'working',
    -- Not every request is for permission: two of Claude's own tools are
    -- how it puts a question to you and how it hands you a plan.
    PermissionRequest = function(ev)
      if ev.tool == 'AskUserQuestion' then
        return 'waiting', 'a question for you'
      elseif ev.tool == 'ExitPlanMode' then
        return 'waiting', 'your go-ahead for its plan'
      end
      return 'waiting'
    end,
    -- Sent a few seconds after a prompt appears and nobody answered. It
    -- also covers prompts PermissionRequest does not (network access,
    -- questions from an MCP server).
    Notification = function(ev)
      if ev.type == 'permission_prompt' then
        return 'waiting', 'a permission prompt'
      elseif ev.type == 'elicitation_dialog' or ev.type == 'elicitation_url_dialog' then
        return 'waiting', 'a question from an MCP server'
      end
      return nil
    end,
    -- An MCP server's question was answered.
    ElicitationResult = 'resolved',
    PostToolUse = 'resolved',
    PostToolUseFailure = function(ev)
      return ev.interrupt and 'aborted' or 'resolved'
    end,
    SubagentStop = 'resolved',
    Stop = 'done',
    StopFailure = 'done',
  },
  process = { claude = true },
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
        'ElicitationResult',
        'PostToolUse',
        'PostToolUseFailure',
        'SubagentStop',
        'Stop',
        'StopFailure',
      },
      timeout = 10,
      note = 'Claude Code reloads its settings by itself: sessions that are already running start reporting at once.',
    }
  end,
}

--- For :checkhealth.
function M.check()
  if fs.is_dir(M.home() .. '/sessions') then
    return {}
  end
  return {
    {
      level = 'info',
      text = ('Claude: no session registry in %s, so running sessions are found by their processes'):format(
        fs.tilde(M.home())
      ),
    },
  }
end

--- Where the transcript of a running session is, once it has one.
function M.locate(id, live)
  if not live.cwd then
    return nil
  end
  local path = ('%s/projects/%s/%s.jsonl'):format(M.home(), (live.cwd:gsub('[^%w]', '-')), id)
  local st = fs.stat(path)
  if st and st.size > 0 then
    return { id = id, path = path, mtime = st.mtime, size = st.size }
  end
end

-----------------------------------------------------------------------------
-- Subagents
-----------------------------------------------------------------------------

function M.subagents(chat)
  local out = {}
  if not chat.path then
    return out
  end
  local dir = chat.path:gsub('%.jsonl$', '') .. '/subagents'
  for _, f in ipairs(fs.scandir(dir)) do
    local id = f.name:match('^agent%-(.+)%.jsonl$')
    if id then
      local path = dir .. '/' .. f.name
      local st = fs.stat(path)
      local meta = fs.read_json(dir .. '/agent-' .. id .. '.meta.json') or {}
      if st then
        local finished = meta.finished == true
        out[#out + 1] = {
          key = chat.key .. '/' .. id,
          provider = 'claude',
          id = id,
          parent = chat.key,
          subagent = true,
          agent_type = type(meta.agentType) == 'string' and meta.agentType or nil,
          title = type(meta.description) == 'string' and meta.description or nil,
          path = path,
          mtime = st.mtime,
          size = st.size,
          cwd = chat.cwd,
          branch = chat.branch,
          updated = st.mtime,
          created = st.mtime,
          turn = finished and 'done' or 'working',
          live = not finished and chat.live == true,
        }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.updated < b.updated
  end)
  return out
end

-----------------------------------------------------------------------------
-- Transcript
-----------------------------------------------------------------------------

local function convert(r, out, sidechain)
  local t = r.type
  if r.isSidechain and not sidechain then
    return
  end
  local ts = time.parse_iso(r.timestamp)
  if t == 'user' then
    if r.isCompactSummary then
      out[#out + 1] =
        { role = 'system', text = 'Earlier conversation was compacted here.', time = ts }
      return
    end
    local content = r.message and r.message.content
    if has_tool_result(r) and type(content) == 'table' then
      for _, b in ipairs(content) do
        if type(b) == 'table' and b.type == 'tool_result' then
          out[#out + 1] = {
            role = 'tool_result',
            id = b.tool_use_id,
            text = common.result_text(b.content),
            error = b.is_error == true,
            time = ts,
          }
        end
      end
      return
    end
    local s, kind = user_text(r, sidechain)
    if kind == 'interrupt' then
      out[#out + 1] = { role = 'system', text = 'Interrupted by user.', time = ts }
    elseif s then
      out[#out + 1] = {
        role = kind == 'system' and 'system' or 'user',
        text = s,
        time = ts,
        -- `/exit`, `/model`: typed, but to the agent's program, not said to it.
        command = kind == 'command' or nil,
      }
    end
  elseif t == 'assistant' then
    local msg = r.message or {}
    for _, b in ipairs(type(msg.content) == 'table' and msg.content or {}) do
      if type(b) == 'table' then
        if b.type == 'text' and type(b.text) == 'string' and vim.trim(b.text) ~= '' then
          out[#out + 1] = { role = 'assistant', text = b.text, time = ts }
        elseif b.type == 'thinking' and type(b.thinking) == 'string' and b.thinking ~= '' then
          out[#out + 1] = { role = 'thinking', text = b.thinking, time = ts }
        elseif b.type == 'tool_use' then
          local view = common.tool(b.name, b.input)
          out[#out + 1] = {
            role = 'tool',
            id = b.id,
            name = b.name,
            summary = view.summary,
            input = view.input,
            lang = view.lang,
            time = ts,
          }
        end
      end
    end
  elseif t == 'system' and r.subtype == 'away_summary' and type(r.content) == 'string' then
    out[#out + 1] = { role = 'system', text = r.content, time = ts }
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
    if skip(line) then
      return
    end
    local r = fs.decode(line)
    if type(r) == 'table' then
      convert(r, out, chat.subagent)
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
  return common.cmd('claude', '--resume', chat.id)
end

function M.new_cmd(opts)
  local args = {}
  if opts.id then
    vim.list_extend(args, { '--session-id', opts.id })
  end
  if opts.prompt and opts.prompt ~= '' then
    args[#args + 1] = arg(opts.prompt)
  end
  return common.cmd('claude', args)
end

function M.headless_cmd(chat, prompt)
  return common.cmd(
    'claude',
    '-p',
    '--resume',
    chat.id,
    config.provider('claude').headless_args,
    arg(prompt)
  )
end

function M.resume_prompt_cmd(chat, prompt)
  return common.cmd('claude', '--resume', chat.id, arg(prompt))
end

return M
