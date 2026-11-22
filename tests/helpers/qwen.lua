-- Builds a synthetic Qwen Code home directory: chats shaped like the real
-- ones (record types, field names, key order) with made-up content.

local T = require('helpers.harness')

local M = {}

local counter = 0
local function uuid()
  counter = counter + 1
  return ('%08x-0000-4000-9000-%012x'):format(counter, counter)
end
M.uuid = uuid

local function iso(ts)
  return os.date('!%Y-%m-%dT%H:%M:%S', math.floor(ts)) .. '.000Z'
end
M.iso = iso

local function encode(v)
  return vim.json.encode(v)
end

--- Project directory name Qwen derives from a working directory.
function M.project_dir(cwd)
  return (cwd:gsub('[^%w]', '-'))
end

--- `<boot id>:<start ticks>` of a process, as Qwen records it (Linux only).
function M.proc_token(pid)
  local boot = io.open('/proc/sys/kernel/random/boot_id', 'r')
  local st = require('agent-chats.util.proc').stat(pid)
  if not boot or not st then
    if boot then
      boot:close()
    end
    return nil
  end
  local id = vim.trim(boot:read('*a'))
  boot:close()
  return ('%s:%d'):format(id, st.start), id, st.start
end

---@class tests.QwenChat
---@field id string
---@field cwd string
---@field path string
---@field ts number
---@field lines string[]
---@field call_id string?
local Chat = {}
Chat.__index = Chat

