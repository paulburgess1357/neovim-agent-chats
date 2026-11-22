-- Builds a synthetic Claude Code home directory: transcripts shaped like the
-- real ones (record types, field names, key order) with made-up content.

local T = require('helpers.harness')

local M = {}

local counter = 0
local function uuid()
  counter = counter + 1
  return ('%08x-0000-4000-8000-%012x'):format(counter, counter)
end
M.uuid = uuid

local function iso(ts)
  return os.date('!%Y-%m-%dT%H:%M:%S', math.floor(ts)) .. '.000Z'
end
M.iso = iso

local function encode(rec)
  return vim.json.encode(rec)
end

--- Project directory name Claude derives from a working directory.
function M.project_dir(cwd)
  return (cwd:gsub('[^%w]', '-'))
end

---@class tests.ClaudeChat
---@field id string
---@field cwd string
---@field path string
---@field ts number
---@field lines string[]
local Chat = {}
Chat.__index = Chat

--- A conversation record: `{"parentUuid":...}` first, as Claude writes them.
function Chat:_conv(fields)
  self.ts = self.ts + 1
  local parts = {
    '"parentUuid":' .. (self.last and ('"' .. self.last .. '"') or 'null'),
    '"isSidechain":' .. (fields.isSidechain and 'true' or 'false'),
  }
  fields.isSidechain = nil
  fields.uuid = uuid()
  fields.timestamp = iso(self.ts)
  fields.cwd = self.cwd
  fields.sessionId = self.id
  fields.version = '2.1.329'
  fields.gitBranch = self.branch
  fields.entrypoint = 'cli'
  fields.userType = 'external'
  local body = encode(fields)
  self.last = fields.uuid
  self.lines[#self.lines + 1] = '{' .. table.concat(parts, ',') .. ',' .. body:sub(2)
  return self
end

--- A bookkeeping record: `{"type":...}` first.
function Chat:_meta(typ, fields)
  local body = encode(vim.tbl_extend('force', fields or {}, { sessionId = self.id }))
  self.lines[#self.lines + 1] = ('{"type":"%s",%s'):format(typ, body:sub(2))
  return self
end

function Chat:user(text, opts)
  opts = opts or {}
  return self:_conv({
    type = 'user',
    message = { role = 'user', content = text },
    origin = { kind = opts.origin or 'human' },
    promptSource = 'typed',
    isMeta = opts.meta or nil,
  })
end

function Chat:assistant(text, stop)
  return self:_conv({
    type = 'assistant',
    message = {
      role = 'assistant',
      model = 'claude-test-1',
      content = { { type = 'text', text = text } },
      stop_reason = stop or 'end_turn',
    },
  })
end

function Chat:thinking(text)
  return self:_conv({
    type = 'assistant',
    message = {
      role = 'assistant',
      model = 'claude-test-1',
      content = { { type = 'thinking', thinking = text } },
      stop_reason = 'tool_use',
    },
  })
end

--- An assistant tool call. Returns the call id as a second value via `self.tool_id`.
function Chat:tool_use(name, input)
  self.tool_id = 'toolu_' .. uuid():sub(1, 8)
  return self:_conv({
    type = 'assistant',
    message = {
      role = 'assistant',
      model = 'claude-test-1',
      content = { { type = 'tool_use', id = self.tool_id, name = name, input = input or {} } },
      stop_reason = 'tool_use',
    },
  })
end

function Chat:tool_result(output, opts)
  opts = opts or {}
  return self:_conv({
    type = 'user',
    message = {
      role = 'user',
      content = {
        {
          type = 'tool_result',
          tool_use_id = opts.id or self.tool_id,
          content = output,
          is_error = opts.error or nil,
        },
      },
    },
    toolUseResult = { stdout = output },
  })
end

function Chat:turn_done()
  return self:_conv({
    type = 'system',
    subtype = 'turn_duration',
    durationMs = 1200,
    isMeta = false,
  })
end

function Chat:interrupt()
  return self:_conv({
    type = 'user',
    message = {
      role = 'user',
      content = { { type = 'text', text = '[Request interrupted by user]' } },
    },
  })
end

function Chat:title(title)
  return self:_meta('ai-title', { aiTitle = title })
end

function Chat:custom_title(title)
  return self:_meta('custom-title', { customTitle = title })
end

function Chat:last_prompt(prompt)
  return self:_meta('last-prompt', { lastPrompt = prompt })
end

--- Bookkeeping noise of the kind real transcripts are full of.
function Chat:noise(bytes)
  self:_meta('mode', { mode = 'normal' })
  self:_meta('permission-mode', { permissionMode = 'auto' })
  if bytes then
    self:_meta(
      'api-request-blob',
      { hash = 'x', message = { role = 'user', content = string.rep('x', bytes) } }
    )
  end
  return self
end

function Chat:attachment()
  return self:_conv({
    attachment = { type = 'environment', snapshot = { workingDirectory = self.cwd } },
    type = 'attachment',
  })
end

--- A local slash command, as Claude records one (caveat, command, output).
function Chat:local_command(name)
  -- As Claude Code 2.1 writes it: the note before the command is a meta
  -- record, the command and its output are plain user records.
  self:user(
    '<local-command-caveat>Caveat: generated while running local commands.</local-command-caveat>',
    { meta = true }
  )
  self:user(
    ('<command-name>%s</command-name>\n<command-message>%s</command-message>\n<command-args></command-args>'):format(
      name,
      name:gsub('^/', '')
    )
  )
  return self:user('<local-command-stdout>ok</local-command-stdout>')
end

--- Write the transcript. `mtime` defaults to the time of its last record.
function Chat:write(mtime)
  T.write(self.path, self.lines)
  T.touch(self.path, mtime or self.ts)
  return self
end

--- A subagent transcript with its meta file.
function Chat:subagent(id, meta, text)
  local dir = self.path:gsub('%.jsonl$', '') .. '/subagents'
  local sub = setmetatable({
    id = self.id,
    cwd = self.cwd,
    branch = self.branch,
    ts = self.ts,
    lines = {},
    path = ('%s/agent-%s.jsonl'):format(dir, id),
  }, Chat)
  sub:_conv({
    type = 'user',
    isSidechain = true,
    agentId = id,
    message = { role = 'user', content = text or 'Find the files.' },
  })
  sub:_conv({
    type = 'assistant',
    isSidechain = true,
    agentId = id,
    message = {
      role = 'assistant',
      content = { { type = 'text', text = 'Found them.' } },
      stop_reason = 'end_turn',
    },
  })
  T.write(sub.path, sub.lines)
  T.write(
    ('%s/agent-%s.meta.json'):format(dir, id),
    vim.json.encode(meta or { agentType = 'Explore', description = 'Find files', finished = true })
  )
  return sub
end

---@class tests.ClaudeHome
---@field dir string
local Home = {}
Home.__index = Home

--- A chat under this home. `opts`: id, cwd, branch, start (epoch seconds).
---@return tests.ClaudeChat
function Home:chat(opts)
  opts = opts or {}
  local id = opts.id or uuid()
  local cwd = opts.cwd or '/work/project'
  return setmetatable({
    id = id,
    cwd = cwd,
    branch = opts.branch or 'main',
    ts = opts.start or (os.time() - 3600),
    lines = {},
    path = ('%s/projects/%s/%s.jsonl'):format(self.dir, M.project_dir(cwd), id),
  }, Chat)
end

--- A live-session registry record for `pid`. `fields` override the defaults.
function Home:registry(pid, fields)
  local rec = vim.tbl_extend('force', {
    pid = pid,
    sessionId = uuid(),
    cwd = '/work/project',
    startedAt = (os.time() - 60) * 1000,
    version = '2.1.329',
    kind = 'interactive',
    entrypoint = 'cli',
    name = 'project-1a',
    nameSource = 'derived',
    status = 'idle',
    updatedAt = os.time() * 1000,
    statusUpdatedAt = os.time() * 1000,
  }, fields or {})
  T.write(('%s/sessions/%d.json'):format(self.dir, pid), vim.json.encode(rec))
  return rec
end

function Home:unregister(pid)
  vim.fn.delete(('%s/sessions/%d.json'):format(self.dir, pid))
end

--- A new, empty Claude home in a temporary folder, selected in the options.
---@return tests.ClaudeHome
function M.home(extra)
  require('helpers.env').reset()
  local root = T.tmpdir()
  local dir = root .. '/.claude'
  vim.fn.mkdir(dir .. '/projects', 'p')
  vim.fn.mkdir(dir .. '/sessions', 'p')
  local opts = vim.tbl_deep_extend('force', {
    providers = {
      claude = { home = dir },
      codex = { enabled = false },
      qwen = { enabled = false },
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