--- One record. The leading fields are written in the order Qwen writes them
--- (uuid, parentUuid, sessionId, timestamp, type, provenance, cwd, version,
--- gitBranch, subtype), the rest in whatever order the encoder picks.
function Chat:_rec(typ, fields, opts)
  opts = opts or {}
  self.ts = self.ts + 1
  local id = uuid()
  local parts = {
    '"uuid":' .. encode(id),
    '"parentUuid":' .. (self.last and encode(self.last) or 'null'),
    '"sessionId":' .. encode(self.id),
    '"timestamp":' .. encode(iso(self.ts)),
    '"type":' .. encode(typ),
    '"provenance":' .. encode(opts.provenance or 'system'),
    '"cwd":' .. encode(self.cwd),
    '"version":"0.26.4"',
  }
  if self.branch and typ ~= 'system' then
    parts[#parts + 1] = '"gitBranch":' .. encode(self.branch)
  end
  if opts.subtype then
    parts[#parts + 1] = '"subtype":' .. encode(opts.subtype)
  end
  local line = '{' .. table.concat(parts, ',')
  if fields and next(fields) ~= nil then
    line = line .. ',' .. encode(fields):sub(2)
  else
    line = line .. '}'
  end
  self.last = id
  self.lines[#self.lines + 1] = line
  return self
end

function Chat:_prompt_id()
  return ('%s########%d'):format(self.id, self.turns)
end

--- A prompt. `opts`: provenance, mid (typed while the agent works),
--- display (text the client showed instead of what was sent).
function Chat:user(text, opts)
  opts = opts or {}
  if not opts.mid then
    self.turns = self.turns + 1
  end
  local fields = {
    executionContext = { modelId = 'qwen-test-1', authType = 'openai', approvalMode = 'default' },
    message = { role = 'user', parts = { { text = text } } },
    promptId = self:_prompt_id(),
  }
  if opts.mid then
    fields.systemPayload = { displayText = opts.display or text }
  elseif opts.display then
    fields.systemPayload = { displayText = opts.display, hookContext = 'context' }
  end
  return self:_rec('user', fields, {
    provenance = opts.provenance or 'real_user',
    subtype = opts.mid and 'mid_turn_user_message' or nil,
  })
end

--- A request start event. `opts.subagent` marks it as a background subagent's.
function Chat:request_start(opts)
  opts = opts or {}
  self.exec = uuid()
  self.exec_started = self.ts * 1000
  self.exec_sub = opts.subagent
  local ev = {
    v = 1,
    kind = 'request',
    executionId = self.exec,
    sessionId = self.id,
    promptId = opts.subagent and ('%s#%s#0'):format(self.id, opts.subagent) or self:_prompt_id(),
    model = 'qwen-test-1',
    startedAt = self.exec_started,
    phase = 'started',
    subagentId = opts.subagent,
    ['event.name'] = 'request_lifecycle',
  }
  return self:_rec('system', { systemPayload = { uiEvent = ev } }, { subtype = 'ui_telemetry' })
end

--- The matching end event, followed by the API-response telemetry Qwen
--- writes after every request.
function Chat:request_end(outcome, opts)
  opts = opts or {}
  local ev = {
    v = 1,
    kind = 'request',
    executionId = self.exec,
    sessionId = self.id,
    promptId = self.exec_sub and ('%s#%s#0'):format(self.id, self.exec_sub) or self:_prompt_id(),
    model = 'qwen-test-1',
    startedAt = self.exec_started,
    phase = 'ended',
    endedAt = self.ts * 1000 + 500,
    durationMs = 500,
    outcome = outcome or 'success',
    subagentId = self.exec_sub,
    ['event.name'] = 'request_lifecycle',
  }
  self:_rec('system', { systemPayload = { uiEvent = ev } }, { subtype = 'ui_telemetry' })
  if (outcome or 'success') == 'success' then
    self:_rec('system', {
      systemPayload = {
        uiEvent = {
          ['event.name'] = 'qwen-code.api_response',
          response_id = 'chatcmpl-1',
          status_code = 200,
          response_text = string.rep('r', opts.bytes or 40),
        },
      },
    }, { subtype = 'ui_telemetry' })
  end
  return self
end

--- A whole request: start, end, telemetry.
function Chat:request(outcome, opts)
  return self:request_start(opts):request_end(outcome, opts)
end

--- A reply. `opts.thought` adds a thought part before the text.
function Chat:assistant(text, opts)
  opts = opts or {}
  local parts = {}
  if opts.thought then
    parts[#parts + 1] = { text = opts.thought, thought = true }
  end
  parts[#parts + 1] = { text = text }
  return self:_rec('assistant', {
    model = 'qwen-test-1',
    message = { role = 'model', parts = parts },
    usageMetadata = { promptTokenCount = 10, candidatesTokenCount = 5, totalTokenCount = 15 },
    contextWindowSize = 1000000,
  }, { provenance = opts.provenance or 'assistant_output' })
end

--- A function call. The call id is left in `self.call_id`. `opts.no_id`
--- writes the call without one, as some models do.
function Chat:tool_call(name, args, opts)
  opts = opts or {}
  self.call_id = 'call_' .. uuid():sub(1, 8)
  self.call_name = name
  local fc = { name = name, args = args or vim.empty_dict() }
  if not opts.no_id then
    fc.id = self.call_id
  end
  local parts = {}
  if opts.thought then
    parts[#parts + 1] = { text = opts.thought, thought = true }
  end
  if opts.text then
    parts[#parts + 1] = { text = opts.text }
  end
  parts[#parts + 1] = { functionCall = fc }
  return self:_rec('assistant', {
    model = 'qwen-test-1',
    message = { role = 'model', parts = parts },
  }, { provenance = 'assistant_output' })
end

--- The result of a call (the last one, unless `opts.id`). `opts.error`
--- records a failure, `opts.display` what the client showed, `opts.no_id`
--- writes it without ids.
function Chat:tool_result(output, opts)
  opts = opts or {}
  local id = opts.id or self.call_id
  local fr = {
    name = opts.name or self.call_name or 'tool',
    response = opts.error and { error = output } or { output = output },
  }
  local tcr = {
    status = opts.error and 'error' or 'success',
    resultDisplay = opts.display or output,
    executionStatus = opts.error and 'not_started' or 'success',
  }
  if not opts.no_id then
    fr.id = id
    tcr.callId = id
  end
  return self:_rec('tool_result', {
    message = { role = 'user', parts = { { functionResponse = fr } } },
    toolCallResult = tcr,
  }, { provenance = 'tool_result' })
end

--- A complete turn as Qwen records one: prompt, request, reply, and the
--- memory-extractor subagent's request that trails every turn.
function Chat:turn(prompt, reply)
  self:user(prompt):snapshots():request():assistant(reply, { thought = 'Thinking it over.' })
  return self:request(
    'success',
    { subagent = 'managed-auto-memory-extractor-' .. uuid():sub(1, 8) }
  )
end

function Chat:slash(command, payload)
  return self:_rec('system', {
    systemPayload = vim.tbl_extend(
      'force',
      { phase = 'invocation', rawCommand = command, sentToModel = false, hiddenInvocation = false },
      payload or {}
    ),
  }, { subtype = 'slash_command' })
end

function Chat:title(title, source)
  return self:_rec(
    'system',
    { systemPayload = { customTitle = title, titleSource = source or 'auto' } },
    { subtype = 'custom_title' }
  )
end

function Chat:parent(id)
  return self:_rec(
    'system',
    { systemPayload = { parentSessionId = id } },
    { subtype = 'parent_session' }
  )
end

function Chat:source(source_type)
  return self:_rec(
    'system',
    { systemPayload = { sourceType = source_type } },
    { subtype = 'session_source' }
  )
end

--- The record `qwen serve` writes when it settles a turn.
function Chat:turn_result(state)
  return self:_rec('system', {
    systemPayload = {
      promptId = self:_prompt_id(),
      state = state,
      stopReason = state,
      endedAt = self.ts * 1000,
    },
  }, { subtype = 'turn_result' })
end

function Chat:compression(bytes)
  return self:_rec('system', {
    systemPayload = { compressedHistory = { string.rep('h', bytes or 200) } },
  }, { subtype = 'chat_compression' })
end

--- The snapshots Qwen writes after each prompt.
function Chat:snapshots()
  self:_rec(
    'system',
    { systemPayload = { snapshot = { type = 'attribution-snapshot', version = 1 } } },
    {
      subtype = 'attribution_snapshot',
    }
  )
  self:_rec('system', { systemPayload = { snapshots = {} } }, { subtype = 'file_history_snapshot' })
  return self
end

--- Bookkeeping noise of the kind real chats are full of: `bytes` of it in
--- one telemetry record.
function Chat:noise(bytes)
  self:snapshots()
  return self:_rec('system', {
    systemPayload = {
      uiEvent = {
        ['event.name'] = 'qwen-code.api_response',
        response_text = string.rep('x', bytes or 100),
      },
    },
  }, { subtype = 'ui_telemetry' })
end

--- Write the chat. `mtime` defaults to the time of its last record.
function Chat:write(mtime)
  T.write(self.path, self.lines)
  T.touch(self.path, mtime or self.ts)
  return self
end

--- The `<id>.runtime.json` Qwen keeps next to a chat.
function Chat:runtime(pid, fields)
  local rec = vim.tbl_extend('force', {
    schema_version = 1,
    pid = pid,
    session_id = self.id,
    work_dir = self.cwd,
    hostname = vim.uv.os_gethostname(),
    started_at = os.time(),
    qwen_version = '0.26.4',
  }, fields or {})
  T.write((self.path:gsub('%.jsonl$', '.runtime.json')), encode(rec))
  return rec
end

--- What the provider's `live()` is handed for this chat.
function Chat:as_chat()
  local st = assert(vim.uv.fs_stat(self.path))
  return {
    key = 'qwen:' .. self.id,
    provider = 'qwen',
    id = self.id,
    path = self.path,
    cwd = self.cwd,
    mtime = st.mtime.sec + st.mtime.nsec / 1e9,
    size = st.size,
  }
end

---@class tests.QwenHome
---@field dir string
local Home = {}
Home.__index = Home

--- A chat under this home. `opts`: id, cwd, branch, start (epoch seconds).
---@return tests.QwenChat
function Home:chat(opts)
  opts = opts or {}
  local id = opts.id or uuid()
  local cwd = opts.cwd or '/work/project'
  return setmetatable({
    id = id,
    cwd = cwd,
    branch = opts.branch,
    ts = opts.start or (os.time() - 3600),
    turns = -1,
    lines = {},
    path = ('%s/projects/%s/chats/%s.jsonl'):format(self.dir, M.project_dir(cwd), id),
  }, Chat)
end

--- A session-registry record for `pid`. `fields` override the defaults;
--- `slot` names the file `<pid>-<slot>.json`.
function Home:registry(pid, fields, slot)
  local rec = vim.tbl_extend('force', {
    schemaVersion = 1,
    pid = pid,
    pidNs = 4026531836,
    sessionId = uuid(),
    cwd = '/work/project',
    startedAt = (os.time() - 60) * 1000,
    qwenVersion = '0.26.4',
    kind = 'tui',
    ipcPath = '/tmp/qwen-ipc.sock',
    ipcToken = 'secret-ipc-token',
  }, fields or {})
  if rec.name == nil then
    rec.name = ('%s-%s'):format(vim.fs.basename(rec.cwd), vim.fn.sha256(rec.sessionId):sub(1, 2))
  end
  local file = slot and ('%d-%s.json'):format(pid, slot) or ('%d.json'):format(pid)
  T.write(('%s/sessions/%s'):format(self.dir, file), encode(rec))
  return rec
end

function Home:unregister(pid)
  vim.fn.delete(('%s/sessions/%d.json'):format(self.dir, pid))
end

--- A new, empty Qwen home in a temporary folder, selected in the options.
---@return tests.QwenHome
function M.home(extra)
  require('helpers.env').reset()
  local root = T.tmpdir()
  local dir = root .. '/.qwen'
  vim.fn.mkdir(dir .. '/projects', 'p')
  vim.fn.mkdir(dir .. '/sessions', 'p')
  local opts = vim.tbl_deep_extend('force', {
    providers = {
      claude = { enabled = false },
      codex = { enabled = false },
      -- No command of this name exists: nothing here may run the real one.
      qwen = { home = dir, cmd = { 'qwen-is-not-installed-in-tests' } },
      opencode = { enabled = false },
    },
    watch = { enabled = false },
    notify = { enabled = false },
    -- The introduction is for a first look at the board, not for a test of
    -- what the pane shows.
    board = { intro = false },
    hooks = { dir = root .. '/events', script = root .. '/share/agent-chats-hook.sh' },
    state_file = root .. '/state.json',
    cache_file = false,
  }, extra or {})
  require('agent-chats.config').setup(opts)
  return setmetatable({ dir = dir, root = root }, Home)
end

return M
